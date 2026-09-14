import Foundation
import Darwin

private final class TCPStream: BillingStream {
    let descriptor: Int32
    init(endpoint: BillingEndpoint, timeout: TimeInterval) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LauncherError.message("无法建立网络连接。") }
        var configured = false
        defer { if !configured { close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else {
            throw LauncherError.message("官方配置的计费服务器地址无效。")
        }
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout.size(ofValue: noSig)))
        var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            if errno != EINPROGRESS { throw LauncherError.message("无法连接所选大区的计费服务器。") }
            var state = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&state, 1, Int32(timeout * 1000)) > 0,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw LauncherError.message("连接官方计费服务器超时。")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        descriptor = fd; configured = true
    }
    deinit { close(descriptor) }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw LauncherError.message("发送认证请求失败或超时。") }
                sent += n
            }
        }
    }
    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= 65536 else { throw LauncherError.message("服务器数据长度无效。") }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { raw in
            var received = 0
            while received < count {
                let n = recv(descriptor, raw.baseAddress!.advanced(by: received), count - received, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw LauncherError.message(n == 0 ? "官方服务器关闭了连接。" : "等待官方计费服务器响应超时。") }
                received += n
            }
        }
        return Data(bytes)
    }
    func u32() throws -> UInt32 { var reader = PacketReader(try read(4)); return try reader.u32() }
    func text(maximum: Int) throws -> String {
        let count = try u32()
        guard count > 0, count <= maximum, let text = String(data: try read(Int(count)), encoding: .ascii) else { throw LauncherError.message("服务器握手字段无效。") }
        return text
    }
}

private final class BillingConnection {
    let stream: any BillingStream
    let cipher: LegacyCipher
    var pending = Data()
    init(endpoint: BillingEndpoint, timeout: TimeInterval, bridge: WineNetworkConfiguration?) throws {
        if let bridge { stream = try WineNetworkStream(endpoint: endpoint, configuration: bridge, timeout: timeout) }
        else { stream = try TCPStream(endpoint: endpoint, timeout: timeout) }
        var hello = Data(); hello.appendBE(1); hello.appendBE(8)
        try stream.write(hello)
        guard try stream.u32() == 0 else { throw LauncherError.message("官方服务器拒绝了协议握手。") }
        let generator = try stream.text(maximum: 62), prime = try stream.text(maximum: 1022), publicKey = try stream.text(maximum: 1022)
        let exchange = try LegacyDH.exchange(generator: generator, prime: prime, publicKey: publicKey)
        cipher = try LegacyCipher(key: exchange.secret)
        var answer = Data(); answer.appendBE(UInt32(exchange.publicKey.utf8.count)); answer.append(contentsOf: exchange.publicKey.utf8)
        try stream.write(answer)
    }
    func send(_ body: Data) throws { try stream.write(cipher.encode(body)) }
    func message() throws -> Data {
        for _ in 0 ..< 32 {
            let bytes = Array(pending)
            if bytes.count >= 2 {
                let size = Int(bytes[0]) << 8 | Int(bytes[1])
                guard size > 0, size <= 16384 else { throw LauncherError.message("服务器消息长度无效。") }
                if bytes.count >= size + 2 {
                    let message = Data(bytes[2 ..< size + 2]); pending = Data(bytes.dropFirst(size + 2))
                    return message
                }
            }
            let encryptedLength = try stream.u32(), plainLength = try stream.u32()
            guard encryptedLength > 0, encryptedLength <= 32760, encryptedLength % 8 == 0, plainLength <= encryptedLength else { throw LauncherError.message("服务器加密帧格式无效。") }
            pending.append(try cipher.decode(encrypted: stream.read(Int(encryptedLength)), originalLength: Int(plainLength)))
            guard pending.count <= 65536 else { throw LauncherError.message("服务器消息超出缓冲限制。") }
        }
        throw LauncherError.message("未收到完整的服务器认证消息。")
    }
}

public enum NativeAuthenticator {
    /// Credential-free ping verifies DH + both encryption directions.
    public static func probe(endpoint: BillingEndpoint, timeout: TimeInterval = 8, bridge: WineNetworkConfiguration? = nil) throws {
        let connection = try BillingConnection(endpoint: endpoint, timeout: timeout, bridge: bridge)
        var request = Data([1]); request.appendBE(0); request.appendBE(123456)
        try connection.send(request)
        var response = PacketReader(try connection.message())
        guard response.remaining == 9, try response.byte() == 2, try response.u32() == 0 else { throw LauncherError.message("加密心跳校验未通过。") }
        _ = try response.u32() // Server heartbeat value; it does not echo the request payload.
    }
    public static func authenticate(username: String, password: String, endpoint: BillingEndpoint, timeout: TimeInterval = 12, bridge: WineNetworkConfiguration? = nil) throws -> AuthenticatedSession {
        var request = try LegacyProtocol.login(username: username, password: password)
        defer { request.resetBytes(in: request.startIndex ..< request.endIndex) }
        let connection = try BillingConnection(endpoint: endpoint, timeout: timeout, bridge: bridge)
        try connection.send(request)
        return try LegacyProtocol.parseLogin(connection.message(), endpoint: endpoint)
    }
}

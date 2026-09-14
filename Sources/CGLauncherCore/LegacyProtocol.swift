import Foundation
import CommonCrypto
import Security

struct PacketReader {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - offset }
    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw LauncherError.message("服务器数据不完整。") }
        defer { offset += count }
        return Array(bytes[offset ..< offset + count])
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func u32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func length(maximum: Int) throws -> Int {
        let first = try byte()
        let value: UInt32
        if first < 253 { value = UInt32(first) }
        else if first == 253 { value = try u32() }
        else { throw LauncherError.message("不支持的服务器字段长度。") }
        guard value <= maximum else { throw LauncherError.message("服务器字段超出长度限制。") }
        return Int(value)
    }
    mutating func blob(maximum: Int) throws -> [UInt8] { try take(length(maximum: maximum)) }
    mutating func intArray() throws -> [Int32] {
        let count = try length(maximum: 64)
        return try (0 ..< count).map { _ in Int32(bitPattern: try u32()) }
    }
}

extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
}

public struct GameAccount: Identifiable, Sendable {
    public let id: String
    public let status: Int32
    public let entitlement: Int32
    public let restriction: Int32
    public var canLaunch: Bool { (status == 0 || status == -4) && (entitlement == 0 || restriction == 0) }
    public var statusText: String { canLaunch ? "可进入" : "官方返回不可用" }
}

public struct AuthenticatedSession: Sendable {
    public let accounts: [GameAccount]
    public let authenticatedAt: Date
    let token: [UInt8]
    let serverStamp: UInt32
    let endpoint: BillingEndpoint?
    public func handoff(for account: GameAccount) throws -> Data {
        guard accounts.contains(where: { $0.id == account.id && $0.canLaunch }),
              account.canLaunch, Date().timeIntervalSince(authenticatedAt) < 300 else {
            throw LauncherError.message("账号不可用或本次登录已过期，请重新验证。")
        }
        // The official callback copies the blob into a char[33], appends NUL,
        // and then appends it as a C string. Ignore any bytes after its first NUL.
        let tokenBytes = token.prefix(while: { $0 != 0 })
        guard !account.id.isEmpty, account.id.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 58 }) else {
            throw LauncherError.message("服务器返回的游戏账号格式无法交接。")
        }
        guard token.count <= 32, !tokenBytes.isEmpty else {
            throw LauncherError.message("服务器返回的认证令牌为空或超出长度限制，请重新登录。")
        }
        // This is a legacy byte string, not Unicode. Decoding/re-encoding a binary
        // token would replace invalid UTF-8 bytes and invalidate the official ticket.
        var data = Data("gid:\(account.id) glt:".utf8)
        data.append(contentsOf: tokenBytes)
        data.append(contentsOf: ":\(String(serverStamp &+ 0x80000000, radix: 32)) ".utf8)
        guard data.count < 256 else { throw LauncherError.message("认证交接数据超出游戏限制。") }
        return data
    }
}

enum LegacyProtocol {
    static func login(username: String, password: String, sequence: UInt32 = 0) throws -> Data {
        let user = Array(username.utf8), pass = Array(password.utf8)
        guard !user.isEmpty, !pass.isEmpty, user.count <= 18, pass.count <= 18,
              user.count + pass.count <= 34,
              user.allSatisfy({ $0 > 32 && $0 < 127 }), pass.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
            throw LauncherError.message("请输入官方通行证账号和密码：各不超过 18 个 ASCII 字符，合计不超过 34 个字符。")
        }
        var body = Data([10]); body.appendBE(sequence)
        body.append(UInt8(user.count)); body.append(contentsOf: user)
        body.append(UInt8(pass.count)); body.append(contentsOf: pass)
        body.appendBE(11) // Game code from the installed official GameList.xml.
        return body
    }
    static func parseLogin(_ data: Data, expectedSequence: UInt32 = 0, endpoint: BillingEndpoint? = nil) throws -> AuthenticatedSession {
        var reader = PacketReader(data)
        guard try reader.byte() == 11, try reader.u32() == expectedSequence else {
            throw LauncherError.message("服务器返回了未预期的认证消息。")
        }
        let status = Int32(bitPattern: try reader.u32())
        guard status == 0 else { throw LauncherError.message(errorMessage(status)) }
        let token = try reader.blob(maximum: 32)
        let count = try reader.length(maximum: 64)
        var ids: [String] = []
        for _ in 0 ..< count {
            let id = try reader.blob(maximum: 41)
            guard id.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw LauncherError.message("游戏 ID 编码无法识别。") }
            ids.append(String(decoding: id, as: UTF8.self))
        }
        let arrays = try (0 ..< 5).map { _ in try reader.intArray() }
        guard arrays.allSatisfy({ $0.count == count }), Set(ids).count == count else {
            throw LauncherError.message("服务器账号列表结构与已分析版本不一致。")
        }
        let stamp = try reader.u32()
        _ = try reader.u32()
        guard reader.remaining == 0 else { throw LauncherError.message("服务器响应包含未识别字段。") }
        let accounts = ids.indices.map { GameAccount(id: ids[$0], status: arrays[1][$0], entitlement: arrays[2][$0], restriction: arrays[4][$0]) }
        return AuthenticatedSession(accounts: accounts, authenticatedAt: Date(), token: token, serverStamp: stamp, endpoint: endpoint)
    }
    static func errorMessage(_ code: Int32) -> String {
        switch code {
        case -11, -32: return "通行证账号或密码不正确，请检查后重试。"
        case -1: return "通行证账号含有官方不接受的字符。"
        case -2, -100: return "官方计费服务连接失败，请稍后再试。"
        case -3: return "官方计费服务器繁忙，请稍后再试。"
        case -12: return "该账号已被停权，请联系官方客服。"
        case -15: return "该账号已被锁定，请联系官方客服。"
        case -25: return "该账号受官方未成年人游戏时段限制。"
        default: return "官方认证未通过（返回码 \(code)）。"
        }
    }
}

struct LegacyCipher {
    private let key: [UInt8]
    init(key: [UInt8]) throws {
        guard key.count == 8 else { throw LauncherError.message("握手密钥长度无效。") }
        self.key = key
    }
    private func transform(_ source: [UInt8], decrypt: Bool) throws -> [UInt8] {
        guard !source.isEmpty, source.count % 8 == 0 else { throw LauncherError.message("加密数据块长度无效。") }
        func swapWords(_ b: [UInt8]) -> [UInt8] {
            stride(from: 0, to: b.count, by: 4).flatMap { Array(b[$0 ..< $0 + 4].reversed()) }
        }
        let input = swapWords(source)
        var output = [UInt8](repeating: 0, count: source.count)
        var moved = 0
        let status = CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmBlowfish), CCOptions(kCCOptionECBMode), key, key.count, nil, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess, moved == input.count else { throw LauncherError.message("认证加密处理失败。") }
        return swapWords(output)
    }
    func encode(_ body: Data) throws -> Data {
        guard body.count <= 32000 else { throw LauncherError.message("请求过长。") }
        var plain = [UInt8(body.count >> 8), UInt8(truncatingIfNeeded: body.count)] + Array(body)
        let count = plain.count
        plain.append(contentsOf: repeatElement(0, count: (count / 8 + 1) * 8 - count))
        var record = Data(); record.appendBE(UInt32(plain.count)); record.appendBE(UInt32(count))
        record.append(contentsOf: try transform(plain, decrypt: false))
        return record
    }
    func decode(encrypted: Data, originalLength: Int) throws -> Data {
        guard originalLength >= 0, originalLength <= encrypted.count, encrypted.count <= 32760 else { throw LauncherError.message("服务器加密包长度无效。") }
        return Data(try transform(Array(encrypted), decrypt: true).prefix(originalLength))
    }
}

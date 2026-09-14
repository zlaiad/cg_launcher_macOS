import Foundation
import Darwin

public struct WineNetworkConfiguration: Sendable {
    public let installation: Installation
    public let helper: URL
    public init(installation: Installation, helper: URL) {
        self.installation = installation; self.helper = helper
    }
}

protocol BillingStream: AnyObject {
    func write(_ data: Data) throws
    func read(_ count: Int) throws -> Data
}

extension BillingStream {
    func u32() throws -> UInt32 { var reader = PacketReader(try read(4)); return try reader.u32() }
    func text(maximum: Int) throws -> String {
        let count = try u32()
        guard count > 0, count <= maximum, let text = String(data: try read(Int(count)), encoding: .ascii) else {
            throw LauncherError.message("服务器握手字段无效。")
        }
        return text
    }
}

/// CrossOver transport follows the same network path as the running Windows game.
/// Pipes contain encrypted protocol records; credentials and tickets never enter argv.
final class WineNetworkStream: BillingStream {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let deadline: TimeInterval

    init(endpoint: BillingEndpoint, configuration: WineNetworkConfiguration, timeout: TimeInterval) throws {
        deadline = ProcessInfo.processInfo.systemUptime + timeout + 10
        guard FileManager.default.isExecutableFile(atPath: configuration.installation.wine.path),
              FileManager.default.fileExists(atPath: configuration.helper.path),
              configuration.installation.regions.contains(where: { $0.billing.contains(endpoint) }) else {
            throw LauncherError.message("CrossOver 网络桥接程序或官方服务器配置无效。")
        }
        process.executableURL = configuration.installation.wine
        process.arguments = configuration.installation.wineArguments(executable: configuration.helper) + [endpoint.host, String(endpoint.port)]
        process.currentDirectoryURL = configuration.installation.gameDirectory
        process.environment = configuration.installation.wineEnvironment()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            for handle in [input.fileHandleForWriting, output.fileHandleForReading] {
                let fd = handle.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            }
            guard try read(4) == Data("CGN1".utf8) else { throw LauncherError.message("CrossOver 网络桥接握手失败。") }
        } catch { cleanup(); throw error }
    }
    deinit { cleanup() }
    private func cleanup() {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        // Closing stdin ends the helper and its socket without touching other Wine apps.
    }
    private func ready(_ fd: Int32, events: Int16) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw LauncherError.message("等待官方计费服务器响应超时。") }
            var state = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&state, 1, Int32(ceil(remaining * 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw LauncherError.message("等待官方计费服务器响应超时。") }
            guard state.revents & (events | Int16(POLLHUP)) != 0 else { throw LauncherError.message("CrossOver 网络连接已中断。") }
            return
        }
    }
    func write(_ data: Data) throws {
        let fd = input.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(fd, events: Int16(POLLOUT))
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw LauncherError.message("发送官方认证请求失败。") }
                offset += n
            }
        }
    }
    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= 65536 else { throw LauncherError.message("服务器数据长度无效。") }
        let fd = output.fileHandleForReading.fileDescriptor
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try ready(fd, events: Int16(POLLIN))
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw LauncherError.message("官方服务器或 CrossOver 网络连接已关闭。") }
                offset += n
            }
        }
        return data
    }
}

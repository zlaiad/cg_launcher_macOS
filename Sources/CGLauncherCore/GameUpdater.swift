import Foundation
import CoreFoundation

/// Process names only: never read the game's command line or authentication arguments.
public struct GameActivity: Equatable, Sendable {
    public let gameRunning: Bool
    public let updaterRunning: Bool

    public init(processNames: String) {
        let names = processNames.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").last?.lowercased() ?? ""
        }
        gameRunning = names.contains { ["cg_se_3000.exe", "cg_se_6000.exe", "cg_item_6000.exe"].contains($0) }
        updaterRunning = names.contains { $0.hasPrefix("patcher_puk3") && $0.hasSuffix(".exe") }
    }

    public static func current() throws -> GameActivity {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LauncherError.message("无法检查游戏运行状态，请稍后重试。")
        }
        return GameActivity(processNames: String(decoding: data, as: UTF8.self))
    }

    public func requireUpdateAllowed() throws {
        guard !gameRunning else { throw LauncherError.message("请先退出所有魔力宝贝游戏窗口，再更新游戏。") }
        guard !updaterRunning else { throw LauncherError.message("游戏更新程序已在运行，请等待它完成。") }
    }
}

public enum GameUpdater {
    public static func validateLog(_ data: Data) throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard data.count <= 16 * 1024 * 1024,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: encoding) else {
            throw LauncherError.message("更新日志无法读取，尚未确认更新完成。")
        }
        let text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        guard text.contains("检查完毕，准备启动游戏。") else {
            throw LauncherError.message("官方更新未完成，请查看更新窗口提示后重试。")
        }
        var file: String?, localDigest: String?, serverDigest: String?, failures = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("开始检查"), line.hasSuffix("。") {
                file = String(line.dropFirst(4).dropLast())
                localDigest = nil; serverDigest = nil
            } else if let file {
                if line.contains("失败") || line.contains("错误") { failures.insert(file) }
                // A later successful retry clears the earlier failure for the same file.
                if line.contains("与服务器一致") || line.contains("追加更新成功") { failures.remove(file) }
                if line.hasPrefix("本地文件哈希值：") { localDigest = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces).uppercased() }
                if line.hasPrefix("服务器哈希值：") { serverDigest = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces).uppercased() }
                if (line.hasPrefix("本地文件哈希值：") || line.hasPrefix("服务器哈希值：")),
                   let localDigest, let serverDigest {
                    if localDigest == serverDigest { failures.remove(file) }
                    else { failures.insert(file) }
                }
            }
        }
        guard failures.isEmpty else {
            throw LauncherError.message("有 \(failures.count) 个游戏文件未更新成功，请稍后重试或用官方客户端修复。")
        }
    }
    public static func arguments(installation: Installation, region: GameRegion) throws -> [String] {
        guard installation.regions.contains(region), let endpoint = region.patchServer,
              endpoint.port > 0, endpoint.host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$"#, options: .regularExpression) != nil else {
            throw LauncherError.message("所选大区缺少有效的官方更新配置。")
        }
        return [endpoint.host, String(endpoint.port)]
    }

    public static func validateExitCode(_ code: Int32) throws {
        // POLCN accepts 100 as completion. Zero also occurs on cancellation: it is not success.
        guard code == 100 else {
            if code == 0 { throw LauncherError.message("更新已中止，尚未确认完成。请重新点击更新游戏。") }
            throw LauncherError.message("官方更新未完成（代码 \(code)），请查看更新窗口提示后重试。")
        }
    }

    public static func run(installation: Installation, region: GameRegion) throws {
        try GameActivity.current().requireUpdateAllowed()
        let arguments = try arguments(installation: installation, region: region)
        guard FileManager.default.fileExists(atPath: installation.patcher.path) else {
            throw LauncherError.message("游戏目录里没有找到 Patcher_PUK3.exe，请使用官方安装程序修复。")
        }
        // Like POLCN's .BAK.EXE, run a copy so the official patcher can update itself.
        let copy = installation.gameDirectory.appendingPathComponent("Patcher_PUK3.CGLauncher-\(UUID().uuidString).exe")
        try FileManager.default.copyItem(at: installation.patcher, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let process = Process()
        process.executableURL = installation.wine
        process.arguments = installation.wineArguments(executable: copy, arguments: arguments)
        process.currentDirectoryURL = installation.gameDirectory
        process.environment = installation.wineEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let log = installation.gameDirectory.appendingPathComponent("Update_Log.htm")
        let previousDate = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // Recheck immediately before starting, including games opened from the official launcher.
        try GameActivity.current().requireUpdateAllowed()
        try process.run()
        process.waitUntilExit()
        try validateExitCode(process.terminationStatus)
        let values = try log.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.contentModificationDate != previousDate, (values.fileSize ?? Int.max) <= 16 * 1024 * 1024 else {
            throw LauncherError.message("未生成本次更新日志，尚未确认更新完成。")
        }
        try validateLog(Data(contentsOf: log))
        _ = try installation.assetArguments()
    }
}

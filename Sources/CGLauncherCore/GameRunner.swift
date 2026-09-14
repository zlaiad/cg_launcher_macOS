import Foundation

public enum GameRunner {
    public static func prepareRequest(installation: Installation, session: AuthenticatedSession, account: GameAccount, region: GameRegion) throws -> Data {
        guard let endpoint = session.endpoint, region.billing.contains(endpoint) else {
            throw LauncherError.message("认证结果不属于当前大区，请重新登录。")
        }
        var packet = Data("CGM1".utf8)
        func string(_ value: String) {
            let bytes = Data(value.utf8); packet.appendLE(UInt32(bytes.count)); packet.append(bytes)
        }
        string(try session.handoff(for: account))
        string(installation.windowsPath(installation.game))
        string(installation.windowsPath(installation.gameDirectory))
        let arguments = try installation.gameArguments(for: region)
        packet.appendLE(UInt32(arguments.count))
        for argument in arguments { string(argument) }
        return packet
    }
    public static func start(installation: Installation, session: AuthenticatedSession, account: GameAccount, region: GameRegion, helper: URL) throws -> Process {
        guard FileManager.default.fileExists(atPath: helper.path) else { throw LauncherError.message("启动桥接程序缺失，请重新构建应用。") }
        var packet = try prepareRequest(installation: installation, session: session, account: account, region: region)
        defer { packet.resetBytes(in: packet.startIndex ..< packet.endIndex) }
        let process = Process()
        process.executableURL = installation.wine
        process.arguments = installation.wineArguments(executable: helper)
        process.currentDirectoryURL = installation.gameDirectory
        process.environment = installation.wineEnvironment()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: packet)
        try input.fileHandleForWriting.close()
        var result = Data()
        while result.count < 512 {
            let next = output.fileHandleForReading.availableData
            guard !next.isEmpty else { break }
            result.append(next)
            if result.contains(10) { break }
        }
        let line = String(decoding: result, as: UTF8.self)
        guard line.hasPrefix("GAME_STARTED ") else {
            throw LauncherError.message("Windows 游戏启动失败，请先用官方登录器检查游戏更新和安装。")
        }
        // The helper keeps the mapping alive while its child game is running.
        return process
    }
}

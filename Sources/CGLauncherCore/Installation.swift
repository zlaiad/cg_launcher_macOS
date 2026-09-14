import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CoreFoundation

public struct BillingEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

public struct GameRegion: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let billing: [BillingEndpoint]
    public let arguments: [String]
}

public enum LauncherError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct Installation: Sendable {
    public let bottle: URL
    public let wine: URL
    public let launcher: URL
    public let gameDirectory: URL
    public let regions: [GameRegion]

    public var game: URL { gameDirectory.appendingPathComponent("cg_se_3000.exe") }
    public var bottleName: String { bottle.lastPathComponent }

    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Installation {
        let bottle = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/CrossGate")
        let programFiles = bottle.appendingPathComponent("drive_c/Program Files (x86)")
        let launcherDir = programFiles.appendingPathComponent("易玩通/“易玩通”娱乐平台")
        let wine = URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        let launcher = launcherDir.appendingPathComponent("POLCN_Launcher.exe")
        let gameDirectory = programFiles.appendingPathComponent("PlayOnline/魔力宝贝")
        for url in [wine, launcher, gameDirectory.appendingPathComponent("cg_se_3000.exe")] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LauncherError.message("未找到 \(url.lastPathComponent)，请检查 CrossGate 容器和游戏安装。")
            }
        }
        let regions = try loadRegions(at: launcherDir.appendingPathComponent("XML/RegionList.xml"))
        guard !regions.isEmpty else { throw LauncherError.message("官方配置里没有找到怀旧服大区。") }
        return Installation(bottle: bottle, wine: wine, launcher: launcher, gameDirectory: gameDirectory, regions: regions)
    }

    public static func loadRegions(at url: URL) throws -> [GameRegion] {
        let data = try Data(contentsOf: url)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: encoding),
              let utf8 = text.data(using: .utf8) else { throw LauncherError.message("大区配置编码无法识别。") }
        let delegate = RegionParser()
        let parser = XMLParser(data: utf8)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw LauncherError.message("大区配置 XML 损坏。") }
        return delegate.regions
    }

    public func assetArguments() throws -> [String] {
        var result: [String] = []
        for (directory, suffix) in [("bin", ""), ("bin/Puk2", "_puk2"), ("bin/Puk3", "_puk3")] {
            let url = gameDirectory.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            var names = Set<String>()
            for file in files.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                guard file.pathExtension.lowercased() == "bin", ["anime", "graphic", "coordinate"].contains(where: name.hasPrefix) else { continue }
                let pieces = name.split(separator: "_", omittingEmptySubsequences: false)
                let version = pieces.count > 1 && UInt(pieces.last!) != nil ? String(pieces.last!) : nil
                var stem = version == nil ? name : pieces.dropLast().joined(separator: "_")
                // Expansion filenames already contain _puk2/_puk3; the argument uses it once.
                if !suffix.isEmpty, stem.hasSuffix(suffix) { stem.removeLast(suffix.count) }
                let markers = ["animeinfo", "graphicinfo", "coordinateinfo", "anime", "graphic", "coordinate"]
                guard let marker = markers.first(where: stem.hasPrefix) else { continue }
                let key = marker + "bin" + stem.dropFirst(marker.count) + suffix
                guard names.insert(key).inserted else { throw LauncherError.message("素材目录存在多个版本：\(key)。请先运行官方更新。") }
                result.append(key + (version.map { ":" + $0 } ?? ""))
            }
        }
        guard !result.isEmpty else { throw LauncherError.message("未找到游戏素材版本文件。") }
        return result
    }

    public func gameArguments(for region: GameRegion) throws -> [String] {
        guard regions.contains(region) else { throw LauncherError.message("所选大区不属于本次加载的官方配置。") }
        return ["updated"] + region.arguments + (try assetArguments())
    }

    public func wineArguments(executable: URL, arguments: [String] = []) -> [String] {
        ["--bottle", bottleName, "--workdir", executable.deletingLastPathComponent().path,
         windowsPath(executable)] + arguments
    }

    public func wineEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["WINEDEBUG"] = "-all"
        // The game's unpacker uses ANSI APIs to reopen its Chinese installation path.
        // Locale is scoped to these child processes; no bottle registry edit is needed.
        environment["LANG"] = "zh_CN.UTF-8"
        environment["LC_ALL"] = "zh_CN.UTF-8"
        return environment
    }

    public func windowsPath(_ url: URL) -> String {
        let driveC = bottle.appendingPathComponent("drive_c").path + "/"
        if url.path.hasPrefix(driveC) { return "C:\\" + url.path.dropFirst(driveC.count).replacingOccurrences(of: "/", with: "\\") }
        return "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }
}

private final class RegionParser: NSObject, XMLParserDelegate {
    var regions: [GameRegion] = []
    var id = 0
    var name = ""
    var billing: [BillingEndpoint] = []
    var arguments: [String] = []
    var inRegion = false
    var gameCode: String?
    var port: UInt16?
    var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if elementName == "Region" {
            inRegion = true; id = Int(attributes["Code"] ?? "") ?? 0
            name = ""; billing = []; arguments = []
        }
        if elementName == "BIP" { port = UInt16(attributes["Port"] ?? "") }
        if elementName == "Args" { gameCode = attributes["Gamecode"] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inRegion else { return }
        if elementName == "Name" { name = value }
        if elementName == "BIP", let port, !value.isEmpty { billing.append(BillingEndpoint(host: value, port: port)) }
        if elementName == "Args", gameCode == "11" {
            arguments = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        if elementName == "Region" {
            if !arguments.isEmpty, !billing.isEmpty, !name.contains("测试"), arguments.allSatisfy({ $0.range(of: #"^IP:\d+:\d{1,3}(\.\d{1,3}){3}:\d+$"#, options: .regularExpression) != nil }) {
                regions.append(GameRegion(id: id, name: name, billing: billing, arguments: arguments))
            }
            inRegion = false
        }
    }
}

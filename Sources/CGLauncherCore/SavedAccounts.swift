import Foundation
import Darwin

public struct SavedAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: String { username }
    public let username: String
    public var password: String
    public var regionID: Int
    public var gameAccountsByRegion: [String: String]
    public var lastVerifiedAt: Date
}

public struct SavedAccountList: Codable, Equatable, Sendable {
    public var version = 1
    public var accounts: [SavedAccount] = []
    public var selectedUsername: String?
    public init() {}
}

/// Local application data, deliberately independent of Keychain at the user's request.
/// Only this app's user can access the directory/file (0700 / 0600).
public struct SavedAccountStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CGLauncher/accounts.json")) {
        self.fileURL = fileURL
    }

    public func load() throws -> SavedAccountList {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SavedAccountList() }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? 0) <= 4_000_000 else {
                throw LauncherError.message("本地账号文件格式无效。")
            }
            let list = try JSONDecoder().decode(SavedAccountList.self, from: Data(contentsOf: fileURL))
            guard list.version == 1, Set(list.accounts.map(\.username)).count == list.accounts.count else {
                throw LauncherError.message("本地账号文件版本或账号列表无效。")
            }
            return list
        } catch { throw LauncherError.message("无法读取已保存的账号；原文件已保留，请检查应用数据目录。") }
    }

    /// Called only after an official authentication response has succeeded.
    public func rememberVerifiedLogin(username: String, password: String, regionID: Int) throws {
        _ = try LegacyProtocol.login(username: username, password: password)
        var list = try load()
        if let index = list.accounts.firstIndex(where: { $0.username == username }) {
            list.accounts[index].password = password
            list.accounts[index].regionID = regionID
            list.accounts[index].lastVerifiedAt = Date()
        } else {
            list.accounts.append(SavedAccount(username: username, password: password, regionID: regionID,
                gameAccountsByRegion: [:], lastVerifiedAt: Date()))
        }
        list.selectedUsername = username
        try write(list)
    }

    public func rememberGameAccount(username: String, regionID: Int, gameAccount: String) throws {
        var list = try load()
        guard let index = list.accounts.firstIndex(where: { $0.username == username }) else { return }
        list.accounts[index].gameAccountsByRegion[String(regionID)] = gameAccount
        list.accounts[index].regionID = regionID
        list.selectedUsername = username
        try write(list)
    }

    private func write(_ list: SavedAccountList) throws {
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw LauncherError.message("账号保存目录无效。")
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var bytes = try encoder.encode(list)
            defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
            var template = Array(directory.appendingPathComponent(".accounts-XXXXXX").path.utf8CString)
            let fd = mkstemp(&template) // Creates 0600 from the first moment, before writing secrets.
            guard fd >= 0 else { throw LauncherError.message("无法建立账号保存文件。") }
            let temporary = String(cString: template)
            defer { close(fd); unlink(temporary) }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw LauncherError.message("写入账号文件失败。") }
                    offset += n
                }
            }
            guard fsync(fd) == 0, rename(temporary, fileURL.path) == 0 else {
                throw LauncherError.message("保存账号文件失败。")
            }
        } catch { throw LauncherError.message("账号认证成功，但本地账号文件保存失败。") }
    }
}

public struct RememberedLoginResult: Sendable {
    public let session: AuthenticatedSession
    public let storageWarning: String?
}

public enum RememberedLogin {
    /// Authentication failure exits before any file operation, preserving previous good passwords.
    public static func authenticate(username: String, password: String, regionID: Int, store: SavedAccountStore,
        using authenticate: () throws -> AuthenticatedSession) throws -> RememberedLoginResult {
        let session = try authenticate()
        do {
            try store.rememberVerifiedLogin(username: username, password: password, regionID: regionID)
            return RememberedLoginResult(session: session, storageWarning: nil)
        } catch {
            return RememberedLoginResult(session: session, storageWarning: error.localizedDescription)
        }
    }
}

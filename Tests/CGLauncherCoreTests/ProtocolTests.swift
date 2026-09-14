#if STANDALONE_CHECKS
import Foundation
class XCTestCase {}
private var checks = 0
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T) {
    do { guard try a() == b() else { fatalError("equality check failed") }; checks += 1 }
    catch { fatalError("unexpected error: \(error)") }
}
func XCTAssertTrue(_ value: @autoclosure () -> Bool) { guard value() else { fatalError("true check failed") }; checks += 1 }
func XCTAssertFalse(_ value: @autoclosure () -> Bool) { XCTAssertTrue(!value()) }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try value() } catch { checks += 1; handler(error); return }
    fatalError("expected error did not occur")
}
@main struct RunChecks {
    static func main() throws {
        let suite = ProtocolTests()
        try suite.testLoginWireFormatAndLimits()
        try suite.testBoundedDHArithmetic()
        try suite.testCipherRoundtripAndTruncation()
        try suite.testSuccessResponseAndAccountRestrictions()
        try suite.testServerFailureDoesNotBecomeSession()
        try suite.testExpansionAssetArguments()
        try suite.testSavedAccountsAndFailedAuthentication()
        try suite.testUpdateConfigurationAndGuards()
        print("PROTOCOL_CHECKS_OK assertions=\(checks)")
    }
}
#else
import XCTest
@testable import CGLauncherCore
#endif

final class ProtocolTests: XCTestCase {
    func testUpdateConfigurationAndGuards() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CGUpdateTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let xml = """
        <Regionlist><Regions><Region Code="33"><Name>牧羊双子</Name>
        <BList><BIP Port="9030">221.122.108.12</BIP></BList><PIP>221.122.108.10</PIP><PPort>80</PPort>
        <Arglist><Args Gamecode="11">IP:0:221.122.119.181:9013</Args></Arglist></Region>
        <Region Code="36"><Name>金牛</Name><BList><BIP Port="9030">221.122.119.158</BIP></BList>
        <PIP>221.122.119.156</PIP><PPort>80</PPort><Arglist><Args Gamecode="11">IP:20:221.122.119.161:9013</Args></Arglist></Region>
        <Region Code="37"><Name>缺少更新配置</Name><BList><BIP Port="9030">127.0.0.1</BIP></BList>
        <Arglist><Args Gamecode="11">IP:0:127.0.0.1:9013</Args></Arglist></Region></Regions></Regionlist>
        """
        let file = base.appendingPathComponent("regions.xml")
        try Data(xml.utf8).write(to: file)
        let regions = try Installation.loadRegions(at: file)
        let installation = Installation(bottle: base, wine: base, launcher: base, gameDirectory: base, regions: regions)
        XCTAssertEqual(try GameUpdater.arguments(installation: installation, region: regions[0]), ["221.122.108.10", "80"])
        XCTAssertEqual(try GameUpdater.arguments(installation: installation, region: regions[1]), ["221.122.119.156", "80"])
        XCTAssertThrowsError(try GameUpdater.arguments(installation: installation, region: regions[2]))
        var invalid = regions[0]; invalid.patchServer = BillingEndpoint(host: "invalid host", port: 80)
        XCTAssertThrowsError(try GameUpdater.arguments(installation: installation, region: invalid))
        let games = GameActivity(processNames: "C:\\Program Files (x86)\\PlayOnline\\魔力宝贝\\cg_se_3000.exe\n/Applications/Safari.app/Contents/MacOS/Safari")
        XCTAssertTrue(games.gameRunning)
        XCTAssertThrowsError(try games.requireUpdateAllowed())
        let patcher = GameActivity(processNames: "Z:\\中文路径\\Patcher_PUK3.CGLauncher-test.exe")
        XCTAssertTrue(patcher.updaterRunning)
        XCTAssertThrowsError(try patcher.requireUpdateAllowed())
        XCTAssertTrue(GameActivity(processNames: "C:\\Game\\PATCHER_PUK3.BAK.EXE").updaterRunning)
        let idle = GameActivity(processNames: "/Applications/CGLauncher.app/Contents/MacOS/CGLauncher\nC:\\Game\\POLCN_Launcher.exe")
        try idle.requireUpdateAllowed()
        XCTAssertFalse(idle.gameRunning || idle.updaterRunning)
        try GameUpdater.validateExitCode(100)
        XCTAssertThrowsError(try GameUpdater.validateExitCode(0))
        XCTAssertThrowsError(try GameUpdater.validateExitCode(101))
        XCTAssertThrowsError(try GameUpdater.validateExitCode(102))
        try GameUpdater.validateLog(Data("开始检查test.bin。\n与服务器一致，无需更新。\n检查完毕，准备启动游戏。".utf8))
        XCTAssertThrowsError(try GameUpdater.validateLog(Data("旧版或不完整日志".utf8)))
        let failed = "开始检查test.bin。\n下载过程中发生错误，无法更新。\n检查完毕，准备启动游戏。"
        XCTAssertThrowsError(try GameUpdater.validateLog(Data(failed.utf8)))
        // The official patcher can return 100 despite a failed file: check its log too.
        let retry = "开始检查test.bin。\n下载失败。\n开始检查test.bin。\n与服务器一致，无需更新。\n检查完毕，准备启动游戏。"
        try GameUpdater.validateLog(Data(retry.utf8))
        let repaired = "开始检查test.bin。\n本地文件哈希值：AAA\n服务器哈希值：BBB\n下载失败。\n本地文件哈希值：BBB\n检查完毕，准备启动游戏。"
        try GameUpdater.validateLog(Data(repaired.utf8))
        XCTAssertThrowsError(try GameUpdater.validateLog(Data("开始检查test.bin。\n本地文件哈希值：AAA\n服务器哈希值：AAA\n追加失败。\n检查完毕，准备启动游戏。".utf8)))
    }
    func testSavedAccountsAndFailedAuthentication() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CGLauncherTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("private/accounts.json")
        let store = SavedAccountStore(fileURL: file)
        let session = AuthenticatedSession(accounts: [], authenticatedAt: Date(), token: Array("TEST".utf8), serverStamp: 1, endpoint: nil)
        XCTAssertEqual(try store.load().accounts.count, 0)
        _ = try RememberedLogin.authenticate(username: "testAlpha", password: "firstPassword", regionID: 33, store: store) { session }
        _ = try RememberedLogin.authenticate(username: "testBeta", password: "secondPassword", regionID: 36, store: store) { session }
        // A fresh store simulates quitting and reopening the app.
        let reopened = SavedAccountStore(fileURL: file)
        XCTAssertEqual(try reopened.load().accounts.count, 2)
        XCTAssertEqual(try reopened.load().selectedUsername, "testBeta")
        XCTAssertEqual(try reopened.load().accounts.first(where: { $0.username == "testAlpha" })?.password, "firstPassword")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try RememberedLogin.authenticate(username: "testAlpha", password: "wrongPassword", regionID: 33, store: store) {
            throw LauncherError.message("Synthetic authentication failure")
        })
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertThrowsError(try RememberedLogin.authenticate(username: "neverVerified", password: "wrongPassword", regionID: 33, store: store) {
            throw LauncherError.message("Synthetic authentication failure")
        })
        XCTAssertEqual(try reopened.load().accounts.count, 2)
        _ = try RememberedLogin.authenticate(username: "testAlpha", password: "updatedPassword", regionID: 36, store: store) { session }
        try store.rememberGameAccount(username: "testAlpha", regionID: 36, gameAccount: "syntheticGame")
        let alpha = try reopened.load().accounts.first(where: { $0.username == "testAlpha" })!
        XCTAssertEqual(alpha.password, "updatedPassword")
        XCTAssertEqual(alpha.regionID, 36)
        XCTAssertEqual(alpha.gameAccountsByRegion["36"], "syntheticGame")
        XCTAssertEqual(try reopened.load().accounts.count, 2)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        // A damaged file must never silently erase the existing account collection.
        let damaged = Data("invalid test data".utf8)
        try damaged.write(to: file)
        let outcome = try RememberedLogin.authenticate(username: "testAlpha", password: "verifiedPassword", regionID: 33, store: store) { session }
        XCTAssertTrue(outcome.storageWarning != nil)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }
    func testExpansionAssetArguments() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        for directory in ["bin", "bin/Puk2", "bin/Puk3"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in ["bin/AnimeInfoEx_1.Bin", "bin/Puk2/Anime_Puk2_4.bin", "bin/Puk3/GraphicInfo_Puk3_1.bin"] {
            try Data().write(to: base.appendingPathComponent(file))
        }
        let install = Installation(bottle: base, wine: base, launcher: base, gameDirectory: base, regions: [])
        XCTAssertEqual(try install.assetArguments(), ["animeinfobinex:1", "animebin_puk2:4", "graphicinfobin_puk3:1"])
        try Data().write(to: base.appendingPathComponent("bin/Puk2/Anime_Puk2_5.bin"))
        XCTAssertThrowsError(try install.assetArguments())
    }
    func testLoginWireFormatAndLimits() throws {
        let request = try LegacyProtocol.login(username: "user", password: "pass")
        XCTAssertEqual(Array(request), [10,0,0,0,0,4,117,115,101,114,4,112,97,115,115,0,0,0,11])
        XCTAssertThrowsError(try LegacyProtocol.login(username: "", password: "pass"))
        XCTAssertThrowsError(try LegacyProtocol.login(username: String(repeating: "u", count: 18), password: String(repeating: "p", count: 18)))
        XCTAssertThrowsError(try LegacyProtocol.login(username: "user", password: "pass\0word"))
    }
    func testBoundedDHArithmetic() throws {
        XCTAssertEqual(try LegacyDH.pow(base: [5], exponent: [117], modulus: [19]), [1])
        XCTAssertEqual(try LegacyDH.pow(base: [2], exponent: [32], modulus: [0xff,0xff,0xff,0xfb]), [5])
        XCTAssertEqual(try LegacyDH.pow(base: [2], exponent: [0], modulus: [19]), [1])
        XCTAssertThrowsError(try LegacyDH.pow(base: [19], exponent: [1], modulus: [19]))
        // Independent golden value generated with Python's integer modular exponentiation.
        let expected = try LegacyDH.bytes(hex: "d479fc91a56a2df99ca97bee8e0b84bf51975865da85bc38554409a60a8dd166be5a39d29f92a9a2b0b6afc90fe38a134e332f1e0308563e9ec6fee813bc8b52afcaa53949e8d3005de6aa70128ec0c6282ebeea4a93a7e3276719093d1ec15fb292462a2f141f1e4a0379259e7e98e33d062fdc44ab15deeda120b25134d25b")
        XCTAssertEqual(try LegacyDH.pow(base: [2], exponent: Array(1...20), modulus: LegacyDH.bytes(hex: LegacyDH.primeHex)), expected)
    }
    func testCipherRoundtripAndTruncation() throws {
        let cipher = try LegacyCipher(key: Array(repeating: 0, count: 8))
        let body = Data([2,0,0,0,0,0,1,0xe2,0x40])
        let record = try cipher.encode(body)
        // Independently computed by PyCryptodome Blowfish, including legacy word order.
        XCTAssertEqual(record, Data(try LegacyDH.bytes(hex: "000000100000000b894a543cb1dd79be2f5cf663b070308a")))
        var reader = PacketReader(record)
        XCTAssertEqual(try reader.u32(), 16)
        let original = try reader.u32()
        let decrypted = try cipher.decode(encrypted: Data(reader.take(16)), originalLength: Int(original))
        XCTAssertEqual(decrypted, Data([0,9]) + body)
        XCTAssertThrowsError(try cipher.decode(encrypted: Data([1,2,3]), originalLength: 3))
    }
    func testSuccessResponseAndAccountRestrictions() throws {
        var response = Data([11]); response.appendBE(0); response.appendBE(0)
        response.append(4); response.append(contentsOf: "TEST".utf8)
        response.append(contentsOf: [1,4]); response.append(contentsOf: "gid1".utf8)
        for status: UInt32 in [0,0,0,12,0] { response.append(1); response.appendBE(status) }
        response.appendBE(0x80000001); response.appendBE(0)
        let session = try LegacyProtocol.parseLogin(response)
        XCTAssertEqual(session.accounts.count, 1)
        XCTAssertEqual(try session.handoff(for: session.accounts[0]), "gid:gid1 glt:TEST:1 ")
        let padded = AuthenticatedSession(accounts: session.accounts, authenticatedAt: Date(), token: Array("TEST".utf8) + [0,0,0,0], serverStamp: 0x80000001, endpoint: nil)
        XCTAssertEqual(try padded.handoff(for: padded.accounts[0]), "gid:gid1 glt:TEST:1 ")
        XCTAssertThrowsError(try LegacyProtocol.parseLogin(response.dropLast()))
        XCTAssertFalse(GameAccount(id: "blocked", status: -1, entitlement: 0, restriction: 0).canLaunch)
        XCTAssertFalse(GameAccount(id: "blocked", status: 0, entitlement: 1, restriction: 1).canLaunch)
    }
    func testServerFailureDoesNotBecomeSession() throws {
        var response = Data([11]); response.appendBE(0); response.appendBE(UInt32(bitPattern: -11))
        XCTAssertThrowsError(try LegacyProtocol.parseLogin(response)) { error in
            XCTAssertTrue(error.localizedDescription.contains("密码不正确"))
        }
        var reader = PacketReader(Data([253,255,255,255,255]))
        XCTAssertThrowsError(try reader.length(maximum: 32))
    }
}

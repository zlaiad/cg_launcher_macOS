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
        print("PROTOCOL_CHECKS_OK assertions=\(checks)")
    }
}
#else
import XCTest
@testable import CGLauncherCore
#endif

final class ProtocolTests: XCTestCase {
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

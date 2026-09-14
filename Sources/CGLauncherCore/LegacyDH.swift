import Foundation
import Security

/// Bounded unsigned arithmetic used only for the installed protocol's 1024-bit DH group.
/// Addition/doubling reduction avoids any external runtime or downloaded crypto module.
enum LegacyDH {
    static let primeHex = "f488fd584e49dbcd20b49de49107366b336c380d451d0f7c88b31c7c5b2d8ef6f3c923c043f0a55b188d8ebb558cb85d38d334fd7c175743a31d186cde33212cb52aff3ce1b1294018118d7c84a70a72d686c40319c807297aca950cd9969fabd00a509b0246d3083d66a45d419f9c7cbd894b221926baaba25ec355e92f78c7"

    static func bytes(hex: String) throws -> [UInt8] {
        guard !hex.isEmpty, hex.count <= 1024, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw LauncherError.message("服务器握手包含无效的十六进制参数。")
        }
        let chars = Array((hex.count % 2 == 0 ? hex : "0" + hex).utf8)
        return stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(decoding: chars[$0 ..< $0 + 2], as: UTF8.self), radix: 16)!
        }
    }
    static func hex(_ bytes: [UInt8]) -> String {
        let significant = bytes.drop(while: { $0 == 0 })
        return significant.isEmpty ? "0" : significant.map { String(format: "%02X", $0) }.joined()
    }
    static func pow(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) throws -> [UInt8] {
        guard !modulus.isEmpty, modulus.count <= 128, exponent.count <= 128 else { throw LauncherError.message("DH 参数长度无效。") }
        let n = (modulus.count + 3) / 4 + 1
        func words(_ bytes: [UInt8]) -> [UInt32] {
            var result = [UInt32](repeating: 0, count: n)
            for (i, byte) in bytes.reversed().enumerated() { result[i / 4] |= UInt32(byte) << ((i % 4) * 8) }
            return result
        }
        guard base.count <= modulus.count else { throw LauncherError.message("DH 公钥超出范围。") }
        let m = words(modulus)
        func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
            for i in (0 ..< n).reversed() { if a[i] != b[i] { return a[i] < b[i] } }
            return false
        }
        var one = [UInt32](repeating: 0, count: n); one[0] = 1
        guard less(one, m) else { throw LauncherError.message("DH 模数无效。") }
        func add(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var r = [UInt32](repeating: 0, count: n)
            var carry: UInt64 = 0
            for i in 0 ..< n {
                let v = UInt64(a[i]) + UInt64(b[i]) + carry
                r[i] = UInt32(truncatingIfNeeded: v); carry = v >> 32
            }
            if !less(r, m) {
                var borrow: UInt64 = 0
                for i in 0 ..< n {
                    let sub = UInt64(m[i]) + borrow
                    let old = UInt64(r[i])
                    r[i] = UInt32(truncatingIfNeeded: old &- sub)
                    borrow = old < sub ? 1 : 0
                }
            }
            return r
        }
        func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var r = [UInt32](repeating: 0, count: n), shifted = a
            for word in b {
                var value = word
                for _ in 0 ..< 32 {
                    if value & 1 == 1 { r = add(r, shifted) }
                    shifted = add(shifted, shifted); value >>= 1
                }
            }
            return r
        }
        let a = words(base)
        guard less(a, m) else { throw LauncherError.message("DH 公钥不在有效范围。") }
        var result = one
        for byte in exponent {
            for bit in (0 ..< 8).reversed() {
                result = multiply(result, result)
                if byte & (1 << bit) != 0 { result = multiply(result, a) }
            }
        }
        let output: [UInt8] = result.reversed().flatMap {
            [UInt8(truncatingIfNeeded: $0 >> 24), UInt8(truncatingIfNeeded: $0 >> 16), UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)]
        }
        let minimal = Array(output.drop(while: { $0 == 0 }))
        return minimal.isEmpty ? [0] : minimal
    }
    static func exchange(generator: String, prime: String, publicKey: String) throws -> (publicKey: String, secret: [UInt8]) {
        guard generator == "2", prime.lowercased() == primeHex else { throw LauncherError.message("服务器的 DH 参数与已核实的官方版本不一致。") }
        var privateKey = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, privateKey.count, &privateKey) == errSecSuccess else { throw LauncherError.message("无法生成安全随机数。") }
        privateKey[0] |= 0x80
        defer { _ = privateKey.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let modulus = try bytes(hex: prime)
        let server = try bytes(hex: publicKey)
        guard server.contains(where: { $0 > 1 }), server.count <= modulus.count else { throw LauncherError.message("服务器 DH 公钥无效。") }
        let client = try pow(base: [2], exponent: privateKey, modulus: modulus)
        let secret = try pow(base: server, exponent: privateKey, modulus: modulus)
        guard secret.count >= 8 else { throw LauncherError.message("服务器协商密钥无效。") }
        return (hex(client), Array(secret.prefix(8)))
    }
}

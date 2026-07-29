// The CostSauce costing kernel, Swift implementation — UUIDv7 id minting.
//
// Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md.
// RFC 9562 §5.7 layout: 48-bit unix-ms timestamp | 4-bit version (0111) |
// 12-bit random (rand_a) | 2-bit variant (0b10) | 62-bit random (rand_b).
// Lowercase hyphenated 36-char output.

import Foundation

public enum UUIDv7 {

    /// Mints a UUIDv7 for `now`. `now`'s instant is read once via
    /// `timeIntervalSince1970` (Foundation's Date is fundamentally a
    /// Double) and rounded down to an integer unix-ms count immediately —
    /// every subsequent step is plain integer bit-twiddling, never further
    /// Date arithmetic. Random fields come from the system CSPRNG.
    public static func generate(now: Date = Date()) -> String {
        let millis = UInt64((now.timeIntervalSince1970 * 1000).rounded(.down))
        var rng = SystemRandomNumberGenerator()
        let randomA = UInt16.random(in: 0...0xFFF, using: &rng)
        let randomB = UInt64.random(in: 0...0x3FFF_FFFF_FFFF_FFFF, using: &rng)
        return generate(millis: millis, randomA: randomA, randomB: randomB)
    }

    /// The deterministic core, split out so tests can pin the timestamp and
    /// random fields exactly. Only the low 48 bits of `millis`, low 12 bits
    /// of `randomA`, and low 62 bits of `randomB` are used.
    public static func generate(millis: UInt64, randomA: UInt16, randomB: UInt64) -> String {
        let ts = millis & 0xFFFF_FFFF_FFFF
        let a = UInt64(randomA) & 0xFFF
        let b = randomB & 0x3FFF_FFFF_FFFF_FFFF

        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8((ts >> 40) & 0xFF)
        bytes[1] = UInt8((ts >> 32) & 0xFF)
        bytes[2] = UInt8((ts >> 24) & 0xFF)
        bytes[3] = UInt8((ts >> 16) & 0xFF)
        bytes[4] = UInt8((ts >> 8) & 0xFF)
        bytes[5] = UInt8(ts & 0xFF)
        bytes[6] = UInt8(0x70 | ((a >> 8) & 0x0F))   // version 7 | top 4 bits of rand_a
        bytes[7] = UInt8(a & 0xFF)                   // low 8 bits of rand_a
        bytes[8] = UInt8(0x80 | ((b >> 56) & 0x3F))  // variant 0b10 | top 6 bits of rand_b
        bytes[9] = UInt8((b >> 48) & 0xFF)
        bytes[10] = UInt8((b >> 40) & 0xFF)
        bytes[11] = UInt8((b >> 32) & 0xFF)
        bytes[12] = UInt8((b >> 24) & 0xFF)
        bytes[13] = UInt8((b >> 16) & 0xFF)
        bytes[14] = UInt8((b >> 8) & 0xFF)
        bytes[15] = UInt8(b & 0xFF)

        let hex = bytes.map { String(format: "%02x", $0) }
        return "\(hex[0])\(hex[1])\(hex[2])\(hex[3])-\(hex[4])\(hex[5])-\(hex[6])\(hex[7])"
            + "-\(hex[8])\(hex[9])-\(hex[10])\(hex[11])\(hex[12])\(hex[13])\(hex[14])\(hex[15])"
    }
}

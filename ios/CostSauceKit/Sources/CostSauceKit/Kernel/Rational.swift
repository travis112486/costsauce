// The CostSauce costing kernel, Swift implementation — rational plumbing.
//
// Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md
// §8-§10, pinned by shared/golden-vectors.json (also run by the Python and
// JavaScript kernels). All decimals cross this API as STRINGS; internals
// are Int128 rationals. Rounding is half-away-from-zero everywhere.
//
// Function-for-function port of shared/kernel.js:10-33 (kernel.js is the
// reference implementation).

import Foundation

/// An error raised by kernel functions on invalid input. Port of
/// `KernelError extends Error` in kernel.js:10.
public struct KernelError: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// An exact rational number backed by `Int128`. `d` (denominator) is always
/// kept strictly positive; sign lives entirely in `n`. Arithmetic never
/// reduces to lowest terms, matching the BigInt plumbing in kernel.js.
///
/// Port of kernel.js:12-33. Uses plain arithmetic operators throughout so
/// overflow traps rather than wraps.
public struct Rational: Equatable, Sendable {
    public var n: Int128
    public var d: Int128

    public init(n: Int128, d: Int128) {
        self.n = n
        self.d = d
    }

    /// Parses a decimal string of the form `-?\d+(\.\d+)?` (regex
    /// `^(-?)(\d+)(?:\.(\d+))?$`, applied to the trimmed input) into an
    /// exact rational. Port of kernel.js:13-19.
    public static func parseDec(_ s: String) throws -> Rational {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: /(-?)(\d+)(?:\.(\d+))?/) else {
            throw KernelError("not a decimal: \(s)")
        }
        let sign = match.output.1
        let intPart = match.output.2
        let fracPart = match.output.3 ?? ""
        guard let magnitude = Int128(String(intPart) + String(fracPart)) else {
            throw KernelError("not a decimal: \(s)")
        }
        let n: Int128 = sign == "-" ? -magnitude : magnitude
        let d = Rational.pow10(fracPart.count)
        return Rational(n: n, d: d)
    }

    /// 10^places as an exact Int128. Shared by `parseDec`'s denominator and
    /// `Kernel.roundHalfAway`'s scale.
    static func pow10(_ places: Int) -> Int128 {
        var result: Int128 = 1
        for _ in 0..<places { result *= 10 }
        return result
    }

    public func mul(_ o: Rational) -> Rational {
        Rational(n: n * o.n, d: d * o.d)
    }

    /// Throws `KernelError("division by zero")` when `o` is zero. Keeps the
    /// resulting denominator positive. Port of kernel.js:21-26.
    public func div(_ o: Rational) throws -> Rational {
        guard o.n != 0 else { throw KernelError("division by zero") }
        var newN = n * o.d
        var newD = d * o.n
        if newD < 0 {
            newN = -newN
            newD = -newD
        }
        return Rational(n: newN, d: newD)
    }

    public func add(_ o: Rational) -> Rational {
        Rational(n: n * o.d + o.n * d, d: d * o.d)
    }

    public func sub(_ o: Rational) -> Rational {
        Rational(n: n * o.d - o.n * d, d: d * o.d)
    }

    /// -1 / 0 / 1 as `self` is less than / equal to / greater than `o`.
    public func cmp(_ o: Rational) -> Int {
        let x = n * o.d - o.n * d
        return x < 0 ? -1 : (x > 0 ? 1 : 0)
    }

    public var isPositive: Bool { n > 0 }
}

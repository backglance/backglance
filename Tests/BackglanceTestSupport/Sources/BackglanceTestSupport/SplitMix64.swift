import Foundation

/// Deterministic 64-bit generator; same seed → same sequence on every platform and runner.
///
/// Every random value in the test suite and in the synthetic fixtures comes from here.
/// That is a privacy rule, not a convenience: a one-time code that appears in a test or a
/// fixture must be generated at run time from a seed, never written into a source file.
public struct SplitMix64: RandomNumberGenerator {
    // MARK: Lifecycle

    public init(seed: UInt64) {
        state = seed
    }

    // MARK: Public

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Int in 0..<bound.
    public mutating func int(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// Deterministic UUID from the stream.
    public mutating func uuid() -> UUID {
        let high = next()
        let low = next()
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: high >> 56),
            UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40),
            UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24),
            UInt8(truncatingIfNeeded: high >> 16),
            UInt8(truncatingIfNeeded: high >> 8),
            UInt8(truncatingIfNeeded: high),
            UInt8(truncatingIfNeeded: low >> 56),
            UInt8(truncatingIfNeeded: low >> 48),
            UInt8(truncatingIfNeeded: low >> 40),
            UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24),
            UInt8(truncatingIfNeeded: low >> 16),
            UInt8(truncatingIfNeeded: low >> 8),
            UInt8(truncatingIfNeeded: low)
        ))
    }

    // MARK: Private

    private var state: UInt64
}

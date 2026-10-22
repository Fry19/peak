import Foundation

/// Decides which skyline matches move the labels. A single match can be wrong while
/// passing every gate (a cloud bank taken for a ridge, a repetitive skyline), so none acts
/// alone: the first lock waits for two matches that agree, and once locked, a match that
/// jumps far from the heading in use is held back until the next one repeats it.
///
/// Headings are the compass correction a match measured, degrees, all under the same
/// north (compare `from + delta` of each match, not the deltas).
public struct HeadingLock: Sendable {
    /// Two matches this close agree, degrees.
    public var agreement = 0.5
    /// Once locked, a match further than this from the heading in use is a jump, degrees.
    public var maxJump = 1.5
    /// Share of the way a locked heading moves toward each match that agrees with it.
    public var gain = 0.5

    public private(set) var isLocked = false
    /// A match waiting for the next one to confirm it.
    public private(set) var pending: Double?

    public init() {}

    /// Takes a match's heading given the heading in use; returns the heading to use from
    /// now on, or nil to keep the current one (the match waits for confirmation).
    public mutating func add(_ measured: Double, current: Double) -> Double? {
        if isLocked, abs(Self.difference(measured, current)) <= maxJump {
            pending = nil
            return current + gain * Self.difference(measured, current)
        }
        // Not locked yet, or a jump: only taken when the one before says the same.
        if let p = pending, abs(Self.difference(measured, p)) <= agreement {
            pending = nil
            isLocked = true
            return p + Self.difference(measured, p) / 2
        }
        pending = measured
        return nil
    }

    /// Back to unlocked, as after the corrections are reset.
    public mutating func reset() {
        isLocked = false
        pending = nil
    }

    /// a − b, wrapped to ±180°.
    static func difference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }
}

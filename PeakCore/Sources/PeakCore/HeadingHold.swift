import Foundation

/// Keeps a heading that was lined up (by skyline matching or by hand) where it was, by the
/// gyroscope, while the compass wanders.
///
/// The phone's fused heading keeps pulling toward the magnetometer, so a correction found
/// outdoors goes stale a few steps later beside a steel railing or indoors: the magnetometer
/// turns, the phone didn't. The gyroscope alone (`GyroAttitude`) doesn't follow it. The
/// hold measures how far the fused heading has turned away from the gyroscope's since the
/// heading was lined up, and takes that back out.
///
/// The gyroscope drifts, slowly: the hold is whole for `full` seconds, then fades out by
/// `end`, back to the compass with the correction last found.
///
/// `divergence` is the camera's fused heading less its heading by the gyroscope alone,
/// degrees, at seconds `time` (any steady clock), from the gyroscope run `epoch` (its zero
/// holds only within one run).
public struct HeadingHold: Sendable {
    public var full = 60.0
    public var end = 300.0

    public private(set) var reference: (divergence: Double, time: Double, epoch: Int)?

    public init() {}

    /// Degrees to add to the heading correction now.
    public func offset(divergence: Double, time: Double, epoch: Int) -> Double {
        guard let r = reference, r.epoch == epoch else { return 0 }
        let age = max(0, time - r.time)
        let weight = age <= full ? 1 : max(0, 1 - (age - full) / (end - full))
        return weight * azimuthDifference(r.divergence, divergence)
    }

    /// The heading was just lined up (the correction now includes any offset the hold gave):
    /// hold it from here.
    public mutating func start(divergence: Double, time: Double, epoch: Int) {
        reference = (divergence, time, epoch)
    }

    public mutating func reset() {
        reference = nil
    }
}

/// The gyroscope at one moment, as `HeadingHold` needs it (see there).
public struct GyroReading: Sendable, Equatable {
    public var divergence: Double
    public var time: Double
    public var epoch: Int

    public init(divergence: Double, time: Double, epoch: Int) {
        self.divergence = divergence
        self.time = time
        self.epoch = epoch
    }
}

/// The compass's heading correction from skyline matches and lining up by hand: `heading`
/// under the fused compass, plus what the gyroscope's `hold` adds while the compass wanders
/// after it was lined up.
///
/// Matches go through `lock` under the gyroscope's zero (the camera's true heading less
/// its heading by the gyroscope), which the compass's wander doesn't move, so a match
/// waiting for confirmation still compares with the next one after the compass has turned.
public struct HeldHeading: Sendable {
    /// Under the fused compass, degrees.
    public var heading = 0.0
    public var lock = HeadingLock()
    public var hold = HeadingHold()
    /// The gyroscope run `lock`'s matches are under.
    public private(set) var lockEpoch: Int?
    /// What the hold gave that `heading` has taken over, summed: whoever eases `heading` (but
    /// not the hold) moves its eased value along by the change.
    public private(set) var folded = 0.0

    public init() {}

    /// The hold's part of the correction with the gyroscope at `gyro`, degrees.
    public func held(_ gyro: GyroReading?) -> Double {
        gyro.map { hold.offset(divergence: $0.divergence, time: $0.time, epoch: $0.epoch) } ?? 0
    }

    /// The whole correction with the gyroscope at `gyro`: `heading` plus the hold.
    public func correction(_ gyro: GyroReading?) -> Double {
        heading + held(gyro)
    }

    /// The view was lined up to `heading` (under the fused compass at `gyro`): the hold
    /// keeps it from there.
    public mutating func set(_ newHeading: Double, at gyro: GyroReading?) {
        folded += held(gyro)
        heading = newHeading
        guard let gyro else { return hold.reset() }
        hold.start(divergence: gyro.divergence, time: gyro.time, epoch: gyro.epoch)
    }

    /// A match found the correction `measured` under the fused compass with the gyroscope
    /// at `frame`; `now` is the gyroscope's latest reading. Returns whether the lock took
    /// it (`HeadingLock`).
    public mutating func add(_ measured: Double, at frame: GyroReading?, now: GyroReading?) -> Bool {
        if lockEpoch != now?.epoch {
            // A restart moved the gyroscope's zero: the matches waiting don't compare.
            lock.reset()
            lockEpoch = now?.epoch
        }
        // A match from before a restart, or without the gyroscope when there is one now, has
        // no place under this zero.
        guard frame?.epoch == now?.epoch else { return false }
        let divergence = now?.divergence ?? 0
        guard let next = lock.add((frame?.divergence ?? 0) + measured, current: divergence + correction(now)) else { return false }
        set(next - divergence, at: now)
        return true
    }

    /// The view was lined up by hand on a picture taken with the gyroscope at `then`, to the
    /// correction `shown` (under the fused compass then): moved to now by the compass's
    /// wander since, and held from now.
    public mutating func lineUp(_ shown: Double, at then: GyroReading?, now: GyroReading?) {
        guard let then, let now, then.epoch == now.epoch else { return set(shown, at: now) }
        set(shown + azimuthDifference(then.divergence, now.divergence), at: now)
    }
}

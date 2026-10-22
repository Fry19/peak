import Foundation

/// A heading correction kept for the next launch at the same spot.
///
/// The compass error is mostly the place's (steel in a balcony railing, a building), so a
/// correction found by skyline matching or lining up by hand is worth starting from when
/// the app opens again where it was found: through a window where only a sliver of ridge
/// shows, single frames may be rightly too ambiguous to match, and the plain compass would
/// be off by as much as it was last time. It's only a starting point: it doesn't count as a
/// match, the matcher searches around the plain compass as before, and the first lock
/// replaces it.
///
/// `heading` is the error under the fused compass (`HeldHeading.heading` plus the hold),
/// degrees, which doesn't depend on whether the compass is referenced to magnetic or true
/// north as long as the declination is known; so it's only kept, and only restored, with
/// the sensors on true north.
public struct RememberedHeading: Codable, Sendable, Equatable {
    public var heading: Double
    public var latitude: Double
    public var longitude: Double
    /// The location fix's accuracy, meters.
    public var accuracy: Double
    public var date: Date
    /// Lined up by hand rather than by skyline matching.
    public var byHand: Bool
    /// The phone was held sideways (for the diagnostics; the heading is shared by both ways).
    public var sideways: Bool

    /// Further than this from where it was found, the compass is pulled differently, meters.
    public static let maxDistance = 100.0
    /// Fixes rougher than this, here or then, can't tell the spot from the next one, meters.
    public static let maxAccuracy = 50.0
    /// The disturbance from buildings stays put, but the phone's own magnetic calibration can
    /// shift (a magnet in a case, a strong field nearby), so after a week it's not trusted.
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    /// A compass this far off is a bad fit, not an error to start from, degrees.
    public static let maxHeading = 30.0

    public init(heading: Double, latitude: Double, longitude: Double, accuracy: Double, date: Date,
                byHand: Bool, sideways: Bool) {
        self.heading = heading
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.date = date
        self.byHand = byHand
        self.sideways = sideways
    }

    /// Whether it's sound to keep: finite, a real place found with a precise fix, a heading
    /// within reason.
    public var isValid: Bool {
        heading.isFinite && abs(heading) <= Self.maxHeading
            && latitude.isFinite && abs(latitude) <= 90 && longitude.isFinite && abs(longitude) <= 180
            && accuracy.isFinite && accuracy >= 0 && accuracy <= Self.maxAccuracy
    }

    /// Meters from where it was found to `latitude`, `longitude`.
    public func distance(latitude: Double, longitude: Double) -> Double {
        LatLon(self.latitude, self.longitude).distance(to: LatLon(latitude, longitude))
    }

    /// Whether to start from it at `latitude`, `longitude` (a fix `accuracy` meters good)
    /// at `now`.
    public func applies(latitude: Double, longitude: Double, accuracy: Double, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return isValid && accuracy >= 0 && accuracy <= Self.maxAccuracy
            && age >= 0 && age <= Self.maxAge
            && distance(latitude: latitude, longitude: longitude) <= Self.maxDistance
    }
}

extension HeadingHold {
    /// Whether the hold is whole with the gyroscope at `gyro` (lined up no more than `full`
    /// seconds ago, in this gyroscope run), so the heading it gives can be trusted as much
    /// as the line-up itself.
    public func isWhole(_ gyro: GyroReading?) -> Bool {
        guard let gyro, let r = reference, r.epoch == gyro.epoch else { return false }
        return gyro.time - r.time <= full
    }
}

extension HeldHeading {
    /// Starts from a heading remembered from before (`RememberedHeading`): no hold, since
    /// the gyroscope's zero didn't survive, and the lock as it is (two fresh matches must
    /// agree before it takes over).
    public mutating func restore(_ remembered: Double) {
        heading = remembered
        hold.reset()
    }
}

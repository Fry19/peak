import CoreLocation
import Foundation
import PeakCore

/// Follows you along the trail drawn on the mountain: where you are on it, what's left of
/// it, and whether you've strayed from it.
@Observable
final class TrailTracker {
    /// Where you are on the trail, while you're on it or near it (within about 150 m,
    /// allowing for the fix's accuracy). Nil otherwise.
    private(set) var progress: TrailProgress?
    /// The trail followed.
    private(set) var trailID: String?
    /// The latest fix, for the maps' you-are-here dot.
    private(set) var here: LatLon?
    /// After following the trail, more than `strayDistance` from it for over a minute:
    /// how far, meters. Nil otherwise.
    private(set) var strayed: Double?

    @ObservationIgnored private var matcher: TrailMatcher?
    @ObservationIgnored private var trail: Trail?
    @ObservationIgnored private var hasProfile = false
    @ObservationIgnored private var offSince: Date?
    /// Been on or near the trail, so straying from it is worth a word.
    @ObservationIgnored private var followed = false

    /// How near the trail counts as on it, for the live numbers, meters.
    static let nearDistance = 150.0
    static let strayDistance = 80.0
    static let strayTime: TimeInterval = 60
    /// Further than this, you're somewhere else, not off the trail.
    static let elsewhereDistance = 2_000.0

    /// Starts following a trail, or carries on with it, matching along the profile once
    /// there is one (it needs the terrain).
    func follow(_ trail: Trail, profile: TrailProfile?) {
        if trailID == trail.id, hasProfile || profile == nil { return }
        let usable = profile.flatMap { $0.points.count > 1 ? $0 : nil }
        let carryOn = trailID == trail.id
        self.trail = trail
        trailID = trail.id
        hasProfile = usable != nil
        matcher = usable.map { TrailMatcher(profile: $0) } ?? TrailMatcher(line: trail.mainLine)
        if !carryOn {
            progress = nil
            strayed = nil
            offSince = nil
            followed = false
        }
    }

    func stop() {
        matcher = nil
        trail = nil
        trailID = nil
        hasProfile = false
        progress = nil
        strayed = nil
        offSince = nil
        followed = false
    }

    /// Where to show you on a map of `trail`: on the trail when you're walking it (within
    /// 30 m), else where the phone puts you.
    func youOnMap(_ trail: Trail) -> LatLon? {
        if trailID == trail.id, let p = progress, p.offTrail < 30, p.confidence > 0.5 { return p.position }
        return here
    }

    func update(_ location: CLLocation) {
        let position = LatLon(location.coordinate.latitude, location.coordinate.longitude)
        if here != position { here = position }
        let accuracy = location.horizontalAccuracy
        guard let trail, var matcher, accuracy >= 0, accuracy < 200 else { return }
        let p = matcher.update(TrailFix(position: position, accuracy: accuracy, time: location.timestamp))
        self.matcher = matcher
        guard let p else { return }

        // On it: near its main line, with some slack once already on it.
        let slack = min(accuracy, 50) + (progress != nil ? 50 : 0)
        let on = p.offTrail <= Self.nearDistance + slack && p.confidence > 0.1
        let next = on ? p : nil
        if next != progress { progress = next }
        if on { followed = true }

        // Off it: further than `strayDistance` from every line of it (a side branch is still
        // the trail), allowing for half the fix's accuracy, for over a minute.
        let off = min(p.offTrail, trail.distance(to: position))
        if off > Self.elsewhereDistance { followed = false }
        if followed, off - accuracy / 2 > Self.strayDistance {
            let since = offSince ?? location.timestamp
            offSince = since
            let value = location.timestamp.timeIntervalSince(since) >= Self.strayTime ? (off / 10).rounded() * 10 : nil
            if value != strayed { strayed = value }
        } else {
            offSince = nil
            if strayed != nil { strayed = nil }
        }
    }
}

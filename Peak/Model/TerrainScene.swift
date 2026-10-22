import Foundation
import PeakCore

/// Everything drawn for one viewpoint: the horizon, its ridgelines and the peaks.
struct TerrainScene: @unchecked Sendable {
    static let radius = 80_000.0

    /// A peak within range, seen from here.
    struct PeakView: Sendable {
        var peak: Peak
        var azimuth: Double
        var elevation: Double
        var distance: Double
        /// In sight, not hidden behind nearer terrain.
        var isVisible: Bool
        /// Seen over the base layer's coarse terrain, which can't tell whether it is in sight:
        /// shown as a dot, never labeled as in sight or hidden.
        var isUncertain = false
    }

    let observer: GeoPoint
    let terrain: Terrain
    /// The view, drawn and labeled from up to `nearAllowance` above the eye as far as the
    /// ground near you goes.
    let horizon: HorizonProfile
    /// The skyline as the ground near you stands, which is what the camera sees from it and
    /// where the sun really goes: skyline matching and today's sun times use this one.
    let matchingHorizon: HorizonProfile
    /// Ridge segments bucketed by whole degree of azimuth, for drawing only what's in view.
    let segments: [[RidgeSegment]]
    /// Visible peaks, the most worth a label first (`PeakRanking`): prominent summits that
    /// stand out from here, not every sub-summit of a high massif.
    let peaks: [VisiblePeak]
    /// Each visible peak's rank score, by id.
    let scores: [Int64: Double]
    /// Every peak within range, visible or not, by id.
    let allPeaks: [Int64: PeakView]
    /// Peaks in `peaks` whose line of sight crosses coarse terrain too closely to tell: dots only.
    let uncertain: Set<Int64>
    /// You're standing on the base layer's coarse terrain (nothing finer is in yet).
    let isCoarse: Bool

    /// Ground within a kilometer that rises less than this above your eye doesn't hide what's
    /// behind it, meters (`HorizonSettings.nearAllowance`). From a valley or a town the
    /// mountains may stand only a degree or two up, and a gentle rise a few meters above
    /// the eye a few hundred meters away would hide them all, though from a floor up, a
    /// deck or a step uphill they're in sight. Real hills still hide them.
    static let nearAllowance = 10.0

    /// `accuracy` is the fix's horizontal accuracy, meters: the eye stands on the highest
    /// ground within it (up to 30 m), so a fix just off a crest doesn't hide the view.
    /// `altitude` is the GPS altitude, meters, if it is good: on the base layer's coarse
    /// terrain, whose ground is kilometers of average, it places the eye instead.
    static func build(terrain: Terrain, latitude: Double, longitude: Double, accuracy: Double, altitude: Double? = nil,
                      peaks: [Peak]) -> TerrainScene {
        // Peaks OpenStreetMap has no elevation for take the terrain's. Then give blunted
        // summits their real tips before drawing skylines from them.
        let peaks = terrain.fillElevations(peaks)
        // Tiles are shared between scenes: no view from above may read them meanwhile.
        terrainWrites.lock()
        terrain.raiseSummits(peaks)
        terrainWrites.unlock()
        let renderer = HorizonRenderer(terrain: terrain)
        var observer = renderer.observer(latitude: latitude, longitude: longitude, accuracy: accuracy)
        let isCoarse = terrain.isCoarse(latitude: latitude, longitude: longitude)
        // On coarse ground the first few kilometers are left out (`HorizonSettings.coarse`).
        var settings = isCoarse ? HorizonSettings.coarse : HorizonSettings()
        settings.maxDistance = radius
        settings.nearAllowance = nearAllowance
        if isCoarse, let altitude { observer.height = altitude }
        return view(from: observer, terrain: terrain, peaks: peaks, settings: settings, isCoarse: isCoarse)
    }

    /// The view from `lift` meters above this one's eye, for seeing over the ridges in front
    /// (`AppModel+Rise`): the same terrain, peaks and horizon settings. It is only drawn, so
    /// its horizon keeps no depth map, and nothing is matched or draped against it.
    func risen(by lift: Double) -> TerrainScene {
        var eye = observer
        eye.height += lift
        Self.terrainWrites.lock()
        defer { Self.terrainWrites.unlock() }
        let view = Self.view(from: eye, terrain: terrain, peaks: allPeaks.values.map(\.peak), settings: horizon.settings,
                             isCoarse: isCoarse)
        let slim = view.horizon.withoutDepth()
        return TerrainScene(observer: eye, terrain: terrain, horizon: slim, matchingHorizon: slim, segments: view.segments,
                            peaks: view.peaks, scores: view.scores, allPeaks: view.allPeaks, uncertain: view.uncertain,
                            isCoarse: isCoarse)
    }

    /// Held while summits are raised in the shared tiles (`build`) and while a view from above
    /// reads them (`risen`): the live view's rebuild may raise new ones as tiles arrive.
    private static let terrainWrites = NSLock()

    private static func view(from observer: GeoPoint, terrain: Terrain, peaks: [Peak], settings: HorizonSettings,
                             isCoarse: Bool) -> TerrainScene {
        let renderer = HorizonRenderer(terrain: terrain)
        let horizon = renderer.render(from: observer, settings: settings)
        var buckets = [[RidgeSegment]](repeating: [], count: 360)
        for s in horizon.ridgeSegments() {
            buckets[Int(s.azimuth0) % 360].append(s)
        }
        // Over coarse terrain, near peaks and those just clearing (or just hidden by) the
        // ridges in front can't be told apart: they get dots, as if in sight, but no label.
        var found: [VisiblePeak] = []
        var uncertain = Set<Int64>()
        if terrain.hasCoarse {
            let here = LatLon(observer.latitude, observer.longitude)
            for (p, v) in renderer.sightlines(peaks, from: observer, maxDistance: radius, settings: settings) {
                let unsure = terrain.isCoarse(between: here, and: p.position) &&
                    CoarseSight.isUncertain(distance: v.distance, clearance: v.clearance)
                if unsure { uncertain.insert(p.id) }
                if v.isVisible || unsure {
                    found.append(VisiblePeak(peak: p, azimuth: v.azimuth, elevation: v.elevation, distance: v.distance))
                }
            }
        } else {
            found = renderer.visiblePeaks(peaks, from: observer, maxDistance: radius, settings: settings)
        }
        var scores: [Int64: Double] = [:]
        for v in found {
            let rise = horizon.rise(azimuth: v.azimuth, elevation: v.elevation)
            scores[v.id] = PeakRanking.score(v.peak, rise: rise, distance: v.distance)
        }
        let visible = found.sorted { scores[$0.id, default: 0] > scores[$1.id, default: 0] }
        let frame = LocalFrame(origin: observer)
        var all: [Int64: PeakView] = [:]
        for p in peaks {
            let look = frame.look(at: p.point, refraction: settings.refraction)
            if look.distance < radius {
                all[p.id] = PeakView(peak: p, azimuth: look.azimuth, elevation: look.elevation, distance: look.distance,
                                     isVisible: false, isUncertain: uncertain.contains(p.id))
            }
        }
        for v in visible where !uncertain.contains(v.id) { all[v.id]?.isVisible = true }
        return TerrainScene(observer: observer, terrain: terrain, horizon: horizon, matchingHorizon: horizon.withNearGround(),
                            segments: buckets, peaks: visible, scores: scores, allPeaks: all, uncertain: uncertain,
                            isCoarse: isCoarse)
    }

    /// A trail laid on the terrain as seen from here, with the stretches behind nearer
    /// ridges marked, so they can be hidden or seen through. Its main line comes first (line
    /// 0), as the profile has it when there is one, so distances along it match those of a
    /// `TrailMatcher` on that profile. Seen from `here` when given (where you are now,
    /// walking the trail) rather than from where the view was built; the trail within 120 m
    /// of it is drawn on the ground in any case.
    func drape(_ trail: Trail, profile: TrailProfile?, from here: LatLon? = nil) -> (runs: [[DrapedPoint]], observer: GeoPoint) {
        let renderer = HorizonRenderer(terrain: terrain)
        let main = profile.map { $0.points.map(\.position) }.flatMap { $0.count > 1 ? $0 : nil } ?? trail.mainLine
        var others = trail.lines
        if let i = others.firstIndex(of: trail.mainLine) { others.remove(at: i) }
        var eye = observer
        if let here, here.distance(to: position) < 2_000 {
            let e = renderer.observer(latitude: here.latitude, longitude: here.longitude)
            if e.height.isFinite, terrain.height(latitude: here.latitude, longitude: here.longitude).isFinite { eye = e }
        }
        let runs = renderer.drape([main] + others, from: eye, horizon: horizon, minDistance: 12, clearDistance: 120, includeHidden: true)
        return (runs, eye)
    }

    var position: LatLon { LatLon(observer.latitude, observer.longitude) }
}

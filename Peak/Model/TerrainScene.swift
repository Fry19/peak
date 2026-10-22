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
    /// The terrain all around, as downloaded: for hikes, maps, the sun on summits and the
    /// heights of the trail drawn on the mountain.
    let terrain: Terrain
    /// The terrain the view is drawn from: `terrain`, but with bare ground within a
    /// kilometer of you where there is some (USGS 3DEP in the United States), so the
    /// buildings and trees in Copernicus's surface model around you neither hide the
    /// mountains nor make skylines of their own. The eye stays on the surface model as before,
    /// so trees all around at its height don't rise into a skyline where the bare ground
    /// ends, unless the bare ground is higher (a summit's top, which a surface model blunts).
    /// Lines, labels, what's hidden and the views from above use it.
    let viewTerrain: Terrain
    /// Whether the view has bare ground near you (`viewTerrain`), to credit it.
    let standsOnGround: Bool
    /// The view, drawn and labeled from up to `nearAllowance` above the eye as far as the
    /// ground near you goes.
    let horizon: HorizonProfile
    /// The view on the surface model alone, from the eye on it, as it was before bare ground
    /// near you: the trail drawn on the mountain, whose heights are the surface model's, is
    /// laid against it. The same as `horizon` without bare ground near you.
    let surfaceHorizon: HorizonProfile
    /// The skyline as the surface near you stands, from the eye on it: what the camera sees,
    /// treetops and roofs included, and where the sun really goes. Skyline matching and
    /// today's sun times use this one.
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
    /// How many peaks within range have a prominence: views that rank them themselves rank
    /// again when Wikidata's comes in, though no peak was added.
    let prominent: Int
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
    /// `prominence` is Wikidata's by item, meters (`DataStore.prominence`).
    static func build(terrain: Terrain, latitude: Double, longitude: Double, accuracy: Double, altitude: Double? = nil,
                      peaks: [Peak], prominence: [String: Double] = [:]) -> TerrainScene {
        // Peaks OpenStreetMap has no elevation for take the terrain's, and those it has no
        // prominence for Wikidata's, for ranking. Then give blunted summits their real tips
        // before drawing skylines from them.
        let peaks = Wikidata.fillProminence(terrain.fillElevations(peaks), from: prominence)
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
        // Bare ground within a kilometer, where it's in (`viewTerrain`).
        guard !isCoarse, let land = terrain.withGround(within: settings.nearRange, latitude: latitude, longitude: longitude) else {
            return view(from: observer, terrain: terrain, viewTerrain: terrain, peaks: peaks, settings: settings, isCoarse: isCoarse)
        }
        // Summits near you get their tips on the copy of the bare ground too (the rest are
        // in the tiles it shares, raised above).
        let reach = settings.nearRange + 2_000
        let here = LatLon(latitude, longitude)
        terrainWrites.lock()
        land.raiseSummits(peaks.filter { $0.position.distance(to: here) < reach })
        terrainWrites.unlock()
        let ground = HorizonRenderer(terrain: land).observer(latitude: latitude, longitude: longitude, accuracy: accuracy)
        let eye = ground.height > observer.height ? ground : observer
        // The trail and matching keep the surface and the eye on it, as the camera sees it.
        let surface = renderer.render(from: observer, settings: settings)
        return view(from: eye, terrain: terrain, viewTerrain: land, peaks: peaks, settings: settings, isCoarse: isCoarse,
                    surface: surface)
    }

    /// How far this view sees, meters: `radius` on the ground; from above, farther.
    var reach: Double { horizon.settings.maxDistance }

    /// How far the view from `lift` meters above the eye reaches, meters (on the base layer
    /// past the tiles, `Beyond`). Seen from high up, a skyline at the edge of the terrain is
    /// that edge, not the real one: from 3 km up an edge 80 km away lies about 2.5° below
    /// level and up to 1–2° under the mountains beyond it. A rule of thumb rather than a bound:
    /// 1.2 times as far as the horizon over ground at your own level is from that height (121 km
    /// from 1 km up, 210 km from 3 km), at least 150 km and at most 250 km. Against views out
    /// to 450 km over the Smokies and from Zermatt, 150 km leaves the skyline at the edge on
    /// at most 3% of bearings from 1 km up, and 250 km on 0.5–9% from 3 km, there within 0.15°.
    static func reach(lift: Double) -> Double {
        let flat = (2 * WGS84.a / (1 - HorizonSettings().refraction) * max(0, lift)).squareRoot()
        return min(250_000, max(150_000, 1.2 * flat))
    }

    /// What the views from above see past the ground view's reach: the view's terrain
    /// (`viewTerrain`), with the base layer's coarse tiles past the ones loaded, and every
    /// peak, out to `reach`.
    struct Beyond: Sendable {
        let terrain: Terrain
        /// This view's own peaks, then the base layer's past `radius` (which this view has none of).
        let peaks: [Peak]
        let reach: Double
    }

    /// The terrain and peaks out to `reach` for the views from above (`risen(by:beyond:)`):
    /// this view's own, and past them the base layer's, its peaks' prominence filled from
    /// Wikidata's (`prominence`) as the live view's are. Without a base layer, only this view's,
    /// out to `radius`.
    func beyond(_ reach: Double, base: BaseLayer?, prominence: [String: Double]) -> Beyond {
        let own = allPeaks.values.map(\.peak)
        guard let base, reach > Self.radius else { return Beyond(terrain: viewTerrain, peaks: own, reach: Self.radius) }
        let wide = Terrain(tiles: viewTerrain.tiles, detail: viewTerrain.detail, ground: viewTerrain.groundPatches, base: base,
                           latitude: observer.latitude, longitude: observer.longitude, radius: reach + 10_000)
        // Within `radius` the peaks are this view's (`allPeaks`, as far as it reaches), so that from
        // above no peak shows up nearer than that which the ground view doesn't have.
        let frame = LocalFrame(origin: observer)
        let refraction = horizon.settings.refraction
        let far = base.peaks(latitude: observer.latitude, longitude: observer.longitude, radius: reach + 1_000).filter {
            allPeaks[$0.id] == nil && frame.look(at: $0.point, refraction: refraction).distance >= Self.radius
        }
        Self.terrainWrites.lock()
        let filled = wide.fillElevations(far)
        Self.terrainWrites.unlock()
        return Beyond(terrain: wide, peaks: own + Wikidata.fillProminence(filled, from: prominence), reach: reach)
    }

    /// The view from `lift` meters above this one's eye, for seeing over the ridges in front
    /// (`AppModel+Rise`): the same horizon settings, out to `reach(lift:)` over `beyond`'s terrain
    /// and peaks. It is only drawn, so its horizon keeps no depth map, and nothing is matched or
    /// draped against it.
    func risen(by lift: Double, beyond: Beyond) -> TerrainScene {
        var eye = observer
        eye.height += lift
        var settings = horizon.settings
        settings.maxDistance = min(beyond.reach, Self.reach(lift: lift))
        Self.terrainWrites.lock()
        defer { Self.terrainWrites.unlock() }
        let view = Self.view(from: eye, terrain: terrain, viewTerrain: beyond.terrain, peaks: beyond.peaks, settings: settings,
                             isCoarse: isCoarse, spareHidden: true)
        let slim = view.horizon.withoutDepth()
        return TerrainScene(observer: eye, terrain: terrain, viewTerrain: beyond.terrain, standsOnGround: standsOnGround, horizon: slim,
                            surfaceHorizon: slim, matchingHorizon: slim, segments: view.segments, peaks: view.peaks, scores: view.scores,
                            allPeaks: view.allPeaks, uncertain: view.uncertain, prominent: view.prominent, isCoarse: isCoarse)
    }

    /// `peaks` past this view's reach (shown from above) as seen from here, out to `reach` over
    /// `beyond`'s terrain: in sight, hidden, or uncertain over coarse terrain, as `allPeaks` has
    /// the nearer ones.
    func sight(ofFar peaks: [Peak], over beyond: Beyond, reach: Double) -> [Int64: PeakView] {
        guard !peaks.isEmpty else { return [:] }
        var settings = horizon.settings
        settings.maxDistance = reach
        let frame = LocalFrame(origin: observer)
        Self.terrainWrites.lock()
        // Seen from the ground most lie deep behind the ridges this view sees (out to `radius`).
        let found = HorizonRenderer(terrain: beyond.terrain).sightings(peaks, from: observer, settings: settings,
                                                                       rendered: horizon)
        Self.terrainWrites.unlock()
        var seen: [Int64: PeakView] = [:]
        for (p, v, unsure) in found {
            let look = frame.look(at: p.point, refraction: settings.refraction)
            seen[p.id] = PeakView(peak: p, azimuth: look.azimuth, elevation: look.elevation, distance: look.distance,
                                  isVisible: v.isVisible && !unsure, isUncertain: unsure)
        }
        return seen
    }

    /// The terrain around this view's eye as triangles, out to `beyond`'s reach, for drawing the
    /// views from above in 3D: one mesh for every height, since only the eye moves (each fades
    /// it out at its own reach).
    func panorama(over beyond: Beyond) -> PanoramaMesh {
        var settings = PanoramaMeshSettings()
        settings.maxDistance = beyond.reach
        settings.refraction = horizon.settings.refraction
        Self.terrainWrites.lock()
        defer { Self.terrainWrites.unlock() }
        return PanoramaMesh.build(terrain: beyond.terrain, from: observer, settings: settings)
    }

    /// Held while summits are raised in the shared tiles (`build`) and while a view from above
    /// reads them (`beyond`, `risen`, `sight`, `panorama`): the live view's rebuild may raise
    /// new ones as tiles arrive.
    private static let terrainWrites = NSLock()

    /// The view from `observer` over `viewTerrain`; `surface` is the view on the surface model
    /// alone (`surfaceHorizon`) when that isn't this one. `spareHidden`: far peaks deep behind
    /// the ridges in front stop their line of sight at a confirmed obstruction
    /// (`HorizonRenderer.sightings`), for views from above with thousands of peaks.
    private static func view(from observer: GeoPoint, terrain: Terrain, viewTerrain: Terrain, peaks: [Peak],
                             settings: HorizonSettings, isCoarse: Bool, surface: HorizonProfile? = nil,
                             spareHidden: Bool = false) -> TerrainScene {
        let renderer = HorizonRenderer(terrain: viewTerrain)
        let horizon = renderer.render(from: observer, settings: settings)
        var buckets = [[RidgeSegment]](repeating: [], count: 360)
        for s in horizon.ridgeSegments() {
            buckets[Int(s.azimuth0) % 360].append(s)
        }
        // Over coarse terrain, near peaks and those just clearing (or just hidden by) the
        // ridges in front can't be told apart: they get dots, as if in sight, but no label.
        // Peaks are seen out to the horizon's reach: `radius` on the ground.
        var found: [VisiblePeak] = []
        var uncertain = Set<Int64>()
        if viewTerrain.hasCoarse {
            for (p, v, unsure) in renderer.sightings(peaks, from: observer, settings: settings,
                                                     rendered: spareHidden ? horizon : nil) {
                if unsure { uncertain.insert(p.id) }
                if v.isVisible || unsure {
                    found.append(VisiblePeak(peak: p, azimuth: v.azimuth, elevation: v.elevation, distance: v.distance))
                }
            }
        } else {
            found = renderer.visiblePeaks(peaks, from: observer, maxDistance: settings.maxDistance, settings: settings)
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
            if look.distance < settings.maxDistance {
                all[p.id] = PeakView(peak: p, azimuth: look.azimuth, elevation: look.elevation, distance: look.distance,
                                     isVisible: false, isUncertain: uncertain.contains(p.id))
            }
        }
        for v in visible where !uncertain.contains(v.id) { all[v.id]?.isVisible = true }
        return TerrainScene(observer: observer, terrain: terrain, viewTerrain: viewTerrain, standsOnGround: viewTerrain !== terrain,
                            horizon: horizon, surfaceHorizon: surface ?? horizon,
                            matchingHorizon: (surface ?? horizon).withNearGround(), segments: buckets,
                            peaks: visible, scores: scores, allPeaks: all, uncertain: uncertain,
                            prominent: all.values.filter { $0.peak.prominence != nil }.count, isCoarse: isCoarse)
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
        // On the surface model from the eye on it, the trail's heights' own (the view's eye may
        // stand on higher bare ground), as before bare ground near you.
        var eye = surfaceHorizon.observer
        if let here, here.distance(to: position) < 2_000 {
            let e = renderer.observer(latitude: here.latitude, longitude: here.longitude)
            if e.height.isFinite, terrain.height(latitude: here.latitude, longitude: here.longitude).isFinite { eye = e }
        }
        let runs = renderer.drape([main] + others, from: eye, horizon: surfaceHorizon, minDistance: 12, clearDistance: 120,
                                  includeHidden: true)
        return (runs, eye)
    }

    var position: LatLon { LatLon(observer.latitude, observer.longitude) }
}

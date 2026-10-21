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
    }

    let observer: GeoPoint
    let terrain: Terrain
    let horizon: HorizonProfile
    /// Ridge segments bucketed by whole degree of azimuth, for drawing only what's in view.
    let segments: [[RidgeSegment]]
    /// Visible peaks, the most worth a label first (`PeakRanking`): prominent summits that
    /// stand out from here, not every sub-summit of a high massif.
    let peaks: [VisiblePeak]
    /// Each visible peak's rank score, by id.
    let scores: [Int64: Double]
    /// Every peak within range, visible or not, by id.
    let allPeaks: [Int64: PeakView]

    static func build(terrain: Terrain, latitude: Double, longitude: Double, peaks: [Peak]) -> TerrainScene {
        // Peaks OpenStreetMap has no elevation for take the terrain's. Then give blunted
        // summits their real tips before drawing skylines from them.
        let peaks = terrain.fillElevations(peaks)
        terrain.raiseSummits(peaks)
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: latitude, longitude: longitude)
        var settings = HorizonSettings()
        settings.maxDistance = radius
        let horizon = renderer.render(from: observer, settings: settings)
        var buckets = [[RidgeSegment]](repeating: [], count: 360)
        for s in horizon.ridgeSegments() {
            buckets[Int(s.azimuth0) % 360].append(s)
        }
        var scores: [Int64: Double] = [:]
        let found = renderer.visiblePeaks(peaks, from: observer, maxDistance: radius, settings: settings)
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
                all[p.id] = PeakView(peak: p, azimuth: look.azimuth, elevation: look.elevation, distance: look.distance, isVisible: false)
            }
        }
        for v in visible { all[v.id]?.isVisible = true }
        return TerrainScene(observer: observer, terrain: terrain, horizon: horizon, segments: buckets, peaks: visible,
                            scores: scores, allPeaks: all)
    }

    /// A trail laid on the terrain as seen from here, with the stretches behind nearer
    /// ridges marked, so they can be hidden or seen through.
    func drape(_ trail: Trail) -> [[DrapedPoint]] {
        HorizonRenderer(terrain: terrain).drape(trail.lines, from: observer, horizon: horizon, includeHidden: true)
    }

    var position: LatLon { LatLon(observer.latitude, observer.longitude) }
}

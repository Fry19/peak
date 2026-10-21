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
    /// Visible peaks, highest first, so labels for the big peaks are placed first.
    let peaks: [VisiblePeak]
    /// Every peak within range, visible or not, by id.
    let allPeaks: [Int64: PeakView]

    static func build(terrain: Terrain, latitude: Double, longitude: Double, peaks: [Peak]) -> TerrainScene {
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: latitude, longitude: longitude)
        var settings = HorizonSettings()
        settings.maxDistance = radius
        let horizon = renderer.render(from: observer, settings: settings)
        var buckets = [[RidgeSegment]](repeating: [], count: 360)
        for s in horizon.ridgeSegments() {
            buckets[Int(s.azimuth0) % 360].append(s)
        }
        let visible = renderer.visiblePeaks(peaks, from: observer, maxDistance: radius, settings: settings)
            .sorted { $0.peak.elevation > $1.peak.elevation }
        let frame = LocalFrame(origin: observer)
        var all: [Int64: PeakView] = [:]
        for p in peaks {
            let look = frame.look(at: p.point, refraction: settings.refraction)
            if look.distance < radius {
                all[p.id] = PeakView(peak: p, azimuth: look.azimuth, elevation: look.elevation, distance: look.distance, isVisible: false)
            }
        }
        for v in visible { all[v.id]?.isVisible = true }
        return TerrainScene(observer: observer, terrain: terrain, horizon: horizon, segments: buckets, peaks: visible, allPeaks: all)
    }

    /// The stretches of a trail in sight from here, laid on the terrain.
    func drape(_ trail: Trail) -> [[DrapedPoint]] {
        HorizonRenderer(terrain: terrain).drape(trail.lines, from: observer, horizon: horizon)
    }

    var position: LatLon { LatLon(observer.latitude, observer.longitude) }
}

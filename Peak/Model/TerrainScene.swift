import Foundation
import PeakCore

/// Everything drawn for one viewpoint: the horizon, its ridgelines and the visible peaks.
struct TerrainScene: @unchecked Sendable {
    static let radius = 80_000.0

    let observer: GeoPoint
    let horizon: HorizonProfile
    /// Ridge segments bucketed by whole degree of azimuth, for drawing only what's in view.
    let segments: [[RidgeSegment]]
    /// Visible peaks, highest first, so labels for the big peaks are placed first.
    let peaks: [VisiblePeak]

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
        return TerrainScene(observer: observer, horizon: horizon, segments: buckets, peaks: visible)
    }
}

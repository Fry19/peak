import XCTest
@testable import PeakCore

final class HorizonTipTests: XCTestCase {
    /// A 30 m grid whose raised summit falls both between 0.1° rays and between 15 m steps.
    private func scene(azimuth: Double = 65.047, ridge: Bool = false, gap: Bool = false) -> (Terrain, Peak, GeoPoint) {
        let observer = GeoPoint(latitude: 45.5, longitude: 8.2, height: 1_001.6)
        let p = destination(from: observer, azimuth: azimuth, distance: 10_002.3)
        let peak = Peak(id: 1, name: "Needle", latitude: p.latitude, longitude: p.longitude, elevation: 2_200)
        let step = 1.0 / 3600, rows = 601, cols = 701
        let north = p.latitude + 100 * step, west = p.longitude - 500 * step
        let rowMeters = step * 111_320, colMeters = rowMeters * cos(p.latitude * .pi / 180)
        let wall = destination(from: observer, azimuth: azimuth, distance: 5_000)
        var heights = [Int16](repeating: 1_000, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let lat = north - Double(r) * step, lon = west + Double(c) * step
                let d = hypot(Double(r - 100) * rowMeters, Double(c - 500) * colMeters)
                var h = 1_000 + max(0, 1_000 - d)
                if ridge {
                    let dw = hypot((lat - wall.latitude) * 111_320,
                                   (lon - wall.longitude) * 111_320 * cos(lat * .pi / 180))
                    h = max(h, 1_000 + max(0, 1_500 * (1 - dw / 300)))
                }
                heights[r * cols + c] = gap && abs(lon - wall.longitude) < 0.002 ? ElevationTile.noData : Int16(h.rounded())
            }
        }
        let tile = ElevationTile(south: 45, west: 8, rows: rows, cols: cols,
                                 originLatitude: north, originLongitude: west,
                                 stepLatitude: step, stepLongitude: step, heights: heights)
        return (Terrain(tiles: [tile], missingIsSea: false), peak, observer)
    }

    private var settings: HorizonSettings {
        var s = HorizonSettings()
        s.maxDistance = 11_500
        return s
    }

    func testRaisedSummitBetweenRaysAndStepsKeepsItsHeightAndDepth() {
        for azimuth in [65.047, 359.96] {
            let (terrain, peak, observer) = scene(azimuth: azimuth)
            XCTAssertEqual(terrain.raiseSummits([peak]), 1)
            let profile = HorizonRenderer(terrain: terrain).render(from: observer, settings: settings)
            let look = LocalFrame(origin: observer).look(at: peak.point, refraction: settings.refraction)
            let i = Int((look.azimuth / settings.azimuthStep).rounded()) % profile.count
            let distance = groundDistance(from: observer, to: peak.point)
            let errorMeters = distance * (tan(look.elevation * .pi / 180) - tan(Double(profile.elevations[i]) * .pi / 180))
            XCTAssertEqual(errorMeters, 0, accuracy: 3, "azimuth \(azimuth): no loss between rays or steps")
            XCTAssertEqual(Double(profile.distances[i]), distance, accuracy: 1)
            let envelope = Array(profile.envelope(ofRay: i))
            XCTAssertEqual(envelope.last?.elevation, profile.elevations[i])
            XCTAssertEqual(envelope.last?.distance, profile.distances[i])
            for j in 1..<envelope.count {
                XCTAssertGreaterThan(envelope[j].elevation, envelope[j - 1].elevation)
                XCTAssertGreaterThan(envelope[j].distance, envelope[j - 1].distance)
            }
            XCTAssertEqual(profile.distance(atAzimuth: profile.azimuth(ofRay: i),
                                             elevation: Double(profile.elevations[i]) - 0.0001)!, distance, accuracy: 1)
        }
    }

    /// Two needles a third of a degree apart, neither on a ray. The farther one's eased flank
    /// passes just by the nearer one's tip, higher than the regular ray there but lower than
    /// that tip, and each ray keeps the higher skyline whichever tip comes first. Every ray's
    /// depth envelope stays in order, including flanks marched again just in front of a tip.
    func testNeighboringTipsBothKeepTheirHeight() {
        let observer = GeoPoint(latitude: 45.5, longitude: 8.2, height: 1_001.6)
        // The farther one is to the south, so it comes later in the tile.
        let summits = [(115.047, 10_002.3), (115.33, 10_481.7)].map { destination(from: observer, azimuth: $0.0, distance: $0.1) }
        let step = 1.0 / 3600, rows = 401, cols = 601
        let north = summits[0].latitude + 200 * step, west = summits[0].longitude - 450 * step
        var heights = [Int16](repeating: 1_000, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let lat = north - Double(r) * step, lon = west + Double(c) * step
                let cones = summits.map { s in
                    1_000 + max(0, 400 - hypot((lat - s.latitude) * 111_320, (lon - s.longitude) * 111_320 * cos(lat * .pi / 180)))
                }
                heights[r * cols + c] = Int16(cones.max()!.rounded())
            }
        }
        let terrain = Terrain(tiles: [ElevationTile(south: 45, west: 8, rows: rows, cols: cols,
                                                    originLatitude: north, originLongitude: west,
                                                    stepLatitude: step, stepLongitude: step, heights: heights)],
                              missingIsSea: false)
        let peaks = summits.enumerated().map {
            Peak(id: Int64($0.offset), name: "Needle", latitude: $0.element.latitude, longitude: $0.element.longitude, elevation: 1_600)
        }
        XCTAssertEqual(terrain.raiseSummits(peaks), 2)
        let profile = HorizonRenderer(terrain: terrain).render(from: observer, settings: settings)

        var apexRays: [Int] = []
        for s in summits {
            // The tip's point is on the grid node nearest the summit.
            let apex = GeoPoint(latitude: north - ((north - s.latitude) / step).rounded() * step,
                                longitude: west + ((s.longitude - west) / step).rounded() * step, height: 1_600)
            let look = LocalFrame(origin: observer).look(at: apex, refraction: settings.refraction)
            let i = Int((look.azimuth / settings.azimuthStep).rounded()) % profile.count
            let distance = groundDistance(from: observer, to: apex)
            let errorMeters = distance * (tan(look.elevation * .pi / 180) - tan(Double(profile.elevations[i]) * .pi / 180))
            XCTAssertEqual(errorMeters, 0, accuracy: 3)
            XCTAssertEqual(Double(profile.distances[i]), distance, accuracy: 1)
            apexRays.append(i)
        }
        XCTAssertEqual(apexRays[1] - apexRays[0], 3, "each one's flanks reach the other's apex ray")
        for i in 0..<profile.count {
            let envelope = Array(profile.envelope(ofRay: i))
            for j in envelope.indices.dropFirst() {
                XCTAssertGreaterThan(envelope[j].elevation, envelope[j - 1].elevation, "ray \(i)")
                XCTAssertGreaterThan(envelope[j].distance, envelope[j - 1].distance, "ray \(i)")
            }
        }
    }

    func testTipSurvivesRebuildingTerrainFromTheSameTiles() {
        let (terrain, peak, observer) = scene()
        XCTAssertEqual(terrain.raiseSummits([peak]), 1)
        let rebuilt = Terrain(tiles: terrain.tiles, missingIsSea: false)
        XCTAssertEqual(rebuilt.raiseSummits([peak]), 0, "the app reuses already raised tiles")
        let profile = HorizonRenderer(terrain: rebuilt).render(from: observer, settings: settings)
        let exact = LocalFrame(origin: observer).look(at: peak.point, refraction: settings.refraction)
        XCTAssertEqual(Double(profile.elevations.max()!), exact.elevation, accuracy: 0.01)
    }

    func testHiddenTipDoesNotReplaceTheNeighboringRay() {
        let (terrain, peak, observer) = scene(ridge: true)
        var coarse = settings
        coarse.azimuthStep = 10 // The regular ray misses the narrow blocking ridge.
        let renderer = HorizonRenderer(terrain: terrain)
        let before = renderer.render(from: observer, settings: coarse)
        XCTAssertEqual(terrain.raiseSummits([peak]), 1)
        XCTAssertFalse(renderer.visibility(of: peak.point, from: observer, settings: coarse).isVisible)
        let after = renderer.render(from: observer, settings: coarse)
        XCTAssertEqual(after.elevations, before.elevations, "a tip hidden on its exact bearing must not be injected")
        XCTAssertEqual(after.distances, before.distances)
    }

    func testTipBeyondMissingTerrainDoesNotBridgeTheGap() {
        let (terrain, peak, observer) = scene(gap: true)
        let renderer = HorizonRenderer(terrain: terrain)
        let before = renderer.render(from: observer, settings: settings)
        XCTAssertEqual(terrain.raiseSummits([peak]), 1)
        let after = renderer.render(from: observer, settings: settings)
        XCTAssertEqual(after.elevations, before.elevations)
        XCTAssertEqual(after.distances, before.distances)
    }

    func testTipOutsideRenderRangeIsExcluded() {
        let (terrain, peak, observer) = scene()
        var short = settings
        short.maxDistance = 9_000
        let renderer = HorizonRenderer(terrain: terrain)
        let before = renderer.render(from: observer, settings: short)
        XCTAssertEqual(terrain.raiseSummits([peak]), 1)
        let after = renderer.render(from: observer, settings: short)
        XCTAssertEqual(after.elevations, before.elevations)
        XCTAssertEqual(after.distances, before.distances)
    }

    func testFinerPatchDoesNotInheritAnObsoleteTipHeight() {
        let (terrain, peak, observer) = scene()
        XCTAssertEqual(terrain.raiseSummits([peak]), 1)
        let t = terrain.tiles[0]
        let flat = ElevationTile(south: t.south, west: t.west, rows: t.rows, cols: t.cols,
                                 originLatitude: t.originLatitude, originLongitude: t.originLongitude,
                                 stepLatitude: t.stepLatitude, stepLongitude: t.stepLongitude,
                                 heights: [Int16](repeating: 1_000, count: t.rows * t.cols))
        let covered = Terrain(tiles: terrain.tiles, detail: [flat], missingIsSea: false)
        let profile = HorizonRenderer(terrain: covered).render(from: observer, settings: settings)
        XCTAssertLessThan(profile.elevations.max()!, 0, "the skyline uses the current blended terrain height")
    }
}

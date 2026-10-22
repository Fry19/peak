import XCTest
@testable import PeakCore

final class ViewshedTests: XCTestCase {
    /// Terrain at 6 arc-second spacing over 45–47°N, 7–9°E, from a height function of map
    /// meters east and north of 46°N 8°E.
    private func terrain(_ height: @escaping (_ east: Double, _ north: Double) -> Double) -> Terrain {
        let projection = MapProjection(center: LatLon(46, 8))
        let tiles = [(45, 7), (45, 8), (46, 7), (46, 8)].map { south, west in
            ElevationTile(south: south, west: west, size: 600) { lat, lon in
                let p = projection.point(LatLon(lat, lon))
                return height(p.x, p.y)
            }
        }
        return Terrain(tiles: tiles)
    }

    private func cell(_ v: Viewshed, east: Double, north: Double) -> Viewshed.Cell {
        v.cell(at: v.projection.latLon(SIMD2(east, north)))
    }

    /// A cone summit with a wall 10 km east of it: the ground behind the wall can't see the
    /// summit, the ground beside it can, as can the cone's own slopes and the plain in front.
    func testConeSeenOverAWall() {
        // Summit 2,000 m above a plain at 500 m; the wall's top is 1,500 m above the plain,
        // 10–10.6 km east and 3 km long north to south. Its shadow ends where the line from
        // the summit over its top meets the plain: 10 km × 2,000 / 500 = 40 km out.
        let terrain = terrain { east, north in
            let r = (east * east + north * north).squareRoot()
            var h = 500.0
            if r < 5_000 { h = max(h, 500 + 2_000 * (1 - r / 5_000)) }
            if east >= 10_000, east <= 10_600, abs(north) <= 1_500 { h = 2_000 }
            return h
        }
        var settings = ViewshedSettings()
        settings.radius = 60_000
        let summit = GeoPoint(latitude: 46, longitude: 8, height: 2_500)
        let v = Viewshed.compute(terrain: terrain, summit: summit, settings: settings)
        XCTAssertEqual(v.radius, 60_000, accuracy: 1)
        XCTAssertEqual(cell(v, east: 0, north: 0), .visible)

        // Behind the wall.
        for east in stride(from: 12_000.0, through: 36_000, by: 4_000) {
            XCTAssertEqual(cell(v, east: east, north: 0), .hidden, "\(east) m east, behind the wall")
        }
        // Past the end of the shadow the plain shows again.
        XCTAssertEqual(cell(v, east: 44_000, north: 0), .visible)
        // Beside the wall, at the same distances, and its face toward the summit.
        for east in stride(from: 12_000.0, through: 36_000, by: 4_000) {
            XCTAssertEqual(cell(v, east: east, north: east * 0.5), .visible, "\(east) m east, beside the wall")
            XCTAssertEqual(cell(v, east: east, north: -east * 0.5), .visible, "\(east) m east, beside the wall")
        }
        XCTAssertEqual(cell(v, east: 10_100, north: 0), .visible, "on the wall")
        // The cone's slopes and the plain in every other direction.
        for (east, north) in [(3_000.0, 0.0), (0, 4_000), (-20_000, 0), (0, -50_000), (-30_000, 30_000)] {
            XCTAssertEqual(cell(v, east: east, north: north), .visible, "\(east) m east, \(north) m north")
        }
        // The shadow's area, roughly the wedge it casts: about 3 km wide at 10 km, 12 km at 40 km.
        let hiddenArea = Double(v.cells.filter { $0 == .hidden }.count) * v.cellSize * v.cellSize
        XCTAssertEqual(hiddenArea, 0.5 * (3_000 + 12_000) * 30_000, accuracy: 0.25 * 225e6)
    }

    /// Seen from 300 m above a flat plain at sea level, the summit drops out of sight past
    /// √(2·300·R′) + √(2·1.6·R′) with R′ = R/(1 − k): an analytic check of curvature and refraction.
    func testCurvatureHidesTheSummitAtLongRange() {
        let flat = TestTerrain.cones([], base: 0)
        var settings = ViewshedSettings()
        settings.radius = 76_000
        settings.tolerance = 0
        let v = Viewshed.compute(terrain: flat, summit: GeoPoint(latitude: 46, longitude: 8, height: 300), settings: settings)
        for azimuth in [0.0, 90, 180, 270] {
            let r = WGS84.radius(latitude: 46 * .pi / 180, azimuth: azimuth * .pi / 180) / (1 - 0.13)
            let limit = (2 * 300 * r).squareRoot() + (2 * 1.6 * r).squareRoot()
            XCTAssertEqual(limit, 71_000, accuracy: 600)
            let direction = SIMD2(sin(azimuth * .pi / 180), cos(azimuth * .pi / 180))
            func at(_ d: Double) -> Viewshed.Cell {
                // Map meters and ground distance differ by well under 0.1% this far out.
                cell(v, east: direction.x * d, north: direction.y * d)
            }
            XCTAssertEqual(at(limit - 1_000), .visible, "azimuth \(azimuth)")
            XCTAssertEqual(at(limit + 1_000), .hidden, "azimuth \(azimuth)")
            // Where the change happens, to within a couple of cells.
            let first = stride(from: 60_000.0, to: 75_000, by: 50).first { at($0) == .hidden }
            XCTAssertEqual(first ?? 0, limit, accuracy: 400, "azimuth \(azimuth)")
        }
    }

    /// Past the edge of the loaded terrain the map says "don't know", not "hidden"; and the
    /// radius shrinks to the farthest terrain found.
    func testNoTerrainIsUnknown() {
        let flat = TestTerrain.cones([], base: 500)
        var settings = ViewshedSettings()
        settings.radius = 100_000
        settings.cellSize = 200
        let summit = GeoPoint(latitude: 46, longitude: 8, height: 2_000)
        let v = Viewshed.compute(terrain: flat, summit: summit, settings: settings)
        // The terrain ends 77 km east and west, 111 km north and south.
        XCTAssertEqual(v.radius, 100_000, accuracy: 1)
        XCTAssertEqual(cell(v, east: 85_000, north: 0), .unknown)
        XCTAssertEqual(cell(v, east: -85_000, north: 0), .unknown)
        XCTAssertEqual(cell(v, east: 70_000, north: 0), .visible)
        XCTAssertEqual(cell(v, east: 0, north: 90_000), .visible)
        XCTAssertEqual(cell(v, east: 80_000, north: 80_000), .outside)
        XCTAssert(v.knownShare > 0.6 && v.knownShare < 0.95, "\(v.knownShare)")

        let small = TestTerrain.cones([], base: 500)
        settings.radius = 300_000
        let wide = Viewshed.compute(terrain: small, summit: summit, settings: settings)
        // The far corners of the 2° block, about 135 km away.
        XCTAssertLessThan(wide.radius, 140_000)
        XCTAssertGreaterThan(wide.radius, 125_000)
    }

    /// Distance and angle from a tapped point match the exact geometry.
    func testSightFromAPoint() {
        let flat = TestTerrain.cones([], base: 500)
        var settings = ViewshedSettings()
        settings.radius = 30_000
        let summit = GeoPoint(latitude: 46, longitude: 8, height: 2_500)
        let v = Viewshed.compute(terrain: flat, summit: summit, settings: settings)
        let point = destination(from: summit, azimuth: 30, distance: 20_000)
        let sight = try! XCTUnwrap(v.sight(from: LatLon(point.latitude, point.longitude), terrain: flat))
        XCTAssertEqual(sight.distance, 20_000, accuracy: 1)
        XCTAssertEqual(sight.azimuth, 210, accuracy: 0.3)
        // About atan(1,998.4 / 20 km), less the curvature drop, plus refraction.
        let r = 6_380_000.0
        let expected = (atan(1_998.4 / 20_000) - 20_000 / (2 * r) * (1 - 0.13)) * 180 / .pi
        XCTAssertEqual(sight.elevation, expected, accuracy: 0.05)
        XCTAssertEqual(sight.cell, .visible)
        XCTAssert(sight.isVisible)
    }
}

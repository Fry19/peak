import XCTest
@testable import PeakCore

final class PanoramaMeshTests: XCTestCase {
    private func elevation(_ v: SIMD4<Float>, lift: Double = 0) -> Double {
        atan2(Double(v.z) - lift, (Double(v.x) * Double(v.x) + Double(v.y) * Double(v.y)).squareRoot()) * 180 / .pi
    }

    private func azimuth(_ v: SIMD4<Float>) -> Double {
        normalizedAzimuth(atan2(Double(v.x), Double(v.y)) * 180 / .pi)
    }

    /// Over flat ground, each vertex lies where `LocalFrame.look` (exact ellipsoid geometry
    /// plus refraction) sees that point on the ground, near and far, from the eye and from
    /// a kilometer and 10,000 ft (the highest view from above) over it.
    func testVerticesSitWhereTheGroundIsSeen() {
        let flat = TestTerrain.cones([], base: 0)
        let eye = GeoPoint(latitude: 46, longitude: 8, height: 300)
        var settings = PanoramaMeshSettings()
        settings.azimuthStep = 30
        settings.maxDistance = 60_000
        let mesh = PanoramaMesh.build(terrain: flat, from: eye, settings: settings)
        XCTAssertEqual(mesh.rays, 12)
        XCTAssertEqual(mesh.vertices.count, mesh.rays * mesh.rings.count + 1)
        for lift in [0.0, 1_000, 3_048] {
            var risen = eye
            risen.height += lift
            let frame = LocalFrame(origin: risen)
            for ray in [0, 4, 7] {
                for ring in [0, 40, mesh.rings.count / 2, mesh.rings.count - 1] {
                    let v = mesh.vertex(ray: ray, ring: ring)
                    let at = destination(from: eye, azimuth: Double(ray) * 30, distance: mesh.rings[ring])
                    let look = frame.look(at: GeoPoint(latitude: at.latitude, longitude: at.longitude, height: 0), refraction: 0.13)
                    XCTAssertEqual(azimuthDifference(azimuth(v), look.azimuth), 0, accuracy: 0.01, "ray \(ray) ring \(ring)")
                    XCTAssertEqual(elevation(v, lift: lift), look.elevation, accuracy: 0.01, "ray \(ray) ring \(ring) lift \(lift)")
                }
            }
        }
        // Flat ground is lit as by the light's altitude.
        let flatShade = 0.3 + 0.7 * Float(sin(45 * Double.pi / 180))
        XCTAssertEqual(mesh.vertex(ray: 3, ring: 100).w, flatShade, accuracy: 0.001)
        XCTAssertEqual(mesh.vertices.last!.w, flatShade, accuracy: 0.001)
        // Every cell is two triangles, plus the fan around the eye.
        XCTAssertEqual(mesh.indices.count, 3 * mesh.rays * (2 * (mesh.rings.count - 1) + 1))
        // Rings start 15 m apart and end 1% apart.
        XCTAssertEqual(mesh.rings[1] - mesh.rings[0], 15, accuracy: 1e-9)
        XCTAssertEqual(mesh.rings[mesh.rings.count - 1] / mesh.rings[mesh.rings.count - 2], 1.01, accuracy: 1e-3)
    }

    /// Toward a cone 12 km east, the mesh's highest point is the horizon renderer's skyline
    /// there, and the cone's sunny and shaded flanks differ.
    func testSummitMatchesTheSkylineAndFlanksAreShaded() {
        let summit = destination(from: TestTerrain.center, azimuth: 90, distance: 12_000)
        let terrain = TestTerrain.cones([.init(latitude: summit.latitude, longitude: summit.longitude, height: 2_000, radius: 8_000)])
        let renderer = HorizonRenderer(terrain: terrain)
        let eye = renderer.observer(latitude: 46, longitude: 8)
        var settings = PanoramaMeshSettings()
        settings.maxDistance = 40_000
        let mesh = PanoramaMesh.build(terrain: terrain, from: eye, settings: settings)
        var horizon = HorizonSettings()
        horizon.maxDistance = 40_000
        let profile = renderer.render(from: eye, settings: horizon)
        let ray = Int(90 / settings.azimuthStep)
        let top = (0..<mesh.rings.count).map { elevation(mesh.vertex(ray: ray, ring: $0)) }.max()!
        XCTAssertEqual(top, profile.elevation(atAzimuth: 90), accuracy: 0.05)
        // The light comes from the north-west: the cone's west flank (facing the eye) is
        // brighter than its east flank, seen along the same ray.
        let near = mesh.rings.firstIndex { $0 > 7_000 }!, far = mesh.rings.firstIndex { $0 > 17_000 }!
        XCTAssertGreaterThan(mesh.vertex(ray: ray, ring: near).w, mesh.vertex(ray: ray, ring: far).w + 0.15)
    }

    /// Where there is no terrain, no triangles are made.
    func testNoTrianglesWithoutTerrain() {
        // One 1° tile: everything farther than about 40 km south or west is missing.
        let tile = ElevationTile(south: 46, west: 8, size: 600) { _, _ in 500 }
        let terrain = Terrain(tiles: [tile], missingIsSea: false)
        let eye = GeoPoint(latitude: 46.5, longitude: 8.5, height: 502)
        var settings = PanoramaMeshSettings()
        settings.azimuthStep = 10
        settings.maxDistance = 70_000
        let mesh = PanoramaMesh.build(terrain: terrain, from: eye, settings: settings)
        let used = Set(mesh.indices)
        XCTAssertFalse(used.isEmpty)
        for k in used where Int(k) < mesh.vertices.count - 1 {
            let ring = Int(k) % mesh.rings.count, ray = Int(k) / mesh.rings.count
            let at = destination(from: eye, azimuth: Double(ray) * 10, distance: mesh.rings[ring])
            XCTAssertTrue(terrain.height(latitude: at.latitude, longitude: at.longitude).isFinite)
        }
        XCTAssertLessThan(mesh.indices.count, 3 * mesh.rays * (2 * (mesh.rings.count - 1) + 1))
    }
}

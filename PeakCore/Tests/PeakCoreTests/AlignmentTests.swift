import XCTest
@testable import PeakCore

/// End to end on synthetic terrain: render a photo with a known camera, give the matcher a
/// compass that is off, and check that it finds the true heading.
final class AlignmentTests: XCTestCase {
    static let terrain = TestTerrain.range()
    let k = CameraIntrinsics(width: 640, height: 480, horizontalFOV: 64)

    func horizon(from observer: GeoPoint, step: Double = 0.1, terrain: Terrain = terrain) -> HorizonProfile {
        var s = HorizonSettings()
        s.azimuthStep = step
        s.maxDistance = 80_000
        return HorizonRenderer(terrain: terrain).render(from: observer, settings: s)
    }

    /// A heading where the skyline is mostly far away.
    func farHeading(_ profile: HorizonProfile) -> Double {
        let half = Int(25 / profile.azimuthStep)
        let best = stride(from: 0, to: profile.count, by: 10).max { a, b in
            func farCount(_ c: Int) -> Int {
                (-half...half).filter { profile.distances[(c + $0 + profile.count) % profile.count] > 8_000 }.count
            }
            return farCount(a) < farCount(b)
        }!
        return profile.azimuth(ofRay: best)
    }

    func testRecoversCompassError() {
        let renderer = HorizonRenderer(terrain: Self.terrain)
        let observer = renderer.observer(latitude: 46.05, longitude: 7.95)
        let world = horizon(from: observer, step: 0.05)
        let truth = Attitude(heading: farHeading(world), pitch: 2.5, roll: 1.2)
        // Clear air: in thick haze the far cones fade into the sky (see the bench for that).
        var scene = SyntheticScene()
        scene.hazeDistance = 200_000
        let photo = SyntheticPhoto.render(world, camera: Camera(intrinsics: k, attitude: truth), scene: scene)

        let model = horizon(from: observer)
        for compassError in [-14.0, 9.0] {
            var prior = truth
            prior.heading = normalizedAzimuth(truth.heading + compassError)
            prior.pitch += 0.3
            prior.roll -= 0.4
            let m = SkylineMatcher().match(photo, intrinsics: k, prior: prior, horizon: model)
            XCTAssertTrue(m.alignment.accepted, m.alignment.rejectionReason ?? "")
            XCTAssertEqual(azimuthDifference(m.alignment.attitude.heading, truth.heading), 0, accuracy: 0.08)
            XCTAssertEqual(m.alignment.attitude.pitch, truth.pitch, accuracy: 0.1)
            XCTAssertEqual(m.alignment.attitude.roll, truth.roll, accuracy: 0.2)
        }
    }

    func testFlatHorizonIsRejected() {
        let observer = GeoPoint(latitude: 46, longitude: 8, height: 450)
        let world = horizon(from: observer, terrain: TestTerrain.cones([], base: 400))
        let truth = Attitude(heading: 75, pitch: 1)
        let photo = SyntheticPhoto.render(world, camera: Camera(intrinsics: k, attitude: truth))
        var prior = truth
        prior.heading += 6
        let m = SkylineMatcher().match(photo, intrinsics: k, prior: prior, horizon: world)
        XCTAssertFalse(m.alignment.accepted)
    }

    func testAnchorsGiveTheTrueAttitude() {
        let observer = GeoPoint(latitude: 46, longitude: 8, height: 2_000)
        let truth = Attitude(heading: 211, pitch: 3, roll: -2)
        let projector = Camera(intrinsics: k, attitude: truth).projector
        let frame = LocalFrame(origin: observer)
        let anchors = [(204.0, 9_000.0, 3_100.0), (220.0, 24_000.0, 3_900.0)].map { az, d, ele -> Anchor in
            let p = destination(from: observer, azimuth: az, distance: d)
            let look = frame.look(at: GeoPoint(latitude: p.latitude, longitude: p.longitude, height: ele), refraction: 0.13)
            let px = projector.pixel(azimuth: look.azimuth, elevation: look.elevation)!
            return Anchor(latitude: p.latitude, longitude: p.longitude, elevation: ele, x: px.x, y: px.y)
        }
        let solved = AnchorSolver.attitude(anchors: anchors, observer: observer, intrinsics: k,
                                           initial: Attitude(heading: 200))!
        XCTAssertEqual(solved.attitude.heading, truth.heading, accuracy: 1e-4)
        XCTAssertEqual(solved.attitude.pitch, truth.pitch, accuracy: 1e-4)
        XCTAssertEqual(solved.attitude.roll, truth.roll, accuracy: 1e-3)
        XCTAssertLessThan(solved.rmsPixels, 0.01)
    }
}

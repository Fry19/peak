import XCTest
@testable import PeakCore

/// Several frames of a pan matched as one skyline (`SkylineStrip`, multi-view alignment).
final class StitchingTests: XCTestCase {
    static let observer = GeoPoint(latitude: 46, longitude: 8, height: 1_500)
    /// Identical peaks 20 km away: every 10° around north, every 12° around 72°. A narrow
    /// view of either row fits a heading a period off as well as the true one; only both
    /// rows together, with the turn between them known, rule those out. Given ray by ray
    /// (as the renderer would) so the peaks are exactly alike.
    static let peaks = Array(stride(from: -40.0, through: 20, by: 10)) + Array(stride(from: 48.0, through: 108, by: 12))

    func horizon(step: Double = 0.1) -> HorizonProfile {
        var settings = HorizonSettings()
        settings.azimuthStep = step
        let rays = Int((360 / step).rounded())
        let elevations = (0..<rays).map { i -> Float in
            let az = Double(i) * step
            let bumps = Self.peaks.map { p in
                let d = azimuthDifference(az, p) / 4
                return 2 * max(0, 1 - d * d)
            }
            return Float(bumps.max()!)
        }
        let envelope = elevations.map { HorizonProfile.EnvelopePoint(elevation: $0, distance: 20_000, startsSegment: false) }
        return HorizonProfile(observer: Self.observer, settings: settings, elevations: elevations,
                              distances: [Float](repeating: 20_000, count: rays),
                              envelopeStart: Array(0...rays), envelope: envelope)
    }
    let k = CameraIntrinsics(width: 640, height: 480, horizontalFOV: 24)

    /// A view matched alone: its skyline, and the camera before correction (compass off by
    /// `compassError`, pitch and roll a little off).
    func view(heading: Double, compassError: Double, world: HorizonProfile, model: HorizonProfile) -> AlignmentView {
        var scene = SyntheticScene()
        scene.hazeDistance = 200_000
        let truth = Attitude(heading: heading, pitch: 1, roll: 0.5)
        let photo = SyntheticPhoto.render(world, camera: Camera(intrinsics: k, attitude: truth), scene: scene)
        var prior = truth
        prior.heading = normalizedAzimuth(heading + compassError)
        prior.pitch += 0.3
        prior.roll -= 0.3
        let m = SkylineMatcher().match(photo, intrinsics: k, prior: prior, horizon: model)
        return AlignmentView(skyline: m.skyline, camera: m.camera)
    }

    var settings: AlignmentSettings {
        var s = AlignmentSettings()
        s.adapt(toHorizontalFOV: k.horizontalFOV)
        return s
    }

    func testPanningPinsDownARepetitiveSkyline() {
        let world = horizon(step: 0.05), model = horizon()
        let a = view(heading: 0, compassError: 6, world: world, model: model)
        let b = view(heading: 72, compassError: 6, world: world, model: model)
        for single in [a, b] {
            let r = SkylineAligner.align([single], horizon: model, settings: settings)
            XCTAssertFalse(r.accepted, "one row of identical cones alone fits another heading")
        }
        let both = SkylineAligner.align([b, a], horizon: model, settings: settings)
        XCTAssertTrue(both.accepted, both.rejectionReason ?? "")
        XCTAssertEqual(azimuthDifference(both.attitude.heading, 72), 0, accuracy: 0.1)
        XCTAssertEqual(both.viewCorrections.count, 2)
        // The order of the views only picks which one the result is for.
        let reversed = SkylineAligner.align([a, b], horizon: model, settings: settings)
        XCTAssertEqual(reversed.headingCorrection, both.headingCorrection, accuracy: 0.03)
        XCTAssertEqual(azimuthDifference(reversed.attitude.heading, 0), 0, accuracy: 0.1)
    }

    /// A frame the gyroscope placed 0.5° off pulls the shared heading toward it: the frames
    /// disagree, and the match is turned away rather than taken with the error.
    func testFramesThatDisagreeAreTurnedAway() {
        let world = horizon(step: 0.05), model = horizon()
        let a = view(heading: 0, compassError: 6, world: world, model: model)
        var b = view(heading: 72, compassError: 6, world: world, model: model)
        b.camera.attitude.heading += 0.5
        let r = SkylineAligner.align([b, a], horizon: model, settings: settings)
        XCTAssertFalse(r.accepted)
        XCTAssertTrue(r.rejectionReason?.hasPrefix("frames disagree") ?? false, r.rejectionReason ?? "")
    }

    /// A frame with almost no skyline can't be checked against the others, and the result
    /// would be for it: turned away.
    func testFrameTooBareToCheckIsTurnedAway() {
        let world = horizon(step: 0.05), model = horizon()
        let a = view(heading: 0, compassError: 6, world: world, model: model)
        let b = view(heading: 72, compassError: 6, world: world, model: model)
        // The newest frame, a quarter turn on, sees skyline in only 10 columns.
        var rows = [Float](repeating: .nan, count: a.skyline.width)
        for c in 300..<310 { rows[c] = a.skyline.rows[c] }
        var bare = a
        bare.skyline = Skyline(width: a.skyline.width, height: a.skyline.height, rows: rows, strength: a.skyline.strength)
        bare.camera.attitude.heading = normalizedAzimuth(bare.camera.attitude.heading + 36)
        let r = SkylineAligner.align([bare, b, a], horizon: model, settings: settings)
        XCTAssertFalse(r.accepted)
        XCTAssertEqual(r.rejectionReason, "a frame of the pan has too little skyline to check")
    }

    /// The same view twice is one view's evidence: it doesn't make an ambiguous match pass.
    func testRepeatedViewAddsNothing() {
        let world = horizon(step: 0.05), model = horizon()
        let a = view(heading: 0, compassError: 6, world: world, model: model)
        let once = SkylineAligner.align([a], horizon: model, settings: settings)
        let thrice = SkylineAligner.align([a, a, a], horizon: model, settings: settings)
        XCTAssertFalse(thrice.accepted)
        XCTAssertEqual(thrice.ambiguity, once.ambiguity, accuracy: 0.05)
        XCTAssertEqual(thrice.headingCorrection, once.headingCorrection, accuracy: 0.05)
    }

    /// The strip puts each frame under the newest frame's north by the gyroscope's turn,
    /// whatever the compass said for it, and the stitched match finds the heading.
    func testStripMatchesThePan() throws {
        let world = horizon(step: 0.05), model = horizon()
        var strip = SkylineStrip()
        // The compass wanders between the frames, as indoors; the gyroscope's zero is anywhere.
        for (i, (heading, compass)) in [(0.0, 9.0), (72.0, 4.0)].enumerated() {
            let v = view(heading: heading, compassError: compass, world: world, model: model)
            strip.add(SkylineStrip.Frame(skyline: v.skyline, camera: v.camera, time: Double(i) * 2,
                                         gyroHeading: normalizedAzimuth(heading + 200), position: Self.observer, lens: "wide"))
            if i == 0 { XCTAssertNil(strip.views, "one frame is no strip") }
        }
        let views = try XCTUnwrap(strip.views)
        XCTAssertEqual(azimuthDifference(views[1].camera.attitude.heading, views[0].camera.attitude.heading), -72, accuracy: 1e-9)
        let r = try XCTUnwrap(strip.match(horizon: model, settings: settings))
        XCTAssertTrue(r.accepted, r.rejectionReason ?? "")
        XCTAssertEqual(azimuthDifference(r.attitude.heading, 72), 0, accuracy: 0.1)
    }

    func testStripDropsFramesItCantMatchWith() {
        let skyline = Skyline(width: 640, height: 480, rows: [Float](repeating: 240, count: 640),
                              strength: [Float](repeating: 1, count: 640))
        let camera = Camera(intrinsics: k, attitude: Attitude(heading: 10))
        func frame(_ t: Double, gyro: Double, lens: String = "wide", east: Double = 0, k: CameraIntrinsics? = nil) -> SkylineStrip.Frame {
            var c = camera
            if let k { c.intrinsics = k }
            let p = destination(from: Self.observer, azimuth: 90, distance: east)
            return SkylineStrip.Frame(skyline: skyline, camera: c, time: t, gyroHeading: gyro,
                                      position: GeoPoint(latitude: p.latitude, longitude: p.longitude, height: 500), lens: lens)
        }
        var strip = SkylineStrip()
        strip.add(frame(0, gyro: 350))
        strip.add(frame(1, gyro: 5))
        XCTAssertEqual(strip.frames.count, 2)
        XCTAssertEqual(strip.widening, 15, accuracy: 1e-9, "across north")
        XCTAssertNotNil(strip.views)
        // Looking the same way again replaces the older frame.
        strip.add(frame(2, gyro: 5.5))
        XCTAssertEqual(strip.frames.map(\.time), [2, 0])
        // Too old, moved too far, another lens or zoom: dropped.
        strip.add(frame(9, gyro: 30))
        XCTAssertEqual(strip.frames.map(\.time), [9, 2])
        strip.add(frame(10, gyro: 50, east: 30))
        XCTAssertEqual(strip.frames.map(\.time), [10])
        strip.add(frame(11, gyro: 70, lens: "tele", east: 30))
        XCTAssertEqual(strip.frames.map(\.time), [11])
        strip.add(frame(12, gyro: 90, lens: "tele", east: 30, k: k.zoomed(by: 2)))
        XCTAssertEqual(strip.frames.map(\.time), [12])
        // Not wide enough yet: no views.
        strip.add(frame(13, gyro: 92, lens: "tele", east: 30, k: k.zoomed(by: 2)))
        XCTAssertEqual(strip.frames.count, 2)
        XCTAssertNil(strip.views)
    }

    /// Phone upright in portrait, back camera looking north: x east, y up, z south.
    func upright() -> GyroAttitude {
        GyroAttitude(x: SIMD3(1, 0, 0), y: SIMD3(0, 0, 1), z: SIMD3(0, -1, 0))
    }
    let back = SIMD3<Double>(0, 0, -1)

    func testGyroHeadingTurnsWithTheGyroscope() {
        var g = upright()
        XCTAssertEqual(g.heading(of: back), 0, accuracy: 1e-9)
        // Turning right (clockwise seen from above) is negative about the phone's y, which is up.
        for _ in 0..<100 { g.rotate(rate: SIMD3(0, -0.1, 0), dt: 0.01) }
        XCTAssertEqual(g.heading(of: back), 0.1 * 180 / .pi, accuracy: 1e-6)
        // Tipped up 30°, then turned about the camera's own axis: the camera's heading stays.
        for _ in 0..<100 { g.rotate(rate: SIMD3(30 * .pi / 180, 0, 0), dt: 0.01) }
        let tipped = g.heading(of: back)
        for _ in 0..<100 { g.rotate(rate: SIMD3(0, 0, 0.5), dt: 0.01) }
        XCTAssertEqual(g.heading(of: back), tipped, accuracy: 1e-6)
    }

    /// Gravity puts the tilt right without moving the camera's heading, even with the
    /// camera pitched up, where tipping about a level axis alone would turn it.
    func testLevelingMovesNoHeading() {
        var truth = upright()
        for _ in 0..<50 { truth.rotate(rate: SIMD3(0, -0.2, 0), dt: 0.01) }
        for _ in 0..<100 { truth.rotate(rate: SIMD3(30 * .pi / 180, 0, 0), dt: 0.01) }
        // The gyroscope's attitude drifted 0.5° about the level axis under the view.
        var g = truth
        let forward = truth.x * back.x + truth.y * back.y + truth.z * back.z
        var axis = SIMD3(forward.x, forward.y, 0)
        axis /= (axis * axis).sum().squareRoot()
        g.rotate(rate: SIMD3((axis * g.x).sum(), (axis * g.y).sum(), (axis * g.z).sum()), dt: 0.5 * .pi / 180)
        let heading = g.heading(of: back)
        XCTAssertGreaterThan(abs(azimuthDifference(heading, truth.heading(of: back))), 0.2, "the drift turned the heading")
        let up = SIMD3(truth.x.z, truth.y.z, truth.z.z)
        g.level(up: up, keeping: back)
        XCTAssertEqual(g.heading(of: back), heading, accuracy: 1e-9)
        for (a, b) in zip([g.x.z, g.y.z, g.z.z], [up.x, up.y, up.z]) { XCTAssertEqual(a, b, accuracy: 1e-9) }
    }
}

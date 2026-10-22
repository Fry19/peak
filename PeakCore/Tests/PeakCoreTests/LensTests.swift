import XCTest
@testable import PeakCore

final class LensTests: XCTestCase {
    let fivex = LensSet(telephotos: [(5, "tele")])
    let threex = LensSet(telephotos: [(3, "tele")])
    let wideFOV = 69.0

    func testMaxZoom() {
        XCTAssertEqual(LensSet.wideOnly.maxZoom, 6)
        XCTAssertEqual(fivex.maxZoom, 15)
        XCTAssertEqual(threex.maxZoom, 10)
        XCTAssertFalse(LensSet.wideOnly.hasTelephoto)
        // The wide-only phone never leaves the wide lens.
        XCTAssertEqual(LensSet.wideOnly.lens(for: 6, current: 0), 0)
    }

    func testLensSwitchingHasHysteresisUpOnly() {
        // Up only a little past the lens's own zoom.
        XCTAssertEqual(threex.lens(for: 3.0, current: 0), 0)
        XCTAssertEqual(threex.lens(for: 3.2, current: 0), 1)
        // Staying on it down to its own zoom, and off it just below (the picture must fill).
        XCTAssertEqual(threex.lens(for: 3.0, current: 1), 1)
        XCTAssertEqual(threex.lens(for: 2.99, current: 1), 0)
        let two = LensSet(telephotos: [(5, "b"), (2, "a")])
        XCTAssertEqual(two.zooms, [1, 2, 5])
        XCTAssertEqual(two.names, ["wide", "a", "b"])
        XCTAssertEqual(two.lens(for: 9, current: 0), 2)
        XCTAssertEqual(two.lens(for: 4, current: 2), 1)
    }

    func testScreenZoomNeverShrinksThePicture() {
        XCTAssertEqual(LensSet.screenZoom(total: 7.5, optical: 5), 1.5, accuracy: 1e-12)
        XCTAssertEqual(LensSet.screenZoom(total: 3.1, optical: 3.2), 1)
    }

    /// The lines are drawn with the frame's intrinsics zoomed on screen: whichever lens took
    /// the frame, a direction lands on the same screen point at the same total zoom.
    func testSameTotalZoomDrawsTheSameAcrossLenses() {
        func frame(_ zoom: Double, lens: Int) -> FrameLens {
            let r = FrameLens.Reading(width: 1920, height: 1080, matrix: nil, zoom: zoom, activeLens: lens, sinceZoomChange: 1)
            return FrameLens.resolve(r, lenses: fivex, wideFOV: wideFOV)
        }
        let wide = frame(1, lens: 0), tele = frame(5, lens: 1)
        XCTAssertEqual(wide.opticalZoom, 1)
        XCTAssertEqual(tele.opticalZoom, 5, accuracy: 1e-9)
        let total = 6.0
        let a = wide.intrinsics.zoomed(by: LensSet.screenZoom(total: total, optical: wide.opticalZoom))
        let b = tele.intrinsics.zoomed(by: LensSet.screenZoom(total: total, optical: tele.opticalZoom))
        XCTAssertEqual(a.fx, b.fx, accuracy: 1e-6)
    }

    func matrix(fov: Double, dx: Double = 0) -> CameraIntrinsics {
        var k = CameraIntrinsics(width: 1920, height: 1080, horizontalFOV: fov)
        k.cx += dx
        return k
    }

    func teleFOV(_ zoom: Double) -> Double { 2 * atan(tan(wideFOV * .pi / 360) / zoom) * 180 / .pi }

    func testMeasuredTelephotoIsUsed() {
        // A real 5× is rarely exactly 5×, and its center is its own.
        let m = matrix(fov: teleFOV(5.15), dx: 12)
        let r = FrameLens.Reading(width: 1920, height: 1080, matrix: m, zoom: 5, activeLens: 1, sinceZoomChange: 2)
        let lens = FrameLens.resolve(r, lenses: fivex, wideFOV: wideFOV)
        XCTAssertTrue(lens.measured)
        XCTAssertEqual(lens.lens, 1)
        XCTAssertEqual(lens.intrinsics, m)
        XCTAssertEqual(lens.opticalZoom, 5.15, accuracy: 0.01)
    }

    func testFrameFromBeforeASwitchKeepsItsOwnLens() {
        // Zoom already set to 5×, the camera says the telephoto is on, but the frame is the
        // wide's: it's drawn as the wide.
        let wide = matrix(fov: wideFOV)
        let r = FrameLens.Reading(width: 1920, height: 1080, matrix: wide, zoom: 5, activeLens: 1, sinceZoomChange: 0.05)
        let lens = FrameLens.resolve(r, lenses: fivex, wideFOV: wideFOV)
        XCTAssertEqual(lens.lens, 0)
        XCTAssertEqual(lens.opticalZoom, 1)
        // And the other way: back at 1×, a last telephoto frame.
        let tele = matrix(fov: teleFOV(5))
        let back = FrameLens.Reading(width: 1920, height: 1080, matrix: tele, zoom: 1, activeLens: 0, sinceZoomChange: 0.05)
        XCTAssertEqual(FrameLens.resolve(back, lenses: fivex, wideFOV: wideFOV).lens, 1)
    }

    func testWideCroppedForTheTelephoto() {
        // In low light the camera may stay on the wide at 5×, cropping it.
        let cropped = matrix(fov: teleFOV(5))
        var r = FrameLens.Reading(width: 1920, height: 1080, matrix: cropped, zoom: 5, activeLens: 0, sinceZoomChange: 2)
        var lens = FrameLens.resolve(r, lenses: fivex, wideFOV: wideFOV)
        XCTAssertEqual(lens.lens, 0, "the wide's offsets, not the telephoto's")
        XCTAssertEqual(lens.opticalZoom, 5, accuracy: 0.01)
        // A matrix that leaves the crop out is scaled for it, once the change has settled...
        r.matrix = matrix(fov: wideFOV)
        lens = FrameLens.resolve(r, lenses: fivex, wideFOV: wideFOV)
        XCTAssertEqual(lens.opticalZoom, 5, accuracy: 0.01)
        // ...but right after it, it's a frame from before the crop.
        r.sinceZoomChange = 0.1
        XCTAssertEqual(FrameLens.resolve(r, lenses: fivex, wideFOV: wideFOV).opticalZoom, 1)
    }

    func testNonsenseMatrixFallsBackToTheZoom() {
        let r = FrameLens.Reading(width: 1920, height: 1080, matrix: matrix(fov: 20), zoom: 1, activeLens: 0, sinceZoomChange: 5)
        let lens = FrameLens.resolve(r, lenses: fivex, wideFOV: wideFOV)
        XCTAssertFalse(lens.measured)
        XCTAssertEqual(lens.intrinsics.horizontalFOV, wideFOV, accuracy: 1e-9)
    }

    func testOffsetsRefineOnlyWhileTheWideIsCurrent() {
        var store = LensOffsets()
        let off = LensOffset(heading: 0.4, pitch: -0.2, roll: 0.1)
        // Right after a wide match: the difference is the lens's, and it moves part way.
        XCTAssertEqual(store.take(lens: "tele", sideways: false, measured: off, sinceWideMatch: 3), .refinedOffset)
        XCTAssertEqual(store.offset(lens: "tele", sideways: false).heading, 0.1, accuracy: 1e-12)
        XCTAssertEqual(store.offset(lens: "tele", sideways: true), LensOffset(), "kept per way of holding")
        // Repeated, it converges on the true offset.
        for _ in 0..<40 {
            let o = store.offset(lens: "tele", sideways: false)
            _ = store.take(lens: "tele", sideways: false,
                           measured: LensOffset(heading: 0.4 - o.heading, pitch: -0.2 - o.pitch, roll: 0.1 - o.roll),
                           sinceWideMatch: 3)
        }
        let o = store.offset(lens: "tele", sideways: false)
        XCTAssertEqual(o.heading, 0.4, accuracy: 1e-3)
        XCTAssertEqual(o.pitch, -0.2, accuracy: 1e-3)
        // Long after the wide was matched, the match corrects the main correction instead.
        XCTAssertEqual(store.take(lens: "tele", sideways: false, measured: off, sinceWideMatch: 60), .main(off))
        XCTAssertEqual(store.take(lens: "tele", sideways: false, measured: off, sinceWideMatch: nil), .main(off))
        // The wide has no offset: it is the main correction.
        XCTAssertEqual(store.take(lens: LensSet.wideName, sideways: false, measured: off, sinceWideMatch: 1), .main(off))
        XCTAssertEqual(store.offset(lens: LensSet.wideName, sideways: false), LensOffset())
        // A bad fit is ignored, and repeated ones can't push it past the bound.
        XCTAssertEqual(store.take(lens: "tele", sideways: true, measured: LensOffset(heading: 5), sinceWideMatch: 1), .ignored)
        for _ in 0..<50 { _ = store.take(lens: "tele", sideways: true, measured: LensOffset(heading: 0.9), sinceWideMatch: 1) }
        XCTAssertEqual(store.offset(lens: "tele", sideways: true).heading, LensOffsets.maxOffset)
        // Saved and loaded.
        let data = try! JSONEncoder().encode(store)
        XCTAssertEqual(try! JSONDecoder().decode(LensOffsets.self, from: data), store)
        store.reset(sideways: true)
        XCTAssertEqual(store.offset(lens: "tele", sideways: true), LensOffset())
        XCTAssertEqual(store.offset(lens: "tele", sideways: false), o)
    }

    func testThresholdsGrowWithZoom() {
        let t = LabelLayout.Thresholds()
        XCTAssertEqual(t.scaled(forZoom: 1).enterMargin, t.enterMargin)
        let z = t.scaled(forZoom: 16)
        XCTAssertEqual(z.enterMargin, 2 * t.enterMargin, accuracy: 1e-9)
        XCTAssertEqual(z.keepMargin, t.keepMargin)
    }

    /// Through a 5× telephoto (about 8° across, held upright) the matcher still finds the
    /// heading, with the far-span gate adapted to the narrow view.
    func testMatchesThroughATelephoto() {
        let renderer = HorizonRenderer(terrain: AlignmentTests.terrain)
        let observer = renderer.observer(latitude: 46.05, longitude: 7.95)
        let tests = AlignmentTests()
        let world = tests.horizon(from: observer, step: 0.05)
        let k = CameraIntrinsics(width: 540, height: 960, horizontalFOV: 8)
        let truth = Attitude(heading: tests.farHeading(world), pitch: 1.5, roll: 0.4)
        var scene = SyntheticScene()
        scene.hazeDistance = 200_000
        let photo = SyntheticPhoto.render(world, camera: Camera(intrinsics: k, attitude: truth), scene: scene)
        var prior = truth
        prior.heading = normalizedAzimuth(truth.heading + 0.5)
        prior.pitch -= 0.2
        var matcher = SkylineMatcher()
        matcher.settings.adapt(toHorizontalFOV: k.horizontalFOV)
        XCTAssertEqual(matcher.settings.minFarSpan, 2.8, accuracy: 1e-9)
        let m = matcher.match(photo, intrinsics: k, prior: prior, horizon: tests.horizon(from: observer))
        XCTAssertTrue(m.alignment.accepted, m.alignment.rejectionReason ?? "")
        XCTAssertEqual(azimuthDifference(m.alignment.attitude.heading, truth.heading), 0, accuracy: 0.05)
        XCTAssertEqual(m.alignment.attitude.pitch, truth.pitch, accuracy: 0.05)
    }
}

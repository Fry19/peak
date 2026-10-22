import XCTest
@testable import PeakCore

final class SummitPinsTests: XCTestCase {
    let k = CameraIntrinsics(width: 390, height: 844, horizontalFOV: 50)

    private func peak(_ id: Int64, azimuth: Double, elevation: Double, prominence: Double? = nil) -> VisiblePeak {
        var p = Peak(id: id, name: "Peak \(id)", latitude: 0, longitude: 0, elevation: 2_000)
        p.prominence = prominence
        return VisiblePeak(peak: p, azimuth: azimuth, elevation: elevation, distance: 10_000)
    }

    /// Where `truth` sees a summit.
    private func pixel(_ v: VisiblePeak, _ truth: Attitude) -> (x: Double, y: Double) {
        Camera(intrinsics: k, attitude: truth).projector.pixel(azimuth: v.azimuth, elevation: v.elevation)!
    }

    func testOneSummitFixesTheHeadingAndKeepsRoll() {
        let truth = Attitude(heading: 132, pitch: 2, roll: 1.5)
        let shown = Attitude(heading: 121, pitch: 2.02, roll: 1.5)   // the compass 11° off
        let green = peak(1, azimuth: 128, elevation: 3.1)
        var pins = SummitPins()
        let at = pixel(green, truth)
        pins.pin(.init(green, x: at.x, y: at.y, intrinsics: k), current: shown)
        let solved = pins.solve(intrinsics: k)!
        XCTAssertEqual(solved.attitude.heading, truth.heading, accuracy: 1e-3)
        // The pitch stays as the phone's level had it: one summit fixes the heading only.
        XCTAssertEqual(solved.attitude.pitch, shown.pitch)
        XCTAssertEqual(solved.attitude.roll, shown.roll)
        XCTAssertFalse(solved.misfit)
        // Dropped a little high, it's still not a misfit: the pitch just stays.
        pins.pin(.init(green, x: at.x, y: at.y - 40, intrinsics: k), current: shown)
        XCTAssertFalse(pins.solve(intrinsics: k)!.misfit)
    }

    func testTwoSummitsFixTheTiltToo() {
        let truth = Attitude(heading: 300, pitch: -1, roll: 3)
        let shown = Attitude(heading: 290, pitch: 0, roll: 0)
        let a = peak(1, azimuth: 292, elevation: 2), b = peak(2, azimuth: 309, elevation: 4)
        var pins = SummitPins()
        for v in [a, b] {
            let at = pixel(v, truth)
            pins.pin(.init(v, x: at.x, y: at.y, intrinsics: k), current: shown)
        }
        let solved = pins.solve(intrinsics: k)!
        XCTAssertEqual(solved.attitude.heading, truth.heading, accuracy: 1e-3)
        XCTAssertEqual(solved.attitude.pitch, truth.pitch, accuracy: 1e-3)
        XCTAssertEqual(solved.attitude.roll, truth.roll, accuracy: 1e-2)
        XCTAssertFalse(solved.misfit)
        XCTAssertTrue(solved.tilt)
        // Where the view can't take that tilt, the heading alone.
        let flat = pins.solve(intrinsics: k, allowTilt: false)!
        XCTAssertFalse(flat.tilt)
        XCTAssertEqual(flat.attitude.roll, shown.roll)
        XCTAssertEqual(flat.attitude.pitch, shown.pitch)
    }

    /// Two pins a finger's width apart can't measure a tilt: roll stays as it was.
    func testClosePinsLeaveRollAlone() {
        let truth = Attitude(heading: 10, pitch: 1, roll: 0)
        let a = peak(1, azimuth: 10, elevation: 2), b = peak(2, azimuth: 11, elevation: 2.2)
        var pins = SummitPins()
        let pa = pixel(a, truth), pb = pixel(b, truth)
        pins.pin(.init(a, x: pa.x, y: pa.y, intrinsics: k), current: truth)
        pins.pin(.init(b, x: pb.x + 3, y: pb.y - 4, intrinsics: k), current: truth)   // a sloppy drop
        let solved = pins.solve(intrinsics: k)!.attitude
        XCTAssertEqual(solved.roll, 0)
        XCTAssertEqual(solved.pitch, 1)
    }

    /// A wrong pick doesn't fit with a right one, and taking it away puts things back.
    func testAWrongPickIsFlaggedAndUndone() {
        let truth = Attitude(heading: 45, pitch: 0, roll: 0)
        let shown = Attitude(heading: 38, pitch: 0, roll: 0)
        let a = peak(1, azimuth: 40, elevation: 2), b = peak(2, azimuth: 52, elevation: 1)
        var pins = SummitPins()
        let pa = pixel(a, truth)
        pins.pin(.init(a, x: pa.x, y: pa.y, intrinsics: k), current: shown)
        let one = pins.solve(intrinsics: k)!.attitude
        // b marked where a different summit, 4° higher, really is.
        let wrong = Camera(intrinsics: k, attitude: truth).projector.pixel(azimuth: 52, elevation: 5)!
        pins.pin(.init(b, x: wrong.x, y: wrong.y, intrinsics: k), current: one)
        let misfit = pins.solve(intrinsics: k)!
        XCTAssertTrue(misfit.misfit)
        XCTAssertEqual(misfit.attitude.roll, 0)   // the bad tilt isn't taken
        pins.remove(2)
        XCTAssertEqual(pins.solve(intrinsics: k)!.attitude.heading, truth.heading, accuracy: 1e-3)
        pins.remove(1)
        XCTAssertEqual(pins.solve(intrinsics: k)!.attitude, shown)
        // Moving a pin replaces it rather than adding another.
        pins.pin(.init(a, x: pa.x, y: pa.y, intrinsics: k), current: shown)
        pins.pin(.init(a, x: pa.x + 10, y: pa.y, intrinsics: k), current: shown)
        XCTAssertEqual(pins.pins.count, 1)
    }

    /// Across north, the heading takes the short way round.
    func testHeadingWrapsAtNorth() {
        let truth = Attitude(heading: 357, pitch: 1)
        let shown = Attitude(heading: 6, pitch: 1)
        let v = peak(1, azimuth: 2, elevation: 1.5)
        var pins = SummitPins()
        let at = pixel(v, truth)
        pins.pin(.init(v, x: at.x, y: at.y, intrinsics: k), current: shown)
        XCTAssertEqual(pins.solve(intrinsics: k)!.attitude.heading, 357, accuracy: 1e-3)
    }

    /// Pins stay on the picture when it's zoomed.
    func testPinsFollowZoom() {
        let v = peak(1, azimuth: 0, elevation: 0)
        let pin = SummitPins.Pin(v, x: 250, y: 300, intrinsics: k)
        let z = k.zoomed(by: 2)
        let p = pin.pixel(z)
        XCTAssertEqual(p.x, 195 + (250 - 195) * 2, accuracy: 1e-9)
        XCTAssertEqual(p.y, 422 + (300 - 422) * 2, accuracy: 1e-9)
    }

    /// The real peak is offered even when the compass draws it far to one side; peaks at the
    /// wrong elevation or behind aren't.
    func testCandidatesAllowForTheCompass() {
        let shown = Camera(intrinsics: k, attitude: Attitude(heading: 100, pitch: 2))
        let real = peak(1, azimuth: 112, elevation: 3)      // drawn 12° right of the tap
        let nearby = peak(2, azimuth: 101, elevation: 7.5)   // right there, but far higher
        let other = peak(3, azimuth: 96, elevation: 2.5)
        let behind = peak(4, azimuth: 280, elevation: 3)
        let tap = shown.projector.pixel(azimuth: 100, elevation: 3)!
        let found = SummitPins.candidates([real, nearby, other, behind], camera: shown, x: tap.x, y: tap.y).map(\.id)
        XCTAssertEqual(found, [3, 1])
    }
}

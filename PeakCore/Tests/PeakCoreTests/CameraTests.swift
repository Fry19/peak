import XCTest
@testable import PeakCore

final class CameraTests: XCTestCase {
    let k = CameraIntrinsics(width: 1200, height: 900, horizontalFOV: 65)

    func testFieldOfView() {
        XCTAssertEqual(k.horizontalFOV, 65, accuracy: 1e-9)
        XCTAssertEqual(k.verticalFOV, 2 * atan(450 / k.fy) * 180 / .pi, accuracy: 1e-9)
        let half = k.scaled(toWidth: 600, height: 450)
        XCTAssertEqual(half.horizontalFOV, 65, accuracy: 1e-9)
        XCTAssertEqual(half.cx, 300)
    }

    func testPixelDirectionRoundTrip() {
        let camera = Camera(intrinsics: k, attitude: Attitude(heading: 352, pitch: 4, roll: -3))
        let p = camera.projector
        for (x, y) in [(0.0, 0.0), (600, 450), (1199, 899), (100, 800), (1000, 60)] {
            let look = p.look(x: x, y: y)
            let back = p.pixel(azimuth: look.azimuth, elevation: look.elevation)!
            XCTAssertEqual(back.x, x, accuracy: 1e-6)
            XCTAssertEqual(back.y, y, accuracy: 1e-6)
        }
    }

    func testCenterLooksAlongHeadingAndPitch() {
        let p = Camera(intrinsics: k, attitude: Attitude(heading: 123, pitch: 5, roll: 17)).projector
        let look = p.look(x: 600, y: 450)
        XCTAssertEqual(look.azimuth, 123, accuracy: 1e-9)
        XCTAssertEqual(look.elevation, 5, accuracy: 1e-9)
        // Pixels to the right look further clockwise, pixels above look higher.
        let level = Camera(intrinsics: k, attitude: Attitude(heading: 123)).projector
        XCTAssertGreaterThan(azimuthDifference(level.look(x: 900, y: 450).azimuth, 123), 0)
        XCTAssertGreaterThan(level.look(x: 600, y: 100).elevation, 0)
    }

    func testPositiveRollTiltsTheHorizonCounterclockwise() {
        // Camera turned clockwise: the horizon's right end rises in the image.
        let p = Camera(intrinsics: k, attitude: Attitude(heading: 0, pitch: 0, roll: 5)).projector
        let left = p.pixel(azimuth: 340, elevation: 0)!, right = p.pixel(azimuth: 20, elevation: 0)!
        XCTAssertLessThan(right.y, left.y)
    }

    func testBehindTheCameraHasNoPixel() {
        let p = Camera(intrinsics: k, attitude: Attitude(heading: 90)).projector
        XCTAssertNil(p.pixel(azimuth: 270, elevation: 0))
    }
}

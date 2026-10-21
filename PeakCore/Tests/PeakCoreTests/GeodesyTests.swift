import XCTest
@testable import PeakCore

final class GeodesyTests: XCTestCase {
    func testDestinationKeepsItsAzimuth() {
        // The ray must leave the observer at the azimuth asked for, as measured exactly on
        // the ellipsoid. A plain sphere is off by up to 0.2° here.
        for latitude in [0.0, 46.0, 65.0, -33.0] {
            let origin = GeoPoint(latitude: latitude, longitude: 7)
            let frame = LocalFrame(origin: origin)
            for azimuth in stride(from: 0.0, to: 360, by: 7.5) {
                for distance in [1_000.0, 25_000, 80_000, 150_000] {
                    let p = destination(from: origin, azimuth: azimuth, distance: distance)
                    let look = frame.look(at: GeoPoint(latitude: p.latitude, longitude: p.longitude))
                    XCTAssertEqual(azimuthDifference(look.azimuth, azimuth), 0, accuracy: 0.003,
                                   "lat \(latitude) az \(azimuth) d \(distance)")
                    XCTAssertEqual(look.distance, distance, accuracy: distance * 1e-4)
                }
            }
        }
    }

    func testLookAtPointsWithKnownGeometry() {
        let origin = GeoPoint(latitude: 46, longitude: 8, height: 1_000)
        let frame = LocalFrame(origin: origin)
        // 10 km due east and 1000 m higher: atan(1000/10000) minus the Earth's curvature.
        let east = destination(from: origin, azimuth: 90, distance: 10_000)
        let target = GeoPoint(latitude: east.latitude, longitude: east.longitude, height: 2_000)
        let look = frame.look(at: target)
        XCTAssertEqual(look.azimuth, 90, accuracy: 1e-3)
        let r = WGS84.radius(latitude: 46 * .pi / 180, azimuth: .pi / 2)
        let expected = atan(1_000 / 10_000.0 - 10_000 / (2 * r)) * 180 / .pi
        XCTAssertEqual(look.elevation, expected, accuracy: 2e-3)
        // Refraction lifts it by about k·d/(2R).
        let refracted = frame.look(at: target, refraction: 0.13)
        XCTAssertEqual(refracted.elevation - look.elevation, 0.13 * 10_000 / (2 * r) * 180 / .pi, accuracy: 1e-4)
    }

    func testAzimuthHelpers() {
        XCTAssertEqual(normalizedAzimuth(-10), 350)
        XCTAssertEqual(normalizedAzimuth(725), 5)
        XCTAssertEqual(azimuthDifference(5, 355), 10)
        XCTAssertEqual(azimuthDifference(355, 5), -10)
        XCTAssertEqual(azimuthDifference(180, 0), 180)
    }

    func testConformalLatitudeRoundTrip() {
        for degrees in stride(from: -85.0, through: 85, by: 5) {
            let phi = degrees * .pi / 180
            let chi = ConformalSphere.conformalLatitude(phi)
            XCTAssertEqual(ConformalSphere.geodeticLatitude(sinChi: sin(chi)), phi, accuracy: 1e-9)
        }
    }
}

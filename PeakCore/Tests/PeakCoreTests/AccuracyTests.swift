import XCTest
@testable import PeakCore

/// Accuracy problems from a review of skyline matching: each failed before its fix.
final class PatchSeamTests: XCTestCase {
    /// A knife-edge ridge (45° sides) running north across 46°N.
    static func ridge(_ lat: Double, _ lon: Double) -> Double {
        3_000 - abs(lon - 7.97) * 111_320 * cos(46 * .pi / 180)
    }

    /// A 30 m patch on the 1/3600° grid of the cell south of `top`, `rows` × 144 pixels
    /// from 7.95°E.
    static func patch(cellSouth: Int, top: Double, rows: Int) -> ElevationTile {
        let step = 1.0 / 3_600
        var values = [Int16]()
        for r in 0..<rows {
            for c in 0..<144 { values.append(Int16(ridge(top - Double(r) * step, 7.95 + Double(c) * step).rounded())) }
        }
        return ElevationTile(south: cellSouth, west: 7, rows: rows, cols: 144, originLatitude: top, originLongitude: 7.95,
                             stepLatitude: step, stepLongitude: step, heights: values)
    }

    /// The app fetches patches per 1° cell, so two meet wherever the area around you crosses
    /// a 1° line. Each blended back into the 240 m tile toward its own edge, so within about
    /// 250 m of the line the crest fell to the coarse tile's blunt one, 60+ m lower.
    func testPatchesMeetingOnACellBoundaryLeaveNoDip() {
        let coarse = [45, 46].map { ElevationTile(south: $0, west: 7, size: 450, height: Self.ridge) }
        // North of the line: rows down to the cell's last one, 1/3600° above 46°N. South of
        // it: from the cell's first row, on 46°N itself.
        let north = Self.patch(cellSouth: 46, top: 46.02, rows: 72)
        let south = Self.patch(cellSouth: 45, top: 46, rows: 72)
        let terrain = Terrain(tiles: coarse, detail: [north, south])
        var worst = 0.0
        for i in -100...100 {
            let lat = 46 + Double(i) * 0.00005
            worst = max(worst, abs(terrain.height(latitude: lat, longitude: 7.97) - 3_000))
        }
        XCTAssertLessThan(worst, 1, "crest dips by \(worst) m at the 1° line")
        // Off the crest too, on and right next to the line.
        for lat in [46.0, 46.0001, 45.9999, 46.0015, 45.9985] {
            XCTAssertEqual(terrain.height(latitude: lat, longitude: 7.965), Self.ridge(lat, 7.965), accuracy: 1, "\(lat)")
        }
        // With no patch across the line, the patch still blends into the coarse tile there.
        let alone = Terrain(tiles: coarse, detail: [north])
        XCTAssertGreaterThan(abs(alone.height(latitude: 46.0001, longitude: 7.97) - 3_000), 20)
    }
}

final class EyeHeightTests: XCTestCase {
    /// An east-west knife-edge crest at 46.05°N (45° sides) and a 4,000 m peak 22 km north.
    static let terrain: Terrain = {
        let crest = 46.05, peak = (lat: 46.25, lon: 7.5)
        let tile = ElevationTile(south: 46, west: 7, size: 1_200) { lat, lon in
            var h = max(1_000, 2_500 - abs(lat - crest) * 111_320)
            let dy = (lat - peak.lat) * 111_320, dx = (lon - peak.lon) * 111_320 * cos(peak.lat * .pi / 180)
            h = max(h, 4_000 - (dx * dx + dy * dy).squareRoot())
            return h
        }
        return Terrain(tiles: [tile], missingIsSea: false)
    }()

    /// A fix 15 m off the crest put the eye 15 m down its side, and the crest hid the view.
    /// The ground is the highest within the fix's accuracy (up to 30 m).
    func testEyeStandsOnTheCrestWithinTheFixAccuracy() {
        let renderer = HorizonRenderer(terrain: Self.terrain)
        let lat = 46.05 - 15 / 111_320.0, lon = 7.5
        let summit = GeoPoint(latitude: 46.25, longitude: 7.5, height: 4_000)

        let exact = renderer.observer(latitude: lat, longitude: lon)
        XCTAssertEqual(exact.height, 2_486.6, accuracy: 1)
        XCTAssertFalse(renderer.visibility(of: summit, from: exact).isVisible)

        let fix = renderer.observer(latitude: lat, longitude: lon, accuracy: 20)
        XCTAssertEqual(fix.height, 2_501.6, accuracy: 1.5)
        XCTAssertEqual(fix.latitude, lat)
        XCTAssertTrue(renderer.visibility(of: summit, from: fix).isVisible)

        // Never further than 30 m, however rough the fix.
        let far = 46.05 - 60 / 111_320.0
        XCTAssertEqual(renderer.observer(latitude: far, longitude: lon, accuracy: 500).height, 2_500 - 30 + 1.6, accuracy: 1.5)
    }
}

final class PositionUncertaintyTests: XCTestCase {
    /// The view is only rebuilt after moving some way, so matching must allow for the fix's
    /// accuracy plus how far you've moved since; it was a fixed 10 m.
    func testUncertaintyGrowsWithAccuracyAndDistanceMoved() {
        XCTAssertEqual(LocationQuality.positionUncertainty(accuracy: 30, moved: 0), 30)
        XCTAssertEqual(LocationQuality.positionUncertainty(accuracy: 30, moved: 45), 75)
        XCTAssertEqual(LocationQuality.positionUncertainty(accuracy: 1, moved: 0), LocationQuality.minUncertainty)
        // No accuracy (negative from Core Location): as rough as matching allows.
        XCTAssertEqual(LocationQuality.positionUncertainty(accuracy: -1, moved: 0), LocationQuality.matchingAccuracy)

        // Near terrain counts for less the less sure the position is; far terrain barely changes.
        var settings = AlignmentSettings()
        settings.positionUncertainty = LocationQuality.positionUncertainty(accuracy: 30, moved: 45)
        XCTAssertGreaterThan(settings.sigma(distance: 1_000), 4)
        XCTAssertLessThan(settings.sigma(distance: 50_000), 0.12)
    }

}

final class HeadingLockTests: XCTestCase {
    func testFirstLockNeedsTwoAgreeingMatches() {
        var lock = HeadingLock()
        XCTAssertNil(lock.add(8.0, current: 0))
        XCTAssertFalse(lock.isLocked)
        // A second that disagrees replaces the first and waits in turn.
        XCTAssertNil(lock.add(-3.0, current: 0))
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(lock.add(-3.4, current: 0) ?? .nan, -3.2, accuracy: 1e-9)
        XCTAssertTrue(lock.isLocked)
    }

    func testLockedIgnoresALoneJumpButFollowsARepeatedOne() {
        var lock = HeadingLock()
        _ = lock.add(5.0, current: 0)
        var heading = lock.add(5.2, current: 0)!
        // Small moves are followed part of the way.
        heading = lock.add(5.5, current: heading)!
        XCTAssertEqual(heading, 5.3, accuracy: 1e-9)
        // One odd match 4° off changes nothing; the next normal one carries on.
        XCTAssertNil(lock.add(9.3, current: heading))
        heading = lock.add(5.3, current: heading)!
        XCTAssertEqual(heading, 5.3, accuracy: 1e-9)
        XCTAssertNil(lock.pending)
        // A jump the next match repeats is real (the compass changed): taken whole.
        XCTAssertNil(lock.add(9.0, current: heading))
        heading = lock.add(9.2, current: heading)!
        XCTAssertEqual(heading, 9.1, accuracy: 1e-9)
        // Two different jumps in a row don't confirm each other.
        XCTAssertNil(lock.add(13.0, current: heading))
        XCTAssertNil(lock.add(4.0, current: heading))
        lock.reset()
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.add(9.1, current: heading))
    }

    func testAnglesWrap() {
        var lock = HeadingLock()
        _ = lock.add(359.9, current: 0)
        XCTAssertEqual(HeadingLock.difference(lock.add(0.1, current: 0)!, 0), 0, accuracy: 1e-9)
    }
}

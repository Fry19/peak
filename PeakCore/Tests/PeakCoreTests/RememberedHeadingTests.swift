import XCTest
@testable import PeakCore

/// A heading correction kept for the next launch at the same spot (`RememberedHeading`).
final class RememberedHeadingTests: XCTestCase {
    let found = Date(timeIntervalSince1970: 1_800_000_000)

    func remembered(heading: Double = -15.5, accuracy: Double = 8) -> RememberedHeading {
        RememberedHeading(heading: heading, latitude: 46.0, longitude: 7.75, accuracy: accuracy, date: found,
                          byHand: false, sideways: false)
    }

    /// Same as the simulated phone in `HeadingHoldTests`.
    func gyro(error: Double, time: Double, epoch: Int = 1) -> GyroReading {
        GyroReading(divergence: 37 + error, time: time, epoch: epoch)
    }

    func testAppliesOnlyNearbyRecentlyAndWithAPreciseFix() {
        let r = remembered()
        // 50 m north, an hour later.
        XCTAssertTrue(r.applies(latitude: 46.00045, longitude: 7.75, accuracy: 10, now: found + 3600))
        // 150 m away: the compass is pulled differently there.
        XCTAssertFalse(r.applies(latitude: 46.00135, longitude: 7.75, accuracy: 10, now: found + 3600))
        // A fix too rough to tell the spot.
        XCTAssertFalse(r.applies(latitude: 46.0, longitude: 7.75, accuracy: 65, now: found + 3600))
        XCTAssertFalse(r.applies(latitude: 46.0, longitude: 7.75, accuracy: -1, now: found + 3600))
        // Older than a week, or from the future (the clock was changed).
        XCTAssertTrue(r.applies(latitude: 46.0, longitude: 7.75, accuracy: 10, now: found + 6 * 86400))
        XCTAssertFalse(r.applies(latitude: 46.0, longitude: 7.75, accuracy: 10, now: found + 8 * 86400))
        XCTAssertFalse(r.applies(latitude: 46.0, longitude: 7.75, accuracy: 10, now: found - 60))
    }

    func testRejectsWhatCouldNotHaveBeenMeasured() {
        XCTAssertTrue(remembered().isValid)
        XCTAssertFalse(remembered(heading: .nan).isValid)
        XCTAssertFalse(remembered(heading: 45).isValid)
        XCTAssertFalse(remembered(accuracy: 80).isValid)
        var r = remembered()
        r.latitude = 95
        XCTAssertFalse(r.isValid)
        XCTAssertFalse(r.applies(latitude: 46.0, longitude: 7.75, accuracy: 10, now: found + 60))
    }

    func testSurvivesEncoding() throws {
        let r = remembered()
        let back = try JSONDecoder().decode(RememberedHeading.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }

    /// The hold is whole for its first minute in the same gyroscope run, and only then.
    func testHoldIsWholeOnlyAtFirst() {
        var hold = HeadingHold()
        XCTAssertFalse(hold.isWhole(gyro(error: 10, time: 0)))
        hold.start(divergence: 47, time: 0, epoch: 1)
        XCTAssertTrue(hold.isWhole(gyro(error: 12, time: 59)))
        XCTAssertFalse(hold.isWhole(gyro(error: 12, time: 61)))
        XCTAssertFalse(hold.isWhole(gyro(error: 12, time: 10, epoch: 2)))
        XCTAssertFalse(hold.isWhole(nil))
    }

    /// Restored, the heading is in use at once, but it isn't a match: the lock still needs
    /// two fresh ones that agree, and those replace it outright (no blending with it).
    func testRestoredHeadingNeedsTwoMatchesAndIsReplaced() {
        var h = HeldHeading()
        h.hold.start(divergence: 40, time: 0, epoch: 1)
        h.restore(-15.5)
        XCTAssertNil(h.hold.reference)
        XCTAssertFalse(h.lock.isLocked)
        XCTAssertEqual(h.correction(gyro(error: 12, time: 5)), -15.5, accuracy: 1e-9)
        // One match that agrees with the remembered heading doesn't lock.
        XCTAssertFalse(h.add(-15.5, at: gyro(error: 15.5, time: 10), now: gyro(error: 15.5, time: 10)))
        XCTAssertEqual(h.heading, -15.5, accuracy: 1e-9)
        XCTAssertFalse(h.lock.isLocked)
        // Two that agree with each other but not with it take over entirely.
        var other = HeldHeading()
        other.restore(-15.5)
        XCTAssertFalse(other.add(-12, at: gyro(error: 12, time: 10), now: gyro(error: 12, time: 10)))
        XCTAssertTrue(other.add(-12, at: gyro(error: 12, time: 11), now: gyro(error: 12, time: 11)))
        XCTAssertTrue(other.lock.isLocked)
        XCTAssertEqual(other.correction(gyro(error: 12, time: 11)), -12, accuracy: 1e-9)
    }
}

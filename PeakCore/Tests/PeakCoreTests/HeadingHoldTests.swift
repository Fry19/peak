import XCTest
@testable import PeakCore

/// The compass correction held by the gyroscope (`HeldHeading`, `HeadingHold`).
///
/// A simulated phone: its camera's true heading is its gyroscope heading plus a constant
/// (the gyroscope's zero), and the fused compass reads the true heading plus an error that
/// wanders as the phone nears steel. The correction is right when the fused heading plus
/// it is the true heading, that is when it is minus the compass's error.
final class HeadingHoldTests: XCTestCase {
    /// The gyroscope's reading with the compass `error` degrees off at `time`.
    func gyro(error: Double, time: Double, epoch: Int = 1) -> GyroReading {
        // divergence = fused − gyro = (true + error) − (true − zero) = zero + error
        GyroReading(divergence: 37 + error, time: time, epoch: epoch)
    }

    /// Locked with the compass 10° off at time 0 (two matches that agree).
    func locked() -> HeldHeading {
        var h = HeldHeading()
        XCTAssertFalse(h.add(-10, at: gyro(error: 10, time: 0), now: gyro(error: 10, time: 0)))
        XCTAssertTrue(h.add(-10, at: gyro(error: 10, time: 1), now: gyro(error: 10, time: 1)))
        XCTAssertEqual(h.correction(gyro(error: 10, time: 1)), -10, accuracy: 1e-9)
        return h
    }

    func testHoldsTheHeadingWhileTheCompassWanders() {
        let h = locked()
        // Beside a railing the compass turns 6° further; the view stays true.
        XCTAssertEqual(h.correction(gyro(error: 16, time: 30)), -16, accuracy: 1e-9)
        // Then the hold fades out, back to the correction last found.
        XCTAssertEqual(h.correction(gyro(error: 16, time: 1 + 60 + 120)), -13, accuracy: 1e-9)
        XCTAssertEqual(h.correction(gyro(error: 16, time: 1 + 300)), -10, accuracy: 1e-9)
    }

    /// A match waiting for confirmation compares with the next one under the gyroscope's
    /// zero, not the compass's, so the compass turning in between doesn't keep it waiting
    /// (nor make two different headings look alike).
    func testConfirmsAcrossTheCompassWandering() {
        var h = HeldHeading()
        XCTAssertFalse(h.add(-10, at: gyro(error: 10, time: 0), now: gyro(error: 10, time: 0.5)))
        // 4° of compass wander later, the next match measures −14 under the fused compass:
        // the same true heading.
        XCTAssertTrue(h.add(-14, at: gyro(error: 14, time: 3), now: gyro(error: 14, time: 3.5)))
        XCTAssertEqual(h.correction(gyro(error: 14, time: 3.5)), -14, accuracy: 1e-9)

        var other = HeldHeading()
        XCTAssertFalse(other.add(-10, at: gyro(error: 10, time: 0), now: gyro(error: 10, time: 0.5)))
        // The same −10 after the compass turned 4° is a different true heading: it waits.
        XCTAssertFalse(other.add(-10, at: gyro(error: 14, time: 3), now: gyro(error: 14, time: 3.5)))
    }

    /// A match whose frame was taken before the compass moved still lands right.
    func testMatchArrivingLateUsesItsFramesGyroscope() {
        var h = locked()
        XCTAssertTrue(h.add(-10, at: gyro(error: 10, time: 5), now: gyro(error: 13, time: 5.4)))
        XCTAssertEqual(h.correction(gyro(error: 13, time: 5.4)), -13, accuracy: 1e-9)
    }

    func testRestartDropsTheHoldAndWaitingMatches() {
        var h = locked()
        let restarted = gyro(error: 16, time: 30, epoch: 2)
        // The gyroscope's zero is new: no hold, the correction as last found.
        XCTAssertEqual(h.correction(restarted), -10, accuracy: 1e-9)
        XCTAssertFalse(h.add(-16, at: restarted, now: restarted), "waits for a second match again")
    }

    /// A match from a frame taken before the restart arrives after it: turned away, and it
    /// can't seed a confirmation under the new zero.
    func testMatchFromBeforeARestartIsTurnedAway() {
        var h = locked()
        XCTAssertFalse(h.add(-10, at: gyro(error: 10, time: 5), now: gyro(error: 10, time: 5.4, epoch: 2)))
        XCTAssertFalse(h.add(-10, at: gyro(error: 10, time: 6, epoch: 2), now: gyro(error: 10, time: 6.4, epoch: 2)),
                       "the first match of the new run still waits for a second")
        XCTAssertFalse(h.add(-10, at: nil, now: gyro(error: 10, time: 7, epoch: 2)), "no gyroscope for the frame")
    }

    /// Lined up by hand on a paused picture: what the compass did since it was taken counts.
    func testLiningUpAPausedPictureCarriesForward() {
        var h = HeldHeading()
        h.lineUp(-10, at: gyro(error: 10, time: 0), now: gyro(error: 12, time: 20))
        XCTAssertEqual(h.correction(gyro(error: 12, time: 20)), -12, accuracy: 1e-9)
        XCTAssertEqual(h.correction(gyro(error: 15, time: 40)), -15, accuracy: 1e-9)
    }

    /// Taking over what the hold gave doesn't move the view; `folded` says by how much the
    /// heading moved instead.
    func testSettingKeepsTheViewAndCountsWhatWasFolded() {
        var h = locked()
        let now = gyro(error: 16, time: 30)
        let before = h.correction(now)
        h.set(h.correction(now), at: now)
        XCTAssertEqual(h.correction(now), before, accuracy: 1e-9)
        XCTAssertEqual(h.folded, -6, accuracy: 1e-9)
        XCTAssertEqual(h.held(now), 0)
    }
}

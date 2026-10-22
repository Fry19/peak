# gyro-hold (claude lead)

- consult · codex · 2 min · exit: 0 · changed outcome: y · 01a16494-401b — the lock now compares matches under the gyroscope's zero (stable K) instead of folding into the fused-compass heading; the hold is applied outside the overlay's easing; paused alignment is anchored at the frame's own gyroscope reading; restarts are handled by gyroscope epoch; the hold stays out of lens offsets.
- review · codex (read-only correctness, resumed) · 3 min · exit: 0 · changed outcome: y · 01a16494-401b — fixed all six: paused redraws no longer discard the eased value (it restarts at the target); matches from another epoch or without the gyroscope are rejected (in takeMatch and HeldHeading); north is taken from the frame's sample; reset rebuilds the paused heading from its own north and lens and clears held; north and hold are applied outside the easing; pose and gyroscope come from one locked sample.

Inspected: AppModel.Correction and alignment paths, MotionTracker, SkylineCorrector, OverlayView, lens offsets. The bookkeeping moved into PeakCore HeldHeading with 7 unit tests. No re-review of the fixes (not substantial new changes); the 60/300 s hold limits are unverified on a phone.

Lesson: when one quantity is added in several places (overlay easing, corrector prior, freeze), list every consumer before choosing where the new term goes; most review findings were at those seams.

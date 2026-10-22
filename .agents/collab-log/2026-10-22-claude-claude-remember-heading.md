# claude-remember-heading (claude lead)

- consult · codex · 1 min · exit: 0 · changed outcome: y — raw-compass matching prior confirmed; added snapshot of the gyro-held correction (not only match-time), true-north readiness gate with retries, revalidation by distance · 01a164db-3fd4
- consult (resumed, correctness review) · codex · 2 min · exit: 0 · changed outcome: y — fixed: saves from a stale gyro reading after the sensors stop, restore settled by a far cached fix, true north counted before any sample, and remembered heading left on after a fallback to magnetic north · 01a164db-3fd4

Inspected: AppModel Correction/updateCorrector/linedUpByHand/resetAlignment, HeldHeading/HeadingLock, SkylineCorrector prior, MotionTracker north handling, StatusPill.
Declined: nothing; radius/age/orientation limits stay unvalidated guesses (both agreed they need phone evidence).
Limits: simulator has no Core Motion, so restore and the "Remembered" pill couldn't be seen there; only the saved record and diagnostics line were.
Lesson: save what the view actually shows (heading plus the gyroscope hold), not only what the last match measured.

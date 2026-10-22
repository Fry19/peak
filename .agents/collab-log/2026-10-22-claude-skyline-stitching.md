# skyline-stitching (claude lead)

- consult · codex · 3 min · exit: 0 · changed outcome: y · 01a163f0-5c02 — kept the shared multi-view core with N=1 parity; added overlap weighting (repeat views add nothing), full gyro rotation integration instead of ω·up, and clearing the strip after any accepted match for HeadingLock independence; no per-frame yaw slack.
- review · codex (read-only correctness) · 5 min · exit: 0 · changed outcome: y · 01a16412-7f60 — applied all six: views with too few points now reject instead of skipping the agreement check; gate statistics counted by overlap share; strip translation uses the GPS fix, not the horizon's observer; a generation counter keeps pre-pause work out of the strip; zoom compatibility is a 1% focal-length check, not exact equality; leveling keeps the camera's heading at pitch (tested at 30°).

Inspected: Aligner, SkylineMatcher, HeadingLock, SkylineCorrector, MotionTracker, AppModel wiring. My own pan bench found shared-heading fits absorbing gyro drift (1.1° and 2.2° errors accepted); I added the per-view agreement gate before the review. Single-frame release benches (7 sets) were identical to baseline after every round. Limits: no physical-phone check of gyro conventions, drift, or live timing.

Lesson: a benchmark mode that simulates the failure (drift, here) found a false-accept path that source review alone hadn't; build the adversarial knob before tuning gates.

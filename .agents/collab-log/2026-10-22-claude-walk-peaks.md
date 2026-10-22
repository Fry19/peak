# walk-peaks (claude lead)

- consult · codex · 2 min · exit: 0 · changed outcome: y — agreed on a screen-space overlay; budget after frustum filtering, not a global top 40; check the drawn triangles, not bilinear heights; rejected ±5 m hysteresis that could keep a blocked peak (enter with margin, leave at once); off-main checks tagged by world; summit card clamping needs a leader to the true anchor · 01a1644a-eb7c
- review · codex · 9 min · exit: 0 · changed outcome: y — applied its patch (world-replacement cleanup, labels gone at once when out of sight, every safe-area inset, all four corners for the surface); found stale positives while moving and half-cell sampling / two-cell skip missing ridges (both reproduced) → exact grid/diagonal traversal and per-peak (clearance, eye) with a movement bound · 01a16461-5bd5
- review (resumed) · codex · 2 min · exit: 0 · changed outcome: y — slope bound unmeasured, infinity never expiring, one-cell skip still hiding a diagonal ridge, grid-aligned rays picking one square → measured steepest slope, capped infinity, whole line checked, both adjacent squares · 01a16461-5bd5
- review (resumed) · codex · 2 min · exit: 0 · changed outcome: y — 10 m contact allowance passed real occlusion; seams break the slope bound → every shown label re-checked exactly from the current eye each frame · 01a16461-5bd5
- review (resumed) · codex · 1 min · exit: 0 · changed outcome: y — fading labels skipped that check; neighborhood-max target was a proxy → fading ones certified too, target is the summit's own point · 01a16461-5bd5
- review (resumed) · codex · 1 min · exit: 0 · changed outcome: y — contact allowance still let 0.2 m through → reduced to a 5 cm rounding tolerance within the summit's grid square (the line ends on the ground there); not re-reviewed after this one-constant change · 01a16461-5bd5

- Scope: new Peak/Views/WalkLabels.swift; TrailWalkView (summit card → overlay, peak pool, exact clearance, keep-clear frames); PeakCore TrailWalk (surfaceHeight, exact clearance, steepestSlope, tests) and Labels (opt-in flipsOthers, test).
- User feedback mid-task: no labels through mountains, subtle → the hike's summit is now also shown only while in sight (it used to draw through terrain); the red markers they saw were fixture-only debugging.
- Checks: PeakCore 238/238 (macOS) plus TrailWalk/Label suites after the last changes; app Debug build; fixture (real OSM peaks, local DEM) in Debug and Release on iPhone 17 Pro iOS 26.5: Alpine follow, paused orbit, landscape, Terrain style, Smokies orbit; hidden peaks marked in a fixture-only build land on nearer ridge faces.
- Limits: no physical iPhone (frame time with ≤6 exact rays a frame; Debug builds of PeakCore make it slow), compact phone, Dynamic Type and VoiceOver (backlogged), Linux not run.

Lesson: for "never wrong" visibility, certify what is actually drawn from the current pose each frame; async checks and motion bounds can nominate, never approve.

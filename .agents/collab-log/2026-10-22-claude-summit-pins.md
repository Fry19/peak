# summit-pins (claude lead)

- consult · codex · 2 min · exit: 0 · changed outcome: y — one pin sets heading only (not heading and pitch, as AnchorSolver did); solve from the pre-pin attitude so order doesn't matter; label drag on the paused view enters lining up; the picker also offers a searchable list, not only nearby peaks; a pending photo re-match must not overwrite a new adjustment · 01a164da-87b6
- review · codex · 4 min · exit: 0 · changed outcome: y — applied its 44 pt chip targets and "Lining up by hand" status; fixed rotation (pins let go when the screen turns), tilt beyond the hand limit (heading alone instead of a silently clamped tilt) and the stale re-match (adjustment counter); declined a movable VoiceOver target for now (backlog) · 01a164ed-b0ac

- Scope: PeakCore SummitPins + AnchorSolver.Free (Anchors.swift), AppModel pin/unpin/applyPins, CameraScreen gestures and actions, OverlayView pin rings and pinned labels, LabeledPhoto/PhotoView/PhotoOverlay pins, SummitPinViews (picker, banner), README.
- Checks: SummitPins tests (one pin, two pins, close pins, wrong pick and undo, north wrap, zoom, candidates, no-tilt fallback); full PeakCore suite 259/259 before the review fixes, SummitPins again after. PEAK_TEST_PHOTO balcony fixture on a temporary iPhone 17 Pro (iOS 27.0): label drag from the plain photo view, tap and pick Green Top, chip removal restoring the matched lines, two pins setting heading and tilt, accessibility-extra-large text, Done clearing pins and re-matching; integrated build after the review. No benchmark run: matching and its gates are unchanged.
- Limits: the camera's paused view (no camera in the simulator), landscape, a compact iPhone and VoiceOver running live were not checked; VoiceOver actions are source-checked only.

Lesson: in a lining-up mode, a drag that just misses its target must not throw away what was placed; make pins hold the lines and removal explicit.

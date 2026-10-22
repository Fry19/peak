# align-on-camera (claude lead)

- consult · codex · 2 min · exit: 0 · changed outcome: y — confirmed the live-bar button and carrying a paused nudge into the live view; added: on a hand adjustment clear `lastMatch` and reset the heading lock (so the pill doesn't say Locked and matches must agree again), publish corrections before unpausing, and keep pinches from nudging · 01a163f8-10dd
- review · codex · 6 min · exit: 0 · changed outcome: y — applied: clear `lastWideMatch` on a hand adjustment (a telephoto match just after would otherwise fold the hand move into that lens's saved offset and restore Locked), ignore a zero nudge, ignore the rest of a paused drag once a second finger joined, VoiceOver/Voice Control actions to move the paused lines. Reworked rather than applied: its `maximumNumberOfTouches` switch fed from `updateUIView` (UIKit may keep tracking the first finger through a pinch; replaced by a per-gesture flag) and its stored accessibility flag (now computed from the model) · 01a16401-4492

- Scope: RootView bottom bar and AlignBanner, SettingsView, CameraScreen gestures and accessibility, AppModel finishAligning/nudge/linedUpByHand, README.
- Checks: Debug builds for iPhone SE (3rd gen) iOS 26.5, 375 pt portrait, at Zermatt with live terrain; with a temporary sim-only stand-in frame (removed before commit): live bar fit, paused drag right/left at 1× and 2.9× (heading only, pitch held), off-center pinch (heading held), unpause → Lined up, camera-screen button → banner → drag → Done, Settings section gone. Found and fixed the banner's white-on-white Done.
- Limits: no physical iPhone (real frames, share button in the paused bar, drag feel); landscape, larger phones and Dynamic Type not exercised; VoiceOver actions and pinch-then-lift not exercised in the simulator.

Lesson: a camera-less simulator can still exercise paused-view gestures with a temporary stand-in frame; keep the patch as a script so it applies and reverts exactly.

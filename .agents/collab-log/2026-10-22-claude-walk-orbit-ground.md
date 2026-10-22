# walk-orbit-ground (claude lead)

- consult · codex · 2 min · exit: 0 · changed outcome: y — keep the camera's own spot clear first; the grid's triangles can rise above the bilinear height (use corner maxima); 20 m vs the 10 m near plane is provisional; the turntable accumulates its own angles, so a lift may not stick · 01a163da-302f
- consult (resumed) · codex · 1 min · exit: 0 · changed outcome: y — on new frames (camera clear but the walker hidden behind the near slope) agreed to keep the line of sight too, with the ring as fallback ground · 01a163da-302f
- consult (resumed) · codex · 2 min · exit: 0 · changed outcome: y — agreed to own the orbit after the turntable fought the lift; bisection must return a verified-clear angle and keep the last pose when none; 30 m minimum can't meet 40 m clearance (now min(40, d/10) and 60 m); clear coasting on cancel; Reduce Motion. Declined for now: VoiceOver camera actions (gap predates this; backlogged) · 01a163da-302f
- review · codex · 10 min · exit: 0 · changed outcome: y — applied: seed the orbit from the camera's model position, not the presentation one, which can lag a scrub or rebuild by a frame. Recorded its verified, pre-existing sightline approximation (bilinear vs. drawn diagonal) in the backlog · 01a163ec-9e58

- Scope: PeakCore TrailWalk (ReliefMap.highest, TrailWalk.raised extracted from camera(at:), orbit/orbitAngles/lowestClearElevation, tests); TrailWalkView (own pan/pinch orbit replacing SceneKit's camera control, clearance checks, coasting).
- Checks: TrailWalkTests 16/16 and full PeakCore 222/222 (macOS); fixture on iPhone 17 Pro iOS 26.5 at 4.4 mi of the Alpine review route: before (camera inside the slope after sideways drags), each intermediate approach, final sideways and vertical drags (elevation held at 13.45°, distance constant, per log), pinch in/out (two-finger path), scrub then drag, resume into following, scrub + first drag after the review fix; real app build and launch.
- Limits: no physical iPhone (gesture feel, sensitivity); landscape, compact phones, Reduce Motion and VoiceOver not exercised; Linux not run.

Lesson: when a framework control keeps its own state (SceneKit's turntable accumulates angles), don't correct its output from outside; take the interaction over, so there's one writer.

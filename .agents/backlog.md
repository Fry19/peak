# Peak backlog

Out-of-scope findings from implementation and peer review belong here. Check entries for the files a task touches; remove an entry only after fixing and verifying it. See [peer collaboration procedures](skills/peer-collaboration/SKILL.md#backlog-and-task-log) for the format.

- 🟡 verified · 2026-10-21 · Codex/map-terrain-detail · Peak/Views/TrailWalkView.swift:853 — The existing back-to-map button has a 28×28 pt target, below the 44 pt iPhone target guidance. Source and simulator accessibility frame agree. Add the existing `tapArea()` around it without enlarging its visible circle. Out of scope for terrain detail/style; lead source/UI inspection.
- 🟡 verified · 2026-10-21 · Codex/map-terrain-detail · Peak/Views/TrailWalkView.swift:541 — The existing SceneKit summit card can extend beyond the viewport when paused near the overhead intro. `matched-walk-portrait.png` under `/tmp/peak-review/codex-map-terrain-detail/` clips the Gornergrat label at the right edge. Clamp a screen-space card or hide it when its bounds leave the view. Out of scope for terrain detail/style; lead rendered inspection.

# card-actions (claude lead)

- consult · codex · 1 min · exit: 0 · changed outcome: y — moved the 3D and viewshed tiles above the picture (I'd planned them under the stats, below the fold at the half-height card with a photo); Find in view with secondary styling under them; agreed on hiding it for photo label taps too and on keeping the sheet's constant "peak" identity · 01a164d3-127b
- review · codex · 2 min · exit: 0 · changed outcome: y — applied its one fix: Find in view measured 42 pt, so tiles now have a 44 pt minimum height; StatGrid's broken titles at accessibility sizes went to the backlog · 01a164dc-b08c

- Scope: PeakDetailView (action tiles under the title, `fromLabel`), AppModel `Sheet.peak`/`select(fromLabel:)`, CameraScreen label tap, PhotoView card, RootView sheet, ViewshedButton/PeakIn3DButton.
- Checks: Debug build on iPhone 17 Pro, iOS 26.5, portrait: list → card at half and full height (Find shown), each tile opened its screen, Find closed the card and showed the find arrow; test photo → label tap → card without Find; accessibility-extra-large text stacks the tiles. A first try with `.bordered` amber read as a heavy brown block on iOS 26; switched to slate tiles.
- Limits: a live camera label tap is source-only (no camera or motion in the simulator); no landscape, compact iPhone or VoiceOver pass.

Lesson: none

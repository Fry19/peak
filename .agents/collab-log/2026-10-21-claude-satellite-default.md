# satellite-default (claude lead)

- consult · codex · 2 min · exit: 0 · changed outcome: y — fit your live position (not only the scene's), cover the whole zoomed-out screen rather than clamping the center, retry imagery on reconnect, keep terrain detail where imagery only partly covers, named Satellite/Terrain choices, bound imagery memory · 01a161af-10fe
- review · codex · 11 min · exit: 0 · changed outcome: y — applied all four fixes in TrailFromAboveView.swift: padding bounded before the 120 km cap (a far-away location could move the zoomed-out area off the trail), imagery tiers chosen by what covers the screen and close-ups retried on reconnect, credits/notes/shading follow any shown tier, camera moves respect Reduce Motion · 01a161c3-fa1a

- Scope: map from above (TrailFromAboveView), AppSettings.mapStyle, README. Inspected: imagery and detail loaders, viewport/zoom/clamp, edge arrows, bottom bar, settings persistence.
- Checks: Debug builds of the app and a scratch review harness (local Alpine DEM, illustrative route); iPhone 17 Pro and SE (3rd gen), iOS 26.5: satellite default, Terrain, style menu, choice kept across relaunch, imagery-failure fallback note, zoom out to a location ~35 km away (satellite and terrain), SE and landscape bottom bar. Found and fixed during checks: Apple imagery at different scales showed as a differently colored square with its logo (only the coarsest sharp-enough tier is drawn now); "Walk in 3D" wrapped on the SE (scale bar shortens).
- Limits: the simulator's input tool dropped taps intermittently and then stopped on both devices, so some post-fix interactions were checked on the SE only; pinch, VoiceOver speech, larger Dynamic Type, a real offline phone and physical-iPhone memory were not checked. The simulator reported offline, so the "didn't load" wording was not seen.

## Walk in 3D follows the style

- consult (resumed, read-only review) · codex · 3 min · exit: 0 · changed outcome: y — applied all four: a late land-cover tint could undo the drape (now rechecks), cancelled drapes no longer install or publish, the ring's imagery is retried on its own, a bottom scrim keeps the credits readable; and the polish note, diffuse 0.55 → 0.48 so even white stays under the bloom threshold · 01a161af-10fe
- Scope: TrailWalkView (drape over the sharp terrain and the ring, crest strength, credits), map style menu and walk back button targets.
- Checks: Debug builds; 17 Pro and SE draped follow views, SE Terrain walk unchanged, SE chip unchanged after the 44 pt frame. Found during checks: `tapArea()` inside Button/Menu labels doesn't widen the target (taps 4–6 pt outside failed, center worked), recorded in the backlog.
- Limits: the simulator input tool stopped delivering taps, so the new 44 pt targets are confirmed by accessibility frame only; texture orientation judged from snow on ridges and green valleys, not a pixel overlay; the ground right in front of the camera is soft (one image for a 10–26 km square); texture memory (~45 MB decoded) and frame rate not measured on a phone.

Lesson: Apple's satellite imagery comes from different captures at different scales; never layer a sharper tier over one that's already sharp enough.

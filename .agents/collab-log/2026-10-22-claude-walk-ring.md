# walk-ring (claude lead)

- consult · codex · 2 min · exit: 0 · changed outcome: y — the z14 cutoff was measured at 1× while the app snapshots at 2× (confirmed: at 2× the mid tier was still the greener mosaic; it now loads at scale 1); the mid tier's fully blended area must reach past the sharp square; spread matching only on equally filtered samples, with guards; rematch the map's wide imagery when the main imagery arrives · 01a163fe-3a27
- review · codex · 7 min · exit: 0 · changed outcome: y — applied all three: matching skips translucent samples and keeps premultiplied pixels; a cached detail of another size no longer blocks a correctly sized one; the far cache is written only after the cancellation/world check · 01a1640c-41f6

- Scope: MapImagery (scale parameter, aerialMetersPerPoint, matched(to:)); TrailWalkView (ring matched to the near imagery, mid tier over the ring at 1×, walker detail square sized to the camera); TrailFromAboveView (wide imagery matched to the map's, rematched when either arrives).
- Checks: macOS MapKit probe at Kuwohi and Zermatt (aerial mosaic ≤12 m a point, other mosaics ≥16); fixture on iPhone 17 Pro iOS 26.5 with a Kuwohi-like route on Smokies tiles and the Alpine route, logging mean colors over the same area (ring 0.282 0.378 0.214 → 0.230 0.240 0.234 vs near 0.232 0.241 0.236; mid at 1× 0.232 0.241 0.235); follow and turned-around views; map zoomed out to a far "you" with and without matching; real app build and relaunch.
- Limits: no physical iPhone (memory with the mid tier up to 3072², load time on cellular); offline and Terrain-style walks not re-run (code paths gated on loads succeeding and the ring being draped); high latitudes, where the mid tier is skipped for the largest squares, not seen; compact phones and landscape not checked.

Lesson: Apple's satellite imagery is several mosaics chosen by meters a point, not a pixel; measure tiers through the app's own loader before choosing a resolution.

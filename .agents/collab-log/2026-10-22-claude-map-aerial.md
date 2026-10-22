# map-aerial (claude lead)

- consult · codex · 2 min · exit: 0 · changed outcome: y — automatic scale alone can't fix wide frames (35 m/px > the limit even at 1×), so a bounded aerial sample calibrates them; coarse close-ups are matched to the corrected main, which covers them wherever panned, not to the central sample; raw images kept and rematched when references change; calibration gets its own retry path; compare Alps and Smokies · 01a16442-86c9
- review · codex · 5 min · exit: 0 · changed outcome: n — no defects; 13 matching assertions and 300 scale/sample cases passed; weakest point the single central sample, which I then checked at the route's far end (residual green lean ≈0.01 vs ≈0.06 uncorrected) · 01a16448-fc2c

- Scope: MapImagery.load picks 1× when 2× would be coarser than the aerial photos, `aerial` flag, `matched(to:)` compares at the coarser picture's pixels; map main imagery calibrated to an aerial sample, close-ups matched to it; the walk's mid tier no longer forces its scale.
- Checks: fixture on iPhone 17 Pro iOS 26.5, long illustrative routes in the Alps (15.9 mi) and Smokies (16.7 mi): logged means before/after over the same areas, overview and zoomed views, the far end of the route, the walk on the long route (sharp terrain now at 1×, aerial); a 14 km Smokies frame needed only the scale change; real app build and relaunch.
- Limits: no physical iPhone (memory, cellular load time); offline/failed sample, high latitudes, compact phones and landscape not exercised; Apple's logo size at 1× not inspected.

Lesson: none.

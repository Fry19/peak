# Peak AR App: Project Brief

An AR app that labels mountain peaks (name + elevation) in the live camera view, traces their outlines, and lets you tap a peak to see details and the hiking trails that climb it.

Existing apps (PeakVisor, PeakFinder) feel clunky and are often misaligned. This app wins on two things: **accuracy** and **a premium, sleek, minimal feel**.

## Product principles

- **Camera first.** The app opens straight into the AR view. No onboarding walls, one floating control.
- **Quiet visuals.** Thin glowing ridgelines, restrained typography (SF Pro), name + elevation only. Nearer ridges brighter, farther ones fade like atmospheric haze.
- **Fewer labels by default.** Prominent peaks first; more appear when zooming or holding steady.
- **Never wrong, never jittery.** Never label a peak that's hidden behind a nearer ridge. Labels must not swim.
- Subtle haptic tick when a peak crosses screen center.

## Platform and stack

- iOS first, native: Swift, SwiftUI, ARKit, Metal, Core ML / Vision.
- Fully offline-capable: mountains often have no signal.

## MVP scope

1. **Skyline-matched labels + ridgeline outline**: the core; everything depends on alignment quality.
2. **Tap a peak → info card**: elevation, prominence, distance, bearing, a few facts.
3. **Trails list** on the card: length, elevation gain, difficulty, distance to trailhead.
4. **Trail drawn on the mountain in AR**: the signature feature. Tap a trail and it drapes onto the real slope.
5. **Offline regions**: downloadable packs.
6. **Freeze frame**: tap to pause the view so the user can lower the phone and explore.

## Technical approach: skyline matching

Phone compasses are often off by 5–15°, which is why competitors drift. Correct heading visually instead:

1. **Render the expected horizon.** From the GPS position, ray-march the DEM in fine azimuth steps (~0.1°) out to ~100–150 km. For each azimuth, keep the maximum elevation angle, accounting for earth curvature and atmospheric refraction (k ≈ 0.13). Output: a horizon profile h(azimuth) plus a depth map.
2. **Detect the real skyline.** On-device sky/terrain segmentation (start with a simple heuristic, move to a small Core ML model). Take the top terrain boundary per image column.
3. **Convert to angles.** Use ARKit camera intrinsics + device attitude to map the detected skyline to (azimuth, elevation).
4. **Align.** Search for the heading offset (plus small pitch/roll) that best matches observed vs rendered profiles, e.g. cross-correlation over ±20°.
5. **Smooth and gate.** Filter corrections (Kalman or complementary filter), apply as a yaw correction to ARKit world tracking, and only accept updates with enough skyline structure (reject cloud, tree, and building occlusion).
6. **Use ARKit tracking between corrections** so the overlay stays rock-steady.

Derived features:
- **Ridgelines**: draw the skyline plus secondary ridges found at depth discontinuities in the rendered depth map.
- **Label visibility**: line-of-sight test from the viewer to each summit.
- **Trail draping**: sample DEM elevations along the trail polyline, project to screen, depth-test against the rendered terrain to hide occluded segments.
- **Elevations** come from the peak database, never GPS altitude.

## Data sources

- **Terrain:** Copernicus GLO-30 DEM (global, 30 m); USGS 3DEP for higher detail in the US.
- **Peaks:** OpenStreetMap `natural=peak` (name, ele).
- **Trails:** OpenStreetMap hiking paths and `route=hiking` relations (`sac_scale` for difficulty).
- **Facts:** Wikidata.
- Commercial trail databases (e.g. AllTrails) don't offer open APIs; OSM is the starting point.
- Respect licenses: OSM (ODbL) and Copernicus require attribution.
- Offline packs: preprocessed region bundles (DEM tiles + peaks + trails).

## Roadmap after MVP

- **Quick wins:** find-a-peak arrow, photo capture with labels, directions to trailhead, summit logging + peak-bagging lists, alpenglow alerts, summit panorama preview (reuses the horizon renderer).
- **Bigger bets:** live position on the AR trail, mountain weather at elevation, daylight/turnaround check, telephoto zoom with locked labels, 3D flyover.
- **Later:** trail conditions (needs user reports), friends in AR, night sky, passenger mode, avalanche slope shading (liability risk), geology and name origins.

## First task

Prototype skyline matching **before any UI**, since it decides whether the app beats PeakVisor:

1. Build the horizon renderer from DEM tiles for a given lat/lon.
2. Build a test harness that runs on still photos with known location, heading, and field of view, so alignment can be tested at a desk.
3. Implement skyline detection and alignment; measure heading error before and after correction.
4. Then move into a live ARKit view.

## Open decisions

- App name.
- Pricing: free with a paid tier (offline maps, trails) vs one-time purchase.

## Working in this repo

- `PeakCore/` is a Swift package with no iOS dependencies (Foundation and Dispatch only), so it builds and tests on macOS and Linux. Keep the algorithms there; the app will be a thin layer on top.
- `swift test` in `PeakCore/` runs the unit tests. They use procedural terrain with known geometry, so they need no downloads.
- `peakbench` (in the same package) is the desk harness: `swift run -c release peakbench` lists its commands. Use a release build; debug builds are 10–35× slower.
- DEM tiles: `python3 Tools/fetch_dem.py --lat … --lon … --radius-km 100 --out DEM` (needs `pip install -r Tools/requirements.txt`). `DEM/` is git-ignored.
- After changing detection or alignment, run the benchmark before and after and compare. CI runs it on every push and puts the table in the job summary:
  `peakbench bench --dem DEM --lat 45.9837 --lon 7.7856 --runs 30` (ARKit mode) and `--mode photo`.
- Angles are degrees, distances meters, azimuths clockwise from true north. Image coordinates have y down, and a row's top edge is at y = row.
- On a Mac (set up with `Tools/setup-mac.sh`), build and install on a plugged-in iPhone without changing the project's signing settings:
  `xcodebuild -project Peak.xcodeproj -scheme Peak -destination 'platform=iOS,name=<iPhone name>' -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM=<team ID> build`,
  then `xcrun devicectl device install app --device '<iPhone name>' build/Build/Products/Debug-iphoneos/Peak.app` and `xcrun devicectl device process launch --device '<iPhone name>' com.fry19.peak`.
  `xcrun devicectl list devices` names the iPhone. The personal team ID is the `OU` in `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject` once Xcode has made a certificate (signing in under Xcode > Settings > Accounts and building once in Xcode makes one). Don't commit a team ID: CI builds unsigned.

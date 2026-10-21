# Peak

An iPhone app that labels the mountains in your camera view and stays lined up with them. Phone compasses are often 5–15° off, which is why other peak apps drift. Peak corrects the heading by matching the skyline the camera sees against the skyline the terrain says should be there.

This repo holds the skyline matching from the [project brief](CLAUDE.md), built and measured at a desk first, and the iPhone app (0.5) that uses it in a live camera view, with peak details and hikes.

![Synthetic photo toward the Matterhorn from Gornergrat. Red: the horizon where an 8° wrong compass puts it. Green: after skyline matching. Yellow: the detected skyline. Cyan: ridges behind the skyline.](docs/matterhorn-aligned.jpg)

*Red is where an 8° wrong compass puts the horizon, green is after correction (0.02° off), yellow is the detected skyline, and cyan marks ridges behind it.*

## The app (0.5)

Peak opens straight into the camera. The lines and labels stay on the mountains as you move the phone, the way PeakVisor's do: the phone's motion sensors (gyroscope, accelerometer and compass) give its orientation. Since the mountains are kilometers away, only the phone's rotation matters, so there's no ARKit world tracking to wait for. It works in portrait and landscape.

The first time you use it somewhere, it downloads the terrain and the named peaks for 80 km around you and keeps them, so the same area works offline afterwards. Then it draws:

- the skyline and the ridges in front of it as thin glowing lines, nearer ones brighter and farther ones fading;
- labels (name and height) for the highest peaks you can actually see (6, 10 or 18, in Settings), and a small dot on every other peak in sight. Peaks hidden behind a nearer ridge aren't shown. Peaks OpenStreetMap has no elevation for show the terrain's, marked "≈".

**Pinch** to zoom in on the picture and the lines together, up to 6× (the camera records in 4K where the phone can, so the picture stays sharp); more labels fit as the peaks spread apart. Tap the zoom chip at the top to zoom back out.

**Tap a label or a dot** for the peak's card: elevation, prominence, distance, bearing, how far above you it is, its range, first ascent and a Wikipedia summary and picture, and the **hikes nearby**: OpenStreetMap hiking routes and named paths within 5 km of the summit (10 km when there are none that close), plus unnamed paths up to it, with length, climb, difficulty on the SAC scale (T1–T6) and how far the start is from you. Those that reach the summit come first. A hike's card has a satellite map, an elevation profile and directions to the start. **Show on the mountain** lays the trail on the real slope in the camera view, leaving out the parts hidden behind nearer terrain.

The **list button** (bottom left) lists every peak around you, those in view first, with search; picking one highlights it in the view, with an arrow at the edge when it's out of frame. **Settings** (bottom right): meters or feet, how many labels, ridges, the haptic tick, terrain on mobile data, saving the area for offline use, and storage.

### Staying lined up

- **Skyline matching.** About once a second, while you hold the phone steady, Peak matches the skyline in the camera picture against the terrain and corrects the compass heading, pitch and roll. The pill at the bottom shows which way you're facing and **Locked** (green, matched within 20 seconds) or **Compass** (orange: point the phone at mountains with a clear skyline and hold it still for a moment).
- **Frame timing.** The app shows the camera frames itself and draws the lines for each frame with the phone's orientation at the moment that frame was taken (motion readings arrive 100 times a second and are interpolated). A camera picture reaches the screen a few hundredths of a second late, so drawing with the latest orientation made the lines run ahead of the picture while turning.
- **Lens.** The field of view and optical center come from each frame's intrinsic matrix when the camera provides one, with focus kept far.
- **Terrain detail.** See below. The shape of a nearby ridge is only as good as the terrain model, and sharp summits get their tips back from the peaks' surveyed heights (see "DEM accuracy at sharp summits").

**Line up by hand** (the arrows button, bottom right) when the skyline can't be matched, say behind trees and roofs: the picture pauses, and you drag the lines onto the mountains and turn them with two fingers to level them. The pill then shows **Lined up** (cyan). The tilt you set is saved for your phone, separately for holding it upright and sideways, since a camera mounted a little askew tilts the view differently each way; skyline matching keeps refining it when it can.

Labels stand upright in the world whichever way you hold the phone, even with the screen's rotation locked.

**Tap the pill** to pause the view so you can lower the phone and look; tap it again to go live. **Long-press the pill** for diagnostics (sensor rate, heading, corrections, last skyline match, GPS, terrain detail, lens, frame timing); a screenshot of them says a lot when something looks off. A light tick marks a labeled peak crossing the middle of the screen.

**Downloads:** the Copernicus tiles have lower-resolution copies built in, and the full 30 m image is stored in blocks of about 2.5 MB. Peak starts downloading as soon as it has a rough position, fetching tiles at 240 m (about 0.6 MB each) and 120 m within 30 km (2 MB), all at once, and shows the view as soon as the tile you're in arrives. Then it sharpens the terrain block by block: the full 30 m within 10 km, 60 m within 35 km and 120 m everywhere, and 30 m within 15–25 km on Wi-Fi (or on mobile data, unless you turn that off). Peaks and hikes come from OpenStreetMap through the Overpass API, facts from Wikidata and Wikipedia. Everything is cached on the phone; **Save this area for offline use** fetches the sharpest terrain for the whole area.

Not in 0.5 yet: a learned skyline detector, your position on a trail, and lidar terrain.

## Installing on your iPhone

You need an iPhone with iOS 17 or later. Both ways work with a free Apple ID; with a free Apple ID the app stops opening after 7 days until you refresh or reinstall it.

### Option 1: Sideload the IPA (no Xcode)

Every push builds an unsigned `Peak.ipa`: open the latest **Build** run under the repo's Actions tab and download the **Peak.ipa** artifact. Tagged versions (`v0.1.0` and so on) also put `Peak_<version>.ipa` on the Releases page.

iPhones can't install an app file directly, so a sideloading tool signs it with your Apple ID:

- **SideStore** installs and refreshes apps from the iPhone itself. Setting it up needs a computer once; follow the guide at [sidestore.io](https://sidestore.io). Then open SideStore, go to **My Apps**, tap **+** and pick the IPA. Open SideStore at least once a week and tap **Refresh All**.
- **Sideloadly** installs from a Mac or Windows PC over a cable: drag the IPA into [Sideloadly](https://sideloadly.io), enter your Apple ID and click **Start**. Do it again within 7 days, or turn on its automatic refresh.

The first time, also turn on **Settings → Privacy & Security → Developer Mode** and restart the iPhone, then trust your Apple ID under **Settings → General → VPN & Device Management**.

### Option 2: Build it in Xcode

On a Mac with Xcode 16 or later: open `Peak.xcodeproj`, select the **Peak** target, set **Signing & Capabilities → Team** to your Apple ID (change the bundle identifier `com.fry19.peak` if Xcode says it's taken), pick your iPhone and press **Run**.

When Peak starts, allow the camera and your location.

## Where it stands

| | |
| --- | --- |
| **Horizon renderer** | Ray-marches the DEM every 0.1° out to 150 km from any point, with the Earth's curvature and atmospheric refraction (k = 0.13). Besides the skyline it keeps a depth map of everything visible below it, so it knows every ridge and how far away each one is. The full 360° takes about 0.4 s on 4 CPU cores. |
| **Skyline detection** | A simple, model-free heuristic for now: it models the sky as a smooth color gradient and the terrain as a mix of colors, then finds the best boundary across the image by dynamic programming. It handles clouds and trees in front of the skyline. It's meant to be replaced by a small Core ML model. |
| **Alignment** | Searches ±20° of heading plus small pitch and roll corrections, then refines with robust least squares. Each skyline point counts according to how far away that part of the skyline is: a 15 m GPS error moves a ridge 500 m away by 1.7°, but a ridge 20 km away by only 0.04°. |
| **Gating** | A frame's correction is only used if most of its skyline matches, enough of it is far away, and no other heading fits nearly as well. Otherwise the frame is skipped. |
| **Desk harness** | `peakbench` renders horizons, makes synthetic photos with a known camera, aligns a photo case (your own iPhone photos included) and runs Monte Carlo benchmarks. |

### Results so far

Synthetic photos of the real terrain within 3 km of Gornergrat above Zermatt, using the Copernicus DEM. Each photo is taken from the true position. The matcher only gets the GPS position (up to 15 m off), a compass heading with ~8° of error, and pitch and roll as ARKit gives them (±0.4°). About half the frames have clouds and some have trees in front. Photos are aimed where the skyline is at least 5 km away, as when someone points the phone at the peaks:

| Heading error | median | 90th percentile | worst |
| --- | --- | --- | --- |
| Compass (before) | 7.20° | 12.82° | 13.62° |
| Skyline matched (after) | 0.035° | 0.081° | 0.115° |

29 of 30 frames were accepted and none was accepted with an error over 0.5°. Without pitch and roll from the phone (as with a photo's EXIF), 30 of 30 were accepted with a median error of 0.027°. Aiming in random directions, often at a slope a few hundred meters away, only 18 of 30 were accepted, all within 0.1°: nearby ridges can't pin the heading down under GPS error, and the gates turn those frames away. CI runs these benchmarks on every push and posts the tables in the job summary.

These photos are synthetic, so they test the geometry and the matching but not how well detection copes with real cameras, real haze and real DEM errors. Real photos are the next test (see below).

### DEM accuracy at sharp summits

The Copernicus 30 m DEM is right for broad mountains but **cuts off sharp summits**. Within 300 m of each summit, the DEM's highest point:

| Summit | Real height | Copernicus | Short by |
| --- | --- | --- | --- |
| Matterhorn | 4,478 m | 4,330 m | 148 m |
| Dom | 4,545 m | 4,472 m | 73 m |
| Weisshorn | 4,506 m | 4,430 m | 76 m |
| Dufourspitze | 4,634 m | 4,536 m | 98 m |
| Mont Blanc (a broad snow dome) | 4,808 m | 4,811 m | — |

From Gornergrat, 10 km away, the Matterhorn's tip should appear about 0.85° higher than the DEM puts it. Robust matching tolerates this, since it's a few columns of the skyline, but it shows up in labels and outlines. Since 0.4 the app raises the terrain around each named summit to a cone (about 45°) reaching the peak's elevation from OpenStreetMap, where the DEM falls 8–300 m short, so skylines and ridgelines get their tips back. National lidar DEMs (swissALTI3D at 2 m in Switzerland, USGS 3DEP in the US) would do better still.

## Trying it

You need Swift 5.9 or later (Xcode 16 on a Mac, or Swift for Linux), and Python 3 to download terrain.

```
pip install -r Tools/requirements.txt
python3 Tools/fetch_dem.py --lat 45.9837 --lon 7.7856 --radius-km 100 --out DEM

cd PeakCore
swift build -c release
.build/release/peakbench horizon --dem ../DEM --lat 45.9837 --lon 7.7856 --image panorama.png
.build/release/peakbench synth --dem ../DEM --lat 45.9837 --lon 7.7856 --heading 262 --compass-error 8 --out matterhorn
.build/release/peakbench align matterhorn.json --dem ../DEM --debug aligned.png
.build/release/peakbench bench --dem ../DEM --lat 45.9837 --lon 7.7856 --runs 30
```

`fetch_dem.py` downloads Copernicus GLO-30 tiles from the public AWS bucket (about 40 MB per 1° tile; 8 tiles for 100 km in the Alps) and converts them to `.pkdem` files. Use a release build of `peakbench`: debug builds are 10–35× slower. On Linux, images are read and written as `.ppm`.

![Depth panorama from Gornergrat, 180° to 360°: nearer terrain lighter, ridges in white. The Matterhorn is the pyramid in the middle.](docs/gornergrat-panorama.png)

### Testing with your own photos

iPhone photos record where they were taken and which way the camera faced (the compass heading), and the lens data gives the field of view. On a Mac:

1. Take photos of mountains with a clear skyline. Leave Location on for the Camera.
2. Download DEM tiles for the area (above).
3. Make a case file from each photo, then align it:
   ```
   .build/release/peakbench case IMG_1234.jpg
   .build/release/peakbench align IMG_1234.json --dem ../DEM --debug IMG_1234-aligned.png
   ```
4. To measure the error, `align` needs the true heading. Add one or two summits you can see to the case file as `anchors`, with the pixel where each summit is in the photo:
   ```json
   "anchors": [
     { "name": "Matterhorn", "latitude": 45.97639, "longitude": 7.65861, "elevation": 4478, "x": 2210, "y": 1480 }
   ]
   ```
   `align` then works out the true attitude from them and reports the compass error before and after correction.

## Project layout

```
Peak.xcodeproj
Peak/                      The iPhone app (SwiftUI)
  Model/                   Motion sensors, camera and lens, location, downloads and caching, skyline
                           correction, settings
  Views/                   Camera screen and overlay (ridgelines, labels, trails), status pill, peak
                           and hike cards, peak list, settings
PeakCore/                  Swift package, no iOS dependencies (builds on macOS and Linux)
  Sources/PeakCore/
    Geodesy.swift          WGS84, east-north-up frames, conformal-sphere rays
    Terrain.swift          DEM tiles (.pkdem) with bilinear lookups across tile edges
    Horizon.swift          Horizon renderer: skyline, depth envelope, ridges, line of sight
    Camera.swift           Pinhole camera and heading/pitch/roll attitude
    SkylineDetector.swift  Sky/terrain boundary per image column
    Aligner.swift          Heading, pitch and roll from skyline vs horizon, with gates
    SkylineMatcher.swift   Detection and alignment for one frame
    Anchors.swift          True attitude of a real photo from marked summits
    Scene.swift            Ridge segments to draw, visible peaks, trails laid on the terrain
    GeoTIFF.swift          Reads Copernicus tiles, their built-in lower resolutions and single
                           blocks (with Inflate.swift)
    Peaks.swift            Peaks from OpenStreetMap's Overpass API
    Trails.swift           Hiking routes and paths: parsing, joining ways, elevation profiles
    PeakFacts.swift        Facts from Wikidata and Wikipedia
    UprightFrame.swift     Turns sideways camera frames so the sky is up
    SyntheticPhoto.swift   Fake photos with a known camera, for testing
    Image.swift            RGB images, PPM files, drawing
  Sources/peakbench/       The desk harness
  Tests/PeakCoreTests/     Unit tests on procedural terrain with known geometry
Tools/fetch_dem.py         Downloads Copernicus tiles and writes .pkdem files
docs/                      Images for this README
```

A `.pkdem` file is a 64-byte header (magic `PKDM`, version, south and west edge in whole degrees, rows, columns, then the first pixel's latitude and longitude and the pixel spacing as doubles) followed by heights in meters as little-endian Int16, rows from north to south.

## Builds

GitHub Actions runs on every push:

- **PeakCore tests** on macOS and on Linux.
- **Build app**: archives the app for iPhone and uploads the unsigned `Peak.ipa` as an artifact (not zipped).
- **Skyline matching benchmark** on macOS: downloads the DEM (cached between runs), runs the three benchmarks above, and posts the tables in the job summary. It also checks live data: decoding a Copernicus tile block by block against the whole image, the hikes near the Matterhorn from Overpass (with their climb and how much of each is in sight from Gornergrat), and the Matterhorn's Wikidata and Wikipedia facts. The panorama, the Matterhorn example, the benchmark frames and the live data are saved as a `skyline-matching` artifact.

**Release** runs when a `v*` tag is pushed (or by hand with a tag name): it builds `Peak_<version>.ipa` and publishes it on the Releases page.

## Next

- Run it on real photos with marked summits, and tune detection on them.
- Match the detected boundary against the rendered ridges too, not just the skyline. In haze, the far skyline can fade into the sky while a nearer ridge stays sharp.
- A small Core ML sky segmentation model in place of the heuristic.
- Try the app on a phone in the mountains, and tune matching on real camera frames.
- Prebuilt offline region packs, including the hikes for every peak.
- Lidar terrain where it's free: swissALTI3D, and USGS 3DEP (10 m) in the US.
- Your live position on a trail drawn in the view.

## Data and attribution

Terrain: produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018, provided under COPERNICUS by the European Union and ESA; all rights reserved. Peaks and trails: © OpenStreetMap contributors, available under the Open Database License (ODbL). The app shows both in small print under the status pill. Facts: Wikidata (CC0) and Wikipedia (CC BY-SA), credited on each peak's card and in Settings.

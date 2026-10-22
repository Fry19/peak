import Foundation
import PeakCore

let usage = """
peakbench: desk test harness for skyline matching.

  peakbench horizon --dem DIR --lat L --lon L [--altitude M] [--peaks OVERPASS.json] [--csv FILE] [--image FILE]
      Render the horizon from a point and print a summary. --image writes a depth panorama.
      --peaks raises blunted summits to those peaks' elevations first, as the app does.

  peakbench synth --dem DIR --lat L --lon L --heading H [--pitch P] [--roll R] [--fov F]
                  [--width W] [--height H] [--compass-error E] [--clouds C] [--trees T]
                  [--seed S] [--haze-km K] [--snow-line M] --out NAME
      Render a synthetic photo (NAME.ppm, or NAME.png on a Mac) and its case file NAME.json.

  peakbench align CASE.json [--dem DIR] [--debug FILE] [--curve] [--points FILE.csv] [--working-width W]
      Find the skyline in a photo, align it to the terrain and report the heading error
      before and after correction.

  peakbench bench --dem DIR --lat L --lon L [--runs N] [--spread-km K] [--gps-error M]
                  [--mode arkit|photo] [--aim far|any] [--seed S] [--markdown FILE] [--save DIR]
                  [--compass-sigma D] [--compass-max D] [--heading-range D]
                  [--harder] [--world same|perturbed] [--dem-smooth PX] [--dem-noise M] [--dem-shift M]
                  [--match full|app] [--peaks OVERPASS.json] [--camera pinhole|real]
                  [--lens-k1 K] [--rolling-shutter D] [--scene alps|smokies]
      Monte Carlo test on synthetic photos of the real terrain around a point. By default
      the camera aims where the skyline is at least 5 km away, as when pointing at peaks.
      Compass errors are Gaussian (default σ 8°, at most 18°); --heading-range overrides
      the matcher's heading search (± degrees).
      Harder conditions (--harder turns on all three): --world perturbed renders the photo
      from blurred, noisy, shifted tiles (default σ 0.8 px, ±5 m, 15 m); --match app matches
      against the app's 30/60/120 m terrain, with summits raised to --peaks as the app does;
      --camera real adds lens distortion (|k1| up to 0.005) and rolling shutter (up to 0.3°).
      --scene smokies renders forest to the top and thick haze.

  peakbench pan --dem DIR --lat L --lon L [--runs N] [--frames F] [--pan D] [--interval S] [--fov F]
                [--occlusion walls|roofs|none] [--gap D] [--roof D] [--wander D] [--drift D] [--seed S] [--markdown FILE]
                [and bench's --harder, --world, --match app, --peaks, --camera, --scene options]
      Panning sequences between buildings: F frames (default 5) over D degrees (default 40),
      S seconds apart (1.5), the skyline seen only in gaps of about --gap degrees (8 between
      walls, 5 between roofs) between buildings about --roof degrees wide (14). Walls reach
      far above the skyline, as a window's frame; roofs stand just over it, sky above them. The compass wanders σ --wander degrees (3) from
      frame to frame, as indoors, and the gyroscope drifts σ --drift °/s (0.02). Each frame is
      matched alone, then with the frames before it (SkylineStrip); reports both.

  peakbench realbench DIR [--dem DIR] [--match full|app] [--peaks OVERPASS.json] [--prior sensors|saved]
                  [--max-fit D] [--working-width W] [--markdown FILE] [--debug DIR] [--label TEXT]
      Run every case in a directory: photos (peakbench case) and frames saved by the app.
      The truth comes from `truth` or checked anchors (AnchorSolver). Reports heading error
      before and after matching, acceptance and why frames were turned away. Frames from
      the app are matched from the raw sensors (a cold start) unless --prior saved. Cases
      whose anchors fit worse than --max-fit (default 0.25° RMS) are left out.

  peakbench suggest-anchors CASE.json --peaks OVERPASS.json [--dem DIR] [--debug FILE] [--max N] [--force]
  peakbench suggest-anchors CASE.json --confirm 1,2,… | --drop 3,…
      Align the photo and propose the pixel of each visible named peak as an unconfirmed
      anchor in the case. --debug draws numbered crosshairs with close-ups to check them
      by; --confirm marks the numbered anchors as checked, --drop removes them.

  peakbench detect IMAGE [--width W] [--debug FILE]
      Run only the skyline detector and draw what it found.

  peakbench geotiff FILE.tif [--level N] [--ranged] [--blocks] [--out FILE.pkdem] [--compare FILE.pkdem]
      Decode a Copernicus GeoTIFF with PeakCore's own reader (what the app does). --blocks
      also decodes each block of the level on its own and checks it against the whole.

  peakbench trails OVERPASS.json --lat L --lon L [--dem DIR] [--ground DIR] [--from-lat L --from-lon L]
  peakbench trails --query --lat L --lon L
      Read hiking routes and paths from an Overpass response (Overpass.trailsQuery) near a
      peak at --lat/--lon. With --dem, climb from the terrain; with --from-*, how much of
      each trail is in sight from there, as the app draws it on the mountain. --ground adds
      bare ground (Tools/fetch_ground.py) for the climb as the app does, and compares it with
      --dem alone.

  peakbench relief --dem DIR --lat L --lon L [--size-km K] [--cell M] [--image FILE]
      The terrain seen from above around a point, as the app draws it under a trail:
      hillshade and ridge crests. Prints how long each step takes and what it found.

  peakbench viewshed --dem DIR --lat L --lon L [--ele M] [--radius-km K] [--cell M] [--image FILE]
      Everywhere a person on the ground can see a summit from. --ele is the summit's height
      (default: the highest terrain within 100 m). Prints the area, how long it took and,
      near the Matterhorn, whether known places see it. --image draws it over a hillshade:
      visible ground tinted, unknown ground hatched.

  peakbench sun --dem DIR --lat L --lon L [--date YYYY-MM-DD] [--tz ZONE]
                [--peak-lat L --peak-lon L --peak-ele M]
      When the sun comes into and goes out of sight over the real terrain, against the
      flat-horizon almanac, and with --peak-*, when it reaches and leaves that summit.

  peakbench base --base FILE.pkbase --dem DIR --lat L --lon L [--max-km K] [--markdown FILE]
      How far the worldwide base layer's skyline is from the full DEM's, by distance.

  peakbench facts ENTITY.json --id Q [--labels LABELS.json] [--summary SUMMARY.json]
      Read a peak's facts from Wikidata and Wikipedia responses.

  peakbench case PHOTO.jpg [--out CASE.json]          (macOS only)
      Make a case file from an iPhone photo's location, compass heading and lens data.
"""

/// A photo plus what the phone knew when it was taken.
struct PhotoCase: Codable {
    var image: String
    var latitude: Double
    var longitude: Double
    /// Eye height above sea level. Leave out to use the DEM height plus 1.6 m.
    var altitude: Double?
    /// Compass heading (degrees from true north) of the camera's optical axis.
    var heading: Double
    /// Pitch and roll if known (ARKit or the motion sensors). Leave out to search wider.
    var pitch: Double?
    var roll: Double?
    var horizontalFOV: Double
    /// The real attitude, when known.
    var truth: Attitude?
    /// Summits marked in the photo; used to work out `truth` when it is missing.
    var anchors: [Anchor]?
    /// DEM directory, relative to this file.
    var dem: String?
    var note: String?
    /// What the app saved with a frame of its own (absent for photos).
    var app: AppFrameInfo? = nil
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]

    init(_ args: ArraySlice<String>) {
        let list = Array(args)
        var i = 0
        while i < list.count {
            let a = list[i]
            i += 1
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if let eq = key.firstIndex(of: "=") {
                    options[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else if i < list.count, !list[i].hasPrefix("--") {
                    options[key] = list[i]
                    i += 1
                } else {
                    options[key] = ""   // a switch, like --ranged
                }
            } else {
                positional.append(a)
            }
        }
    }

    func string(_ key: String) -> String? { options[key] }
    func double(_ key: String) -> Double? { options[key].flatMap(Double.init) }
    func int(_ key: String) -> Int? { options[key].flatMap(Int.init) }

    func required(_ key: String) throws -> Double {
        guard let v = double(key) else { throw HarnessError("missing --\(key)") }
        return v
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func loadTerrain(_ path: String?) throws -> Terrain {
    let dir = path ?? ProcessInfo.processInfo.environment["PEAK_DEM"] ?? "DEM"
    let start = Date()
    let terrain = try Terrain(directory: URL(fileURLWithPath: dir))
    log(String(format: "Loaded %d DEM tiles from %@ in %.1f s", terrain.tiles.count, dir, Date().timeIntervalSince(start)))
    return terrain
}

/// Bare-ground patches: every .pkdem file in a directory (Tools/fetch_ground.py).
func loadGround(_ dir: String) throws -> [ElevationTile] {
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "pkdem" }
    guard !files.isEmpty else { throw TerrainError.empty(dir) }
    let patches = try files.map { try ElevationTile(contentsOf: $0) }
    log("Loaded \(patches.count) bare-ground patches from \(dir)")
    return patches
}

func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = Date()
    let v = try body()
    log(String(format: "%@: %.2f s", label, Date().timeIntervalSince(start)))
    return v
}

func f(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v) }
func signed(_ v: Double, _ digits: Int = 2) -> String { String(format: "%+.\(digits)f", v) }

// MARK: - horizon

func horizonCommand(_ args: Arguments) throws {
    let terrain = try loadTerrain(args.string("dem"))
    if let path = args.string("peaks") {
        let peaks = try Overpass.peaks(fromJSON: Data(contentsOf: URL(fileURLWithPath: path)))
        log("Raised \(terrain.raiseSummits(terrain.fillElevations(peaks))) of \(peaks.count) summits")
    }
    let renderer = HorizonRenderer(terrain: terrain)
    let lat = try args.required("lat"), lon = try args.required("lon")
    let observer = args.double("altitude").map { GeoPoint(latitude: lat, longitude: lon, height: $0) }
        ?? renderer.observer(latitude: lat, longitude: lon)
    var settings = HorizonSettings()
    if let km = args.double("max-km") { settings.maxDistance = km * 1000 }
    if let step = args.double("step") { settings.azimuthStep = step }
    let profile = timed("Horizon (\(Int(360 / settings.azimuthStep)) rays)") { renderer.render(from: observer, settings: settings) }

    let top = profile.elevations.indices.max { profile.elevations[$0] < profile.elevations[$1] }!
    print("Observer: \(f(lat, 5)), \(f(lon, 5)) at \(f(observer.height, 0)) m")
    print("Highest point on the skyline: azimuth \(f(profile.azimuth(ofRay: top), 1))°, elevation " +
          "\(f(Double(profile.elevations[top])))°, \(f(Double(profile.distances[top]) / 1000, 1)) km away")
    print("Farthest skyline: \(f(Double(profile.distances.max()!) / 1000, 1)) km")

    if let path = args.string("csv") {
        var csv = "azimuth,elevation,distance\n"
        for i in 0..<profile.count {
            csv += "\(f(profile.azimuth(ofRay: i), 2)),\(f(Double(profile.elevations[i]), 4)),\(Int(profile.distances[i]))\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
        print("Wrote \(path)")
    }
    if let path = args.string("image") {
        try saveImage(depthPanorama(profile), to: path)
        print("Wrote \(path)")
    }
}

/// Equirectangular panorama, 10 px per degree: terrain shaded by distance, ridges in white.
func depthPanorama(_ profile: HorizonProfile) -> RGBImage {
    let pxPerDegree = 10.0
    let top = Double(profile.elevations.max()!) + 2
    let bottom = min(-3, Double(profile.elevations.min()!) - 1)
    let w = Int(360 * pxPerDegree), h = Int(((top - bottom) * pxPerDegree).rounded(.up))
    var image = RGBImage(width: w, height: h, fill: (12, 16, 28))
    for x in 0..<w {
        let az = (Double(x) + 0.5) / pxPerDegree
        for y in 0..<h {
            let el = top - (Double(y) + 0.5) / pxPerDegree
            guard let d = profile.distance(atAzimuth: az, elevation: el) else { continue }
            // Near terrain bright, far terrain fading, like haze.
            let t = min(1, log(1 + d / 1000) / log(151))
            let v = UInt8(200 - 160 * t)
            image.set(x, y, (v, v, UInt8(min(255, Double(v) + 20))))
        }
        let i = Int((az / profile.azimuthStep).rounded()) % profile.count
        for ridge in profile.ridges(ofRay: i) {
            image.set(x, Int((top - Double(ridge.elevation)) * pxPerDegree), (255, 255, 255))
        }
    }
    return image
}

// MARK: - synth

func synthCommand(_ args: Arguments) throws {
    guard let out = args.string("out") else { throw HarnessError("missing --out") }
    let terrain = try loadTerrain(args.string("dem"))
    let renderer = HorizonRenderer(terrain: terrain)
    let lat = try args.required("lat"), lon = try args.required("lon")
    let observer = renderer.observer(latitude: lat, longitude: lon)
    var settings = HorizonSettings()
    settings.azimuthStep = 0.05
    let profile = timed("Horizon") { renderer.render(from: observer, settings: settings) }

    let truth = Attitude(heading: try args.required("heading"), pitch: args.double("pitch") ?? 2, roll: args.double("roll") ?? 0)
    let fov = args.double("fov") ?? 65
    let k = CameraIntrinsics(width: args.int("width") ?? 1280, height: args.int("height") ?? 960, horizontalFOV: fov)
    var scene = SyntheticScene()
    scene.seed = UInt64(args.int("seed") ?? 1)
    scene.clouds = args.double("clouds") ?? 0
    scene.trees = args.double("trees") ?? 0
    if let haze = args.double("haze-km") { scene.hazeDistance = haze * 1000 }
    if let snow = args.double("snow-line") { scene.snowLine = snow }
    let image = timed("Photo") { SyntheticPhoto.render(profile, camera: Camera(intrinsics: k, attitude: truth), scene: scene) }

    let imagePath = out + "." + defaultImageExtension
    try saveImage(image, to: imagePath)
    let photo = PhotoCase(image: URL(fileURLWithPath: imagePath).lastPathComponent, latitude: lat, longitude: lon,
                          altitude: nil, heading: normalizedAzimuth(truth.heading + (args.double("compass-error") ?? 8)),
                          pitch: truth.pitch, roll: truth.roll, horizontalFOV: fov, truth: truth, anchors: nil,
                          dem: nil, note: "synthetic")
    try writeCase(photo, to: out + ".json")
    print("Wrote \(imagePath) and \(out).json")
}

func writeCase(_ photo: PhotoCase, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(photo).write(to: URL(fileURLWithPath: path))
}

// MARK: - align

func alignCommand(_ args: Arguments) throws {
    guard let casePath = args.positional.first else { throw HarnessError("which case file?") }
    let c = try LoadedCase(URL(fileURLWithPath: casePath), demOverride: args.string("dem")) { path, _, _ in try loadTerrain(path) }
    var photo = c.photo
    let image = c.image, intrinsics = c.intrinsics, horizon = c.horizon

    if photo.truth == nil, let t = c.truth() {
        photo.truth = t.attitude
        print("Truth from \(t.source): heading \(f(t.attitude.heading))°, pitch \(f(t.attitude.pitch))°, " +
              "roll \(f(t.attitude.roll))° (fit \(f(t.fit ?? 0, 3))° RMS)")
    }
    let unconfirmed = (photo.anchors ?? []).filter { !$0.isChecked }.count
    if unconfirmed > 0 { print("\(unconfirmed) proposed anchor(s) not yet confirmed; left out of the truth") }

    var matcher = SkylineMatcher()
    if photo.pitch == nil || photo.roll == nil { matcher.settings = .photo }
    // The app matches at 640 pixels wide.
    if let width = args.int("working-width") { matcher.workingWidth = width }
    let prior = Attitude(heading: photo.heading, pitch: photo.pitch ?? 0, roll: photo.roll ?? 0)
    let match = matcher.match(image, intrinsics: intrinsics, prior: prior, horizon: horizon)
    report(match, truth: photo.truth)
    if let path = args.string("points") {
        // Each detected skyline point where the sensors put it, beside the rendered horizon.
        let projector = match.camera.projector
        var csv = "x,y,azimuth,elevation,horizon,distance,kind\n"
        let sky = match.skyline
        for x in 0..<sky.width {
            for (y, kind) in [(sky.rows[x], "boundary"), (sky.upperRows[x], "upper")] where !y.isNaN {
                let d = projector.look(x: Double(x) + 0.5, y: Double(y))
                let ray = Int((normalizedAzimuth(d.azimuth) / horizon.azimuthStep).rounded()) % horizon.count
                csv += String(format: "%.1f,%.1f,%.3f,%.3f,%.3f,%.0f,", Double(x) + 0.5, Double(y), d.azimuth, d.elevation,
                              horizon.elevation(atAzimuth: d.azimuth), Double(horizon.distances[ray])) + kind + "\n"
            }
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
        print("Wrote \(path)")
    }
    if args.string("curve") != nil {
        // The coarse search's cost for each heading correction, at 1° steps, lowest marked.
        let curve = match.alignment.headingCurve
        let best = curve.min { $0.cost < $1.cost }?.correction ?? 0
        for c in curve where Int((c.correction * 10).rounded()) % 10 == 0 {
            print(String(format: "%+6.1f°  %.3f %@", c.correction, c.cost, String(repeating: "#", count: Int(c.cost * 40)))
                  + (abs(c.correction - best) < 0.5 ? "  <" : ""))
        }
    }

    if let path = args.string("debug") {
        try saveImage(debugOverlay(match, horizon: horizon), to: path)
        print("Wrote \(path)")
    }
}

func report(_ m: SkylineMatcher.Match, truth: Attitude?) {
    let a = m.alignment
    print("Skyline found in \(Int(m.skyline.validFraction * 100))% of columns; \(a.pointCount) points used")
    print("Heading \(f(m.camera.attitude.heading))° → \(f(a.attitude.heading))° (correction \(signed(a.headingCorrection))°)")
    print("Pitch correction \(signed(a.pitchCorrection))°, roll correction \(signed(a.rollCorrection))°")
    print("Fit: \(f(a.rms, 3))° RMS; \(Int(a.inlierFraction * 100))% of points match, \(Int(a.farFraction * 100))% " +
          "match and are far away; ambiguity \(f(a.ambiguity)), within 1.5° \(f(a.nearAmbiguity))")
    for (label, rival) in [("Runner-up", a.runnerUp), ("Runner-up within 1.5°", a.nearRunnerUp)] {
        guard let rival else { continue }
        print("\(label): heading \(signed(rival.headingCorrection))°, pitch \(signed(rival.pitchCorrection))°, " +
              "roll \(signed(rival.rollCorrection))° (\(f(rival.ratio)))")
    }
    print(a.accepted ? "Accepted" : "Rejected: \(a.rejectionReason ?? "")")
    if let truth {
        let before = azimuthDifference(m.camera.attitude.heading, truth.heading)
        let after = azimuthDifference(a.attitude.heading, truth.heading)
        print("Heading error: \(signed(before))° before, \(signed(after, 3))° after")
        print("Pitch error after: \(signed(a.attitude.pitch - truth.pitch, 3))°, " +
              "roll error after: \(signed(a.attitude.roll - truth.roll, 3))°")
    }
    print(String(format: "Matching took %.0f ms", m.seconds * 1000))
}

/// The working image with the horizon where the sensors put it (red), where the correction
/// puts it (green), ridges behind the skyline (cyan), the detected skyline (yellow) and the
/// fainter edges above it (magenta).
func debugOverlay(_ m: SkylineMatcher.Match, horizon: HorizonProfile) -> RGBImage {
    var image = m.image
    let w = image.width
    func horizonLine(_ camera: Camera) -> [(Double, Double)] {
        let projector = camera.projector
        return (0..<w).map { x in
            let az = projector.look(x: Double(x) + 0.5, y: Double(image.height) / 2).azimuth
            guard let p = projector.pixel(azimuth: az, elevation: horizon.elevation(atAzimuth: az)) else { return (.nan, .nan) }
            return (p.x, p.y)
        }
    }
    let corrected = Camera(intrinsics: m.alignment.intrinsics, attitude: m.alignment.attitude)
    image.drawPolyline(horizonLine(m.camera), color: (255, 64, 64), thickness: 2, maxGap: 40)
    let projector = corrected.projector
    for x in stride(from: 0, to: w, by: 2) {
        let az = projector.look(x: Double(x) + 0.5, y: Double(image.height) / 2).azimuth
        let i = Int((az / horizon.azimuthStep).rounded()) % horizon.count
        for ridge in horizon.ridges(ofRay: i).dropLast() {
            if let p = projector.pixel(azimuth: horizon.azimuth(ofRay: i), elevation: Double(ridge.elevation)) {
                image.drawDot(p.x, p.y, radius: 1, color: (0, 220, 255))
            }
        }
    }
    image.drawPolyline(horizonLine(corrected), color: (64, 255, 96), thickness: 2, maxGap: 40)
    let detected = (0..<m.skyline.width).map { x -> (Double, Double) in
        let r = m.skyline.rows[x]
        return r.isNaN ? (.nan, .nan) : (Double(x) + 0.5, Double(r))
    }
    image.drawPolyline(detected, color: (255, 220, 0), thickness: 1, maxGap: 6)
    let upper = (0..<m.skyline.width).map { x -> (Double, Double) in
        let r = m.skyline.upperRows[x]
        return r.isNaN ? (.nan, .nan) : (Double(x) + 0.5, Double(r))
    }
    image.drawPolyline(upper, color: (255, 64, 255), thickness: 1, maxGap: 6)
    return image
}

// MARK: - detect

func detectCommand(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw HarnessError("which image?") }
    let full = try loadImage(path)
    let width = args.int("width") ?? 960
    let image = full.width > width ? full.resized(toWidth: width) : full
    let skyline = timed("Detection") { SkylineDetector().detect(in: image) }
    let strengths = skyline.strength.sorted()
    print("Skyline found in \(Int(skyline.validFraction * 100))% of \(skyline.width) columns; " +
          "median edge strength \(f(Double(strengths[strengths.count / 2])))")
    if let out = args.string("debug") {
        var overlay = image
        let points = (0..<skyline.width).map { x -> (Double, Double) in
            let r = skyline.rows[x]
            return r.isNaN ? (.nan, .nan) : (Double(x) + 0.5, Double(r))
        }
        overlay.drawPolyline(points, color: (255, 220, 0), thickness: 2, maxGap: 6)
        try saveImage(overlay, to: out)
        print("Wrote \(out)")
    }
}

// MARK: - geotiff

func geotiffCommand(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw HarnessError("which GeoTIFF?") }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let level = args.int("level") ?? 0
    let tile: ElevationTile
    if args.options["ranged"] != nil {
        // As the app does it: the directories from the first 16 KB, then one level's bytes.
        let bytes = [UInt8](data)
        let layout = try GeoTIFF.layout(Array(bytes.prefix(16_384)))
        let range = layout.images[level].byteRange
        print("Levels: " + layout.images.map { "\($0.width)×\($0.height)" }.joined(separator: ", ") +
              "; level \(level) is bytes \(range.lowerBound)..<\(range.upperBound) (\(range.count / 1000) KB)")
        tile = try timed("Decode") { try GeoTIFF.decode(layout, level: level, bytes: Array(bytes[range]), base: range.lowerBound) }
    } else {
        tile = try timed("Decode") { try GeoTIFF.elevationTile(data, level: level) }
    }
    let heights = tile.heightValues
    print("Tile \(tile.south), \(tile.west): \(tile.rows)×\(tile.cols), first pixel at \(tile.originLatitude), " +
          "\(tile.originLongitude), \(heights.min()!)–\(heights.max()!) m")
    if args.options["blocks"] != nil {
        // As the app fetches full detail near the viewer: one block at a time.
        let bytes = [UInt8](data)
        let layout = try GeoTIFF.layout(Array(bytes.prefix(16_384)))
        let image = layout.images[level]
        var mismatched = 0
        let parts = try timed("Decode \(image.blockCount) blocks one by one") {
            try (0..<image.blockCount).map { block in
                try GeoTIFF.decode(layout, level: level, blocks: [block]) { _ in bytes[image.byteRange(ofBlock: block)] }
            }
        }
        for part in parts {
            let r0 = Int(((tile.originLatitude - part.originLatitude) / tile.stepLatitude).rounded())
            let c0 = Int(((part.originLongitude - tile.originLongitude) / tile.stepLongitude).rounded())
            let values = part.heightValues
            for r in 0..<part.rows {
                for c in 0..<part.cols where values[r * part.cols + c] != heights[(r0 + r) * tile.cols + c0 + c] { mismatched += 1 }
            }
        }
        let merged = ElevationTile(merging: parts)
        print("Blocks: \(parts.count), \(mismatched) heights differ from the whole image; merged " +
              "\(merged.map { "\($0.rows)×\($0.cols)" } ?? "failed")" + (merged?.heightValues == heights ? ", identical" : ", DIFFERENT"))
        if mismatched > 0 || merged?.heightValues != heights { throw HarnessError("block decoding differs") }
    }
    if let other = args.string("compare") {
        let reference = try ElevationTile(contentsOf: URL(fileURLWithPath: other)).heightValues
        guard reference.count == heights.count else { throw HarnessError("sizes differ") }
        let diffs = zip(heights, reference).map { abs(Int($0) - Int($1)) }
        print("Compared with \(other): \(diffs.filter { $0 > 0 }.count) of \(diffs.count) heights differ, " +
              "by at most \(diffs.max()!) m")
    }
    if let out = args.string("out") {
        try tile.write(to: URL(fileURLWithPath: out))
        print("Wrote \(out)")
    }
}

// MARK: - trails and facts

func trailsCommand(_ args: Arguments) throws {
    if args.options["query"] != nil {
        // The app's own query, to fetch a response with: hikes for one peak, or with
        // --area METERS, everything saved for an offline area of that radius.
        let lat = try args.required("lat"), lon = try args.required("lon")
        if let r = args.double("area") {
            let dlat = r / 111_000, dlon = r / (111_000 * max(cos(lat * .pi / 180), 0.05))
            print(Overpass.trailsQuery(south: lat - dlat, west: lon - dlon, north: lat + dlat, east: lon + dlon, timeout: 180))
        } else {
            print(Overpass.trailsQuery(latitude: lat, longitude: lon, radius: 8_000))
        }
        return
    }
    guard let path = args.positional.first else { throw HarnessError("which Overpass response?") }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let peak = LatLon(try args.required("lat"), try args.required("lon"))
    let trails = try Overpass.trails(fromJSON: data)
        .map { ($0, $0.distance(to: peak)) }
        .sorted { ($0.1 < 250 ? 0 : 1, $0.1) < ($1.1 < 250 ? 0 : 1, $1.1) }
    var terrain = try args.string("dem").map { try loadTerrain($0) }
    // With bare ground (Tools/fetch_ground.py), the climb follows it, as in the app, and is
    // compared with the Copernicus terrain alone.
    let surface = terrain
    if let ground = try args.string("ground").map(loadGround), let t = terrain {
        terrain = Terrain(tiles: t.tiles, detail: t.detail, ground: ground)
    }
    var drape: ((Trail) -> [[DrapedPoint]])?
    if let terrain, let lat = args.double("from-lat"), let lon = args.double("from-lon") {
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: lat, longitude: lon)
        var settings = HorizonSettings()
        settings.maxDistance = 80_000
        let horizon = timed("Horizon") { renderer.render(from: observer, settings: settings) }
        drape = { renderer.drape($0.lines, from: observer, horizon: horizon) }
    }
    print("\(trails.count) trails (\(data.count / 1000) KB of JSON)")
    for (t, d) in trails {
        var line = "\(t.kind == .route ? "route" : "path ") \(t.name) [\(t.id)]: \(t.lines.count) line(s), " +
            "\(f(t.mappedLength / 1000, 1)) km mapped"
        if let tagged = t.taggedLength { line += ", \(f(tagged / 1000, 1)) km tagged" }
        if t.isPartial { line += ", partial" }
        line += ", \(t.difficulty?.grade ?? "no grade"), \(d < 250 ? "reaches the summit" : "\(f(d / 1000, 1)) km from it")"
        if let terrain, let p = t.profile(on: terrain) {
            line += ", climb \(f(p.gain, 0)) m, descent \(f(p.loss, 0)) m, \(f(p.lowest, 0))–\(f(p.highest, 0)) m"
            if let surface, surface !== terrain, let q = t.profile(on: surface) {
                line += " (Copernicus alone: climb \(f(q.gain, 0)) m, descent \(f(q.loss, 0)) m, \(f(q.lowest, 0))–\(f(q.highest, 0)) m)"
            }
        }
        if let drape {
            let runs = drape(t)
            line += ", in sight: \(runs.count) stretch(es), \(runs.reduce(0) { $0 + $1.count }) points"
        }
        print(line)
    }
}

func factsCommand(_ args: Arguments) throws {
    guard let path = args.positional.first, let id = args.string("id") else { throw HarnessError("facts ENTITY.json --id Q…") }
    var facts = try Wikidata.facts(fromJSON: try Data(contentsOf: URL(fileURLWithPath: path)), id: id)
    if let labelsPath = args.string("labels") {
        let labels = try Wikidata.labels(fromJSON: try Data(contentsOf: URL(fileURLWithPath: labelsPath)))
        facts.range = facts.rangeID.flatMap { labels[$0] }
        facts.parent = facts.parentID.flatMap { labels[$0] }
        facts.countries = facts.countryIDs.compactMap { labels[$0] }
    }
    if let summaryPath = args.string("summary") {
        try Wikipedia.addSummary(fromJSON: try Data(contentsOf: URL(fileURLWithPath: summaryPath)), to: &facts)
    }
    print("description: \(facts.description ?? "-")")
    print("prominence: \(facts.prominence.map { f($0, 0) + " m" } ?? "-"), isolation: \(facts.isolation.map { f($0 / 1000, 1) + " km" } ?? "-")")
    print("range: \(facts.range ?? facts.rangeID ?? "-"), parent: \(facts.parent ?? facts.parentID ?? "-"), " +
          "countries: \(facts.countries.isEmpty ? facts.countryIDs.joined(separator: ", ") : facts.countries.joined(separator: ", "))")
    print("first ascent: \(facts.firstAscentYear.map(String.init) ?? "-"), image: \(facts.image ?? "-")")
    print("articles: \(facts.articles.count) languages; English: \(facts.articles["en"] ?? "-")")
    print("linked ids: \(facts.linkedIDs.joined(separator: "|"))")
    if let summary = facts.summary { print("summary: \(summary.prefix(160))…") }
    print("picture: \(facts.pictureURL?.absoluteString ?? "-")")
}

// MARK: - scene

/// Times what the app does to build its view from a point: the horizon, the ridgelines and
/// line of sight to every peak (made-up peaks on the real terrain when none are given).
func sceneCommand(_ args: Arguments) throws {
    let terrain = try loadTerrain(args.string("dem"))
    let renderer = HorizonRenderer(terrain: terrain)
    let lat = try args.required("lat"), lon = try args.required("lon")
    let count = args.int("peaks") ?? 3000
    var rng = SplitMix64(seed: 9)
    var peaks: [Peak] = []
    for i in 0..<count {
        let p = destination(from: GeoPoint(latitude: lat, longitude: lon), azimuth: 360 * rng.uniform(),
                            distance: 80_000 * rng.uniform().squareRoot())
        let h = terrain.height(latitude: p.latitude, longitude: p.longitude)
        if h.isFinite { peaks.append(Peak(id: Int64(i), name: "P\(i)", latitude: p.latitude, longitude: p.longitude, elevation: h + 5)) }
    }
    var settings = HorizonSettings()
    settings.maxDistance = args.double("radius-km").map { $0 * 1000 } ?? 80_000
    let observer = renderer.observer(latitude: lat, longitude: lon)
    let horizon = timed("Horizon") { renderer.render(from: observer, settings: settings) }
    let segments = timed("Ridge segments") { horizon.ridgeSegments() }
    let visible = timed("Line of sight for \(peaks.count) peaks") {
        renderer.visiblePeaks(peaks, from: observer, maxDistance: settings.maxDistance, settings: settings)
    }
    print("\(segments.count) segments, \(visible.count) of \(peaks.count) peaks visible")
}

// MARK: - bench

struct BenchRun {
    var before: Double
    var after: Double
    var accepted: Bool
    var seconds: Double
    /// Pitch and roll errors before (the sensors) and after matching, degrees.
    var pitch: (before: Double, after: Double) = (0, 0)
    var roll: (before: Double, after: Double) = (0, 0)
    var rejection: String?
}

/// What makes a bench harder than the default: the photo's world differs from the terrain
/// matched against, the camera isn't a perfect pinhole, the scenery is another kind.
struct BenchConditions {
    /// Render the photo from perturbed tiles rather than those matched against.
    var perturbation: DEMPerturbation?
    /// Match against the app's mixed 30/60/120 m terrain (summits raised if peaks are given).
    var appTerrain = false
    var peaks: [Peak]?
    /// Match against the worldwide base layer only, as on first launch with nothing downloaded.
    var base: BaseLayer?
    /// Largest |k1| and |rolling shutter| (degrees); each run draws its own within them.
    var maxK1 = 0.0
    var maxRollingShutter = 0.0
    var scene = "alps"

    var isDefault: Bool { perturbation == nil && !appTerrain && base == nil && maxK1 == 0 && maxRollingShutter == 0 && scene == "alps" }

    init(_ args: Arguments) throws {
        let harder = args.options["harder"] != nil
        if harder || args.string("world") == "perturbed" {
            var p = DEMPerturbation()
            if let v = args.double("dem-smooth") { p.smoothing = v }
            if let v = args.double("dem-noise") { p.noise = v }
            if let v = args.double("dem-shift") { p.shiftEast = v * 0.8; p.shiftNorth = -v * 0.6 }
            p.seed = UInt64(args.int("seed") ?? 1) &+ 77
            perturbation = p
        }
        appTerrain = harder || args.string("match") == "app"
        if args.string("match") == "base" {
            guard let path = args.string("base") else { throw HarnessError("--match base needs --base FILE.pkbase") }
            base = try BaseLayer(contentsOf: URL(fileURLWithPath: path))
            appTerrain = false
        }
        if harder || args.string("camera") == "real" {
            maxK1 = 0.005
            maxRollingShutter = 0.3
        }
        if let v = args.double("lens-k1") { maxK1 = v }
        if let v = args.double("rolling-shutter") { maxRollingShutter = v }
        scene = args.string("scene") ?? "alps"
        guard ["alps", "smokies"].contains(scene) else { throw HarnessError("--scene is alps or smokies") }
        if let path = args.string("peaks") { peaks = try Overpass.peaks(fromJSON: Data(contentsOf: URL(fileURLWithPath: path))) }
    }

    /// Short, for the table's header.
    var label: String {
        var parts: [String] = []
        if scene != "alps" { parts.append(scene) }
        if perturbation != nil { parts.append("different DEM") }
        if appTerrain { parts.append(peaks == nil ? "app terrain" : "app terrain + summit cones") }
        if base != nil { parts.append("base layer only") }
        if maxK1 > 0 || maxRollingShutter > 0 { parts.append("lens + rolling shutter") }
        return parts.joined(separator: ", ")
    }

    /// One line on each condition, for under the table.
    var details: String {
        var lines: [String] = []
        if let p = perturbation {
            lines.append("Photo rendered from perturbed tiles: blurred (σ \(f(p.smoothing, 1)) px), height noise within ±\(f(p.noise, 0)) m " +
                         "over ~\(f(p.noiseScale, 0)) m, shifted \(f((p.shiftEast * p.shiftEast + p.shiftNorth * p.shiftNorth).squareRoot(), 0)) m.")
        }
        if appTerrain {
            lines.append("Matched against the app's terrain: 30 m within 10 km, 60 m within 35 km, 120 m beyond" +
                         (peaks.map { ", summits raised to \($0.count) OpenStreetMap peaks (matching side only)." }
                          ?? "; summits not raised (no --peaks file)."))
        }
        if base != nil {
            lines.append("Matched against the worldwide base layer only (no tiles downloaded), the eye at the GPS altitude (±10 m).")
        }
        if maxK1 > 0 || maxRollingShutter > 0 {
            lines.append("Camera: radial distortion k1 within ±\(f(maxK1, 4)), rolling shutter within ±\(f(maxRollingShutter, 2))° across the frame.")
        }
        if scene == "smokies" { lines.append("Scene: forested to the top, thick haze, no snow.") }
        return lines.joined(separator: " ")
    }

    func syntheticScene() -> SyntheticScene {
        var s = SyntheticScene()
        if scene == "smokies" {
            s.snowLine = nil
            s.treeLine = 10_000
            s.hazeDistance = 18_000
        }
        return s
    }
}

func benchCommand(_ args: Arguments) throws {
    let terrain = try loadTerrain(args.string("dem"))
    let lat = try args.required("lat"), lon = try args.required("lon")
    let conditions = try BenchConditions(args)
    // The photo is rendered from `world`, and matched against `renderer`'s terrain.
    var worldTerrain = terrain, matchTerrain = terrain
    if let p = conditions.perturbation {
        worldTerrain = timed("Perturbed world") { Terrain(tiles: terrain.tiles.map { $0.perturbed(p) }) }
    }
    if conditions.appTerrain {
        matchTerrain = timed("App terrain") { Terrain.appDetail(from: terrain.tiles, latitude: lat, longitude: lon) }
        if let peaks = conditions.peaks {
            // As the app does: fill in missing elevations, then raise blunted summits.
            let raised = matchTerrain.raiseSummits(matchTerrain.fillElevations(peaks))
            log("Raised \(raised) of \(peaks.count) summits")
        }
    }
    if let base = conditions.base {
        matchTerrain = Terrain(tiles: [], base: base, latitude: lat, longitude: lon, radius: HorizonSettings().maxDistance + 20_000)
    }
    let renderer = HorizonRenderer(terrain: matchTerrain)
    let worldRenderer = HorizonRenderer(terrain: worldTerrain)
    let runs = args.int("runs") ?? 30
    let spread = (args.double("spread-km") ?? 3) * 1000
    let gpsError = args.double("gps-error") ?? 15
    let mode = args.string("mode") ?? "arkit"
    let aim = args.string("aim") ?? "far"
    let compassSigma = args.double("compass-sigma") ?? 8, compassMax = args.double("compass-max") ?? 18
    var rng = SplitMix64(seed: UInt64(args.int("seed") ?? 1))
    // Draws for the harder conditions come from their own generator, so the runs (where,
    // which way, the compass error) are the same as without them.
    var extra = SplitMix64(seed: UInt64(args.int("seed") ?? 1) &+ 0x5EED)
    var results: [BenchRun] = []

    print("Mode: \(mode), aim: \(aim), \(runs) runs within \(f(spread / 1000, 1)) km of \(f(lat, 4)), \(f(lon, 4)); " +
          "GPS error up to \(f(gpsError, 0)) m")
    if !conditions.isDefault { print(conditions.details) }
    print(" run  heading   fov clouds trees  skyline   before     after  ok    time")
    for run in 0..<runs {
        // The real spot, and where the GPS thinks it is.
        let spot = destination(from: GeoPoint(latitude: lat, longitude: lon), azimuth: 360 * rng.uniform(),
                               distance: spread * rng.uniform().squareRoot())
        let truePosition = worldRenderer.observer(latitude: spot.latitude, longitude: spot.longitude)
        let gps = destination(from: truePosition, azimuth: 360 * rng.uniform(), distance: gpsError * rng.uniform())
        var believed = renderer.observer(latitude: gps.latitude, longitude: gps.longitude)
        // On the base layer the ground under you is kilometers of average: the app stands
        // the eye at the GPS altitude instead.
        if conditions.base != nil { believed.height = truePosition.height + 10 * extra.gaussian() }

        var heading = 360 * rng.uniform()
        // The photo comes from a finer render at the true spot than the one we match against.
        var fine = HorizonSettings()
        fine.azimuthStep = 0.05
        let world = worldRenderer.render(from: truePosition, settings: fine)
        if aim == "far" {
            let far = world.distances.indices.filter { world.distances[$0] >= 5_000 }
            if !far.isEmpty { heading = world.azimuth(ofRay: far[Int(rng.next() % UInt64(far.count))]) }
        }
        let truth = Attitude(heading: heading, pitch: -2 + 8 * rng.uniform(), roll: -4 + 8 * rng.uniform())
        let fov = 55 + 20 * rng.uniform()
        let k = CameraIntrinsics(width: 1280, height: 960, horizontalFOV: fov)
        var scene = conditions.syntheticScene()
        scene.seed = rng.next()
        scene.clouds = rng.uniform() < 0.5 ? 0.5 * rng.uniform() : 0
        scene.trees = rng.uniform() < 0.4 ? 0.3 * rng.uniform() : 0
        var realism = CameraRealism()
        if conditions.maxK1 > 0 { realism.k1 = conditions.maxK1 * (2 * extra.uniform() - 1) }
        if conditions.maxRollingShutter > 0 { realism.rollingShutter = conditions.maxRollingShutter * (2 * extra.uniform() - 1) }

        let photo = SyntheticPhoto.render(world, camera: Camera(intrinsics: k, attitude: truth), scene: scene, realism: realism)
        let horizon = renderer.render(from: believed, settings: conditions.base != nil ? .coarse : HorizonSettings())

        let compassError = max(-compassMax, min(compassMax, compassSigma * rng.gaussian()))
        var prior = truth
        prior.heading = normalizedAzimuth(truth.heading + compassError)
        var matcher = SkylineMatcher()
        if mode == "photo" {
            prior.pitch = 0
            prior.roll = 0
            matcher.settings = .photo
        } else {
            prior.pitch += 0.4 * rng.gaussian()
            prior.roll += 0.4 * rng.gaussian()
        }
        if let range = args.double("heading-range") { matcher.settings.headingRange = range }
        let m = matcher.match(photo, intrinsics: k, prior: prior, horizon: horizon)
        let after = azimuthDifference(m.alignment.attitude.heading, truth.heading)
        // Median distance of the skyline across the view.
        let half = fov / 2
        let inView = horizon.distances.indices.filter {
            abs(azimuthDifference(horizon.azimuth(ofRay: $0), truth.heading)) <= half
        }.map { Double(horizon.distances[$0]) }.sorted()
        let skylineKm = inView.isEmpty ? 0 : inView[inView.count / 2] / 1000
        var r = BenchRun(before: compassError, after: after, accepted: m.alignment.accepted, seconds: m.seconds)
        r.pitch = (prior.pitch - truth.pitch, m.alignment.attitude.pitch - truth.pitch)
        r.roll = (prior.roll - truth.roll, m.alignment.attitude.roll - truth.roll)
        r.rejection = m.alignment.rejectionReason
        results.append(r)
        print(String(format: "%4d  %6.1f°  %3.0f°  %4.2f  %4.2f  %5.1f km  %+6.2f°  %+7.3f°  %@  %4.0f ms",
                     run + 1, truth.heading, fov, scene.clouds, scene.trees, skylineKm, r.before, r.after,
                     r.accepted ? "yes" : " no", r.seconds * 1000)
              + String(format: "  near %.2f", m.alignment.nearAmbiguity)
              + (realism.isPinhole ? "" : String(format: "  k1 %+.4f rs %+.2f°", realism.k1, realism.rollingShutter))
              + (m.alignment.rejectionReason.map { "  (\($0))" } ?? ""))
        if let dir = args.string("save") {
            try saveImage(debugOverlay(m, horizon: horizon), to: "\(dir)/run\(run + 1).\(defaultImageExtension)")
        }
    }

    var summary = benchSummary(results, mode: mode, aim: aim, label: conditions.isDefault ? nil : conditions.label)
    if !conditions.isDefault {
        summary += rejectionSummary(results.compactMap(\.rejection))
        summary += conditions.details + "\n"
    }
    print("\n" + summary)
    if let path = args.string("markdown") {
        try summary.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// "Rejected: 2 not enough distant skyline, 1 ambiguous: …" or nothing. Reasons count
/// together without the numbers in their closing parentheses.
func rejectionSummary(_ reasons: [String]) -> String {
    guard !reasons.isEmpty else { return "" }
    var counts: [String: Int] = [:]
    for r in reasons {
        var kind = r
        if kind.hasSuffix(")"), let open = kind.range(of: " (", options: .backwards) { kind = String(kind[..<open.lowerBound]) }
        counts[kind, default: 0] += 1
    }
    let list = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.value) \($0.key)" }
    return "Rejected: " + list.joined(separator: ", ") + ".\n"
}

func errorStats(_ v: [Double]) -> (median: Double, p90: Double, max: Double) {
    let s = v.map(abs).sorted()
    guard !s.isEmpty else { return (.nan, .nan, .nan) }
    return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))], s.last!)
}

func benchSummary(_ results: [BenchRun], mode: String, aim: String, label: String? = nil) -> String {
    let stats = errorStats
    let accepted = results.filter(\.accepted)
    let before = stats(results.map(\.before))
    let after = stats(accepted.map(\.after))
    let bad = accepted.filter { abs($0.after) > 0.5 }.count
    var md = "| Error (\(mode) mode, aim \(aim)\(label.map { "; " + $0 } ?? "")) | median | 90th percentile | worst |\n|---|---|---|---|\n"
    md += "| Compass (before) | \(f(before.median))° | \(f(before.p90))° | \(f(before.max))° |\n"
    md += "| Skyline matched (after) | \(f(after.median, 3))° | \(f(after.p90, 3))° | \(f(after.max, 3))° |\n"
    // The level as the motion sensors give it, and after matching (accepted frames).
    let pitchBefore = stats(accepted.map(\.pitch.before)), pitchAfter = stats(accepted.map(\.pitch.after))
    let rollBefore = stats(accepted.map(\.roll.before)), rollAfter = stats(accepted.map(\.roll.after))
    md += "| Pitch, sensors (before) | \(f(pitchBefore.median, 3))° | \(f(pitchBefore.p90, 3))° | \(f(pitchBefore.max, 3))° |\n"
    md += "| Pitch, matched (after) | \(f(pitchAfter.median, 3))° | \(f(pitchAfter.p90, 3))° | \(f(pitchAfter.max, 3))° |\n"
    md += "| Roll, sensors (before) | \(f(rollBefore.median, 3))° | \(f(rollBefore.p90, 3))° | \(f(rollBefore.max, 3))° |\n"
    md += "| Roll, matched (after) | \(f(rollAfter.median, 3))° | \(f(rollAfter.p90, 3))° | \(f(rollAfter.max, 3))° |\n\n"
    md += "Accepted \(accepted.count) of \(results.count) frames; \(bad) accepted with an error over 0.5°. "
    md += String(format: "Median matching time %.0f ms.\n", stats(results.map(\.seconds)).median * 1000)
    return md
}

// MARK: - Relief

func reliefCommand(_ args: Arguments) throws {
    let terrain = try loadTerrain(args.string("dem"))
    let size = (args.double("size-km") ?? 12) * 1000, cell = args.double("cell") ?? 30
    let extent = MapExtent(center: LatLon(try args.required("lat"), try args.required("lon")), width: size, height: size)
    let map = timed("Grid") { ReliefMap(terrain: terrain, extent: extent, cellSize: cell) }
    let shade = timed("Hillshade") { map.hillshade(exaggeration: 1.5) }
    let crests = timed("Crests") { map.crestLines() }
    let bands = [(400.0, "main ridges"), (150, "ridges"), (60, "spurs"), (0, "small spurs")]
    let known = map.heights.filter(\.isFinite)
    print("Heights \(f(Double(known.min() ?? .nan), 0))–\(f(Double(known.max() ?? .nan), 0)) m, " +
          "\(f(Double(map.heights[map.rows / 2 * map.cols + map.cols / 2]), 0)) m in the middle")
    print("\(map.cols)×\(map.rows) grid at \(f(cell, 0)) m; \(crests.count) crest lines, " +
          "\(crests.reduce(0) { $0 + $1.points.count }) points")
    for (k, band) in bands.enumerated() {
        let inBand = crests.filter { $0.relief >= band.0 && (k == 0 || $0.relief < bands[k - 1].0) }
        let km = inBand.reduce(0.0) { $0 + $1.length } / 1000
        print("  \(band.1) (relief over \(Int(band.0)) m): \(inBand.count) lines, \(f(km, 1)) km")
    }
    guard let path = args.string("image") else { return }
    var image = RGBImage(width: map.cols, height: map.rows, fill: (9, 11, 16))
    for r in 0..<map.rows {
        for c in 0..<map.cols where shade[r * map.cols + c].isFinite {
            let v = Double(shade[r * map.cols + c])
            image.set(c, r, (UInt8(10 + 70 * v), UInt8(12 + 78 * v), UInt8(18 + 88 * v)))
        }
    }
    func pixel(_ p: SIMD2<Double>) -> (Double, Double) {
        (p.x / cell + Double(map.cols - 1) / 2, Double(map.rows - 1) / 2 - p.y / cell)
    }
    for line in crests.sorted(by: { $0.relief < $1.relief }) {
        let t = min(1, line.relief / 400)
        let v = UInt8(110 + 145 * t)
        image.drawPolyline(line.points.map(pixel), color: (UInt8(Double(v) * 0.86), UInt8(Double(v) * 0.94), v))
    }
    try saveImage(image, to: path)
    print("Wrote \(path)")
}

// MARK: - Viewshed

/// Places around the Matterhorn and whether they see it: true for the classic views, false
/// for spots tucked behind nearer ridges.
let matterhornChecks: [(name: String, at: LatLon, sees: Bool?)] = [
    ("Zermatt, church", LatLon(46.0200, 7.7486), true),
    ("Gornergrat", LatLon(45.9833, 7.7845), true),
    ("Schwarzsee", LatLon(45.9917, 7.7083), true),
    ("Breuil-Cervinia", LatLon(45.9353, 7.6303), true),
    ("Theodul Pass", LatLon(45.9433, 7.7097), true),
    ("Weisshorn summit", LatLon(46.1013, 7.7163), true),
    ("Dufourspitze", LatLon(45.9369, 7.8668), true),
    ("Täsch", LatLon(46.0700, 7.7780), nil),
    ("St. Niklaus", LatLon(46.1770, 7.8040), false),
    ("Visp", LatLon(46.2930, 7.8820), false),
    ("Saas-Fee", LatLon(46.1090, 7.9280), false),
    ("Valtournenche village", LatLon(45.8770, 7.6240), nil),
    ("Aosta", LatLon(45.7370, 7.3200), nil),
]

func viewshedCommand(_ args: Arguments) throws {
    let terrain = try loadTerrain(args.string("dem"))
    let lat = try args.required("lat"), lon = try args.required("lon")
    var settings = ViewshedSettings()
    if let km = args.double("radius-km") { settings.radius = km * 1000 }
    if let cell = args.double("cell") { settings.cellSize = cell }
    let ele = args.double("ele") ?? HorizonRenderer(terrain: terrain).groundHeight(latitude: lat, longitude: lon, within: 100)
    let summit = GeoPoint(latitude: lat, longitude: lon, height: ele)
    // Once to warm up, once to time.
    _ = Viewshed.compute(terrain: terrain, summit: summit, settings: settings)
    let v = timed("Viewshed") { Viewshed.compute(terrain: terrain, summit: summit, settings: settings) }
    print("Summit \(f(ele, 0)) m; \(v.cols)×\(v.rows) cells of \(f(v.cellSize, 0)) m, radius \(f(v.radius / 1000, 1)) km")
    print("Seen from \(f(v.visibleArea / 1e6, 0)) km² (\(f(100 * v.visibleArea / (.pi * v.radius * v.radius), 1))% of the disc); " +
          "terrain known for \(f(100 * v.knownShare, 1))%")
    var wrong = 0
    for check in matterhornChecks {
        guard let sight = v.sight(from: check.at, terrain: terrain), sight.distance <= v.radius else { continue }
        let sees = sight.cell == .visible
        let verdict = check.sees.map { $0 == sees ? "ok" : "WRONG" } ?? "?"
        if check.sees != nil, check.sees != sees { wrong += 1 }
        print("  \(check.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(f(sight.distance / 1000, 1).leftPad(5)) km  " +
              "\(signed(sight.elevation, 2).leftPad(6))°  \(String(describing: sight.cell).padding(toLength: 8, withPad: " ", startingAt: 0)) \(verdict)")
    }
    if wrong > 0 { print("\(wrong) known places disagree") }

    guard let path = args.string("image") else { return }
    let size = Double(v.cols - 1) * v.cellSize
    let relief = ReliefMap(terrain: terrain, extent: MapExtent(center: LatLon(lat, lon), width: size, height: size), cellSize: v.cellSize)
    let shade = relief.hillshade(exaggeration: 1.3)
    var image = RGBImage(width: v.cols, height: v.rows, fill: (9, 11, 16))
    for r in 0..<v.rows {
        for c in 0..<v.cols {
            let s = r < relief.rows && c < relief.cols ? Double(shade[r * relief.cols + c]) : .nan
            let base = s.isFinite ? 10 + 70 * s : 6
            var rgb = (base * 0.86, base * 0.94, base * 1.08)
            switch v.cell(row: r, col: c) {
            case .visible: rgb = (rgb.0 * 0.55 + 120, rgb.1 * 0.55 + 96, rgb.2 * 0.55 + 52)
            case .unknown: if (r + c) % 8 < 2 { rgb = (70, 74, 82) }
            case .hidden, .outside: break
            }
            image.set(c, r, (UInt8(min(255, rgb.0)), UInt8(min(255, rgb.1)), UInt8(min(255, rgb.2))))
        }
    }
    func pixel(_ p: LatLon) -> (Int, Int) {
        let xy = v.projection.point(p)
        return (v.cols / 2 + Int((xy.x / v.cellSize).rounded()), v.rows / 2 - Int((xy.y / v.cellSize).rounded()))
    }
    for (x, y) in [pixel(LatLon(lat, lon))] + matterhornChecks.map({ pixel($0.at) }) {
        for d in -4...4 {
            for (px, py) in [(x + d, y), (x, y + d)] where px >= 0 && px < v.cols && py >= 0 && py < v.rows {
                image.set(px, py, (255, 255, 255))
            }
        }
    }
    try saveImage(image, to: path)
    print("Wrote \(path)")
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
}

// MARK: - main

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    print(usage)
    exit(1)
}
let args = Arguments(argv.dropFirst(2))
do {
    switch argv[1] {
    case "horizon": try horizonCommand(args)
    case "synth": try synthCommand(args)
    case "align": try alignCommand(args)
    case "bench": try benchCommand(args)
    case "pan": try panCommand(args)
    case "realbench": try realbenchCommand(args)
    case "suggest-anchors": try suggestAnchorsCommand(args)
    case "detect": try detectCommand(args)
    case "geotiff": try geotiffCommand(args)
    case "scene": try sceneCommand(args)
    case "trails": try trailsCommand(args)
    case "facts": try factsCommand(args)
    case "sun": try sunCommand(args)
    case "relief": try reliefCommand(args)
    case "base": try baseCommand(args)
    case "viewshed": try viewshedCommand(args)
    case "case": try caseCommand(args)
    case "help", "-h", "--help": print(usage)
    default:
        print(usage)
        exit(1)
    }
} catch {
    log("error: \(error)")
    exit(1)
}

// MARK: - sun

func sunCommand(_ args: Arguments) throws {
    let terrain = try loadTerrain(args.string("dem"))
    let renderer = HorizonRenderer(terrain: terrain)
    let lat = try args.required("lat"), lon = try args.required("lon")
    let zone = args.string("tz").flatMap(TimeZone.init(identifier:)) ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let date: Date
    if let text = args.string("date") {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let d = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { throw HarnessError("--date YYYY-MM-DD") }
        date = d
    } else {
        date = Date()
    }
    let day = DateInterval.day(containing: date, in: zone)
    let time = DateFormatter()
    time.timeZone = zone
    time.dateFormat = "HH:mm:ss"
    func line(_ c: SunDay.Crossing) -> String {
        "\(time.string(from: c.date))  \(c.rising ? "comes out" : "goes behind") at azimuth \(f(c.azimuth, 1))°, " +
            "terrain \(f(c.elevation))° and \(f(c.distance / 1000, 1)) km away"
    }

    let observer = renderer.observer(latitude: lat, longitude: lon)
    let horizon = timed("Horizon from the observer") { renderer.render(from: observer, settings: HorizonSettings()) }
    let almanac = SunDay.astronomical(latitude: lat, longitude: lon, interval: day)
    let seen = timed("Sun over the terrain") { SunDay(horizon: horizon, interval: day) }
    print("\(f(lat, 4)), \(f(lon, 4)) at \(f(observer.height, 0)) m on \(calendar.component(.year, from: date))-" +
          "\(calendar.component(.month, from: date))-\(calendar.component(.day, from: date)) (\(zone.identifier))")
    print("Almanac (flat horizon): sunrise \(almanac.firstLight.map { time.string(from: $0.date) } ?? "–"), " +
          "sunset \(almanac.lastLight.map { time.string(from: $0.date) } ?? "–"), \(f(almanac.duration / 3600, 2)) h")
    print("Over the terrain (first and last light):")
    for c in seen.crossings { print("  " + line(c)) }
    if seen.alwaysInSight { print("  in sight all day") }
    if seen.neverInSight { print("  never in sight") }
    print("  \(f(seen.duration / 3600, 2)) h of sun")
    if let a = almanac.lastLight, let s = seen.lastLight {
        print("Sun leaves you \(f(a.date.timeIntervalSince(s.date) / 60, 1)) min before the almanac sunset; " +
              "reaches you \(f(seen.firstLight.map { $0.date.timeIntervalSince(almanac.firstLight!.date) / 60 } ?? 0, 1)) min after sunrise")
    }

    if let plat = args.double("peak-lat"), let plon = args.double("peak-lon"), let ele = args.double("peak-ele") {
        let summit = timed("Horizon from the summit") { renderer.summitHorizon(latitude: plat, longitude: plon, height: ele) }
        let light = timed("Summit light") { renderer.summitLight(horizon: summit, day: day, ceiling: 4_900) }
        let flat = SunDay.astronomical(latitude: plat, longitude: plon, interval: day)
        print("Summit \(f(plat, 4)), \(f(plon, 4)) at \(f(ele, 0)) m:")
        for c in light.day.crossings { print("  " + line(c)) }
        print("  first light \(light.firstLight.map(time.string) ?? "–"), last light \(light.lastLight.map(time.string) ?? "–")" +
              " (almanac sunset \(flat.lastLight.map { time.string(from: $0.date) } ?? "–"))")
        if let r = light.reachAtLastLight { print("  terrain toward last light ends at \(f(r / 1000, 0)) km") }
        if let r = light.reachAtFirstLight { print("  terrain toward first light ends at \(f(r / 1000, 0)) km") }
        if light.rangeLimited { print("  range limited: farther terrain could change these") }
    }
}

import Foundation
import PeakCore

let usage = """
peakbench: desk test harness for skyline matching.

  peakbench horizon --dem DIR --lat L --lon L [--altitude M] [--csv FILE] [--image FILE]
      Render the horizon from a point and print a summary. --image writes a depth panorama.

  peakbench synth --dem DIR --lat L --lon L --heading H [--pitch P] [--roll R] [--fov F]
                  [--width W] [--height H] [--compass-error E] [--clouds C] [--trees T]
                  [--seed S] --out NAME
      Render a synthetic photo (NAME.ppm, or NAME.png on a Mac) and its case file NAME.json.

  peakbench align CASE.json [--dem DIR] [--debug FILE] [--curve] [--points FILE.csv]
      Find the skyline in a photo, align it to the terrain and report the heading error
      before and after correction.

  peakbench bench --dem DIR --lat L --lon L [--runs N] [--spread-km K] [--gps-error M]
                  [--mode arkit|photo] [--aim far|any] [--seed S] [--markdown FILE] [--save DIR]
                  [--compass-sigma D] [--compass-max D] [--heading-range D]
      Monte Carlo test on synthetic photos of the real terrain around a point. By default
      the camera aims where the skyline is at least 5 km away, as when pointing at peaks.
      Compass errors are Gaussian (default σ 8°, at most 18°); --heading-range overrides
      the matcher's heading search (± degrees).

  peakbench detect IMAGE [--width W] [--debug FILE]
      Run only the skyline detector and draw what it found.

  peakbench geotiff FILE.tif [--level N] [--ranged] [--blocks] [--out FILE.pkdem] [--compare FILE.pkdem]
      Decode a Copernicus GeoTIFF with PeakCore's own reader (what the app does). --blocks
      also decodes each block of the level on its own and checks it against the whole.

  peakbench trails OVERPASS.json --lat L --lon L [--dem DIR] [--from-lat L --from-lon L]
  peakbench trails --query --lat L --lon L
      Read hiking routes and paths from an Overpass response (Overpass.trailsQuery) near a
      peak at --lat/--lon. With --dem, climb from the terrain; with --from-*, how much of
      each trail is in sight from there, as the app draws it on the mountain.

  peakbench relief --dem DIR --lat L --lon L [--size-km K] [--cell M] [--image FILE]
      The terrain seen from above around a point, as the app draws it under a trail:
      hillshade and ridge crests. Prints how long each step takes and what it found.

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
    let caseURL = URL(fileURLWithPath: casePath)
    var photo = try JSONDecoder().decode(PhotoCase.self, from: Data(contentsOf: caseURL))
    let base = caseURL.deletingLastPathComponent()
    let demPath = args.string("dem") ?? photo.dem.map { base.appendingPathComponent($0).path }
    let terrain = try loadTerrain(demPath)
    let renderer = HorizonRenderer(terrain: terrain)
    let observer = photo.altitude.map { GeoPoint(latitude: photo.latitude, longitude: photo.longitude, height: $0) }
        ?? renderer.observer(latitude: photo.latitude, longitude: photo.longitude)
    let image = try loadImage(base.appendingPathComponent(photo.image).path)
    let intrinsics = CameraIntrinsics(width: image.width, height: image.height, horizontalFOV: photo.horizontalFOV)
    let horizon = timed("Horizon") { renderer.render(from: observer) }

    if photo.truth == nil, let anchors = photo.anchors, !anchors.isEmpty {
        let initial = Attitude(heading: photo.heading, pitch: photo.pitch ?? 0, roll: photo.roll ?? 0)
        if let solved = AnchorSolver.attitude(anchors: anchors, observer: observer, intrinsics: intrinsics, initial: initial) {
            photo.truth = solved.attitude
            print("Truth from \(anchors.count) marked summit(s): heading \(f(solved.attitude.heading))°, " +
                  "pitch \(f(solved.attitude.pitch))°, roll \(f(solved.attitude.roll))° (fit \(f(solved.rmsPixels, 1)) px)")
        }
    }

    var matcher = SkylineMatcher()
    if photo.pitch == nil || photo.roll == nil { matcher.settings = .photo }
    let prior = Attitude(heading: photo.heading, pitch: photo.pitch ?? 0, roll: photo.roll ?? 0)
    let match = matcher.match(image, intrinsics: intrinsics, prior: prior, horizon: horizon)
    report(match, truth: photo.truth)
    if let path = args.string("points") {
        // Each detected skyline point where the sensors put it, beside the rendered horizon.
        let projector = match.camera.projector
        var csv = "x,y,azimuth,elevation,horizon,distance\n"
        for p in match.skyline.points {
            let d = projector.look(x: p.x, y: p.y)
            let ray = Int((normalizedAzimuth(d.azimuth) / horizon.azimuthStep).rounded()) % horizon.count
            csv += String(format: "%.1f,%.1f,%.3f,%.3f,%.3f,%.0f\n", p.x, p.y, d.azimuth, d.elevation,
                          horizon.elevation(atAzimuth: d.azimuth), Double(horizon.distances[ray]))
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
          "match and are far away; ambiguity \(f(a.ambiguity))")
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
/// puts it (green), ridges behind the skyline (cyan) and the detected skyline (yellow).
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
    let terrain = try args.string("dem").map { try loadTerrain($0) }
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
}

func benchCommand(_ args: Arguments) throws {
    let terrain = try loadTerrain(args.string("dem"))
    let renderer = HorizonRenderer(terrain: terrain)
    let lat = try args.required("lat"), lon = try args.required("lon")
    let runs = args.int("runs") ?? 30
    let spread = (args.double("spread-km") ?? 3) * 1000
    let gpsError = args.double("gps-error") ?? 15
    let mode = args.string("mode") ?? "arkit"
    let aim = args.string("aim") ?? "far"
    let compassSigma = args.double("compass-sigma") ?? 8, compassMax = args.double("compass-max") ?? 18
    var rng = SplitMix64(seed: UInt64(args.int("seed") ?? 1))
    var results: [BenchRun] = []

    print("Mode: \(mode), aim: \(aim), \(runs) runs within \(f(spread / 1000, 1)) km of \(f(lat, 4)), \(f(lon, 4)); " +
          "GPS error up to \(f(gpsError, 0)) m")
    print(" run  heading   fov clouds trees  skyline   before     after  ok    time")
    for run in 0..<runs {
        // The real spot, and where the GPS thinks it is.
        let spot = destination(from: GeoPoint(latitude: lat, longitude: lon), azimuth: 360 * rng.uniform(),
                               distance: spread * rng.uniform().squareRoot())
        let truePosition = renderer.observer(latitude: spot.latitude, longitude: spot.longitude)
        let gps = destination(from: truePosition, azimuth: 360 * rng.uniform(), distance: gpsError * rng.uniform())
        let believed = renderer.observer(latitude: gps.latitude, longitude: gps.longitude)

        var heading = 360 * rng.uniform()
        // The photo comes from a finer render at the true spot than the one we match against.
        var fine = HorizonSettings()
        fine.azimuthStep = 0.05
        let world = renderer.render(from: truePosition, settings: fine)
        if aim == "far" {
            let far = world.distances.indices.filter { world.distances[$0] >= 5_000 }
            if !far.isEmpty { heading = world.azimuth(ofRay: far[Int(rng.next() % UInt64(far.count))]) }
        }
        let truth = Attitude(heading: heading, pitch: -2 + 8 * rng.uniform(), roll: -4 + 8 * rng.uniform())
        let fov = 55 + 20 * rng.uniform()
        let k = CameraIntrinsics(width: 1280, height: 960, horizontalFOV: fov)
        var scene = SyntheticScene()
        scene.seed = rng.next()
        scene.clouds = rng.uniform() < 0.5 ? 0.5 * rng.uniform() : 0
        scene.trees = rng.uniform() < 0.4 ? 0.3 * rng.uniform() : 0

        let photo = SyntheticPhoto.render(world, camera: Camera(intrinsics: k, attitude: truth), scene: scene)
        let horizon = renderer.render(from: believed)

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
        results.append(r)
        print(String(format: "%4d  %6.1f°  %3.0f°  %4.2f  %4.2f  %5.1f km  %+6.2f°  %+7.3f°  %@  %4.0f ms",
                     run + 1, truth.heading, fov, scene.clouds, scene.trees, skylineKm, r.before, r.after,
                     r.accepted ? "yes" : " no", r.seconds * 1000)
              + (m.alignment.rejectionReason.map { "  (\($0))" } ?? ""))
        if let dir = args.string("save") {
            try saveImage(debugOverlay(m, horizon: horizon), to: "\(dir)/run\(run + 1).\(defaultImageExtension)")
        }
    }

    let summary = benchSummary(results, mode: mode, aim: aim)
    print("\n" + summary)
    if let path = args.string("markdown") {
        try summary.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func benchSummary(_ results: [BenchRun], mode: String, aim: String) -> String {
    func stats(_ v: [Double]) -> (median: Double, p90: Double, max: Double) {
        let s = v.map(abs).sorted()
        guard !s.isEmpty else { return (.nan, .nan, .nan) }
        return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))], s.last!)
    }
    let accepted = results.filter(\.accepted)
    let before = stats(results.map(\.before))
    let after = stats(accepted.map(\.after))
    let bad = accepted.filter { abs($0.after) > 0.5 }.count
    var md = "| Error (\(mode) mode, aim \(aim)) | median | 90th percentile | worst |\n|---|---|---|---|\n"
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
        let km = inBand.reduce(0.0) { sum, line in
            sum + zip(line.points, line.points.dropFirst()).reduce(0) { $0 + (($1.1 - $1.0) * ($1.1 - $1.0)).sum().squareRoot() }
        } / 1000
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
    case "detect": try detectCommand(args)
    case "geotiff": try geotiffCommand(args)
    case "scene": try sceneCommand(args)
    case "trails": try trailsCommand(args)
    case "facts": try factsCommand(args)
    case "relief": try reliefCommand(args)
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

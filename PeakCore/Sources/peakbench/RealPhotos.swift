import Foundation
import PeakCore

// Real photos: cases from `peakbench case` or frames saved by the app, the truth from marked
// summits, and help marking them.

/// What the app saved with a test frame (`SkylineCorrector.TestFrame`), kept as is.
struct AppFrameInfo: Codable {
    /// The motion sensors' attitude, before any correction.
    var sensors: [String: Double]?
    /// The corrections in use when the frame was taken.
    var correction: [String: Double]?
    /// The lens: width, height, fx, fy, cx, cy for the saved picture.
    var intrinsics: [String: Double]?
    var measuredLens: Bool?
    /// How the app's own match of this frame went.
    var match: [String: String]?
}

/// A case file loaded with its picture, the terrain and the horizon from where it was taken.
struct LoadedCase {
    var url: URL
    var photo: PhotoCase
    var image: RGBImage
    var intrinsics: CameraIntrinsics
    var terrain: Terrain
    var renderer: HorizonRenderer
    var observer: GeoPoint
    var horizon: HorizonProfile

    var name: String { url.deletingPathExtension().lastPathComponent }

    /// `terrain` gives the terrain for a DEM directory (nil: the default) at a place.
    init(_ url: URL, demOverride: String?, terrain: (String?, Double, Double) throws -> Terrain) throws {
        self.url = url
        photo = try JSONDecoder().decode(PhotoCase.self, from: Data(contentsOf: url))
        let base = url.deletingLastPathComponent()
        let demPath = demOverride ?? photo.dem.map { base.appendingPathComponent($0).path }
        self.terrain = try terrain(demPath, photo.latitude, photo.longitude)
        renderer = HorizonRenderer(terrain: self.terrain)
        let photo = photo, renderer = renderer
        observer = photo.altitude.map { GeoPoint(latitude: photo.latitude, longitude: photo.longitude, height: $0) }
            ?? renderer.observer(latitude: photo.latitude, longitude: photo.longitude)
        image = try loadImage(base.appendingPathComponent(photo.image).path)
        intrinsics = photo.intrinsics(width: image.width, height: image.height)
        let observer = observer
        horizon = timed("Horizon") { renderer.render(from: observer) }
    }

    /// The true attitude: given in the case, or worked out from checked anchors. `fit` is
    /// how far the anchors sit from where that attitude puts them (RMS, degrees).
    func truth() -> (attitude: Attitude, source: String, fit: Double?)? {
        if let t = photo.truth { return (t, "given", nil) }
        let checked = (photo.anchors ?? []).filter(\.isChecked)
        guard !checked.isEmpty,
              let solved = AnchorSolver.attitude(anchors: checked, observer: observer, intrinsics: intrinsics,
                                                 initial: photo.saved) else { return nil }
        return (solved.attitude, "\(checked.count) anchor\(checked.count == 1 ? "" : "s")", solved.rmsPixels / intrinsics.fx * 180 / .pi)
    }

    /// Matches the photo from `prior`, as the app would: at 960 pixels on the long side
    /// unless `workingWidth` says otherwise, searching wider without pitch and roll.
    func match(prior: Attitude, workingWidth: Int?) -> SkylineMatcher.Match {
        var matcher = SkylineMatcher()
        if photo.pitch == nil || photo.roll == nil { matcher.settings = .photo }
        if let workingWidth {
            matcher.workingWidth = workingWidth
        } else {
            matcher.workingWidth = image.width >= image.height ? 960 : 960 * image.width / image.height
        }
        return matcher.match(image, intrinsics: intrinsics, prior: prior, horizon: horizon)
    }
}

extension PhotoCase {
    /// The attitude saved in the case: for a frame from the app, the sensors plus the
    /// corrections it had in use.
    var saved: Attitude { Attitude(heading: heading, pitch: pitch ?? 0, roll: roll ?? 0) }

    /// The motion sensors' own attitude, before any correction, when the app saved it.
    var sensors: Attitude? {
        guard let s = app?.sensors, let h = s["heading"] else { return nil }
        return Attitude(heading: normalizedAzimuth(h), pitch: s["pitch"] ?? pitch ?? 0, roll: s["roll"] ?? roll ?? 0)
    }

    /// The lens the app measured, if it saved one for a picture this size; otherwise a
    /// pinhole with the case's field of view.
    func intrinsics(width: Int, height: Int) -> CameraIntrinsics {
        if let i = app?.intrinsics, let w = i["width"], let h = i["height"], let fx = i["fx"], let fy = i["fy"],
           let cx = i["cx"], let cy = i["cy"], w > 0, h > 0 {
            let k = CameraIntrinsics(width: Int(w), height: Int(h), fx: fx, fy: fy, cx: cx, cy: cy)
            if k.width == width && k.height == height { return k }
            if abs(w / h - Double(width) / Double(height)) < 0.01 { return k.scaled(toWidth: width, height: height) }
        }
        return CameraIntrinsics(width: width, height: height, horizontalFOV: horizontalFOV)
    }
}

/// Terrain loaded once per DEM directory (and with `appTerrain`, built once per place):
/// either the full tiles, or what the app would hold there with its summits raised.
final class TerrainCache {
    var full: [String: Terrain] = [:]
    var app: [String: Terrain] = [:]
    let appTerrain: Bool
    let peaks: [Peak]?

    init(appTerrain: Bool, peaks: [Peak]?) {
        self.appTerrain = appTerrain
        self.peaks = peaks
    }

    func terrain(_ path: String?, _ latitude: Double, _ longitude: Double) throws -> Terrain {
        let key = path ?? ""
        let tiles = try full[key] ?? loadTerrain(path)
        full[key] = tiles
        guard appTerrain else { return tiles }
        let place = key + String(format: "|%.2f|%.2f", latitude, longitude)
        if let t = app[place] { return t }
        let t = Terrain.appDetail(from: tiles.tiles, latitude: latitude, longitude: longitude)
        if let peaks { t.raiseSummits(t.fillElevations(peaks)) }
        app[place] = t
        return t
    }
}

/// The case files in a directory (JSON files that decode as cases), sorted by name.
func caseFiles(in dir: String) throws -> [URL] {
    let url = URL(fileURLWithPath: dir)
    return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "json" }
        .filter { (try? JSONDecoder().decode(PhotoCase.self, from: Data(contentsOf: $0))) != nil }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

// MARK: - realbench

func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - s.count))
    return right ? fill + s : s + fill
}

struct RealRun {
    var name: String
    /// Heading errors before and after matching; nil without a truth.
    var before: Double?
    var after: Double?
    var accepted: Bool
    var rejection: String?
    var truthSource: String?
    var fit: Double?
    var seconds: Double
}

func realbenchCommand(_ args: Arguments) throws {
    guard let dir = args.positional.first else { throw HarnessError("which directory of cases?") }
    let peaks = try args.string("peaks").map { try Overpass.peaks(fromJSON: Data(contentsOf: URL(fileURLWithPath: $0))) }
    let appTerrain = args.string("match") == "app"
    let cache = TerrainCache(appTerrain: appTerrain, peaks: peaks)
    let maxFit = args.double("max-fit") ?? 0.25
    let useSaved = args.string("prior") == "saved"
    let files = try caseFiles(in: dir)
    guard !files.isEmpty else { throw HarnessError("no case files in \(dir)") }

    var runs: [RealRun] = []
    var poorFit: [String] = []
    print("\(files.count) cases in \(dir); matching from \(useSaved ? "the saved attitude" : "the sensors (raw compass)")" +
          (appTerrain ? ", against the app's terrain" : ""))
    print(pad("case", 34) + " " + pad("before", 9, right: true) + " " + pad("after", 9, right: true) + "  ok  " +
          pad("truth", 12) + " " + pad("fit", 6, right: true) + "   time")
    for url in files {
        let c: LoadedCase
        do {
            c = try LoadedCase(url, demOverride: args.string("dem"), terrain: cache.terrain)
        } catch {
            log("\(url.lastPathComponent): skipped: \(error)")
            continue
        }
        // A cold start: the raw sensors when the app saved them, unless asked for the saved attitude.
        let prior = useSaved ? c.photo.saved : (c.photo.sensors ?? c.photo.saved)
        let m = c.match(prior: prior, workingWidth: args.int("working-width"))
        var run = RealRun(name: c.name, accepted: m.alignment.accepted, rejection: m.alignment.rejectionReason,
                          seconds: m.seconds)
        if let t = c.truth() {
            run.truthSource = t.source
            run.fit = t.fit
            if let fit = t.fit, fit > maxFit {
                // The marks disagree with each other: one is likely on the wrong summit.
                poorFit.append("\(c.name) (\(f(fit, 2))°)")
            } else {
                run.before = azimuthDifference(prior.heading, t.attitude.heading)
                run.after = azimuthDifference(m.alignment.attitude.heading, t.attitude.heading)
            }
        }
        runs.append(run)
        print(pad(String(c.name.prefix(34)), 34) + " " + pad(run.before.map { signed($0) + "°" } ?? "-", 9, right: true) + " " +
              pad(run.after.map { signed($0, 3) + "°" } ?? "-", 9, right: true) + "  " + (run.accepted ? "yes" : " no") + "  " +
              pad(run.truthSource ?? "none", 12) + " " + pad(run.fit.map { f($0, 3) + "°" } ?? "-", 6, right: true) +
              String(format: "  %4.0f ms", run.seconds * 1000) + (run.rejection.map { "  (\($0))" } ?? ""))
        if let out = args.string("debug") {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try saveImage(debugOverlay(m, horizon: c.horizon), to: "\(out)/\(c.name)-aligned.\(defaultImageExtension)")
        }
    }

    let summary = realbenchSummary(runs, poorFit: poorFit, maxFit: maxFit,
                                   label: args.string("label") ?? (appTerrain ? "app terrain" : nil))
    print("\n" + summary)
    if let path = args.string("markdown") { try summary.write(toFile: path, atomically: true, encoding: .utf8) }
}

func realbenchSummary(_ runs: [RealRun], poorFit: [String], maxFit: Double, label: String?) -> String {
    let measured = runs.filter { $0.before != nil }
    let accepted = runs.filter(\.accepted)
    let acceptedMeasured = measured.filter(\.accepted)
    let before = errorStats(measured.compactMap(\.before))
    let after = errorStats(acceptedMeasured.compactMap(\.after))
    let bad = acceptedMeasured.filter { abs($0.after!) > 0.5 }.count
    var md = "| Heading error (real photos\(label.map { "; " + $0 } ?? "")) | median | 90th percentile | worst |\n|---|---|---|---|\n"
    md += "| Compass (before) | \(f(before.median))° | \(f(before.p90))° | \(f(before.max))° |\n"
    md += "| Skyline matched (after) | \(f(after.median, 3))° | \(f(after.p90, 3))° | \(f(after.max, 3))° |\n\n"
    md += "Accepted \(accepted.count) of \(runs.count) frames. Of the \(measured.count) with a known true heading, "
    md += "\(acceptedMeasured.count) accepted, \(bad) of them with an error over 0.5°. "
    md += String(format: "Median matching time %.0f ms.\n", errorStats(runs.map(\.seconds)).median * 1000)
    md += rejectionSummary(runs.compactMap(\.rejection))
    let unknown = runs.count - measured.count - poorFit.count
    if unknown > 0 {
        md += "\(unknown) frame\(unknown == 1 ? "" : "s") without a true heading (no anchors, or only unconfirmed suggestions): counted for acceptance only.\n"
    }
    if !poorFit.isEmpty {
        md += "Left out for anchors that don't fit together (over \(f(maxFit, 2))° RMS): " + poorFit.joined(separator: ", ") + ".\n"
    }
    return md
}

// MARK: - suggest-anchors

func suggestAnchorsCommand(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw HarnessError("which case file?") }
    let url = URL(fileURLWithPath: path)
    if let list = args.string("confirm") ?? args.string("drop") {
        // Mark (or drop) anchors by their numbers in the debug image, without matching again.
        let photo = try JSONDecoder().decode(PhotoCase.self, from: Data(contentsOf: url))
        var anchors = photo.anchors ?? []
        let numbers = Set(list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 >= 1 && $0 <= anchors.count }) else {
            throw HarnessError("anchor numbers run from 1 to \(anchors.count)")
        }
        if args.string("confirm") != nil {
            for n in numbers { anchors[n - 1].confirmed = true }
        } else {
            anchors = anchors.enumerated().filter { !numbers.contains($0.offset + 1) }.map(\.element)
        }
        try writeAnchors(anchors, into: path)
        for (i, a) in anchors.enumerated() { print("\(i + 1). \(a.name ?? "?"): \(a.isChecked ? "checked" : "unconfirmed")") }
        return
    }

    guard let peaksPath = args.string("peaks") else { throw HarnessError("missing --peaks OVERPASS.json (the cached peak files are the same format)") }
    let peaks = try Overpass.peaks(fromJSON: Data(contentsOf: URL(fileURLWithPath: peaksPath)))
    var c = try LoadedCase(url, demOverride: args.string("dem")) { path, _, _ in try loadTerrain(path) }
    let prior = c.photo.sensors ?? c.photo.saved
    let m = c.match(prior: prior, workingWidth: args.int("working-width"))
    report(m, truth: c.truth()?.attitude)
    var attitude = m.alignment.attitude
    if !m.alignment.accepted {
        if args.options["force"] != nil {
            log("warning: the match was rejected; proposing from it anyway (--force)")
        } else {
            log("warning: the match was rejected, so the proposals use the compass and may be far off (--force uses the match anyway)")
            attitude = prior
        }
    }
    // Which named peaks can be seen, as the app works it out: estimated elevations filled in
    // and blunted summits raised first.
    let filled = c.terrain.fillElevations(peaks)
    c.terrain.raiseSummits(filled)
    let visible = c.renderer.visiblePeaks(filled, from: c.observer, maxDistance: c.horizon.settings.maxDistance,
                                          settings: c.horizon.settings)
    let camera = Camera(intrinsics: c.intrinsics, attitude: attitude)
    let suggested = AnchorSuggester.suggest(visible, camera: camera, limit: args.int("max") ?? 12)

    // Keep anchors already checked; replace earlier suggestions.
    let checked = (c.photo.anchors ?? []).filter(\.isChecked)
    let fresh = suggested.filter { s in
        !checked.contains { a in
            groundDistance(from: GeoPoint(latitude: a.latitude, longitude: a.longitude, height: 0),
                           to: GeoPoint(latitude: s.latitude, longitude: s.longitude, height: 0)) < 100
        }
    }
    c.photo.anchors = checked + fresh
    let out = args.string("out") ?? path
    if out != path { try FileManager.default.copyItem(atPath: path, toPath: out) }
    try writeAnchors(c.photo.anchors ?? [], into: out)
    let frame = LocalFrame(origin: c.observer)
    for (i, a) in (c.photo.anchors ?? []).enumerated() {
        let d = frame.look(at: GeoPoint(latitude: a.latitude, longitude: a.longitude, height: a.elevation)).distance
        print("\(i + 1). \(a.name ?? "?") (\(f(a.elevation, 0)) m, \(f(d / 1000, 1)) km): x \(f(a.x, 1)), y \(f(a.y, 1))" +
              (a.isChecked ? ", checked" : ""))
    }
    print("Wrote \(fresh.count) proposed anchor(s) to \(out), unconfirmed. Check each against the photo, nudge x/y onto the " +
          "summit's tip if needed, then confirm with --confirm 1,2,… (or set \"confirmed\": true).")
    if let debug = args.string("debug") {
        try saveImage(anchorSheet(c.image, anchors: c.photo.anchors ?? [], horizon: c.horizon, camera: camera), to: debug)
        print("Wrote \(debug)")
    }
}

/// Replaces the anchors in a case file, leaving everything else in it as it was (the app's
/// notes, fields added by hand).
func writeAnchors(_ anchors: [Anchor], into path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw HarnessError("\(path) is not a case file")
    }
    object["anchors"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(anchors))
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

/// The photo (at most 1600 pixels wide) with a numbered crosshair on each anchor and the
/// matched skyline, and below it a close-up of each anchor at full size, magnified 3×, so a
/// mark a few pixels off the summit shows.
func anchorSheet(_ photo: RGBImage, anchors: [Anchor], horizon: HorizonProfile, camera: Camera) -> RGBImage {
    let scale = min(1, 1600 / Double(photo.width))
    let view = scale < 1 ? photo.resized(toWidth: 1600) : photo
    let crop = 48, zoom = 3, inset = crop * zoom, gap = 8
    let perRow = max(1, (view.width + gap) / (inset + gap))
    let insetRows = (anchors.count + perRow - 1) / perRow
    var sheet = RGBImage(width: view.width, height: view.height + insetRows * (inset + gap) + (insetRows > 0 ? gap : 0),
                         fill: (16, 18, 24))
    for y in 0..<view.height {
        for x in 0..<view.width { sheet.set(x, y, view.pixel(x, y)) }
    }
    // The skyline where the attitude puts it, faint, to judge the attitude by.
    let projector = camera.projector
    let line = (0..<view.width).map { x -> (Double, Double) in
        let az = projector.look(x: (Double(x) + 0.5) / scale, y: Double(photo.height) / 2).azimuth
        guard let p = projector.pixel(azimuth: az, elevation: horizon.elevation(atAzimuth: az)) else { return (.nan, .nan) }
        return (p.x * scale, p.y * scale)
    }
    sheet.drawPolyline(line, color: (64, 200, 96), thickness: 1, maxGap: 40)
    for (i, a) in anchors.enumerated() {
        let color: (UInt8, UInt8, UInt8) = a.isChecked ? (80, 255, 120) : (255, 220, 0)
        drawCrosshair(&sheet, a.x * scale, a.y * scale, size: 12, color: color)
        drawNumber(&sheet, i + 1, x: Int(a.x * scale) + 8, y: Int(a.y * scale) - 22, scale: 3, color: color)
        // The close-up.
        let ox = gap / 2 + (i % perRow) * (inset + gap), oy = view.height + gap + (i / perRow) * (inset + gap)
        for y in 0..<inset {
            for x in 0..<inset {
                let px = Int(a.x.rounded(.down)) - crop / 2 + x / zoom, py = Int(a.y.rounded(.down)) - crop / 2 + y / zoom
                guard px >= 0, py >= 0, px < photo.width, py < photo.height else { continue }
                sheet.set(ox + x, oy + y, photo.pixel(px, py))
            }
        }
        let cx = Double(ox) + (a.x - (a.x.rounded(.down) - Double(crop / 2))) * Double(zoom)
        let cy = Double(oy) + (a.y - (a.y.rounded(.down) - Double(crop / 2))) * Double(zoom)
        drawCrosshair(&sheet, cx, cy, size: 20, color: color, gap: 5)
        drawNumber(&sheet, i + 1, x: ox + 4, y: oy + 4, scale: 3, color: color)
    }
    return sheet
}

/// A crosshair with an open middle, so the summit under it stays visible, outlined in black.
func drawCrosshair(_ image: inout RGBImage, _ x: Double, _ y: Double, size: Double, color: (UInt8, UInt8, UInt8), gap: Double = 3) {
    for (c, w) in [((0, 0, 0) as (UInt8, UInt8, UInt8), 3), (color, 1)] {
        image.drawLine(x - size, y, x - gap, y, color: c, thickness: w)
        image.drawLine(x + gap, y, x + size, y, color: c, thickness: w)
        image.drawLine(x, y - size, x, y - gap, color: c, thickness: w)
        image.drawLine(x, y + gap, x, y + size, color: c, thickness: w)
    }
}

/// Digits 0–9 in a 3×5 grid, a row per string, top to bottom.
let digitGlyphs: [[String]] = [
    ["###", "#.#", "#.#", "#.#", "###"], [".#.", "##.", ".#.", ".#.", "###"], ["###", "..#", "###", "#..", "###"],
    ["###", "..#", "###", "..#", "###"], ["#.#", "#.#", "###", "..#", "..#"], ["###", "#..", "###", "..#", "###"],
    ["###", "#..", "###", "#.#", "###"], ["###", "..#", "..#", "..#", "..#"], ["###", "#.#", "###", "#.#", "###"],
    ["###", "#.#", "###", "..#", "###"],
]

/// Writes a number with its top-left corner at (x, y), each glyph cell `scale` pixels, on a
/// dark backing so it reads on snow and sky alike.
func drawNumber(_ image: inout RGBImage, _ n: Int, x: Int, y: Int, scale: Int, color: (UInt8, UInt8, UInt8)) {
    let digits = String(n).compactMap(\.wholeNumberValue)
    let w = digits.count * 4 * scale + scale, h = 7 * scale
    for yy in max(0, y)..<min(image.height, y + h) {
        for xx in max(0, x)..<min(image.width, x + w) { image.set(xx, yy, (0, 0, 0)) }
    }
    for (k, d) in digits.enumerated() {
        for (row, bits) in digitGlyphs[d].enumerated() {
            for (col, bit) in bits.enumerated() where bit == "#" {
                let x0 = x + scale + k * 4 * scale + col * scale, y0 = y + scale + row * scale
                for yy in y0..<(y0 + scale) where yy >= 0 && yy < image.height {
                    for xx in x0..<(x0 + scale) where xx >= 0 && xx < image.width { image.set(xx, yy, color) }
                }
            }
        }
    }
}

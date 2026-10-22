import Foundation
import PeakCore

// MARK: - pan

/// Panning sequences seen between buildings: several frames a second or so apart, each
/// showing the skyline only in the gaps between roofs, with a compass that wanders from
/// frame to frame (as indoors) and a gyroscope that drifts. Each frame is matched alone as
/// the app does; a frame turned away goes into a `SkylineStrip`, matched together with the
/// frames before it. Reports what single frames alone get, and what the strip adds.
func panCommand(_ args: Arguments) throws {
    let terrain = try loadTerrain(args.string("dem"))
    let lat = try args.required("lat"), lon = try args.required("lon")
    let conditions = try BenchConditions(args)
    var worldTerrain = terrain, matchTerrain = terrain
    if let p = conditions.perturbation {
        worldTerrain = timed("Perturbed world") { Terrain(tiles: terrain.tiles.map { $0.perturbed(p) }) }
    }
    if conditions.appTerrain {
        matchTerrain = timed("App terrain") { Terrain.appDetail(from: terrain.tiles, latitude: lat, longitude: lon) }
        if let peaks = conditions.peaks {
            let raised = matchTerrain.raiseSummits(matchTerrain.fillElevations(peaks))
            log("Raised \(raised) of \(peaks.count) summits")
        }
    }
    let renderer = HorizonRenderer(terrain: matchTerrain)
    let worldRenderer = HorizonRenderer(terrain: worldTerrain)
    let runs = args.int("runs") ?? 20
    let frameCount = max(2, args.int("frames") ?? 5)
    let pan = args.double("pan") ?? 40
    let interval = args.double("interval") ?? 1.5
    let spread = (args.double("spread-km") ?? 3) * 1000
    let gpsError = args.double("gps-error") ?? 15
    let driftSigma = args.double("drift") ?? 0.02
    let wander = args.double("wander") ?? 3
    let occlusion = args.string("occlusion") ?? "walls"
    guard ["walls", "roofs", "none"].contains(occlusion) else { throw HarnessError("--occlusion is walls, roofs or none") }
    let gap = args.double("gap") ?? (occlusion == "walls" ? 8 : 5)
    let roofWidth = args.double("roof") ?? 14
    let fixedFOV = args.double("fov")
    var rng = SplitMix64(seed: UInt64(args.int("seed") ?? 1))
    var extra = SplitMix64(seed: UInt64(args.int("seed") ?? 1) &+ 0x5EED)

    struct Accepted {
        var error: Double
        var stitched: Bool
    }
    var accepted: [Accepted] = []
    var singleSequences = 0, anySequences = 0, stitchedTries = 0
    var stitchedRejections: [String] = []
    var singleSeconds: [Double] = [], stitchedSeconds: [Double] = []

    print("Pan: \(runs) sequences of \(frameCount) frames over \(f(pan, 0))°, \(f(interval, 1)) s apart, within " +
          "\(f(spread / 1000, 1)) km of \(f(lat, 4)), \(f(lon, 4)); occlusion \(occlusion)" +
          (occlusion != "none" ? " (gaps ~\(f(gap, 1))°, roofs ~\(f(roofWidth, 0))°)" : "") +
          "; compass wander σ \(f(wander, 1))° per frame, gyro drift σ \(f(driftSigma, 3))°/s")
    if !conditions.isDefault { print(conditions.details) }
    for run in 0..<runs {
        let spot = destination(from: GeoPoint(latitude: lat, longitude: lon), azimuth: 360 * rng.uniform(),
                               distance: spread * rng.uniform().squareRoot())
        let truePosition = worldRenderer.observer(latitude: spot.latitude, longitude: spot.longitude)
        let gps = destination(from: truePosition, azimuth: 360 * rng.uniform(), distance: gpsError * rng.uniform())
        let believed = renderer.observer(latitude: gps.latitude, longitude: gps.longitude)
        var fine = HorizonSettings()
        fine.azimuthStep = 0.05
        let world = worldRenderer.render(from: truePosition, settings: fine)
        let horizon = renderer.render(from: believed, settings: HorizonSettings())
        // The pan's middle aims where the skyline is far, as when pointing at peaks.
        let far = world.distances.indices.filter { world.distances[$0] >= 5_000 }
        let center = far.isEmpty ? 360 * rng.uniform() : world.azimuth(ofRay: far[Int(rng.next() % UInt64(far.count))])
        let fov = fixedFOV ?? 55 + 20 * rng.uniform()
        let k = CameraIntrinsics(width: 1280, height: 960, horizontalFOV: fov)
        let basePitch = -1 + 4 * rng.uniform(), baseRoll = -3 + 6 * rng.uniform()
        let compassError = max(-18, min(18, 8 * rng.gaussian()))
        let drift = driftSigma * rng.gaussian()
        let gyroZero = 360 * rng.uniform()
        var scene = conditions.syntheticScene()
        scene.seed = rng.next()
        scene.clouds = rng.uniform() < 0.5 ? 0.5 * rng.uniform() : 0
        scene.trees = occlusion == "none" && rng.uniform() < 0.4 ? 0.3 * rng.uniform() : 0

        // Buildings across the whole pan, a field of view past either end, with gaps between:
        // walls reach far above the skyline (as a window's frame), roofs just over it, with
        // sky above them.
        var buildings: [SyntheticPhoto.Building] = []
        if occlusion != "none" {
            let rise = occlusion == "walls" ? 20.0 : 0.5
            var az = center - pan / 2 - fov - roofWidth * rng.uniform()
            while az < center + pan / 2 + fov {
                let width = roofWidth * (0.6 + 0.8 * rng.uniform())
                let top = stride(from: az, through: az + width, by: 0.1).map { world.elevation(atAzimuth: $0) }.max() ?? 0
                buildings.append(SyntheticPhoto.Building(
                    from: normalizedAzimuth(az), width: width,
                    roof: (top + rise + 3 * rng.uniform(), top + rise + 3 * rng.uniform()), shade: UInt8(90 + rng.next() % 70)))
                az += width + gap * (0.7 + 0.6 * rng.uniform())
            }
        }

        var strip = SkylineStrip()
        var singles = 0, stitchedHere = 0
        var line = String(format: "%4d  %6.1f°  %3.0f°  %+6.2f°  %+.3f°/s ", run + 1, center, fov, compassError, drift)
        for i in 0..<frameCount {
            let t = Double(i) * interval
            let heading = normalizedAzimuth(center - pan / 2 + pan * Double(i) / Double(frameCount - 1))
            let truth = Attitude(heading: heading, pitch: basePitch + 0.5 * rng.gaussian(), roll: baseRoll + 0.5 * rng.gaussian())
            var realism = CameraRealism()
            if conditions.maxK1 > 0 { realism.k1 = conditions.maxK1 * (2 * extra.uniform() - 1) }
            if conditions.maxRollingShutter > 0 { realism.rollingShutter = conditions.maxRollingShutter * (2 * extra.uniform() - 1) }
            var frameScene = scene
            frameScene.seed = scene.seed &+ UInt64(i)
            let camera = Camera(intrinsics: k, attitude: truth)
            var photo = SyntheticPhoto.render(world, camera: camera, scene: frameScene, realism: realism)
            SyntheticPhoto.occlude(&photo, camera: camera, buildings: buildings, realism: realism)

            // What the sensors say: the compass off by its error plus this frame's wander,
            // pitch and roll a little off; the gyroscope's heading off by its drift.
            if let dir = args.string("save") {
                try saveImage(photo, to: "\(dir)/pan\(run + 1)-\(i + 1).\(defaultImageExtension)")
            }
            var prior = truth
            prior.heading = normalizedAzimuth(truth.heading + compassError + wander * rng.gaussian())
            prior.pitch += 0.4 * rng.gaussian()
            prior.roll += 0.4 * rng.gaussian()
            let gyroHeading = normalizedAzimuth(gyroZero + truth.heading + drift * t)

            var matcher = SkylineMatcher()
            matcher.settings.adapt(toHorizontalFOV: fov)
            if let range = args.double("heading-range") { matcher.settings.headingRange = range }
            let m = matcher.match(photo, intrinsics: k, prior: prior, horizon: horizon)
            singleSeconds.append(m.seconds)
            if m.alignment.accepted {
                singles += 1
                accepted.append(Accepted(error: azimuthDifference(m.alignment.attitude.heading, truth.heading), stitched: false))
                line += String(format: " S%+.2f", azimuthDifference(m.alignment.attitude.heading, truth.heading))
                strip.removeAll()
                continue
            }
            strip.add(SkylineStrip.Frame(skyline: m.skyline, camera: m.camera, time: t, gyroHeading: gyroHeading,
                                         position: believed, lens: "wide"))
            let stitching = Date()
            guard let r = strip.match(horizon: horizon, settings: matcher.settings) else {
                line += "  ."
                continue
            }
            stitchedTries += 1
            stitchedSeconds.append(Date().timeIntervalSince(stitching))
            if r.accepted {
                stitchedHere += 1
                let error = azimuthDifference(r.attitude.heading, truth.heading)
                accepted.append(Accepted(error: error, stitched: true))
                line += String(format: " M%+.2f", error) + "(\(strip.frames.count))"
                strip.removeAll()
            } else {
                stitchedRejections.append(r.rejectionReason ?? "?")
                line += "  x"
            }
        }
        if singles > 0 { singleSequences += 1 }
        if singles + stitchedHere > 0 { anySequences += 1 }
        print(line)
    }

    // Tables: what single frames alone get (today), and with the strip as well.
    let stats = errorStats
    let singleErrors = accepted.filter { !$0.stitched }.map(\.error)
    let stitchedErrors = accepted.filter(\.stitched).map(\.error)
    func row(_ name: String, _ e: [Double], sequences: Int?) -> String {
        let s = stats(e)
        let bad = e.filter { abs($0) > 0.5 }.count
        return "| \(name) | \(sequences.map { "\($0) of \(runs)" } ?? "") | \(e.count) | " +
            (e.isEmpty ? "– | – | – " : "\(f(s.median, 3))° | \(f(s.p90, 3))° | \(f(s.max, 3))° ") + "| \(bad) |\n"
    }
    let label = conditions.isDefault ? "" : "; " + conditions.label
    var md = "| Pan (\(frameCount) frames over \(f(pan, 0))°, occlusion \(occlusion)\(label)) | sequences matched | matches | " +
        "median error | 90th percentile | worst | over 0.5° |\n|---|---|---|---|---|---|---|\n"
    md += row("Single frames (today)", singleErrors, sequences: singleSequences)
    md += row("Stitched strips", stitchedErrors, sequences: nil)
    md += row("Both", singleErrors + stitchedErrors, sequences: anySequences)
    md += "\nStrips matched \(stitchedTries) times, \(stitchedErrors.count) accepted. "
    md += String(format: "Median time: %.0f ms a frame alone, %.0f ms a strip. ", stats(singleSeconds).median * 1000,
                 stats(stitchedSeconds).median * 1000)
    md += rejectionSummary(stitchedRejections).isEmpty ? "\n" : rejectionSummary(stitchedRejections)
    print("\nPer frame: S = accepted alone, M = accepted stitched (frames used), x = strip turned away, . = no strip to match.")
    print("\n" + md)
    if let path = args.string("markdown") {
        try md.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

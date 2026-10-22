import Foundation
import PeakCore

/// `peakbench base`: how far the base layer's skyline is from the full DEM's, by distance.
func baseCommand(_ args: Arguments) throws {
    guard let path = args.string("base") else { throw HarnessError("missing --base FILE.pkbase") }
    let base = try BaseLayer(contentsOf: URL(fileURLWithPath: path))
    let full = try loadTerrain(args.string("dem"))
    let lat = try args.required("lat"), lon = try args.required("lon")
    var settings = HorizonSettings()
    settings.maxDistance = (args.double("max-km") ?? 80) * 1000
    let coarse = Terrain(tiles: [], base: base, latitude: lat, longitude: lon, radius: settings.maxDistance + 10_000)

    let fullRenderer = HorizonRenderer(terrain: full), coarseRenderer = HorizonRenderer(terrain: coarse)
    let fullObserver = fullRenderer.observer(latitude: lat, longitude: lon)
    let coarseObserver = coarseRenderer.observer(latitude: lat, longitude: lon)
    print("Observer: \(f(lat, 5)), \(f(lon, 5)); ground \(f(fullObserver.height - 1.6, 0)) m in the DEM, " +
          "\(f(coarseObserver.height - 1.6, 0)) m in the base layer")
    let reference = timed("Full DEM horizon") { fullRenderer.render(from: fullObserver, settings: settings) }
    // The base layer's terrain alone (the eye at the right height, as the GPS altitude puts
    // it), and standing on its own ground, which the app avoids: kilometers of average.
    let sameEye = timed("Base layer horizon") { coarseRenderer.render(from: fullObserver, settings: settings) }
    let onCoarseGround = coarseRenderer.render(from: coarseObserver, settings: settings)

    let bands: [(String, ClosedRange<Double>)] = [
        ("0–5 km", 0...5_000), ("5–10 km", 5_000...10_000), ("10–20 km", 10_000...20_000),
        ("20–40 km", 20_000...40_000), ("40–80 km", 40_000...80_000), ("80+ km", 80_000...1e9), ("all", 0...1e9),
    ]
    func table(_ title: String, _ profile: HorizonProfile) -> String {
        var out = "\n\(title)\n\n| Skyline distance (full DEM) | Rays | Median \\|Δ\\| | 90th pct | Worst | Bias (median Δ) |\n"
        out += "|---|---:|---:|---:|---:|---:|\n"
        for (name, range) in bands {
            var diffs: [Double] = []
            for i in 0..<reference.count where range.contains(Double(reference.distances[i])) {
                diffs.append(Double(profile.elevations[i] - reference.elevations[i]))
            }
            guard !diffs.isEmpty else { continue }
            let abs = diffs.map { Swift.abs($0) }.sorted()
            let signed = diffs.sorted()
            out += "| \(name) | \(diffs.count) | \(f(abs[abs.count / 2], 2))° | \(f(abs[min(abs.count - 1, abs.count * 9 / 10)], 2))° " +
                   "| \(f(abs.last!, 2))° | \(f(signed[signed.count / 2], 2))° |\n"
        }
        return out
    }
    let report = "## Base layer vs full DEM at \(f(lat, 4)), \(f(lon, 4))\n" +
        "Skyline elevation angle, base layer minus full DEM, per 0.1° ray, by how far the full DEM's skyline is.\n" +
        table("Eye at the right height (the terrain's error)", sameEye) +
        table("Standing on the base layer's own ground (which the app avoids)", onCoarseGround)
    print(report)
    if let md = args.string("markdown") {
        try report.write(toFile: md, atomically: true, encoding: .utf8)
        print("Wrote \(md)")
    }
}

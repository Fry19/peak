import Dispatch
import Foundation

// Terrain that differs from the full-detail tiles, for testing matching honestly: the app
// matches against coarser, mixed-detail terrain, and the real world is not exactly the DEM.

/// How a "world" DEM is made to differ from the one matched against: the kinds of error a
/// real terrain model has relative to the ground (smoothed detail, height noise that is
/// correlated over hundreds of meters, a small misregistration).
public struct DEMPerturbation: Sendable, Equatable {
    /// Gaussian blur, standard deviation in pixels. 0: none.
    public var smoothing = 0.8
    /// Peak amplitude of the height noise, meters (it stays within about ±noise).
    public var noise = 5.0
    /// Size of the noise's largest features, meters.
    public var noiseScale = 400.0
    /// Shift of the whole terrain, meters east and north.
    public var shiftEast = 12.0
    public var shiftNorth = -9.0
    public var seed: UInt64 = 1

    public init() {}

    public init(smoothing: Double, noise: Double, noiseScale: Double = 400, shiftEast: Double, shiftNorth: Double, seed: UInt64 = 1) {
        self.smoothing = smoothing
        self.noise = noise
        self.noiseScale = noiseScale
        self.shiftEast = shiftEast
        self.shiftNorth = shiftNorth
        self.seed = seed
    }

    /// The height noise at a point, meters. Continuous across tiles, since it depends on the
    /// position only.
    public func noise(latitude: Double, longitude: Double) -> Double {
        guard noise > 0 else { return 0 }
        let x = longitude * 111_320 * cos(latitude * .pi / 180) / noiseScale
        let y = latitude * 111_320 / noiseScale
        // Fractal noise sits mostly within 0.5 ± 0.25.
        return max(-noise, min(noise, (fractalNoise(x, y, seed: seed) - 0.5) * 4 * noise))
    }
}

extension ElevationTile {
    /// The tile at a coarser level, as a GeoTIFF overview: each pixel the mean of `factor` ×
    /// `factor` pixels (those with data), centered on them. Level 1 of a Copernicus tile is
    /// `downsampled(by: 2)`, level 2 `downsampled(by: 4)`.
    public func downsampled(by factor: Int) -> ElevationTile {
        guard factor > 1 else { return self }
        let newRows = (rows + factor - 1) / factor, newCols = (cols + factor - 1) / factor
        var values = [Int16](repeating: Self.noData, count: newRows * newCols)
        for r in 0..<newRows {
            for c in 0..<newCols {
                var sum = 0, n = 0
                for rr in (r * factor)..<min(rows, (r + 1) * factor) {
                    for cc in (c * factor)..<min(cols, (c + 1) * factor) {
                        let v = heights[rr * cols + cc]
                        if v != Self.noData { sum += Int(v); n += 1 }
                    }
                }
                if n > 0 { values[r * newCols + c] = Int16((Double(sum) / Double(n)).rounded()) }
            }
        }
        let f = Double(factor)
        return ElevationTile(south: south, west: west, rows: newRows, cols: newCols,
                             originLatitude: originLatitude - (f - 1) * stepLatitude / 2,
                             originLongitude: originLongitude + (f - 1) * stepLongitude / 2,
                             stepLatitude: stepLatitude * f, stepLongitude: stepLongitude * f, heights: values)
    }

    /// The pixels within a box (degrees), as a patch over part of the cell; nil if the box
    /// misses the tile.
    public func cropped(south boxSouth: Double, north: Double, west boxWest: Double, east: Double) -> ElevationTile? {
        let r0 = max(0, Int(((originLatitude - north) / stepLatitude).rounded(.down)))
        let r1 = min(rows, Int(((originLatitude - boxSouth) / stepLatitude).rounded(.up)) + 1)
        let c0 = max(0, Int(((boxWest - originLongitude) / stepLongitude).rounded(.down)))
        let c1 = min(cols, Int(((east - originLongitude) / stepLongitude).rounded(.up)) + 1)
        guard r1 - r0 >= 2, c1 - c0 >= 2 else { return nil }
        var values = [Int16](repeating: 0, count: (r1 - r0) * (c1 - c0))
        for r in r0..<r1 {
            for c in c0..<c1 { values[(r - r0) * (c1 - c0) + c - c0] = heights[r * cols + c] }
        }
        return ElevationTile(south: south, west: west, rows: r1 - r0, cols: c1 - c0,
                             originLatitude: originLatitude - Double(r0) * stepLatitude,
                             originLongitude: originLongitude + Double(c0) * stepLongitude,
                             stepLatitude: stepLatitude, stepLongitude: stepLongitude, heights: values)
    }

    /// A copy blurred, with height noise added and shifted, as `perturbation` says. Pixels
    /// without data stay without data.
    public func perturbed(_ perturbation: DEMPerturbation) -> ElevationTile {
        let out = UnsafeMutableBufferPointer<Int16>.allocate(capacity: rows * cols)
        let sigma = perturbation.smoothing
        let reach = sigma > 0 ? Int((3 * sigma).rounded(.up)) : 0
        let kernel = (-reach...reach).map { sigma > 0 ? exp(-Double($0 * $0) / (2 * sigma * sigma)) : 1 }
        // Blur rows into a scratch grid of doubles, then columns from it.
        let across = UnsafeMutableBufferPointer<Double>.allocate(capacity: rows * cols)
        defer { across.deallocate() }
        let rows = self.rows, cols = self.cols, heights = self.heights
        let void = Self.noData
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            for c in 0..<cols {
                var sum = 0.0, weight = 0.0
                for k in -reach...reach {
                    let cc = c + k
                    guard cc >= 0, cc < cols else { continue }
                    let v = heights[r * cols + cc]
                    if v != void { sum += Double(v) * kernel[k + reach]; weight += kernel[k + reach] }
                }
                across[r * cols + c] = weight > 0 ? sum / weight : .nan
            }
        }
        // The shift moves the terrain: the pixel grid stays and the heights move with the origin.
        let lat0 = originLatitude + perturbation.shiftNorth / 111_320
        let lon0 = originLongitude + perturbation.shiftEast / (111_320 * cos(Double(south) * .pi / 180 + .pi / 360))
        let stepLat = stepLatitude, stepLon = stepLongitude
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            let lat = lat0 - Double(r) * stepLat
            for c in 0..<cols {
                if heights[r * cols + c] == void { out[r * cols + c] = void; continue }
                var sum = 0.0, weight = 0.0
                for k in -reach...reach {
                    let rr = r + k
                    guard rr >= 0, rr < rows else { continue }
                    let v = across[rr * cols + c]
                    if !v.isNaN { sum += v * kernel[k + reach]; weight += kernel[k + reach] }
                }
                let h = sum / weight + perturbation.noise(latitude: lat, longitude: lon0 + Double(c) * stepLon)
                out[r * cols + c] = Int16(max(-32767, min(32767, h.rounded())))
            }
        }
        return ElevationTile(south: south, west: west, rows: rows, cols: cols, originLatitude: lat0, originLongitude: lon0,
                             stepLatitude: stepLatitude, stepLongitude: stepLongitude, taking: out)
    }
}

extension Terrain {
    /// The terrain as the app holds it around a point, made from full-detail (30 m) tiles:
    /// every tile at level 2 (120 m), with level 1 (60 m) within `mediumRadius` and full
    /// detail within `fullRadius` meters laid over it as patches. The app fetches patches
    /// block by block, so its patches reach a little further; this is the least it has.
    public static func appDetail(from tiles: [ElevationTile], latitude: Double, longitude: Double,
                                 fullRadius: Double = 10_000, mediumRadius: Double = 35_000) -> Terrain {
        var detail: [ElevationTile] = []
        for (factor, radius) in [(1, fullRadius), (2, mediumRadius)] {
            let dlat = radius / 111_000, dlon = radius / (111_000 * max(cos(latitude * .pi / 180), 0.05))
            for tile in tiles {
                if let patch = tile.cropped(south: latitude - dlat, north: latitude + dlat,
                                            west: longitude - dlon, east: longitude + dlon) {
                    detail.append(factor == 1 ? patch : patch.downsampled(by: factor))
                }
            }
        }
        return Terrain(tiles: tiles.map { $0.downsampled(by: 4) }, detail: detail)
    }
}

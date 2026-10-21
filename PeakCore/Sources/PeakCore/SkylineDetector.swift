import Foundation

/// The detected boundary between sky and terrain, one point per image column.
public struct Skyline: Sendable {
    public let width: Int
    public let height: Int
    /// Boundary y for each column, in pixels from the top edge (row r's top edge is y = r).
    /// NaN where no trustworthy boundary was found.
    public var rows: [Float]
    /// Edge contrast at the boundary, 0...1.
    public var strength: [Float]

    public var validCount: Int { rows.reduce(0) { $1.isNaN ? $0 : $0 + 1 } }
    public var validFraction: Double { Double(validCount) / Double(max(width, 1)) }

    /// Pixel coordinates (x at column centers) of the valid points.
    public var points: [(x: Double, y: Double, weight: Double)] {
        (0..<width).compactMap { c in
            rows[c].isNaN ? nil : (Double(c) + 0.5, Double(rows[c]), Double(strength[c]))
        }
    }
}

/// Finds the skyline with a simple, model-free heuristic: sky and terrain color models
/// learned from the image itself, and a dynamic-programming path across the columns that
/// best separates them along a strong edge. Meant to be replaced by a small segmentation
/// model; it is good enough to test alignment against.
public struct SkylineDetector: Sendable {
    public var iterations = 3
    /// How much a strong edge counts relative to the per-pixel sky/terrain evidence.
    public var edgeWeight: Float = 12
    /// Cost per pixel of vertical jump between neighboring columns.
    public var smoothness: Float = 0.25
    /// Columns whose boundary contrast is below this are dropped.
    public var minStrength: Float = 0.08
    /// Columns where the "sky" just above the boundary is busier than this are dropped
    /// (texture is 4× the mean luminance gradient; clean sky is near 0.1).
    public var maxSkyTexture: Float = 0.3

    public init() {}

    public func detect(in image: RGBImage) -> Skyline {
        let w = image.width, h = image.height
        let f = Features(image)

        // First guess: the first strong edge down each column, smoothed across columns.
        var boundary = firstStrongEdges(f)
        var llr = [Float](repeating: 0, count: w * h)
        var sky = SkyModel(f, boundary: boundary)
        var ground = ColorModel.fit(f, components: 3) { x, y in y >= boundary[x] + max(2, h / 60) }

        for iteration in 0..<iterations {
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let v = sky.logLikelihood(f, x, y) - ground.logLikelihood(f, i)
                    llr[i] = max(-4, min(4, v))
                }
            }
            boundary = bestPath(llr: llr, edges: f.edges, width: w, height: h)
            if iteration + 1 < iterations {
                let b = boundary
                sky = SkyModel(f, boundary: b)
                ground = ColorModel.fit(f, components: 3) { x, y in y >= b[x] + max(2, h / 60) }
            }
        }

        // Sub-pixel edge position and per-column trust.
        var rows = [Float](repeating: .nan, count: w)
        var strength = [Float](repeating: 0, count: w)
        let band = max(3, h / 40)
        for x in 0..<w {
            let r = boundary[x]
            guard r > 1, r < h - 1 else { continue }
            // Refine on the uncapped edge, which peaks where the color step is steepest.
            let raw = f.rawEdges
            var bestY = r, bestE: Float = -1
            for y in max(1, r - 2)...min(h - 2, r + 2) where raw[y * w + x] > bestE {
                bestE = raw[y * w + x]
                bestY = y
            }
            let e0 = raw[(bestY - 1) * w + x], e1 = bestE, e2 = raw[(bestY + 1) * w + x]
            let denom = e0 - 2 * e1 + e2
            let offset = denom < 0 ? max(-0.5, min(0.5, 0.5 * (e0 - e2) / denom)) : 0
            // The evidence just above should look like sky and just below like terrain.
            // Sky is also smooth: real sky has little texture right above the skyline.
            // And it is blue or neutral gray, never brown or green.
            var above: Float = 0, below: Float = 0, texture: Float = 0, warmth: Float = 0
            for k in 1...band {
                let yAbove = max(0, r - k - 1)
                above += llr[yAbove * w + x]
                below += llr[min(h - 1, r + k - 1) * w + x]
                let i = 4 * (yAbove * w + x)
                texture += f.values[i + 3]
                warmth += max(f.values[i], f.values[i + 1]) - f.values[i + 2]
            }
            let n = Float(band)
            strength[x] = f.edges[bestY * w + x]
            if strength[x] >= minStrength, above > 0, below < 0, texture / n < maxSkyTexture, warmth / n < 0.04 {
                rows[x] = Float(bestY) + offset
            }
        }
        return Skyline(width: w, height: h, rows: rows, strength: strength)
    }

    /// For each column, the first row from the top with a clear color step, median-filtered
    /// across columns so that stray edges (birds, cloud wisps) don't matter.
    func firstStrongEdges(_ f: Features) -> [Int] {
        let w = f.width, h = f.height
        var first = [Int](repeating: h * 2 / 3, count: w)
        for x in 0..<w {
            for y in 3..<(h - 3) where f.edges[y * w + x] >= 0.25 {
                first[x] = y
                break
            }
        }
        let radius = max(3, w / 60)
        return (0..<w).map { x in
            let window = first[max(0, x - radius)...min(w - 1, x + radius)].sorted()
            return window[window.count / 2]
        }
    }

    /// Boundary row for every column maximizing sky-above/terrain-below evidence plus edge
    /// strength, minus a smoothness cost. Row r means rows 0..<r are sky.
    func bestPath(llr: [Float], edges: [Float], width w: Int, height h: Int) -> [Int] {
        let n = h + 1
        var score = [Float](repeating: 0, count: n)
        var prev = [Float](repeating: 0, count: n)
        var best = [Float](repeating: 0, count: n)
        var from = [Int32](repeating: 0, count: n)
        var back = [Int32](repeating: 0, count: w * n)
        let lambda = smoothness

        for x in 0..<w {
            // score(r) = Σ_{y<r} llr − Σ_{y≥r} llr + edge term.
            var total: Float = 0
            for y in 0..<h { total += llr[y * w + x] }
            var above: Float = 0
            for r in 0...h {
                let edge = r > 0 && r < h ? edges[r * w + x] : 0
                score[r] = 2 * above - total + edgeWeight * edge
                if r < h { above += llr[r * w + x] }
            }
            if x == 0 {
                prev = score
                continue
            }
            // best(r) = max_r' prev(r') − λ|r − r'|, in two linear passes.
            for r in 0..<n {
                best[r] = prev[r]
                from[r] = Int32(r)
                if r > 0, best[r - 1] - lambda > best[r] {
                    best[r] = best[r - 1] - lambda
                    from[r] = from[r - 1]
                }
            }
            for r in stride(from: n - 2, through: 0, by: -1) where best[r + 1] - lambda > best[r] {
                best[r] = best[r + 1] - lambda
                from[r] = from[r + 1]
            }
            for r in 0..<n {
                prev[r] = score[r] + best[r]
                back[x * n + r] = from[r]
            }
        }
        var r = prev.indices.max { prev[$0] < prev[$1] } ?? h / 2
        var path = [Int](repeating: 0, count: w)
        for x in stride(from: w - 1, through: 0, by: -1) {
            path[x] = r
            if x > 0 { r = Int(back[x * n + r]) }
        }
        return path
    }
}

/// Per-pixel features: color, local texture, and vertical edge strength.
struct Features {
    let width: Int
    let height: Int
    /// rgb in 0...1 and texture, interleaved (4 per pixel).
    var values: [Float]
    /// Vertical color step at the top of each row, in color units (0...√3).
    var rawEdges: [Float]
    /// The same, scaled so that a clear sky-to-rock step is 1, and capped there.
    var edges: [Float]

    init(_ image: RGBImage) {
        let w = image.width, h = image.height
        width = w
        height = h
        var rgb = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h * 3) { rgb[i] = Float(image.pixels[i]) / 255 }

        // Blur each channel horizontally a little so single noisy pixels don't make edges.
        var blurred = rgb
        for y in 0..<h {
            for x in 0..<w {
                for ch in 0..<3 {
                    var s: Float = 0, n: Float = 0
                    for dx in -1...1 where x + dx >= 0 && x + dx < w {
                        s += rgb[3 * (y * w + x + dx) + ch]
                        n += 1
                    }
                    blurred[3 * (y * w + x) + ch] = s / n
                }
            }
        }

        // Texture: local mean absolute luminance gradient over a 5×5 window.
        var lum = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { lum[i] = 0.299 * rgb[3 * i] + 0.587 * rgb[3 * i + 1] + 0.114 * rgb[3 * i + 2] }
        var grad = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let gx = x + 1 < w ? abs(lum[i + 1] - lum[i]) : 0
                let gy = y + 1 < h ? abs(lum[i + w] - lum[i]) : 0
                grad[i] = gx + gy
            }
        }
        let texture = boxBlur(grad, width: w, height: h, radius: 2)

        values = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            values[4 * i] = rgb[3 * i]
            values[4 * i + 1] = rgb[3 * i + 1]
            values[4 * i + 2] = rgb[3 * i + 2]
            values[4 * i + 3] = min(1, texture[i] * 4)
        }

        // Edge at the top of row y: color difference between the 3 rows above and the 3 below.
        var e = [Float](repeating: 0, count: w * h)
        let k = 3
        for x in 0..<w {
            for y in k..<(h - k + 1) {
                var d2: Float = 0
                for ch in 0..<3 {
                    var a: Float = 0, b: Float = 0
                    for j in 1...k {
                        a += blurred[3 * ((y - j) * w + x) + ch]
                        b += blurred[3 * ((y + j - 1) * w + x) + ch]
                    }
                    let diff = (a - b) / Float(k)
                    d2 += diff * diff
                }
                e[y * w + x] = d2.squareRoot()
            }
        }
        // A fixed scale: 0.2 is a clear sky-to-rock step; sensor noise averages to ~0.005.
        rawEdges = e
        edges = e.map { min(1, $0 / 0.2) }
    }
}

func boxBlur(_ v: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
    var tmp = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        var s: Float = 0
        for x in -r...r { s += v[y * w + max(0, min(w - 1, x))] }
        for x in 0..<w {
            tmp[y * w + x] = s / Float(2 * r + 1)
            s += v[y * w + min(w - 1, x + r + 1)] - v[y * w + max(0, x - r)]
        }
    }
    var out = [Float](repeating: 0, count: w * h)
    for x in 0..<w {
        var s: Float = 0
        for y in -r...r { s += tmp[max(0, min(h - 1, y)) * w + x] }
        for y in 0..<h {
            out[y * w + x] = s / Float(2 * r + 1)
            s += tmp[min(h - 1, y + r + 1) * w + x] - tmp[max(0, y - r) * w + x]
        }
    }
    return out
}

/// Clear sky changes color smoothly across the frame (deep blue overhead, pale at the
/// horizon), so it is modeled as a smooth color surface over the image plus low texture.
/// A small mixture on top covers clouds.
struct SkyModel {
    /// Per channel: coefficients of 1, y, y², x (y and x scaled to the image).
    var coefficients: [[Double]] = []
    var invVar = SIMD4<Float>(repeating: 1)
    var logNorm: Float = 0
    var clouds: ColorModel

    init(_ f: Features, boundary: [Int]) {
        let w = f.width, h = f.height
        let margin = max(2, h / 60)
        clouds = ColorModel.fit(f, components: 2) { x, y in y < boundary[x] - margin }

        var rows: [[Double]] = []
        var values: [SIMD4<Float>] = []
        let stride = max(1, Int((Double(w * h) / 30_000).squareRoot()))
        for y in Swift.stride(from: 0, to: h, by: stride) {
            for x in Swift.stride(from: 0, to: w, by: stride) where y < boundary[x] - margin {
                let i = 4 * (y * w + x)
                rows.append(Self.basis(x, y, w, h))
                values.append(SIMD4(f.values[i], f.values[i + 1], f.values[i + 2], f.values[i + 3]))
            }
        }
        guard rows.count >= 20 else {
            coefficients = [[0.6, 0, 0, 0], [0.7, 0, 0, 0], [0.85, 0, 0, 0]]
            invVar = SIMD4(repeating: 10)
            return
        }
        // Least squares per channel.
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for r in rows { for a in 0..<4 { for b in 0..<4 { ata[a][b] += r[a] * r[b] } } }
        for a in 0..<4 { ata[a][a] += 1e-6 }
        for ch in 0..<3 {
            var atb = [Double](repeating: 0, count: 4)
            for (r, v) in zip(rows, values) { for a in 0..<4 { atb[a] += r[a] * Double(v[ch]) } }
            coefficients.append(solve(ata, atb) ?? [Double(values[0][ch]), 0, 0, 0])
        }
        // Spread of the residuals, and of the texture, with floors so a perfectly clean
        // synthetic sky doesn't make the model brittle.
        var sum = SIMD4<Float>(repeating: 0)
        for (r, v) in zip(rows, values) {
            var d = SIMD4<Float>(0, 0, 0, v[3])
            for ch in 0..<3 { d[ch] = v[ch] - Float(zip(coefficients[ch], r).reduce(0) { $0 + $1.0 * $1.1 }) }
            sum += d * d
        }
        let variance = sum / Float(rows.count) + SIMD4(0.0004, 0.0004, 0.0004, 0.0009)
        invVar = 1 / variance
        logNorm = -0.5 * (log(variance.x) + log(variance.y) + log(variance.z) + log(variance.w))
    }

    static func basis(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [Double] {
        let yn = Double(y) / Double(h), xn = Double(x) / Double(w) - 0.5
        return [1, yn, yn * yn, xn]
    }

    @inline(__always)
    func logLikelihood(_ f: Features, _ x: Int, _ y: Int) -> Float {
        let i = y * f.width + x
        let yn = Double(y) / Double(f.height), xn = Double(x) / Double(f.width) - 0.5
        var d = SIMD4<Float>(0, 0, 0, f.values[4 * i + 3])
        for ch in 0..<3 {
            let c = coefficients[ch]
            d[ch] = f.values[4 * i + ch] - Float(c[0] + c[1] * yn + c[2] * yn * yn + c[3] * xn)
        }
        let smooth = logNorm - 0.5 * (d * d * invVar).sum()
        return max(smooth, clouds.logLikelihood(f, i))
    }
}

/// A small mixture of diagonal Gaussians over the 4 features, fitted with k-means.
struct ColorModel {
    struct Component {
        var mean: SIMD4<Float>
        var invVar: SIMD4<Float>
        var logNorm: Float
    }
    var components: [Component]

    static func fit(_ f: Features, components k: Int, where include: (Int, Int) -> Bool) -> ColorModel {
        // Subsample for speed.
        var samples: [SIMD4<Float>] = []
        let stride = max(1, Int((Double(f.width * f.height) / 20_000).squareRoot()))
        for y in Swift.stride(from: 0, to: f.height, by: stride) {
            for x in Swift.stride(from: 0, to: f.width, by: stride) where include(x, y) {
                let i = 4 * (y * f.width + x)
                samples.append(SIMD4(f.values[i], f.values[i + 1], f.values[i + 2], f.values[i + 3]))
            }
        }
        if samples.count < 10 * k {
            // Not enough pixels: a broad model that says little either way.
            return ColorModel(components: [Component(mean: SIMD4(repeating: 0.5), invVar: SIMD4(repeating: 4),
                                                     logNorm: 0)])
        }
        // Deterministic k-means seeds spread over luminance.
        func brightness(_ v: SIMD4<Float>) -> Float { v.x + v.y + v.z }
        let byLum = samples.sorted { brightness($0) < brightness($1) }
        var means: [SIMD4<Float>] = (0..<k).map { byLum[(2 * $0 + 1) * byLum.count / (2 * k)] }
        var assign = [Int](repeating: 0, count: samples.count)
        for _ in 0..<8 {
            for (i, s) in samples.enumerated() {
                var best = 0, bestD = Float.infinity
                for (j, m) in means.enumerated() {
                    let d = ((s - m) * (s - m)).sum()
                    if d < bestD { bestD = d; best = j }
                }
                assign[i] = best
            }
            for j in 0..<k {
                var sum = SIMD4<Float>(repeating: 0), n: Float = 0
                for (i, s) in samples.enumerated() where assign[i] == j { sum += s; n += 1 }
                if n > 0 { means[j] = sum / n }
            }
        }
        var comps: [Component] = []
        for j in 0..<k {
            var sum = SIMD4<Float>(repeating: 0), n: Float = 0
            for (i, s) in samples.enumerated() where assign[i] == j {
                let d = s - means[j]
                sum += d * d
                n += 1
            }
            guard n >= 5 else { continue }
            let variance = sum / n + SIMD4(repeating: 0.002)
            let weight = n / Float(samples.count)
            let logDet = log(variance.x) + log(variance.y) + log(variance.z) + log(variance.w)
            comps.append(Component(mean: means[j], invVar: 1 / variance, logNorm: log(weight) - 0.5 * logDet))
        }
        return ColorModel(components: comps)
    }

    @inline(__always)
    func logLikelihood(_ f: Features, _ i: Int) -> Float {
        let v = SIMD4(f.values[4 * i], f.values[4 * i + 1], f.values[4 * i + 2], f.values[4 * i + 3])
        var best = -Float.infinity
        for c in components {
            let d = v - c.mean
            let l = c.logNorm - 0.5 * (d * d * c.invVar).sum()
            if l > best { best = l }
        }
        return best
    }
}

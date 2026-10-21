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
    /// For each column, a fainter edge above the boundary with sky over it, where there is
    /// one (NaN otherwise). Far ranges fade into haze, so a nearer, sharper ridge in front
    /// can take the boundary; the real skyline may be this one.
    public var upperRows: [Float]
    public var upperStrength: [Float]

    public init(width: Int, height: Int, rows: [Float], strength: [Float], upperRows: [Float]? = nil,
                upperStrength: [Float]? = nil) {
        self.width = width
        self.height = height
        self.rows = rows
        self.strength = strength
        self.upperRows = upperRows ?? [Float](repeating: .nan, count: width)
        self.upperStrength = upperStrength ?? [Float](repeating: 0, count: width)
    }

    public var validCount: Int { rows.reduce(0) { $1.isNaN ? $0 : $0 + 1 } }
    public var validFraction: Double { Double(validCount) / Double(max(width, 1)) }

    /// Pixel coordinates (x at column centers) of the valid points.
    public var points: [(x: Double, y: Double, weight: Double)] {
        (0..<width).compactMap { c in
            rows[c].isNaN ? nil : (Double(c) + 0.5, Double(rows[c]), Double(strength[c]))
        }
    }

    /// Each column's candidates for the skyline, topmost first: the fainter edge above the
    /// boundary and the boundary, or either alone. Weighed by the boundary's contrast (the
    /// upper edge's when it stands alone).
    public var candidates: [(x: Double, ys: [Double], weight: Double)] {
        (0..<width).compactMap { c in
            let ys = [upperRows[c], rows[c]].filter { !$0.isNaN }.map(Double.init)
            guard !ys.isEmpty else { return nil }
            return (Double(c) + 0.5, ys, Double(rows[c].isNaN ? upperStrength[c] : strength[c]))
        }
    }

    /// Fraction of columns with any candidate.
    public var candidateFraction: Double {
        Double((0..<width).filter { !rows[$0].isNaN || !upperRows[$0].isNaN }.count) / Double(max(width, 1))
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
    /// Contrast an edge above the boundary needs to be a candidate: well clear of the sky's
    /// own gradient and noise, though a hazy far ridge's step is often well under a near one's.
    public var minUpperStrength: Float = 0.35
    /// Columns where the "sky" just above the boundary is busier than this are dropped
    /// (texture is 4× the mean luminance gradient; clean sky is near 0.1).
    public var maxSkyTexture: Float = 0.3

    public init() {}

    /// Finds the skyline. `band`, when given, holds for each column the boundary rows the
    /// skyline may be at (row r: the rows above r are sky): where the terrain's skyline can
    /// appear. Sky seen past things above it (eaves, blinds, a porch roof) then can't pull
    /// the skyline up to them, and the sky is learned from what's just above the band.
    public func detect(in image: RGBImage, band: [ClosedRange<Int>]? = nil) -> Skyline {
        let w = image.width, h = image.height
        let f = Features(image)
        let band = band.flatMap { $0.count == w ? $0.map { max(0, min(h, $0.lowerBound))...max(0, min(h, $0.upperBound)) } : nil }

        // First guess: the first strong edge down each column, smoothed across columns.
        var boundary = firstStrongEdges(f, band: band)
        var llr = [Float](repeating: 0, count: w * h)
        var sky = SkyModel(f, boundary: boundary, band: band)
        var ground = ColorModel.fit(f, components: 3) { x, y in y >= boundary[x] + max(2, h / 60) }

        for iteration in 0..<iterations {
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let v = sky.logLikelihood(f, x, y) - ground.logLikelihood(f, i)
                    llr[i] = max(-4, min(4, v))
                }
            }
            boundary = bestPath(llr: llr, edges: f.edges, width: w, height: h, band: band)
            if iteration + 1 < iterations {
                let b = boundary
                sky = SkyModel(f, boundary: b, band: band)
                ground = ColorModel.fit(f, components: 3) { x, y in y >= b[x] + max(2, h / 60) }
            }
        }

        // Sub-pixel edge position and per-column trust.
        var rows = [Float](repeating: .nan, count: w)
        var strength = [Float](repeating: 0, count: w)
        let rim = max(3, h / 40)
        let raw = f.rawEdges
        // The edge's peak near row r, to a fraction of a pixel: the uncapped edge peaks where
        // the color step is steepest.
        func peak(_ x: Int, near r: Int, reach: Int) -> (row: Int, offset: Float) {
            var bestY = r, bestE: Float = -1
            for y in max(1, r - reach)...min(h - 2, r + reach) where raw[y * w + x] > bestE {
                bestE = raw[y * w + x]
                bestY = y
            }
            let e0 = raw[(bestY - 1) * w + x], e1 = bestE, e2 = raw[(bestY + 1) * w + x]
            let denom = e0 - 2 * e1 + e2
            return (bestY, denom < 0 ? max(-0.5, min(0.5, 0.5 * (e0 - e2) / denom)) : 0)
        }
        // Whether what's just above row r looks like sky: sky by the color models, and smooth,
        // since real sky has little texture right above the skyline. And blue or neutral
        // gray, never brown or green, except low sun turns it orange near the horizon, where
        // it stays bright.
        func skyAbove(_ x: Int, _ r: Int) -> Bool {
            var above: Float = 0, texture: Float = 0, warmth: Float = 0, light: Float = 0
            for k in 1...rim {
                let yAbove = max(0, r - k - 1)
                above += llr[yAbove * w + x]
                let i = 4 * (yAbove * w + x)
                texture += f.values[i + 3]
                warmth += max(f.values[i], f.values[i + 1]) - f.values[i + 2]
                light += (f.values[i] + f.values[i + 1] + f.values[i + 2]) / 3
            }
            let n = Float(rim)
            return above > 0 && texture / n < maxSkyTexture && (warmth / n < 0.04 || light / n > 0.6)
        }
        for x in 0..<w {
            let r = boundary[x]
            guard r > 1, r < h - 1 else { continue }
            let (bestY, offset) = peak(x, near: r, reach: 2)
            // Just below should look like terrain.
            var below: Float = 0
            for k in 1...rim { below += llr[min(h - 1, r + k - 1) * w + x] }
            strength[x] = f.edges[bestY * w + x]
            if strength[x] >= minStrength, below < 0, skyAbove(x, r) {
                rows[x] = Float(bestY) + offset
            }
        }

        // The topmost clear edge above the boundary with sky over it, if any.
        var upperRows = [Float](repeating: .nan, count: w)
        var upperStrength = [Float](repeating: 0, count: w)
        for x in 0..<w {
            let r = boundary[x]
            let top = max(rim + 2, band?[x].lowerBound ?? 0)
            guard top < r - 3 else { continue }
            for y in top..<(r - 3) {
                let e = raw[y * w + x]
                guard f.edges[y * w + x] >= minUpperStrength, e >= raw[(y - 1) * w + x], e >= raw[(y + 1) * w + x],
                      skyAbove(x, y) else { continue }
                let (row, offset) = peak(x, near: y, reach: 1)
                upperRows[x] = Float(row) + offset
                upperStrength[x] = f.edges[row * w + x]
                break
            }
        }
        return Skyline(width: w, height: h, rows: rows, strength: strength, upperRows: upperRows,
                       upperStrength: upperStrength)
    }

    /// For each column, the first row from the top with a clear color step, median-filtered
    /// across columns so that stray edges (birds, cloud wisps) don't matter.
    func firstStrongEdges(_ f: Features, band: [ClosedRange<Int>]? = nil) -> [Int] {
        let w = f.width, h = f.height
        var first = [Int](repeating: h * 2 / 3, count: w)
        for x in 0..<w {
            let low = max(3, band?[x].lowerBound ?? 3), high = min(h - 4, band?[x].upperBound ?? h - 4)
            if let band { first[x] = (band[x].lowerBound + band[x].upperBound) / 2 }
            guard low <= high else { continue }
            for y in low...high where f.edges[y * w + x] >= 0.25 {
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
    func bestPath(llr: [Float], edges: [Float], width w: Int, height h: Int, band: [ClosedRange<Int>]? = nil) -> [Int] {
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
            if let band {
                for r in 0...h where !band[x].contains(r) { score[r] = -1e9 }
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

    /// Learned from the pixels above `boundary`; with a `band`, only from those within it
    /// (when there are enough), the sky right above where the skyline can be.
    init(_ f: Features, boundary: [Int], band: [ClosedRange<Int>]? = nil) {
        let w = f.width, h = f.height
        let margin = max(2, h / 60)
        let stride = max(1, Int((Double(w * h) / 30_000).squareRoot()))
        func isSky(_ x: Int, _ y: Int, inBand: Bool) -> Bool {
            y < boundary[x] - margin && (!inBand || y >= band![x].lowerBound)
        }
        var inBand = false
        if let band {
            var n = 0
            for y in Swift.stride(from: 0, to: h, by: stride) {
                for x in Swift.stride(from: 0, to: w, by: stride) where y < boundary[x] - margin && y >= band[x].lowerBound { n += 1 }
            }
            inBand = n >= 200
        }
        clouds = ColorModel.fit(f, components: 2) { x, y in isSky(x, y, inBand: inBand) }

        var rows: [[Double]] = []
        var values: [SIMD4<Float>] = []
        for y in Swift.stride(from: 0, to: h, by: stride) {
            for x in Swift.stride(from: 0, to: w, by: stride) where isSky(x, y, inBand: inBand) {
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

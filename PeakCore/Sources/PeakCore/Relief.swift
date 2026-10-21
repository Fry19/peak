import Dispatch
import Foundation

/// A flat map around a center point, north up: x meters east and y meters north of it.
/// Over the few tens of kilometers a map shows, the stretch this leaves is far below a
/// pixel.
public struct MapProjection: Sendable {
    public let center: LatLon
    let metersPerDegreeLatitude: Double
    let metersPerDegreeLongitude: Double

    public init(center: LatLon) {
        self.center = center
        let phi = center.latitude * .pi / 180
        metersPerDegreeLatitude = WGS84.meridionalRadius(latitude: phi) * .pi / 180
        metersPerDegreeLongitude = max(1, WGS84.primeVerticalRadius(latitude: phi) * cos(phi) * .pi / 180)
    }

    public func point(_ p: LatLon) -> SIMD2<Double> {
        SIMD2((p.longitude - center.longitude) * metersPerDegreeLongitude,
              (p.latitude - center.latitude) * metersPerDegreeLatitude)
    }

    public func latLon(_ p: SIMD2<Double>) -> LatLon {
        LatLon(center.latitude + p.y / metersPerDegreeLatitude, center.longitude + p.x / metersPerDegreeLongitude)
    }
}

/// A map area: its center and size in meters.
public struct MapExtent: Sendable, Equatable {
    public var center: LatLon
    public var width: Double
    public var height: Double

    public init(center: LatLon, width: Double, height: Double) {
        self.center = center
        self.width = width
        self.height = height
    }

    /// The smallest area holding all `points`, widened by `padding` (a share of its size)
    /// on each side and to at least `minimumSize` meters each way.
    public static func around(_ points: [LatLon], padding: Double = 0.15, minimumSize: Double = 1_000) -> MapExtent? {
        guard let first = points.first else { return nil }
        let projection = MapProjection(center: first)
        let xy = points.map { projection.point($0) }
        let low = xy.reduce(xy[0]) { pointwiseMin($0, $1) }, high = xy.reduce(xy[0]) { pointwiseMax($0, $1) }
        let size = high - low
        return MapExtent(center: projection.latLon((low + high) / 2),
                         width: max(minimumSize, size.x * (1 + 2 * padding)),
                         height: max(minimumSize, size.y * (1 + 2 * padding)))
    }
}

/// The crest of a ridge seen from above, as a line on a `ReliefMap`.
public struct CrestLine: Sendable {
    /// Map positions in meters (x east, y north of the map's center).
    public var points: [SIMD2<Double>]
    /// How far the ground falls away on the crest's lower side, meters, averaged along the
    /// line: a few tens of meters for a spur, hundreds for a main ridge.
    public var relief: Double
    /// Mean height of the crest, meters.
    public var height: Double
}

/// Terrain seen from straight above, north up, sampled on a square grid in meters: its
/// heights, a hillshade and the crests of its ridges, for drawing a map.
public struct ReliefMap: Sendable {
    public let projection: MapProjection
    /// Grid spacing, meters.
    public let cellSize: Double
    public let rows: Int
    public let cols: Int
    /// Heights row by row from the north, NaN where there's no terrain.
    public let heights: [Float]

    /// Samples `terrain` over `extent` every `cellSize` meters.
    public init(terrain: Terrain, extent: MapExtent, cellSize: Double) {
        projection = MapProjection(center: extent.center)
        self.cellSize = cellSize
        cols = max(3, Int((extent.width / cellSize).rounded(.up)) + 1)
        rows = max(3, Int((extent.height / cellSize).rounded(.up)) + 1)
        var heights = [Float](repeating: .nan, count: rows * cols)
        let projection = self.projection, rows = self.rows, cols = self.cols
        let x0 = -Double(cols - 1) / 2 * cellSize, y0 = Double(rows - 1) / 2 * cellSize
        heights.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: rows) { r in
                for c in 0..<cols {
                    let p = projection.latLon(SIMD2(x0 + Double(c) * cellSize, y0 - Double(r) * cellSize))
                    out[r * cols + c] = Float(terrain.height(latitude: p.latitude, longitude: p.longitude))
                }
            }
        }
        self.heights = heights
    }

    /// A grid of given heights (row by row from the north), for tests.
    public init(center: LatLon, cellSize: Double, rows: Int, cols: Int, heights: [Float]) {
        precondition(heights.count == rows * cols)
        projection = MapProjection(center: center)
        self.cellSize = cellSize
        self.rows = rows
        self.cols = cols
        self.heights = heights
    }

    /// Map position of a grid point, meters.
    public func position(row: Double, col: Double) -> SIMD2<Double> {
        SIMD2((col - Double(cols - 1) / 2) * cellSize, (Double(rows - 1) / 2 - row) * cellSize)
    }

    /// The map area the grid covers, from the first grid point to the last.
    public var size: SIMD2<Double> { SIMD2(Double(cols - 1), Double(rows - 1)) * cellSize }

    @inline(__always)
    func h(_ r: Int, _ c: Int) -> Float { heights[r * cols + c] }

    // MARK: Hillshade

    /// How brightly each grid point is lit, 0 to 1 (NaN without terrain), by a light from
    /// `azimuth` degrees (the usual north-west) at `altitude` degrees above the horizon.
    /// Flat ground gets sin(altitude). Slopes are made `exaggeration` times steeper first,
    /// so gentle relief still shows.
    public func hillshade(azimuth: Double = 315, altitude: Double = 45, exaggeration: Double = 1) -> [Float] {
        let az = azimuth * .pi / 180, alt = altitude * .pi / 180
        let light = SIMD3(sin(az) * cos(alt), cos(az) * cos(alt), sin(alt))
        var shade = [Float](repeating: .nan, count: rows * cols)
        let rows = self.rows, cols = self.cols, scale = exaggeration / (8 * cellSize)
        shade.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: rows) { r in
                let n = max(0, r - 1), s = min(rows - 1, r + 1)
                for c in 0..<cols {
                    guard h(r, c).isFinite else { continue }
                    let w = max(0, c - 1), e = min(cols - 1, c + 1)
                    // Horn's method; a missing neighbor takes the center's height.
                    func z(_ rr: Int, _ cc: Int) -> Double {
                        let v = h(rr, cc)
                        return Double(v.isFinite ? v : h(r, c))
                    }
                    let dx = (z(n, e) + 2 * z(r, e) + z(s, e)) - (z(n, w) + 2 * z(r, w) + z(s, w))
                    let dy = (z(n, w) + 2 * z(n, c) + z(n, e)) - (z(s, w) + 2 * z(s, c) + z(s, e))
                    // Edges have neighbors on one side only: scale up to the full span.
                    let normal = SIMD3(-dx * scale * 2 / Double(e - w), -dy * scale * 2 / Double(s - n), 1)
                    let lit = (normal * light).sum() / (normal * normal).sum().squareRoot()
                    out[r * cols + c] = Float(max(0, lit))
                }
            }
        }
        return shade
    }

    // MARK: Crests

    /// The crests of the ridges: grid points higher than their neighbors across the ridge,
    /// with the ground falling away at least `minSlope` (rise over run) on both sides and
    /// by at least `minRelief` meters within `reach` meters, traced into lines. Lines
    /// shorter than `minLength` meters, or whose mean relief is under `minRelief`, are left
    /// out. The lines are smoothed, so they don't follow the grid's staircase.
    public func crestLines(minSlope: Double = 0.15, minRelief: Double = 40, reach: Double = 600,
                           minLength: Double = 300) -> [CrestLine] {
        var relief = crestRelief(minSlope: minSlope, reach: reach)
        // Weak crest points are kept on lines whose mean is strong, so a ridge isn't cut at
        // every dip; points far below the bar are dropped.
        for i in relief.indices where relief[i] < Float(minRelief / 2) { relief[i] = 0 }
        // Along a steep ridge the crest can flicker between neighboring grid points; widening
        // it by a point before thinning bridges the gaps.
        var mask = Self.thin(Self.dilate(relief.map { $0 > 0 }, rows: rows, cols: cols), rows: rows, cols: cols)
        func length(_ run: [Int]) -> Double {
            zip(run, run.dropFirst()).reduce(0.0) { sum, step in
                let d = position(row: Double(step.1 / cols), col: Double(step.1 % cols)) -
                    position(row: Double(step.0 / cols), col: Double(step.0 % cols))
                return sum + (d * d).sum().squareRoot()
            }
        }
        // Rough ground leaves short spurs all along a ridge, and each one would cut it into
        // runs too short to keep. Prune them (and then spurs of spurs), so the ridge runs on.
        for _ in 0..<3 {
            var ends: [Int: Int] = [:]
            let runs = Self.trace(mask, rows: rows, cols: cols)
            for run in runs {
                ends[run[0], default: 0] += 1
                ends[run[run.count - 1], default: 0] += 1
            }
            var pruned = false
            for run in runs {
                let freeStart = ends[run[0]] == 1, freeEnd = ends[run[run.count - 1]] == 1
                guard freeStart != freeEnd, length(run) < minLength else { continue }
                for i in freeStart ? run.dropLast() : run.dropFirst() { mask[i] = false }
                pruned = true
            }
            if !pruned { break }
        }
        let runs = Self.trace(mask, rows: rows, cols: cols)
        let lengths = runs.map(length)
        let reliefs = runs.map { run in run.reduce(0) { $0 + Double(relief[$1]) } / Double(run.count) }
        var keep = runs.indices.map { lengths[$0] >= minLength && reliefs[$0] >= minRelief }
        // Where crests branch, the thinned lines can leave a short run between two branch
        // points. Keep it where it joins kept crests at both ends, or they'd part there.
        let joined = Set(runs.indices.filter { keep[$0] }.flatMap { [runs[$0][0], runs[$0][runs[$0].count - 1]] })
        for k in runs.indices where !keep[k] && lengths[k] < minLength {
            let a = runs[k][0], b = runs[k][runs[k].count - 1]
            keep[k] = a != b && joined.contains(a) && joined.contains(b)
        }
        var lines: [CrestLine] = []
        for k in runs.indices where keep[k] {
            let run = runs[k]
            let points = run.map { position(row: Double($0 / cols), col: Double($0 % cols)) }
            let meanHeight = run.reduce(0) { $0 + Double(heights[$1]) } / Double(run.count)
            let smooth = Self.chaikin(Self.simplify(points, tolerance: 0.6 * cellSize), iterations: 2)
            lines.append(CrestLine(points: smooth, relief: reliefs[k], height: meanHeight))
        }
        return lines
    }

    /// For each crest point, how far the ground falls on the lower side across the ridge
    /// within `reach` meters; 0 off the crests. The ground must fall at `minSlope` or more
    /// over `span` meters on both sides, whatever the grid spacing, so a blunt summit in the
    /// terrain model still counts.
    func crestRelief(minSlope: Double, reach: Double, span: Double = 120) -> [Float] {
        // Across the ridge: east-west, north-south and the two diagonals, as (rows, cols),
        // with the length of a step and how many steps make the span and the reach.
        let directions = [(0, 1), (1, 0), (1, 1), (1, -1)].map { dr, dc in
            let step = cellSize * (dr != 0 && dc != 0 ? 2.squareRoot() : 1)
            return (dr: dr, dc: dc, step: step, span: max(2, Int((span / step).rounded())), reach: max(2, Int(reach / step)))
        }
        var relief = [Float](repeating: 0, count: rows * cols)
        let rows = self.rows, cols = self.cols
        relief.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: rows) { r in
                for c in 0..<cols {
                    let top = h(r, c)
                    guard top.isFinite else { continue }
                    var best = 0.0, across = directions[0]
                    for d in directions {
                        let n = d.span
                        guard r - n * d.dr >= 0, r + n * d.dr < rows, c - n * abs(d.dc) >= 0, c + n * abs(d.dc) < cols else { continue }
                        let a1 = h(r - d.dr, c - d.dc), b1 = h(r + d.dr, c + d.dc)
                        let an = h(r - n * d.dr, c - n * d.dc), bn = h(r + n * d.dr, c + n * d.dc)
                        // A crest between two grid points leaves them level with each other,
                        // so the nearest neighbors may tie; further out it must fall.
                        guard an.isFinite, bn.isFinite, top >= a1, top >= b1 else { continue }
                        let slope = Double(min(top - an, top - bn)) / (Double(n) * d.step)
                        if slope > best { best = slope; across = d }
                    }
                    guard best >= minSlope else { continue }
                    func drop(_ sign: Int) -> Float {
                        var low = top
                        for s in 1...across.reach {
                            let rr = r + sign * s * across.dr, cc = c + sign * s * across.dc
                            guard rr >= 0, rr < rows, cc >= 0, cc < cols else { break }
                            let v = h(rr, cc)
                            if v.isFinite { low = min(low, v) }
                        }
                        return top - low
                    }
                    out[r * cols + c] = max(Float.leastNonzeroMagnitude, min(drop(-1), drop(1)))
                }
            }
        }
        return relief
    }

    /// Widens a mask by one point in every direction.
    static func dilate(_ mask: [Bool], rows: Int, cols: Int) -> [Bool] {
        var out = mask
        for r in 0..<rows {
            for c in 0..<cols where mask[r * cols + c] {
                for rr in max(0, r - 1)...min(rows - 1, r + 1) {
                    for cc in max(0, c - 1)...min(cols - 1, c + 1) { out[rr * cols + cc] = true }
                }
            }
        }
        return out
    }

    /// Thins a mask to lines one point wide (Zhang and Suen), keeping them connected.
    static func thin(_ mask: [Bool], rows: Int, cols: Int) -> [Bool] {
        var m = mask
        func at(_ r: Int, _ c: Int) -> Bool { r >= 0 && r < rows && c >= 0 && c < cols && m[r * cols + c] }
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var remove: [Int] = []
                for r in 0..<rows {
                    for c in 0..<cols where m[r * cols + c] {
                        // Neighbors clockwise from north.
                        let p = [at(r - 1, c), at(r - 1, c + 1), at(r, c + 1), at(r + 1, c + 1),
                                 at(r + 1, c), at(r + 1, c - 1), at(r, c - 1), at(r - 1, c - 1)]
                        let count = p.filter { $0 }.count
                        guard count >= 2, count <= 6 else { continue }
                        var transitions = 0
                        for k in 0..<8 where !p[k] && p[(k + 1) % 8] { transitions += 1 }
                        guard transitions == 1 else { continue }
                        let (n, e, s, w) = (p[0], p[2], p[4], p[6])
                        if pass == 0 ? !(n && e && s) && !(e && s && w) : !(n && e && w) && !(n && s && w) {
                            remove.append(r * cols + c)
                        }
                    }
                }
                for i in remove { m[i] = false }
                if !remove.isEmpty { changed = true }
            }
        }
        return m
    }

    /// Traces a thinned mask into runs of grid indices. Runs end where lines end or branch;
    /// runs meeting at a branch share its point. Diagonal steps count only where no
    /// straight step joins the same two points, so corners don't read as branches.
    static func trace(_ mask: [Bool], rows: Int, cols: Int) -> [[Int]] {
        func on(_ r: Int, _ c: Int) -> Bool { r >= 0 && r < rows && c >= 0 && c < cols && mask[r * cols + c] }
        func neighbors(_ i: Int) -> [Int] {
            let r = i / cols, c = i % cols
            var out: [Int] = []
            for (dr, dc) in [(-1, 0), (0, 1), (1, 0), (0, -1)] where on(r + dr, c + dc) { out.append((r + dr) * cols + c + dc) }
            for (dr, dc) in [(-1, 1), (1, 1), (1, -1), (-1, -1)] where on(r + dr, c + dc) && !on(r + dr, c) && !on(r, c + dc) {
                out.append((r + dr) * cols + c + dc)
            }
            return out
        }
        var links: [Int: [Int]] = [:]
        for i in mask.indices where mask[i] { links[i] = neighbors(i) }
        var used = Set<Int64>()
        func key(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) * Int64(rows * cols) + Int64(max(a, b)) }
        var runs: [[Int]] = []
        func walk(from start: Int, to next: Int) {
            var run = [start, next]
            used.insert(key(start, next))
            var previous = start, current = next
            while let around = links[current], around.count == 2 {
                guard let step = around.first(where: { $0 != previous }), !used.contains(key(current, step)) else { break }
                used.insert(key(current, step))
                run.append(step)
                previous = current
                current = step
            }
            runs.append(run)
        }
        // From the ends and branches first, then whatever is left: closed loops.
        let ordered = links.keys.sorted()
        for i in ordered where links[i]!.count != 2 {
            for j in links[i]! where !used.contains(key(i, j)) { walk(from: i, to: j) }
        }
        for i in ordered {
            for j in links[i]! where !used.contains(key(i, j)) { walk(from: i, to: j) }
        }
        return runs
    }

    /// Drops points that stray less than `tolerance` from the line (Douglas–Peucker).
    static func simplify(_ points: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let d = points[b] - points[a]
            let length = (d * d).sum().squareRoot()
            var far = 0.0, index = a
            for i in (a + 1)..<b {
                let v = points[i] - points[a]
                let off = length > 0 ? abs(d.x * v.y - d.y * v.x) / length : (v * v).sum().squareRoot()
                if off > far { far = off; index = i }
            }
            if far > tolerance {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// Rounds a line's corners by cutting each one (Chaikin), keeping its ends.
    static func chaikin(_ points: [SIMD2<Double>], iterations: Int) -> [SIMD2<Double>] {
        var line = points
        for _ in 0..<iterations where line.count > 2 {
            var next = [line[0]]
            for i in 0..<(line.count - 1) {
                let a = line[i], b = line[i + 1]
                if i > 0 { next.append(0.75 * a + 0.25 * b) }
                if i < line.count - 2 { next.append(0.25 * a + 0.75 * b) }
            }
            next.append(line[line.count - 1])
            line = next
        }
        return line
    }
}

import Foundation

/// Terrain as triangles, for drawing it in 3D. Positions are map meters: x east and y north
/// of the map's center, z up (the height above sea level).
public struct TerrainMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    /// Where each vertex is on the map's grid, 0 to 1: u from west to east, v from north to
    /// south (row 0 is the northern edge), for laying an image of the map over it.
    public var uvs: [SIMD2<Float>]
    /// Heights of the vertices, meters (NaN-free).
    public var heights: [Float]
    /// Triangles, three vertex indices each, counter-clockwise seen from above.
    public var indices: [UInt32]
}

extension ReliefMap {
    /// Bilinear height at a map position, meters; NaN off the grid or without terrain.
    public func height(at p: SIMD2<Double>) -> Double {
        let col = p.x / cellSize + Double(cols - 1) / 2
        let row = Double(rows - 1) / 2 - p.y / cellSize
        guard col >= 0, row >= 0, col <= Double(cols - 1), row <= Double(rows - 1) else { return .nan }
        let c0 = min(Int(col), cols - 2), r0 = min(Int(row), rows - 2)
        let fx = col - Double(c0), fy = row - Double(r0)
        let a = Double(h(r0, c0)), b = Double(h(r0, c0 + 1)), c = Double(h(r0 + 1, c0)), d = Double(h(r0 + 1, c0 + 1))
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// The height of the mesh drawn from this grid (`mesh()`, every point) at a map
    /// position, meters: on the triangle of its square, which is split along the higher
    /// diagonal, so over a diagonal ridge it can be above the bilinear height. NaN off the
    /// grid or where a corner has no terrain, as the mesh leaves those squares out.
    public func surfaceHeight(at p: SIMD2<Double>) -> Double {
        let col = p.x / cellSize + Double(cols - 1) / 2
        let row = Double(rows - 1) / 2 - p.y / cellSize
        guard col >= 0, row >= 0, col <= Double(cols - 1), row <= Double(rows - 1) else { return .nan }
        let c0 = min(Int(col), cols - 2), r0 = min(Int(row), rows - 2)
        return triangleHeight(r0, c0, fx: col - Double(c0), fy: row - Double(r0))
    }

    /// The drawn height in the square whose north-west corner is grid point (r0, c0), at
    /// (fx, fy) across it (east, south; 0 to 1); NaN when a corner has no terrain.
    private func triangleHeight(_ r0: Int, _ c0: Int, fx: Double, fy: Double) -> Double {
        // Corners: nw, ne, sw, se.
        let a = Double(h(r0, c0)), b = Double(h(r0, c0 + 1)), c = Double(h(r0 + 1, c0)), d = Double(h(r0 + 1, c0 + 1))
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else { return .nan }
        if a + d >= b + c {
            // Split from nw to se.
            return fy >= fx ? a + (d - c) * fx + (c - a) * fy : a + (b - a) * fx + (d - b) * fy
        }
        // Split from ne to sw.
        return fx + fy <= 1 ? a + (b - a) * fx + (c - a) * fy : d + (c - d) * (1 - fx) + (b - d) * (1 - fy)
    }

    /// How far the straight line from `eye` to `target` passes over the mesh drawn from this
    /// grid (`mesh(hole:)`), lowered by `sink` meters, at its lowest, meters; negative where
    /// the mesh is in the way. Exact: the line is checked wherever it crosses a grid line or a
    /// square's diagonal, where its lowest points over the flat triangles are, along its whole
    /// length. The target stands on the ground, so within `contact` meters of it (across the
    /// map) the ground may reach up to `contactDepth` meters above the line at the target,
    /// tapering to none at `contact` away. Squares without terrain, and those the mesh leaves
    /// to a sharper one in `hole`, are left out. Infinity when nothing is checked, as looking
    /// straight down.
    public func clearance(from eye: SIMD3<Double>, to target: SIMD3<Double>, contact: Double = 0, contactDepth: Double = 0,
                          sink: Double = 0, hole: (low: SIMD2<Double>, high: SIMD2<Double>)? = nil) -> Double {
        let run = SIMD2(target.x - eye.x, target.y - eye.y)
        let length = (run * run).sum().squareRoot()
        guard length > 0 else { return .infinity }
        // Grid coordinates along the line: col(t) = col0 + dc·t, row(t) = row0 + dr·t.
        let col0 = eye.x / cellSize + Double(cols - 1) / 2, row0 = Double(rows - 1) / 2 - eye.y / cellSize
        let dc = run.x / cellSize, dr = -run.y / cellSize
        // Where the allowance near the target begins: it's linear in t past there.
        let near = contact > 0 ? max(0, 1 - contact / length) : 1
        func allowance(_ t: Double) -> Double { t > near ? contactDepth * (t - near) / (1 - near) : 0 }
        var ts: [Double] = [0, 1]
        if near > 0, near < 1 { ts.append(near) }
        func crossings(_ start: Double, _ step: Double) {
            guard abs(step) > 1e-12 else { return }
            let a = start, b = start + step
            var k = (min(a, b)).rounded(.up)
            while k <= max(a, b) {
                let t = (k - start) / step
                if t > 0, t < 1 { ts.append(t) }
                k += 1
            }
        }
        crossings(col0, dc)
        crossings(row0, dr)
        ts.sort()
        /// The squares a coordinate's piece lies over: both sides when it runs along a grid line.
        func squares(_ x: Double, _ count: Int) -> [Int] {
            guard x >= 0, x <= Double(count - 1) else { return [] }
            let k = x.rounded()
            if abs(x - k) < 1e-9 { return [Int(k) - 1, Int(k)].filter { $0 >= 0 && $0 <= count - 2 } }
            return [min(Int(x), count - 2)]
        }
        var lowest = Double.infinity
        for i in 1..<ts.count {
            let t0 = ts[i - 1], t1 = ts[i]
            guard t1 - t0 > 1e-12 else { continue }
            let tm = (t0 + t1) / 2
            for r in squares(row0 + dr * tm, rows) {
                for c in squares(col0 + dc * tm, cols) {
                    if let hole {
                        let a = position(row: Double(r + 1), col: Double(c)), b = position(row: Double(r), col: Double(c + 1))
                        if a.x >= hole.low.x, a.y >= hole.low.y, b.x <= hole.high.x, b.y <= hole.high.y { continue }
                    }
                    func fx(_ t: Double) -> Double { min(1, max(0, col0 + dc * t - Double(c))) }
                    func fy(_ t: Double) -> Double { min(1, max(0, row0 + dr * t - Double(r))) }
                    var checks = [t0, t1]
                    // Where it crosses the square's diagonal, between its two triangles.
                    let nwToSe = h(r, c) + h(r + 1, c + 1) >= h(r, c + 1) + h(r + 1, c)
                    let g0 = nwToSe ? fx(t0) - fy(t0) : fx(t0) + fy(t0) - 1
                    let g1 = nwToSe ? fx(t1) - fy(t1) : fx(t1) + fy(t1) - 1
                    if g0 * g1 < 0 { checks.append(t0 + (t1 - t0) * g0 / (g0 - g1)) }
                    for t in checks {
                        let ground = triangleHeight(r, c, fx: fx(t), fy: fy(t))
                        guard ground.isFinite else { break }
                        lowest = min(lowest, eye.z + (target.z - eye.z) * t - (ground - sink) + allowance(t))
                    }
                }
            }
        }
        return lowest
    }

    /// The steepest slope of the mesh drawn from this grid (rise over run, of any of its
    /// triangles), for bounding how much the ground under a moving line can change.
    public var steepestSlope: Double {
        var steepest = 0.0
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let a = Double(h(r, c)), b = Double(h(r, c + 1)), cc = Double(h(r + 1, c)), d = Double(h(r + 1, c + 1))
                guard a.isFinite, b.isFinite, cc.isFinite, d.isFinite else { continue }
                // Each triangle's gradient from two of its edges along the grid.
                let pairs = a + d >= b + cc ? [(b - a, d - b), (d - cc, cc - a)] : [(b - a, cc - a), (cc - d, b - d)]
                for (east, south) in pairs { steepest = max(steepest, (east * east + south * south).squareRoot() / cellSize) }
            }
        }
        return steepest
    }

    /// The highest grid point of every grid square within `radius` meters of `p` (a square
    /// around it, to be safe), meters; NaN where none has terrain. The mesh's triangles never
    /// rise above their corners, so nothing drawn there is higher; the bilinear height can be
    /// lower than a triangle split along the higher diagonal.
    public func highest(within radius: Double, of p: SIMD2<Double>) -> Double {
        let col = p.x / cellSize + Double(cols - 1) / 2
        let row = Double(rows - 1) / 2 - p.y / cellSize
        let reach = radius / cellSize
        let c0 = max(0, Int((col - reach).rounded(.down))), c1 = min(cols - 1, Int((col + reach).rounded(.up)))
        let r0 = max(0, Int((row - reach).rounded(.down))), r1 = min(rows - 1, Int((row + reach).rounded(.up)))
        guard c0 <= c1, r0 <= r1 else { return .nan }
        var top = -Float.infinity
        for r in r0...r1 {
            for c in c0...c1 where h(r, c).isFinite { top = max(top, h(r, c)) }
        }
        return top.isFinite ? Double(top) : .nan
    }

    /// The terrain as a mesh, using every `step`-th grid point each way (at least 1), so it
    /// can be kept to a size the GPU draws smoothly. Squares with a corner without terrain
    /// are left out, and so are squares entirely inside `hole` (map meters, lowest and
    /// highest corner), where a sharper mesh takes over. Each square is split along its higher diagonal, so ridges, which make
    /// the skylines, stay sharp instead of zigzagging.
    public func mesh(step: Int = 1, hole: (low: SIMD2<Double>, high: SIMD2<Double>)? = nil) -> TerrainMesh {
        let step = max(1, step)
        let rowIndex = Array(stride(from: 0, to: rows, by: step)) + ((rows - 1) % step == 0 ? [] : [rows - 1])
        let colIndex = Array(stride(from: 0, to: cols, by: step)) + ((cols - 1) % step == 0 ? [] : [cols - 1])
        let n = rowIndex.count, m = colIndex.count
        let known = heights.filter(\.isFinite)
        let floor = known.min() ?? 0
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], tops: [Float] = []
        positions.reserveCapacity(n * m)
        normals.reserveCapacity(n * m)
        uvs.reserveCapacity(n * m)
        tops.reserveCapacity(n * m)
        func z(_ r: Int, _ c: Int) -> Float {
            let v = h(max(0, min(rows - 1, r)), max(0, min(cols - 1, c)))
            return v.isFinite ? v : floor
        }
        for r in rowIndex {
            for c in colIndex {
                let p = position(row: Double(r), col: Double(c))
                let top = z(r, c)
                positions.append(SIMD3(Float(p.x), Float(p.y), top))
                tops.append(top)
                // The slope from the neighbors a step away on each side.
                let east = z(r, c + step), west = z(r, c - step), north = z(r - step, c), south = z(r + step, c)
                let run = Float(2 * Double(step) * cellSize)
                let normal = SIMD3<Float>(-(east - west) / run, -(north - south) / run, 1)
                normals.append(normal / (normal * normal).sum().squareRoot())
                uvs.append(SIMD2(Float(c) / Float(max(1, cols - 1)), Float(r) / Float(max(1, rows - 1))))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((n - 1) * (m - 1) * 6)
        for i in 0..<(n - 1) {
            for j in 0..<(m - 1) {
                let r0 = rowIndex[i], r1 = rowIndex[i + 1], c0 = colIndex[j], c1 = colIndex[j + 1]
                guard h(r0, c0).isFinite, h(r0, c1).isFinite, h(r1, c0).isFinite, h(r1, c1).isFinite else { continue }
                if let hole {
                    let a = position(row: Double(r1), col: Double(c0)), b = position(row: Double(r0), col: Double(c1))
                    if a.x >= hole.low.x, a.y >= hole.low.y, b.x <= hole.high.x, b.y <= hole.high.y { continue }
                }
                // Corners: nw, ne, sw, se. Counter-clockwise seen from above (north up).
                let nw = UInt32(i * m + j), ne = nw + 1, sw = UInt32((i + 1) * m + j), se = sw + 1
                if h(r0, c0) + h(r1, c1) >= h(r0, c1) + h(r1, c0) {
                    indices += [nw, sw, se, nw, se, ne]
                } else {
                    indices += [nw, sw, ne, ne, sw, se]
                }
            }
        }
        return TerrainMesh(positions: positions, normals: normals, uvs: uvs, heights: tops, indices: indices)
    }
}

/// Walking a trail in 3D: a point moving along it, which way it's heading, and a camera
/// following it from behind and above that keeps the walker in sight over the terrain.
/// Positions are map meters (x east, y north, z up).
public struct TrailWalk: Sendable {
    public let points: [SIMD3<Double>]
    /// Horizontal distance from the start to each point, meters.
    public let along: [Double]

    /// A walk through `points` (on the ground); repeated points are dropped.
    public init(points: [SIMD3<Double>]) {
        var kept: [SIMD3<Double>] = []
        for p in points where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            if let last = kept.last, Self.flat(p - last) < 0.01 { continue }
            kept.append(p)
        }
        var along = [0.0]
        for i in kept.indices.dropFirst() { along.append(along[i - 1] + Self.flat(kept[i] - kept[i - 1])) }
        self.points = kept
        self.along = kept.isEmpty ? [] : along
    }

    static func flat(_ v: SIMD3<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

    /// Horizontal length, meters.
    public var length: Double { along.last ?? 0 }

    /// The point `distance` meters along the walk (clamped to its ends).
    public func point(at distance: Double) -> SIMD3<Double> {
        guard let first = points.first else { return .zero }
        guard points.count > 1, distance > 0 else { return first }
        guard distance < length else { return points[points.count - 1] }
        // The last point at or before `distance`.
        var low = 0, high = along.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if along[mid] <= distance { low = mid } else { high = mid }
        }
        let span = along[high] - along[low]
        let f = span > 0 ? (distance - along[low]) / span : 0
        return points[low] + (points[high] - points[low]) * f
    }

    /// Which way the walk heads at `distance`, as a horizontal unit vector: from a little
    /// behind to `lookAhead` meters ahead, so switchbacks don't swing it around.
    public func heading(at distance: Double, lookAhead: Double = 150) -> SIMD2<Double> {
        guard length > 0 else { return SIMD2(0, 1) }
        var from = max(0, distance - lookAhead / 3), to = min(length, distance + lookAhead)
        // Near the ends, keep the span by reaching the other way.
        if to - from < lookAhead { if from == 0 { to = min(length, lookAhead) } else { from = max(0, length - lookAhead) } }
        let d = point(at: to) - point(at: from)
        let flat = SIMD2(d.x, d.y)
        let size = (flat * flat).sum().squareRoot()
        return size > 1e-6 ? flat / size : SIMD2(0, 1)
    }

    /// A camera following the walker at `distance`, like a drone: `range` meters away, behind
    /// and above, looking down at `pitch` degrees onto a point `lead` times the range ahead
    /// of the walker, so more of the way ahead is in view.
    /// Where the trail climbs ahead, the camera looks down more steeply (up to `maxPitch`),
    /// so a face being climbed is seen rather than looked into. It is raised where needed to stay
    /// `clearance` meters above the ground, at its own spot and along its line of sight.
    /// `ground` gives the terrain's height at a map position (NaN for none).
    public func camera(at distance: Double, range: Double = 600, pitch: Double = 35, maxPitch: Double = 60,
                       lead: Double = 0.12, clearance: Double = 40,
                       ground: (SIMD2<Double>) -> Double) -> (eye: SIMD3<Double>, target: SIMD3<Double>) {
        let p = point(at: distance)
        let dir = heading(at: distance)
        // The grade along the path, not across it: switchbacks climb gently, however fast
        // they gain height as the crow flies.
        let from = max(0, distance - 50), to = min(length, distance + 200)
        let rise = point(at: to).z - point(at: from).z
        let climb = to - from > 1 ? atan(rise / (to - from)) * 180 / .pi : 0
        let angle = min(maxPitch, max(pitch, pitch + climb * 0.5)) * .pi / 180
        let focus = SIMD2(p.x, p.y) + dir * (range * lead)
        func groundOr(_ q: SIMD2<Double>, _ fallback: Double) -> Double {
            let g = ground(q)
            return g.isFinite ? g : fallback
        }
        let target = SIMD3(focus.x, focus.y, max(p.z, groundOr(focus, p.z)))
        let spot = SIMD2(target.x, target.y) - dir * (range * cos(angle))
        var eye = SIMD3(spot.x, spot.y, target.z + range * sin(angle))
        eye.z = max(eye.z, groundOr(spot, target.z) + clearance)
        return (Self.raised(eye, toSee: p, clearance: clearance, ground: ground), target)
    }

    /// A camera orbiting `subject`: `distance` meters from it, in the direction `azimuth`
    /// degrees clockwise from north and `elevation` degrees above level, as seen from it.
    public static func orbit(around subject: SIMD3<Double>, azimuth: Double, elevation: Double,
                             distance: Double) -> SIMD3<Double> {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        return subject + distance * SIMD3(sin(a) * cos(e), cos(a) * cos(e), sin(e))
    }

    /// Where `eye` is around `subject`, as `orbit` takes it.
    public static func orbitAngles(of eye: SIMD3<Double>, around subject: SIMD3<Double>)
        -> (azimuth: Double, elevation: Double, distance: Double) {
        let v = eye - subject
        let distance = (v * v).sum().squareRoot()
        guard distance > 1e-9 else { return (0, 90, 0) }
        return (atan2(v.x, v.y) * 180 / .pi, asin(max(-1, min(1, v.z / distance))) * 180 / .pi, distance)
    }

    /// The lowest elevation from `elevation` up to `highest` degrees at which an eye orbiting
    /// `subject` is clear, to a hundredth of a degree, or nil if it isn't even at `highest`.
    /// What's returned was found clear; in between, once clear, higher is taken to be clear
    /// too, as over a landscape.
    public static func lowestClearElevation(around subject: SIMD3<Double>, azimuth: Double, distance: Double,
                                            from elevation: Double, highest: Double = 89,
                                            isClear: (SIMD3<Double>) -> Bool) -> Double? {
        func clear(_ e: Double) -> Bool {
            isClear(orbit(around: subject, azimuth: azimuth, elevation: e, distance: distance))
        }
        if clear(elevation) { return elevation }
        guard elevation < highest, clear(highest) else { return nil }
        var low = elevation, high = highest
        while high - low > 0.01 {
            let mid = (low + high) / 2
            if clear(mid) { high = mid } else { low = mid }
        }
        return high
    }

    /// `eye` raised where needed so the line from it to `subject` passes over the ground in
    /// between, checked every 15 m or so: by `clearance` near the eye, tapering to nothing at
    /// the subject, who stands on the ground. (A full clearance right beside the subject would
    /// hoist a low camera hundreds of meters.) `ground` gives the terrain's height at a map
    /// position (NaN for none).
    public static func raised(_ eye: SIMD3<Double>, toSee subject: SIMD3<Double>, clearance: Double,
                              ground: (SIMD2<Double>) -> Double) -> SIMD3<Double> {
        var eye = eye
        let start = SIMD2(eye.x, eye.y), end = SIMD2(subject.x, subject.y)
        let samples = max(8, Int(flat(SIMD3(end - start, 0)) / 15))
        for k in 1..<samples {
            let f = Double(k) / Double(samples)
            let g = ground(start + (end - start) * f)
            guard g.isFinite else { continue }
            // eye.z·(1−f) + subject.z·f ≥ the ground + clearance·(1−f)
            eye.z = max(eye.z, (g + clearance * (1 - f) - subject.z * f) / (1 - f))
        }
        return eye
    }

    /// A flat band `width` meters wide along a line, laid on the ground: each edge sits `lift`
    /// meters above the terrain under it, so the band follows slopes across the trail too.
    /// Returns two vertices per point (left, then right edge) and the triangles between.
    public static func ribbon(_ line: [SIMD2<Double>], width: Double, lift: Double,
                              ground: (SIMD2<Double>) -> Double) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        guard line.count > 1 else { return (positions, indices) }
        for i in line.indices {
            let a = line[max(0, i - 1)], b = line[min(line.count - 1, i + 1)]
            var d = b - a
            let size = (d * d).sum().squareRoot()
            d = size > 1e-9 ? d / size : SIMD2(0, 1)
            let side = SIMD2(-d.y, d.x) * (width / 2)
            for edge in [line[i] + side, line[i] - side] {
                var z = ground(edge)
                if !z.isFinite { z = ground(line[i]) }
                positions.append(SIMD3(Float(edge.x), Float(edge.y), Float((z.isFinite ? z : 0) + lift)))
            }
            if i > 0 {
                let l0 = UInt32(2 * (i - 1)), r0 = l0 + 1, l1 = l0 + 2, r1 = l0 + 3
                indices += [l0, r0, r1, l0, r1, l1]
            }
        }
        return (positions, indices)
    }
}

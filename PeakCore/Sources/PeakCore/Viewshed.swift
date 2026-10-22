import Dispatch
import Foundation

public struct ViewshedSettings: Sendable {
    /// How far from the summit to look, meters. Limited to the loaded terrain.
    public var radius = 80_000.0
    /// Map cell size, meters.
    public var cellSize = 150.0
    /// Eye height of the person looking, meters above the ground.
    public var eyeHeight = 1.6
    /// Terrain this close to the summit is ignored: OSM summits are often a few meters off
    /// the DEM's, whose flat top would otherwise hide the slopes below. Same idea as the
    /// `summitRadius` of `HorizonRenderer.visibility`, kept small since the summit is the eye here.
    public var summitRadius = 150.0
    /// Slack for the summit's height, meters: it may be up to this much lower than seen, as
    /// `HorizonRenderer.visibility` allows, so the map agrees with the labels. Without it,
    /// meter-rounded DEM heights near the summit hide long straight slopes they graze.
    public var tolerance = 15.0
    /// Atmospheric refraction coefficient k, as in `HorizonSettings`.
    public var refraction = 0.13

    public init() {}
}

/// Everywhere a person standing on the ground can see a summit from, as a map raster.
///
/// Line of sight is symmetric, so the summit is the eye: rays march outward from it, keeping
/// the highest elevation angle of the terrain so far, as the horizon renderer's march does,
/// with the same curvature and refraction. A ground point sees the summit when its eye
/// (the ground plus `eyeHeight`) reaches that angle of everything nearer. A cell counts as
/// visible when any of nine points spread over it is, so a crest or knoll inside it shows.
public struct Viewshed: Sendable {
    public enum Cell: UInt8, Sendable {
        /// Beyond the radius.
        case outside = 0
        /// No terrain loaded there, or between it and the summit.
        case unknown = 1
        case hidden = 2
        case visible = 3
    }

    public let summit: GeoPoint
    public let settings: ViewshedSettings
    /// North-up map centered on the summit.
    public let projection: MapProjection
    public let cellSize: Double
    public let rows: Int
    public let cols: Int
    /// Row by row from the north; the summit is the middle cell.
    public let cells: [Cell]
    /// The radius actually covered: the requested one, or less where the terrain ends sooner.
    public let radius: Double

    public func cell(row: Int, col: Int) -> Cell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return .outside }
        return cells[row * cols + col]
    }

    /// Map position of a cell's center, meters east and north of the summit.
    public func position(row: Int, col: Int) -> SIMD2<Double> {
        SIMD2(Double(col - cols / 2) * cellSize, Double(rows / 2 - row) * cellSize)
    }

    public func cell(at p: LatLon) -> Cell {
        let xy = projection.point(p)
        return cell(row: rows / 2 - Int((xy.y / cellSize).rounded()), col: cols / 2 + Int((xy.x / cellSize).rounded()))
    }

    /// Area the summit can be seen from, square meters.
    public var visibleArea: Double {
        Double(cells.reduce(0) { $0 + ($1 == .visible ? 1 : 0) }) * cellSize * cellSize
    }

    /// Share of the cells within the radius that have terrain.
    public var knownShare: Double {
        var known = 0, inside = 0
        for c in cells where c != .outside {
            inside += 1
            if c != .unknown { known += 1 }
        }
        return inside == 0 ? 0 : Double(known) / Double(inside)
    }

    // MARK: Computing

    public static func compute(terrain: Terrain, summit: GeoPoint, settings: ViewshedSettings = ViewshedSettings()) -> Viewshed {
        let step = settings.cellSize / 2
        let sampleCount = max(1, Int((settings.radius / step).rounded(.up)) + 1)
        // Rays close enough at the edge that neighbors are less than a cell apart there.
        let rayCount = max(360, Int((2 * .pi * settings.radius / (0.75 * settings.cellSize)).rounded(.up)))
        let azimuthStep = 360 / Double(rayCount)
        let sphere = ConformalSphere(latitude: summit.latitude)
        let cosDelta = (0..<sampleCount).map { cos(Double($0) * step * sphere.radiansPerMeter) }
        let sinDelta = (0..<sampleCount).map { sin(Double($0) * step * sphere.radiansPerMeter) }
        let firstSample = Int((settings.summitRadius / step).rounded(.up))

        // For ray i, blocking[i * sampleCount + k] is the highest tan(elevation) of the terrain
        // at samples 0...k; reach[i] is the number of samples with terrain.
        // Nothing blocks yet: a large finite value rather than −∞, so blending two rays stays finite.
        let open: Float = -1e30
        var blocking = [Float](repeating: open, count: rayCount * sampleCount)
        var reach = [Int32](repeating: 0, count: rayCount)
        var radii = [Double](repeating: 0, count: rayCount)
        blocking.withUnsafeMutableBufferPointer { out in
            reach.withUnsafeMutableBufferPointer { reachOut in
                radii.withUnsafeMutableBufferPointer { radiiOut in
                    let chunk = 32
                    DispatchQueue.concurrentPerform(iterations: (rayCount + chunk - 1) / chunk) { block in
                        for i in block * chunk..<min(rayCount, (block + 1) * chunk) {
                            let azimuth = Double(i) * azimuthStep
                            let ray = GreatCircleRay(sphere: sphere, longitude: summit.longitude, azimuth: azimuth)
                            let r = effectiveRadius(summit, azimuth, settings.refraction)
                            radiiOut[i] = r
                            let observerRadius = r + summit.height + settings.tolerance
                            var best = open
                            var count = sampleCount
                            let base = i * sampleCount
                            for k in 0..<sampleCount {
                                if k >= firstSample {
                                    let p = ray.point(cosDelta: cosDelta[k], sinDelta: sinDelta[k])
                                    let h = terrain.height(latitude: p.latitude, longitude: p.longitude)
                                    if h.isNaN { count = k; break }
                                    let t = Float(tanElevation(distance: Double(k) * step, height: h,
                                                               effectiveRadius: r, observerRadius: observerRadius))
                                    if t > best { best = t }
                                }
                                out[base + k] = best
                            }
                            reachOut[i] = Int32(count)
                        }
                    }
                }
            }
        }

        // The map covers the requested radius, or as far as any ray found terrain.
        let farthest = Double(max(0, (reach.max() ?? 0) - 1)) * step
        let radius = min(settings.radius, farthest)
        let half = max(1, Int((radius / settings.cellSize).rounded(.up)))
        let size = 2 * half + 1
        let center = LatLon(summit.latitude, summit.longitude)
        let projection = MapProjection(center: center)
        var cells = [Cell](repeating: .outside, count: size * size)
        let chi0 = sphere.chi0, cosChi0 = cos(chi0), sinChi0 = sin(chi0)
        let lon0 = summit.longitude
        let cellSize = settings.cellSize, eye = settings.eyeHeight
        // Points tested in each cell, as offsets in cells: the middle first.
        let subsamples = [0.0, -1.0 / 3, 1.0 / 3]

        let rayBlocking = blocking, rayReach = reach, rayRadii = radii
        cells.withUnsafeMutableBufferPointer { out in
            do {
                DispatchQueue.concurrentPerform(iterations: size) { row in
                    let y = Double(half - row) * cellSize
                    // The map is a plain lat/lon grid, so a row of points is one latitude.
                    let lines = subsamples.map { dy -> (latitude: Double, cos: Double, sin: Double, chi: Double) in
                        let latitude = projection.latLon(SIMD2(0, y + dy * cellSize)).latitude
                        let chi = ConformalSphere.conformalLatitude(latitude * .pi / 180)
                        return (latitude, cos(chi), sin(chi), chi)
                    }
                    /// Whether the point `x` meters east on line `j` sees the summit.
                    func look(_ x: Double, _ j: Int) -> Cell {
                        let line = lines[j]
                        let longitude = projection.latLon(SIMD2(x, 0)).longitude
                        let dl = (longitude - lon0) * .pi / 180
                        // Distance and azimuth on the conformal sphere, as the rays measure them.
                        let sinHalf = sin((line.chi - chi0) / 2)
                        let a = sinHalf * sinHalf + cosChi0 * line.cos * sin(dl / 2) * sin(dl / 2)
                        let d = 2 * asin(min(1, a.squareRoot())) / sphere.radiansPerMeter
                        if d < settings.summitRadius { return .visible }
                        let azimuth = normalizedAzimuth(atan2(sin(dl) * line.cos, cosChi0 * line.sin - sinChi0 * line.cos * cos(dl)) * 180 / .pi)
                        let ray = azimuth / azimuthStep
                        let i0 = Int(ray) % rayCount, i1 = (i0 + 1) % rayCount
                        let f = Float(ray - Double(Int(ray)))
                        // Everything at least half a sample nearer.
                        let k = Int((d - step / 2) / step)
                        let h = terrain.height(latitude: line.latitude, longitude: longitude)
                        guard h.isFinite, k + 1 < Int(rayReach[i0]), k + 1 < Int(rayReach[i1]) else { return .unknown }
                        let block = rayBlocking[i0 * sampleCount + k] * (1 - f) + rayBlocking[i1 * sampleCount + k] * f
                        let r = rayRadii[i0]
                        let t = tanElevation(distance: d, height: h + eye, effectiveRadius: r, observerRadius: r + summit.height + settings.tolerance)
                        return Float(t) >= block ? .visible : .hidden
                    }
                    for col in 0..<size {
                        let x = Double(col - half) * cellSize
                        guard x * x + y * y <= radius * radius else { continue }
                        // Seen from anywhere in the cell: a crest or knoll inside it counts.
                        var cell = Cell.hidden
                        search: for j in subsamples.indices {
                            for dx in subsamples {
                                switch look(x + dx * cellSize, j) {
                                case .visible: cell = .visible; break search
                                case .unknown: cell = .unknown
                                default: break
                                }
                            }
                        }
                        out[row * size + col] = cell
                    }
                }
            }
        }

        return Viewshed(summit: summit, settings: settings, projection: projection, cellSize: cellSize,
                        rows: size, cols: size, cells: cells, radius: radius)
    }

    /// Refraction as a larger effective Earth, R' = R / (1 − k), as the horizon renderer does.
    static func effectiveRadius(_ observer: GeoPoint, _ azimuth: Double, _ refraction: Double) -> Double {
        WGS84.radius(latitude: observer.latitude * .pi / 180, azimuth: azimuth * .pi / 180) / (1 - refraction)
    }

    /// tan of the elevation angle, from an eye `observerRadius` from the effective sphere's
    /// center, of a point at `height` meters `distance` meters away along the ground.
    @inline(__always)
    static func tanElevation(distance: Double, height: Double, effectiveRadius: Double, observerRadius: Double) -> Double {
        let theta = distance / effectiveRadius
        let r = effectiveRadius + height
        return (cos(theta) * r - observerRadius) / (sin(theta) * r)
    }

    // MARK: From a point

    /// How the summit looks from a point on the map, for someone standing there.
    public struct Sight: Sendable {
        /// Distance along the ground, meters.
        public var distance: Double
        /// Apparent elevation angle of the summit above level, degrees, with refraction.
        public var elevation: Double
        /// Azimuth from the point to the summit, degrees.
        public var azimuth: Double
        /// The map cell the point is in.
        public var cell: Cell
        /// Line of sight from exactly this point, as the labels test it. It can differ from
        /// the cell's on a crest or steep face, where the cell's center sits elsewhere.
        public var isVisible: Bool
    }

    /// The summit as seen from `point`, standing on `terrain` there.
    public func sight(from point: LatLon, terrain: Terrain) -> Sight? {
        let ground = terrain.height(latitude: point.latitude, longitude: point.longitude)
        guard ground.isFinite else { return nil }
        let eye = GeoPoint(latitude: point.latitude, longitude: point.longitude, height: ground + settings.eyeHeight)
        var horizon = HorizonSettings()
        horizon.refraction = settings.refraction
        let line = HorizonRenderer(terrain: terrain).visibility(of: summit, from: eye, summitRadius: settings.summitRadius,
                                                                tolerance: settings.tolerance, settings: horizon)
        return Sight(distance: line.distance, elevation: line.elevation, azimuth: line.azimuth,
                     cell: cell(at: point), isVisible: line.isVisible)
    }
}

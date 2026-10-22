import Foundation

/// What covers the ground where OpenStreetMap maps it, for tinting the terrain: bare rock
/// and scree, glaciers and water. Everything else keeps the terrain's own shading.
public enum LandCover: UInt8, Sendable, CaseIterable {
    /// `natural=bare_rock` and `natural=scree`.
    case rock = 1
    /// `natural=glacier`.
    case glacier = 2
    /// `natural=water` (lakes, reservoirs, wide rivers) and the older `waterway=riverbank`.
    case water = 3

    /// The cover an element's tags give, or nil for none of these.
    public init?(tags: [String: String]) {
        switch tags["natural"] {
        case "bare_rock", "scree": self = .rock
        case "glacier": self = .glacier
        case "water": self = .water
        default:
            guard tags["waterway"] == "riverbank" else { return nil }
            self = .water
        }
    }
}

/// An area of one land cover from OpenStreetMap: a closed way, or a multipolygon's rings.
public struct LandCoverArea: Sendable, Hashable {
    /// The way's id, or the relation's negated, so the two never clash.
    public var id: Int64
    public var cover: LandCover
    /// Closed rings (the first point repeated at the end), outer and inner alike: a point is
    /// in the area when it's inside an odd number of them.
    public var rings: [[LatLon]]

    public init(id: Int64, cover: LandCover, rings: [[LatLon]]) {
        self.id = id
        self.cover = cover
        self.rings = rings
    }

    /// The box around it.
    public var bounds: GeoBox {
        var box = GeoBox(south: .infinity, west: .infinity, north: -.infinity, east: -.infinity)
        for ring in rings {
            for p in ring {
                box.south = min(box.south, p.latitude)
                box.north = max(box.north, p.latitude)
                box.west = min(box.west, p.longitude)
                box.east = max(box.east, p.longitude)
            }
        }
        return box
    }
}

extension GeoBox {
    /// A map area as a box, widened by `margin` meters on each side.
    public init(_ extent: MapExtent, margin: Double = 0) {
        let projection = MapProjection(center: extent.center)
        let sw = projection.latLon(SIMD2(-extent.width / 2 - margin, -extent.height / 2 - margin))
        let ne = projection.latLon(SIMD2(extent.width / 2 + margin, extent.height / 2 + margin))
        self.init(south: sw.latitude, west: sw.longitude, north: ne.latitude, east: ne.longitude)
    }

    public func intersects(_ other: GeoBox) -> Bool {
        south <= other.north && north >= other.south && west <= other.east && east >= other.west
    }

    /// The part of the box inside `other`, or nil when they don't overlap.
    public func intersection(_ other: GeoBox) -> GeoBox? {
        let box = GeoBox(south: max(south, other.south), west: max(west, other.west),
                         north: min(north, other.north), east: min(east, other.east))
        return box.south < box.north && box.west < box.east ? box : nil
    }
}

/// The 0.1° grid cells land cover is fetched and kept by, so nearby trails, peaks and
/// saved areas share one download. A cell keeps every area that reaches into it, whole.
public struct LandCoverCell: Sendable, Hashable, Comparable {
    /// The south-west corner in tenths of a degree.
    public var south: Int
    public var west: Int

    public init(south: Int, west: Int) {
        self.south = south
        self.west = west
    }

    /// The cell a point is in.
    public init(_ p: LatLon) {
        self.init(south: Int((p.latitude * 10).rounded(.down)), west: Int((p.longitude * 10).rounded(.down)))
    }

    public var box: GeoBox {
        GeoBox(south: Double(south) / 10, west: Double(west) / 10, north: Double(south + 1) / 10, east: Double(west + 1) / 10)
    }

    public var fileName: String { "\(south)_\(west).pklc" }

    /// The cells a box reaches into, rows from the south.
    public static func covering(_ box: GeoBox) -> [LandCoverCell] {
        let low = LandCoverCell(LatLon(box.south, box.west)), high = LandCoverCell(LatLon(box.north, box.east))
        guard low.south <= high.south, low.west <= high.west else { return [] }
        return (low.south...high.south).flatMap { s in (low.west...high.west).map { LandCoverCell(south: s, west: $0) } }
    }

    /// Cells grouped into blocks at most `side` cells each way, one query each: an Alpine
    /// block of 3 by 3 comes to a few megabytes.
    public static func batches(_ cells: [LandCoverCell], side: Int = 3) -> [[LandCoverCell]] {
        // Blocks counted from the south-west cell, so a square of cells splits evenly.
        guard let south = cells.map(\.south).min(), let west = cells.map(\.west).min() else { return [] }
        let groups = Dictionary(grouping: Set(cells)) { [($0.south - south) / side, ($0.west - west) / side] }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// The box around some cells.
    public static func box(_ cells: [LandCoverCell]) -> GeoBox? {
        guard let first = cells.first else { return nil }
        return cells.dropFirst().reduce(first.box) { box, cell in
            let b = cell.box
            return GeoBox(south: min(box.south, b.south), west: min(box.west, b.west),
                          north: max(box.north, b.north), east: max(box.east, b.east))
        }
    }

    public static func < (a: LandCoverCell, b: LandCoverCell) -> Bool { (a.south, a.west) < (b.south, b.west) }
}

extension Overpass {
    /// Land cover in a box (degrees): ways and multipolygon relations of bare rock, scree,
    /// glaciers and water, with their whole geometry (not clipped to the box: a ring that
    /// crosses its edge wouldn't close).
    public static func landCoverQuery(south: Double, west: Double, north: Double, east: Double, timeout: Int = 90) -> String {
        let box = String(format: "%.5f,%.5f,%.5f,%.5f", south, west, north, east)
        let natural = "[\"natural\"~\"^(bare_rock|scree|glacier|water)$\"]"
        return """
        [out:json][timeout:\(timeout)];
        (
          way\(natural)(\(box));
          way["waterway"="riverbank"](\(box));
        );
        out tags geom;
        (
          relation\(natural)["type"="multipolygon"](\(box));
          relation["waterway"="riverbank"]["type"="multipolygon"](\(box));
        );
        out geom;
        """
    }

    /// The areas in an Overpass response to `landCoverQuery`. A relation's member ways are
    /// joined into rings; ways that don't close a ring (a member missing, or broken mapping)
    /// are left out, since they'd spill the fill across the map.
    public static func landCover(fromJSON data: Data) throws -> [LandCoverArea] {
        struct Point: Decodable {
            var lat: Double
            var lon: Double
        }
        struct Member: Decodable {
            var type: String
            var geometry: [Point?]?
        }
        struct Element: Decodable {
            var type: String
            var id: Int64
            var tags: [String: String]?
            var members: [Member]?
            var geometry: [Point?]?
        }
        struct Response: Decodable { var elements: [Element] }

        // Points of a way, split where some are missing.
        func pieces(_ geometry: [Point?]) -> [[LatLon]] {
            var out: [[LatLon]] = [], current: [LatLon] = []
            for p in geometry {
                if let p { current.append(LatLon(p.lat, p.lon)) } else if !current.isEmpty { out.append(current); current = [] }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        func closed(_ ring: [LatLon]) -> Bool {
            guard ring.count >= 4, let a = ring.first, let b = ring.last else { return false }
            return abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7
        }

        var areas: [LandCoverArea] = []
        for e in try JSONDecoder().decode(Response.self, from: data).elements {
            guard let cover = LandCover(tags: e.tags ?? [:]) else { continue }
            let rings: [[LatLon]]
            switch e.type {
            case "way":
                rings = pieces(e.geometry ?? []).filter(closed)
            case "relation":
                let parts = (e.members ?? []).filter { $0.type == "way" }.flatMap { pieces($0.geometry ?? []) }
                rings = Trail.chain(parts).filter(closed)
            default:
                continue
            }
            guard !rings.isEmpty else { continue }
            areas.append(LandCoverArea(id: e.type == "relation" ? -e.id : e.id, cover: cover, rings: rings))
        }
        return areas
    }
}

// MARK: Keeping it on the phone

extension LandCoverArea {
    private static let magic = Array("PKLC".utf8)

    /// Areas in a compact form for keeping on the phone, 8 bytes a point (to about a
    /// centimeter): an Overpass answer is six times the size.
    public static func encode(_ areas: [LandCoverArea]) -> Data {
        var out = Data(magic)
        out.append(1)   // version
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put(UInt32(areas.count))
        for area in areas {
            put(area.id)
            out.append(area.cover.rawValue)
            put(UInt32(area.rings.count))
            for ring in area.rings {
                put(UInt32(ring.count))
                for p in ring {
                    put(Int32((p.latitude * 1e7).rounded()))
                    put(Int32((p.longitude * 1e7).rounded()))
                }
            }
        }
        return out
    }

    /// Areas from `encode`. Throws for anything else, or a file cut short.
    public static func decode(_ data: Data) throws -> [LandCoverArea] {
        let bytes = [UInt8](data)
        var at = 0
        func take<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard at + size <= bytes.count else { throw CocoaError(.coderReadCorrupt) }
            var v: T = 0
            for k in 0..<size { v |= T(truncatingIfNeeded: bytes[at + k]) << (8 * k) }
            at += size
            return v
        }
        guard bytes.count >= magic.count + 1, Array(bytes[0..<magic.count]) == magic, bytes[magic.count] == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        at = magic.count + 1
        let count = Int(try take(UInt32.self))
        var areas: [LandCoverArea] = []
        areas.reserveCapacity(min(count, bytes.count / 30))
        for _ in 0..<count {
            let id = try take(Int64.self)
            guard let cover = LandCover(rawValue: try take(UInt8.self)) else { throw CocoaError(.coderReadCorrupt) }
            let ringCount = Int(try take(UInt32.self))
            guard ringCount <= (bytes.count - at) / 4 else { throw CocoaError(.coderReadCorrupt) }
            var rings: [[LatLon]] = []
            for _ in 0..<ringCount {
                let n = Int(try take(UInt32.self))
                guard n <= (bytes.count - at) / 8 else { throw CocoaError(.coderReadCorrupt) }
                var ring: [LatLon] = []
                ring.reserveCapacity(n)
                for _ in 0..<n {
                    let lat = Double(try take(Int32.self)) / 1e7, lon = Double(try take(Int32.self)) / 1e7
                    ring.append(LatLon(lat, lon))
                }
                rings.append(ring)
            }
            areas.append(LandCoverArea(id: id, cover: cover, rings: rings))
        }
        return areas
    }
}

// MARK: On the map's grid

/// How much of the square around each point of a `ReliefMap`'s grid (a cell wide) each land
/// cover takes, 0 to 1, row by row from the north like the heights. Covers can overlap (a
/// lake on a glacier); drawing them in the order rock, glacier, water puts the right one on top.
public struct LandCoverGrid: Sendable {
    public let rows: Int
    public let cols: Int
    public internal(set) var rock: [Float]
    public internal(set) var glacier: [Float]
    public internal(set) var water: [Float]

    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        rock = [Float](repeating: 0, count: rows * cols)
        glacier = rock
        water = rock
    }

    public subscript(cover: LandCover) -> [Float] {
        switch cover {
        case .rock: return rock
        case .glacier: return glacier
        case .water: return water
        }
    }

    /// Nothing covered anywhere.
    public var isEmpty: Bool { !rock.contains { $0 > 0 } && !glacier.contains { $0 > 0 } && !water.contains { $0 > 0 } }
}

extension ReliefMap {
    /// The box the grid covers, from its first point to its last.
    public var box: GeoBox {
        let sw = projection.latLon(-size / 2), ne = projection.latLon(size / 2)
        return GeoBox(south: sw.latitude, west: sw.longitude, north: ne.latitude, east: ne.longitude)
    }

    /// Land cover on this grid. Each square is measured along four lines across it, so edges
    /// come out soft rather than stepped, and a stream narrower than a cell still shows,
    /// faintly. Outside `within` (where land cover was fetched) there is none, and inside it
    /// fades in over `fade` meters, so it doesn't end in a hard straight edge.
    public func landCover(_ areas: [LandCoverArea], within: GeoBox? = nil, fade: Double = 0) -> LandCoverGrid {
        var grid = LandCoverGrid(rows: rows, cols: cols)
        let lines = 4
        let step = cellSize / Double(lines)
        // The edges of the squares around the grid points.
        let top = Double(rows - 1) / 2 * cellSize + cellSize / 2, bottom = top - Double(rows) * cellSize
        let left = -Double(cols - 1) / 2 * cellSize - cellSize / 2, right = left + Double(cols) * cellSize
        let weight = Float(1 / (cellSize * Double(lines)))

        func fill(_ out: inout [Float], _ rings: [[SIMD2<Double>]], first: Int, last: Int) {
            // Where the rings' edges cross each scan line. Scan line k is at
            // y = top − (k + ½)·step; an edge crosses it when its low end is at or below it
            // and its high end above, so a vertex on the line counts once.
            var crossings = [[Double]](repeating: [], count: last - first + 1)
            for ring in rings {
                for (a, b) in zip(ring, ring.dropFirst()) where a.y != b.y {
                    let low = min(a.y, b.y), high = max(a.y, b.y)
                    let k0 = max(first, Int(((top - high) / step - 0.5).rounded(.down)) + 1)
                    let k1 = min(last, Int(((top - low) / step - 0.5).rounded(.down)))
                    guard k0 <= k1 else { continue }
                    let slope = (b.x - a.x) / (b.y - a.y)
                    for k in k0...k1 {
                        let y = top - (Double(k) + 0.5) * step
                        crossings[k - first].append(a.x + (y - a.y) * slope)
                    }
                }
            }
            // Inside between the first and second crossing, the third and fourth, and so on.
            for (offset, found) in crossings.enumerated() where found.count >= 2 {
                let xs = found.sorted()
                let row = (first + offset) / lines
                for i in stride(from: 0, to: xs.count - 1, by: 2) {
                    let a = max(left, xs[i]), b = min(right, xs[i + 1])
                    guard b > a else { continue }
                    let c0 = Int((a - left) / cellSize), c1 = min(cols - 1, Int((b - left) / cellSize))
                    for c in c0...c1 {
                        let l = left + Double(c) * cellSize
                        let overlap = min(b, l + cellSize) - max(a, l)
                        if overlap > 0 { out[row * cols + c] += Float(overlap) * weight }
                    }
                }
            }
        }

        for area in areas {
            let rings = area.rings.map { $0.map(projection.point) }
            var low = Double.infinity, high = -Double.infinity, west = Double.infinity, east = -Double.infinity
            for ring in rings {
                for p in ring {
                    low = min(low, p.y)
                    high = max(high, p.y)
                    west = min(west, p.x)
                    east = max(east, p.x)
                }
            }
            guard high > bottom, low < top, east > left, west < right else { continue }
            let first = max(0, Int(((top - high) / step - 0.5).rounded(.down)) + 1)
            let last = min(rows * lines - 1, Int(((top - low) / step - 0.5).rounded(.down)))
            guard first <= last else { continue }
            switch area.cover {
            case .rock: fill(&grid.rock, rings, first: first, last: last)
            case .glacier: fill(&grid.glacier, rings, first: first, last: last)
            case .water: fill(&grid.water, rings, first: first, last: last)
            }
        }

        // Overlapping areas of one cover (mapped twice) add up to more than all of it.
        var fadeIn = [Float](repeating: 1, count: rows * cols)
        if let within {
            let sw = projection.point(LatLon(within.south, within.west)), ne = projection.point(LatLon(within.north, within.east))
            for r in 0..<rows {
                for c in 0..<cols {
                    let p = position(row: Double(r), col: Double(c))
                    let inside = min(p.x - sw.x, ne.x - p.x, p.y - sw.y, ne.y - p.y)
                    let t = fade > 0 ? min(1, max(0, inside / fade)) : (inside >= 0 ? 1 : 0)
                    fadeIn[r * cols + c] = Float(t * t * (3 - 2 * t))
                }
            }
        }
        for i in 0..<(rows * cols) {
            grid.rock[i] = min(1, grid.rock[i]) * fadeIn[i]
            grid.glacier[i] = min(1, grid.glacier[i]) * fadeIn[i]
            grid.water[i] = min(1, grid.water[i]) * fadeIn[i]
        }
        return grid
    }
}

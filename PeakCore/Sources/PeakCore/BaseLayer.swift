import Dispatch
import Foundation

/// The worldwide base layer bundled with the app: coarse terrain and every named peak, so
/// the view works on first launch anywhere, before any download (and without a signal).
///
/// Built by Tools/build_base_layer.py from NOAA ETOPO 2022 (public domain) and
/// OpenStreetMap (ODbL); its docstring has the file layout. Each 1° cell is a grid of 30″
/// (about 0.9 km) where the relief is high, down to 4′ (about 7 km) over plains and ice;
/// open sea has none. Tiles made from it are marked `isCoarse`: they are good for far
/// skylines, not for what's near or for telling whether a nearby peak is in sight.
public final class BaseLayer: @unchecked Sendable {
    static let magic = Array("PKBL".utf8)
    static let headerSize = 64
    static let cellCount = 180 * 360
    static let blockSize = 5
    static let blockCount = (180 / blockSize) * (360 / blockSize)

    private let data: Data
    /// Height step of the stored values, meters.
    public let heightStep: Double
    /// Peaks in the file.
    public let peakCount: Int
    private let terrainIndex: Int
    private let terrainData: Int
    private let peakIndex: Int
    private let peakData: Int
    private let lock = NSLock()
    private var cache: [Int: ElevationTile] = [:]

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped), name: url.lastPathComponent)
    }

    public init(data: Data, name: String = "base layer") throws {
        guard data.count >= Self.headerSize, Array(data.prefix(4)) == Self.magic else {
            throw TerrainError.badFile(name, "not a base layer")
        }
        self.data = data
        let version = data.u32(4)
        guard version == 1 else { throw TerrainError.badFile(name, "version \(version)") }
        heightStep = Double(Float(bitPattern: data.u32(8)))
        peakCount = Int(data.u32(12))
        terrainIndex = Int(data.u64(16))
        terrainData = Int(data.u64(24))
        peakIndex = Int(data.u64(32))
        peakData = Int(data.u64(40))
        guard terrainData - terrainIndex == Self.cellCount * 6, peakData - peakIndex == Self.blockCount * 4,
              peakData <= data.count else {
            throw TerrainError.badFile(name, "damaged")
        }
    }

    // MARK: Terrain

    /// The 1° cell south…south+1, west…west+1: a coarse tile, or a flat one for open sea.
    /// Nil if the cell can't be read (a damaged file). Tiles are kept once read.
    public func tile(south: Int, west: Int) -> ElevationTile? {
        guard south >= -90, south < 90 else { return nil }
        let west = (west + 540) % 360 - 180
        let cell = (south + 90) * 360 + (west + 180)
        lock.lock()
        if let tile = cache[cell] {
            lock.unlock()
            return tile
        }
        lock.unlock()
        guard let tile = decode(cell: cell, south: south, west: west) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let other = cache[cell] { return other }
        cache[cell] = tile
        return tile
    }

    /// The cells within `radius` meters of a point, as tiles (`DataStore`'s 1° tiles).
    public func tiles(latitude: Double, longitude: Double, radius: Double) -> [ElevationTile] {
        Self.cells(latitude: latitude, longitude: longitude, radius: radius).compactMap { tile(south: $0.south, west: $0.west) }
    }

    /// 1° cells (south, west) covering `radius` meters around a point.
    public static func cells(latitude: Double, longitude: Double, radius: Double) -> [(south: Int, west: Int)] {
        let dlat = radius / 111_000
        let dlon = radius / (111_000 * max(cos(latitude * .pi / 180), 0.05))
        var cells: [(south: Int, west: Int)] = []
        for south in Int((latitude - dlat).rounded(.down))...Int((latitude + dlat).rounded(.down)) where south >= -90 && south < 90 {
            for west in Int((longitude - dlon).rounded(.down))...Int((longitude + dlon).rounded(.down)) {
                cells.append((south, (west + 540) % 360 - 180))
            }
        }
        return cells
    }

    private func decode(cell: Int, south: Int, west: Int) -> ElevationTile? {
        let entry = terrainIndex + cell * 6
        let rows = Int(data[data.startIndex + entry]), cols = Int(data[data.startIndex + entry + 1])
        let end = Int(data.u32(entry + 2))
        let start = cell == 0 ? 0 : Int(data.u32(entry - 4))
        guard rows > 0, cols > 0 else {
            // Open sea: flat at sea level, which is exact.
            return ElevationTile(south: south, west: west, size: 2) { _, _ in 0 }
        }
        guard start <= end, terrainData + end <= peakIndex,
              let planes = try? Inflate.zlib([UInt8](data[(data.startIndex + terrainData + start)..<(data.startIndex + terrainData + end)]),
                                             expectedSize: 2 * rows * cols),
              planes.count == 2 * rows * cols else { return nil }
        let n = rows * cols
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: n)
        // Undo the planar prediction: value = residual + left + up − up-left.
        var values = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let z = Int32(planes[i]) | Int32(planes[n + i]) << 8
            let residual = (z >> 1) ^ -(z & 1)
            let r = i / cols, c = i % cols
            let predicted: Int32
            if r == 0 {
                predicted = c == 0 ? 0 : values[i - 1]
            } else if c == 0 {
                predicted = values[i - cols]
            } else {
                predicted = values[i - 1] + values[i - cols] - values[i - cols - 1]
            }
            values[i] = residual + predicted
            buffer[i] = Int16(max(-32767, min(32767, (Double(values[i]) * heightStep).rounded())))
        }
        // Pixels are areas: pixel (0, 0) is centered half a pixel in from the north-west corner.
        let tile = ElevationTile(south: south, west: west, rows: rows, cols: cols,
                                 originLatitude: Double(south + 1) - 0.5 / Double(rows),
                                 originLongitude: Double(west) + 0.5 / Double(cols),
                                 stepLatitude: 1 / Double(rows), stepLongitude: 1 / Double(cols), taking: buffer)
        tile.isCoarse = true
        return tile
    }

    // MARK: Peaks

    /// Named peaks within `radius` meters of a point. Those without an elevation in
    /// OpenStreetMap have `estimatedElevation` set, for the terrain to fill in.
    public func peaks(latitude: Double, longitude: Double, radius: Double) -> [Peak] {
        let here = LatLon(latitude, longitude)
        let dlat = radius / 111_000
        let dlon = radius / (111_000 * max(cos(latitude * .pi / 180), 0.05))
        let rows = Int(((latitude - dlat + 90) / Double(Self.blockSize)).rounded(.down))...Int(((latitude + dlat + 90) / Double(Self.blockSize)).rounded(.down))
        let cols = Int(((longitude - dlon + 180) / Double(Self.blockSize)).rounded(.down))...Int(((longitude + dlon + 180) / Double(Self.blockSize)).rounded(.down))
        let perRow = 360 / Self.blockSize
        var blocks = Set<Int>()
        for r in rows where r >= 0 && r < 180 / Self.blockSize {
            for c in cols { blocks.insert(r * perRow + ((c % perRow) + perRow) % perRow) }
        }
        return blocks.sorted().flatMap { peaks(inBlock: $0) }.filter { here.distance(to: $0.position) <= radius }
    }

    /// Every peak of one 5° block.
    func peaks(inBlock block: Int) -> [Peak] {
        let end = Int(data.u32(peakIndex + block * 4))
        let start = block == 0 ? 0 : Int(data.u32(peakIndex + (block - 1) * 4))
        guard start < end, peakData + end <= data.count,
              let bytes = try? Inflate.zlib([UInt8](data[(data.startIndex + peakData + start)..<(data.startIndex + peakData + end)]))
        else { return [] }
        var reader = ByteReader(bytes: bytes)
        guard let count = reader.u32().map(Int.init), count < 10_000_000 else { return [] }
        let south = Double((block / (360 / Self.blockSize)) * Self.blockSize - 90)
        let west = Double((block % (360 / Self.blockSize)) * Self.blockSize - 180)
        var ids = [Int64](), lats = [Double](), lons = [Double](), elevations = [Int16](), prominences = [UInt16](), wikidata = [UInt64]()
        var id: Int64 = 0
        for _ in 0..<count {
            guard let d = reader.varint() else { return [] }
            id += Int64(d)
            ids.append(id)
        }
        for _ in 0..<count { lats.append(south + Double(reader.u24() ?? 0) / 1e5) }
        for _ in 0..<count { lons.append(west + Double(reader.u24() ?? 0) / 1e5) }
        for _ in 0..<count { elevations.append(Int16(bitPattern: reader.u16() ?? 0)) }
        for _ in 0..<count { prominences.append(reader.u16() ?? 0) }
        for _ in 0..<count { wikidata.append(reader.varint() ?? 0) }
        var peaks: [Peak] = []
        peaks.reserveCapacity(count)
        for i in 0..<count {
            guard let name = reader.cString(), !reader.failed else { return peaks }
            let known = elevations[i] != Int16.min
            var peak = Peak(id: ids[i], name: name, latitude: lats[i], longitude: lons[i],
                            elevation: known ? Double(elevations[i]) : 0,
                            prominence: prominences[i] > 0 ? Double(prominences[i]) : nil,
                            wikidata: wikidata[i] > 0 ? "Q\(wikidata[i])" : nil)
            peak.estimatedElevation = !known
            peaks.append(peak)
        }
        return peaks
    }
}

/// Reads little-endian values one after another; past the end it returns nil and sets `failed`.
private struct ByteReader {
    let bytes: [UInt8]
    var at = 0
    var failed = false

    mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard at + n <= bytes.count else { failed = true; return nil }
        defer { at += n }
        return bytes[at..<at + n]
    }

    mutating func u16() -> UInt16? { take(2).map { UInt16($0[$0.startIndex]) | UInt16($0[$0.startIndex + 1]) << 8 } }
    mutating func u24() -> UInt32? {
        take(3).map { UInt32($0[$0.startIndex]) | UInt32($0[$0.startIndex + 1]) << 8 | UInt32($0[$0.startIndex + 2]) << 16 }
    }
    mutating func u32() -> UInt32? {
        take(4).map { $0.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
    }

    mutating func varint() -> UInt64? {
        var value: UInt64 = 0, shift: UInt64 = 0
        while let b = take(1)?.first {
            value |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { failed = true; return nil }
        }
        return nil
    }

    mutating func cString() -> String? {
        guard let end = bytes[at...].firstIndex(of: 0) else { failed = true; return nil }
        defer { at = end + 1 }
        return String(decoding: bytes[at..<end], as: UTF8.self)
    }
}

private extension Data {
    func u32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    func u64(_ offset: Int) -> UInt64 {
        withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}

extension Terrain {
    /// Terrain from `tiles` and `detail` where they are, and the base layer's coarse tiles
    /// for every other 1° cell within `radius` meters of a point.
    public convenience init(tiles: [ElevationTile], detail: [ElevationTile] = [], base: BaseLayer,
                            latitude: Double, longitude: Double, radius: Double) {
        let have = Set(tiles.map { $0.south * 1000 + $0.west })
        let fill = BaseLayer.cells(latitude: latitude, longitude: longitude, radius: radius)
            .filter { !have.contains($0.south * 1000 + $0.west) }
            .compactMap { base.tile(south: $0.south, west: $0.west) }
        self.init(tiles: tiles + fill, detail: detail, missingIsSea: false)
    }
}

/// What can be told about a peak's line of sight when it crosses the base layer's coarse
/// terrain, whose ridges are typically 75 m and up to 400 m off in height.
public enum CoarseSight {
    /// Nearer than this, whether a peak shows over the coarse ridges in front can't be told.
    public static let nearDistance = 20_000.0
    /// Height error allowed for the ridges in front of a farther peak, meters.
    public static let heightError = 150.0

    /// Whether a peak `distance` meters away that clears the terrain in front by `clearance`
    /// degrees (negative: hidden) may as well be hidden as in sight, or the other way round.
    /// The terrain in front is taken to be about halfway there.
    public static func isUncertain(distance: Double, clearance: Double) -> Bool {
        distance < nearDistance || abs(clearance) < atan(heightError / max(distance / 2, 1)) * 180 / .pi
    }
}

extension Terrain {
    /// Whether any of the ground between two points is the base layer's coarse terrain.
    public func isCoarse(between a: LatLon, and b: LatLon, samples: Int = 16) -> Bool {
        guard hasCoarse else { return false }
        return (0...samples).contains { k in
            let t = Double(k) / Double(samples)
            return isCoarse(latitude: a.latitude + (b.latitude - a.latitude) * t,
                            longitude: a.longitude + (b.longitude - a.longitude) * t)
        }
    }
}

extension HorizonRenderer {
    /// Line of sight to every peak between 200 m and `maxDistance` away, in no set order.
    public func sightlines(_ peaks: [Peak], from observer: GeoPoint, maxDistance: Double,
                           settings: HorizonSettings = HorizonSettings()) -> [(peak: Peak, visibility: Visibility)] {
        let near = peaks.filter {
            let d = groundDistance(from: observer, to: $0.point)
            return d > 200 && d < maxDistance
        }
        var results = [Visibility?](repeating: nil, count: near.count)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: near.count) { i in
                out[i] = visibility(of: near[i].point, from: observer, settings: settings)
            }
        }
        return zip(near, results).map { ($0, $1!) }
    }
}

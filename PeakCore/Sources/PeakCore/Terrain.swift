import Foundation

/// One DEM tile: a grid of heights in meters, rows from north to south.
///
/// Pixel centers sit at `originLatitude − row·stepLatitude`, `originLongitude + col·stepLongitude`.
/// Copernicus GLO-30 tiles are 1° with the first pixel centered on the tile's north-west
/// corner (3600 rows; 3600 columns below 50° latitude, fewer further north). A tile can
/// also cover just part of its 1° cell, as a sharper patch over a coarser tile; pixels it
/// has no data for hold `noData`.
public final class ElevationTile: @unchecked Sendable {
    /// Marks a pixel without data. Decoded heights never take this value.
    public static let noData = Int16.min

    public let south: Int
    public let west: Int
    public let rows: Int
    public let cols: Int
    public let originLatitude: Double
    public let originLongitude: Double
    public let stepLatitude: Double
    public let stepLongitude: Double
    let heights: UnsafeMutableBufferPointer<Int16>

    public convenience init(south: Int, west: Int, rows: Int, cols: Int,
                            originLatitude: Double, originLongitude: Double,
                            stepLatitude: Double, stepLongitude: Double, heights: [Int16]) {
        precondition(heights.count == rows * cols, "expected \(rows * cols) heights, got \(heights.count)")
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: heights.count)
        _ = buffer.initialize(from: heights)
        self.init(south: south, west: west, rows: rows, cols: cols, originLatitude: originLatitude,
                  originLongitude: originLongitude, stepLatitude: stepLatitude, stepLongitude: stepLongitude,
                  taking: buffer)
    }

    /// Takes ownership of `buffer`, which must hold rows × cols heights.
    init(south: Int, west: Int, rows: Int, cols: Int, originLatitude: Double, originLongitude: Double,
         stepLatitude: Double, stepLongitude: Double, taking buffer: UnsafeMutableBufferPointer<Int16>) {
        self.south = south
        self.west = west
        self.rows = rows
        self.cols = cols
        self.originLatitude = originLatitude
        self.originLongitude = originLongitude
        self.stepLatitude = stepLatitude
        self.stepLongitude = stepLongitude
        heights = buffer
    }

    /// A Copernicus-style 1° tile filled by `height(latitude, longitude)`, for tests.
    public convenience init(south: Int, west: Int, size: Int = 3600, height: (Double, Double) -> Double) {
        let step = 1.0 / Double(size)
        var values = [Int16](repeating: 0, count: size * size)
        for r in 0..<size {
            let lat = Double(south + 1) - Double(r) * step
            for c in 0..<size {
                let h = height(lat, Double(west) + Double(c) * step)
                values[r * size + c] = Int16(max(-32767, min(32767, h.rounded())))
            }
        }
        self.init(south: south, west: west, rows: size, cols: size,
                  originLatitude: Double(south + 1), originLongitude: Double(west),
                  stepLatitude: step, stepLongitude: step, heights: values)
    }

    deinit { heights.deallocate() }

    static let magic = Array("PKDM".utf8)
    static let headerSize = 64

    /// Reads a .pkdem file written by Tools/fetch_dem.py.
    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= Self.headerSize, Array(data.prefix(4)) == Self.magic else {
            throw TerrainError.badFile(url.lastPathComponent, "not a .pkdem file")
        }
        func int32(_ offset: Int) -> Int32 {
            data.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int32.self)) }
        }
        func double(_ offset: Int) -> Double {
            data.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))) }
        }
        let version = int32(4)
        guard version == 1 else { throw TerrainError.badFile(url.lastPathComponent, "version \(version)") }
        let rows = Int(int32(16)), cols = Int(int32(20))
        guard data.count == Self.headerSize + rows * cols * 2 else {
            throw TerrainError.badFile(url.lastPathComponent, "size doesn't match \(rows)x\(cols)")
        }
        // Copy the heights straight from the mapped file into the tile's own memory.
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: rows * cols)
        data.withUnsafeBytes { src in
            UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: src[Self.headerSize...]))
        }
        #if _endian(big)
        for i in buffer.indices { buffer[i] = Int16(littleEndian: buffer[i]) }
        #endif
        self.init(south: Int(int32(8)), west: Int(int32(12)), rows: rows, cols: cols,
                  originLatitude: double(24), originLongitude: double(32),
                  stepLatitude: double(40), stepLongitude: double(48), taking: buffer)
    }

    public func write(to url: URL) throws {
        var data = Data(Self.magic)
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append(Int32(1))
        append(Int32(south))
        append(Int32(west))
        append(Int32(rows))
        append(Int32(cols))
        for v in [originLatitude, originLongitude, stepLatitude, stepLongitude] { append(v.bitPattern) }
        data.append(Data(count: Self.headerSize - data.count))
        data.append(UnsafeBufferPointer(heights))
        try data.write(to: url)
    }

    /// Joins patches of one cell with the same pixel grid (such as neighboring blocks of a
    /// GeoTIFF) into one patch covering all of them; pixels none of them cover are `noData`.
    public convenience init?(merging parts: [ElevationTile]) {
        guard let first = parts.first,
              parts.allSatisfy({ $0.south == first.south && $0.west == first.west &&
                                 abs($0.stepLatitude - first.stepLatitude) < 1e-12 &&
                                 abs($0.stepLongitude - first.stepLongitude) < 1e-12 }) else { return nil }
        // Pixel offsets of each part from the first one's origin.
        let offsets = parts.map { t in
            (row: Int(((first.originLatitude - t.originLatitude) / first.stepLatitude).rounded()),
             col: Int(((t.originLongitude - first.originLongitude) / first.stepLongitude).rounded()))
        }
        let row0 = offsets.map(\.row).min()!, col0 = offsets.map(\.col).min()!
        let rows = zip(parts, offsets).map { $1.row + $0.rows }.max()! - row0
        let cols = zip(parts, offsets).map { $1.col + $0.cols }.max()! - col0
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: rows * cols)
        buffer.initialize(repeating: Self.noData)
        for (t, o) in zip(parts, offsets) {
            for r in 0..<t.rows {
                let dst = (o.row - row0 + r) * cols + (o.col - col0)
                for c in 0..<t.cols where t.heights[r * t.cols + c] != Self.noData {
                    buffer[dst + c] = t.heights[r * t.cols + c]
                }
            }
        }
        self.init(south: first.south, west: first.west, rows: rows, cols: cols,
                  originLatitude: first.originLatitude - Double(row0) * first.stepLatitude,
                  originLongitude: first.originLongitude + Double(col0) * first.stepLongitude,
                  stepLatitude: first.stepLatitude, stepLongitude: first.stepLongitude, taking: buffer)
    }

    @inline(__always)
    func value(row: Int, col: Int) -> Int16 { heights[row * cols + col] }

    /// Bilinear height inside the patch, or nil near its edges or where it has no data.
    @inline(__always)
    func interiorHeight(_ latitude: Double, _ longitude: Double) -> Double? {
        let y = (originLatitude - latitude) / stepLatitude
        let x = (longitude - originLongitude) / stepLongitude
        guard y >= 0, x >= 0 else { return nil }
        let r0 = Int(y), c0 = Int(x)
        guard r0 + 1 < rows, c0 + 1 < cols else { return nil }
        let i = r0 * cols + c0
        let a = heights[i], b = heights[i + 1], c = heights[i + cols], d = heights[i + cols + 1]
        if a == Self.noData || b == Self.noData || c == Self.noData || d == Self.noData { return nil }
        let fy = y - Double(r0), fx = x - Double(c0)
        return (Double(a) * (1 - fx) + Double(b) * fx) * (1 - fy) + (Double(c) * (1 - fx) + Double(d) * fx) * fy
    }

    /// The share of the 1° cell this tile covers with data, 0 to 1.
    public var coverage: Double {
        let area = Double(rows) * stepLatitude * Double(cols) * stepLongitude
        let filled = Double(heights.reduce(0) { $1 == Self.noData ? $0 : $0 + 1 }) / Double(max(1, rows * cols))
        return min(1, area * filled)
    }

    /// All heights, row by row from the north.
    public var heightValues: [Int16] { Array(heights) }
}

public enum TerrainError: Error, CustomStringConvertible {
    case badFile(String, String)
    case empty(String)

    public var description: String {
        switch self {
        case let .badFile(name, why): return "\(name): \(why)"
        case let .empty(dir): return "no .pkdem tiles in \(dir)"
        }
    }
}

/// A set of 1° tiles with bilinear height lookups that work across tile edges, plus
/// optional sharper patches over parts of them.
///
/// By default, a missing tile inside the bounding box of the loaded tiles reads as sea
/// level, since the Copernicus bucket has no tiles over open ocean. Outside the box, or
/// everywhere with `missingIsSea: false`, missing heights are NaN, so rays stop where the
/// data stops instead of seeing a flat sea.
public final class Terrain: @unchecked Sendable {
    public let tiles: [ElevationTile]
    public let detail: [ElevationTile]
    let minSouth: Int
    let minWest: Int
    let latCount: Int
    let lonCount: Int
    let grid: [ElevationTile?]
    let missing: Double
    /// Patches of each cell, finest first: `patches[patchStart[cell]..<patchStart[cell + 1]]`.
    let patches: [ElevationTile]
    let patchStart: [Int]

    /// `detail` patches are used wherever they have data, finest first; elsewhere, and
    /// within a pixel of their edges, the 1° `tiles` are.
    public init(tiles: [ElevationTile], detail: [ElevationTile] = [], missingIsSea: Bool = true) {
        self.tiles = tiles
        self.detail = detail
        missing = missingIsSea ? 0 : .nan
        let all = tiles + detail
        minSouth = all.map(\.south).min() ?? 0
        minWest = all.map(\.west).min() ?? 0
        latCount = all.isEmpty ? 0 : (all.map(\.south).max()! - minSouth + 1)
        lonCount = all.isEmpty ? 0 : (all.map(\.west).max()! - minWest + 1)
        var grid = [ElevationTile?](repeating: nil, count: latCount * lonCount)
        for t in tiles { grid[(t.south - minSouth) * lonCount + (t.west - minWest)] = t }
        self.grid = grid
        var byCell = [[ElevationTile]](repeating: [], count: latCount * lonCount)
        for t in detail { byCell[(t.south - minSouth) * lonCount + (t.west - minWest)].append(t) }
        var start = [0]
        var patches: [ElevationTile] = []
        for cell in byCell {
            patches += cell.sorted { $0.stepLatitude < $1.stepLatitude }
            start.append(patches.count)
        }
        self.patches = patches
        patchStart = start
    }

    /// Loads every .pkdem file in a directory.
    public convenience init(directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pkdem" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw TerrainError.empty(directory.path) }
        try self.init(tiles: files.map { try ElevationTile(contentsOf: $0) })
    }

    /// Bilinearly interpolated height in meters, or NaN outside the loaded area.
    @inline(__always)
    public func height(latitude: Double, longitude: Double) -> Double {
        // A tile owns latitudes in (south, south + 1] and longitudes in [west, west + 1).
        let south = Int((latitude).rounded(.up)) - 1
        let west = Int(longitude.rounded(.down))
        let li = south - minSouth, wi = west - minWest
        guard li >= 0, li < latCount, wi >= 0, wi < lonCount else { return .nan }
        let cell = li * lonCount + wi
        if !patches.isEmpty {
            var k = patchStart[cell]
            let end = patchStart[cell + 1]
            while k < end {
                if let h = patches[k].interiorHeight(latitude, longitude) { return h }
                k += 1
            }
        }
        guard let tile = grid[cell] else { return missing }
        let y = (tile.originLatitude - latitude) / tile.stepLatitude
        let x = (longitude - tile.originLongitude) / tile.stepLongitude
        let r0 = Int(y.rounded(.down)), c0 = Int(x.rounded(.down))
        let fy = y - Double(r0), fx = x - Double(c0)
        if r0 >= 0, c0 >= 0, r0 + 1 < tile.rows, c0 + 1 < tile.cols {
            let i = r0 * tile.cols + c0
            let h00 = Double(tile.heights[i]), h01 = Double(tile.heights[i + 1])
            let h10 = Double(tile.heights[i + tile.cols]), h11 = Double(tile.heights[i + tile.cols + 1])
            return (h00 * (1 - fx) + h01 * fx) * (1 - fy) + (h10 * (1 - fx) + h11 * fx) * fy
        }
        // On the last row or column the neighbors live in the next tile.
        let h00 = sample(tile, r0, c0), h01 = sample(tile, r0, c0 + 1)
        let h10 = sample(tile, r0 + 1, c0), h11 = sample(tile, r0 + 1, c0 + 1)
        return (h00 * (1 - fx) + h01 * fx) * (1 - fy) + (h10 * (1 - fx) + h11 * fx) * fy
    }

    /// Height of pixel (row, col) of `tile`, following it into a neighbor tile when out of range.
    func sample(_ tile: ElevationTile, _ row: Int, _ col: Int) -> Double {
        if row >= 0, col >= 0, row < tile.rows, col < tile.cols {
            return Double(tile.value(row: row, col: col))
        }
        let lat = tile.originLatitude - Double(row) * tile.stepLatitude
        let lon = tile.originLongitude + Double(col) * tile.stepLongitude
        let south = Int(lat.rounded(.up)) - 1, west = Int(lon.rounded(.down))
        let li = south - minSouth, wi = west - minWest
        guard li >= 0, li < latCount, wi >= 0, wi < lonCount else { return .nan }
        guard let other = grid[li * lonCount + wi] else { return missing }
        let r = Int(((other.originLatitude - lat) / other.stepLatitude).rounded())
        let c = Int(((lon - other.originLongitude) / other.stepLongitude).rounded())
        return Double(other.value(row: max(0, min(other.rows - 1, r)), col: max(0, min(other.cols - 1, c))))
    }
}

import Foundation

/// One DEM tile: a grid of heights in meters, rows from north to south.
///
/// Pixel centers sit at `originLatitude − row·stepLatitude`, `originLongitude + col·stepLongitude`.
/// Copernicus GLO-30 tiles are 1° with the first pixel centered on the tile's north-west
/// corner (3600 rows; 3600 columns below 50° latitude, fewer further north).
public final class ElevationTile: @unchecked Sendable {
    public let south: Int
    public let west: Int
    public let rows: Int
    public let cols: Int
    public let originLatitude: Double
    public let originLongitude: Double
    public let stepLatitude: Double
    public let stepLongitude: Double
    let heights: UnsafeMutableBufferPointer<Int16>

    public init(south: Int, west: Int, rows: Int, cols: Int,
                originLatitude: Double, originLongitude: Double,
                stepLatitude: Double, stepLongitude: Double, heights: [Int16]) {
        precondition(heights.count == rows * cols, "expected \(rows * cols) heights, got \(heights.count)")
        self.south = south
        self.west = west
        self.rows = rows
        self.cols = cols
        self.originLatitude = originLatitude
        self.originLongitude = originLongitude
        self.stepLatitude = stepLatitude
        self.stepLongitude = stepLongitude
        self.heights = .allocate(capacity: heights.count)
        _ = self.heights.initialize(from: heights)
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
        var heights = [Int16](repeating: 0, count: rows * cols)
        heights.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[Self.headerSize...]))
            }
        }
        #if _endian(big)
        for i in heights.indices { heights[i] = Int16(littleEndian: heights[i]) }
        #endif
        self.init(south: Int(int32(8)), west: Int(int32(12)), rows: rows, cols: cols,
                  originLatitude: double(24), originLongitude: double(32),
                  stepLatitude: double(40), stepLongitude: double(48), heights: heights)
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

    @inline(__always)
    func value(row: Int, col: Int) -> Int16 { heights[row * cols + col] }
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

/// A set of 1° tiles with bilinear height lookups that work across tile edges.
///
/// Inside the bounding box of the loaded tiles a missing tile reads as sea level, since
/// the Copernicus bucket has no tiles over open ocean. Outside it, heights are NaN, so
/// rays stop where the data stops instead of seeing a flat sea.
public final class Terrain: @unchecked Sendable {
    public let tiles: [ElevationTile]
    let minSouth: Int
    let minWest: Int
    let latCount: Int
    let lonCount: Int
    let grid: [ElevationTile?]

    public init(tiles: [ElevationTile]) {
        self.tiles = tiles
        minSouth = tiles.map(\.south).min() ?? 0
        minWest = tiles.map(\.west).min() ?? 0
        latCount = tiles.isEmpty ? 0 : (tiles.map(\.south).max()! - minSouth + 1)
        lonCount = tiles.isEmpty ? 0 : (tiles.map(\.west).max()! - minWest + 1)
        var grid = [ElevationTile?](repeating: nil, count: latCount * lonCount)
        for t in tiles { grid[(t.south - minSouth) * lonCount + (t.west - minWest)] = t }
        self.grid = grid
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
        guard let tile = grid[li * lonCount + wi] else { return 0 }
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
        guard let other = grid[li * lonCount + wi] else { return 0 }
        let r = Int(((other.originLatitude - lat) / other.stepLatitude).rounded())
        let c = Int(((lon - other.originLongitude) / other.stepLongitude).rounded())
        return Double(other.value(row: max(0, min(other.rows - 1, r)), col: max(0, min(other.cols - 1, c))))
    }
}

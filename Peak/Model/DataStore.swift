import Foundation
import PeakCore

/// Downloads terrain and peaks around a point and keeps them on the phone, so a place
/// visited once works offline afterwards.
///
/// Copernicus tiles are cloud-optimized GeoTIFFs with built-in lower-resolution copies, so
/// a tile can be fetched at 240 m (about 0.6 MB), 120 m (2 MB), 60 m (8 MB) or the full
/// 30 m (31 MB) with one range request, instead of downloading the whole 40 MB file.
actor DataStore {
    /// Pixel size: 0 is the full 30 m, 1 is 60 m, 2 is 120 m, 3 is 240 m.
    typealias Level = Int

    struct Key: Hashable, Sendable {
        var south: Int
        var west: Int
        var name: String { DataStore.tileName(south, west) }
    }

    enum Failure: LocalizedError {
        case download(String)

        var errorDescription: String? {
            switch self {
            case let .download(what): return "Couldn't download \(what). Check your connection."
            }
        }
    }

    private let demDirectory: URL
    private let peakDirectory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peak", isDirectory: true)
        demDirectory = base.appendingPathComponent("DEM", isDirectory: true)
        peakDirectory = base.appendingPathComponent("Peaks", isDirectory: true)
        for dir in [demDirectory, peakDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 1° tiles covering `radius` meters around a point.
    nonisolated static func tiles(latitude: Double, longitude: Double, radius: Double) -> [Key] {
        let dlat = radius / 111_000
        let dlon = radius / (111_000 * max(cos(latitude * .pi / 180), 0.05))
        var keys: [Key] = []
        for south in Int((latitude - dlat).rounded(.down))...Int((latitude + dlat).rounded(.down)) where south >= -90 && south < 90 {
            for west in Int((longitude - dlon).rounded(.down))...Int((longitude + dlon).rounded(.down)) {
                keys.append(Key(south: south, west: (west + 540) % 360 - 180))
            }
        }
        return keys
    }

    nonisolated static func tileName(_ south: Int, _ west: Int) -> String {
        String(format: "%@%02d%@%03d", south >= 0 ? "N" : "S", abs(south), west >= 0 ? "E" : "W", abs(west))
    }

    /// Distance in meters from a point to the nearest part of a tile.
    nonisolated static func distance(from latitude: Double, _ longitude: Double, to key: Key) -> Double {
        let lat = min(max(latitude, Double(key.south)), Double(key.south + 1))
        let lon = min(max(longitude, Double(key.west)), Double(key.west + 1))
        let dy = (lat - latitude) * 111_000
        let dx = (lon - longitude) * 111_000 * cos(latitude * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Terrain

    /// The finest level of a tile already on the phone, or nil if none is.
    func cachedLevel(_ key: Key) -> Level? {
        (0...3).first { FileManager.default.fileExists(atPath: tileURL(key, $0).path) }
    }

    /// Bytes downloaded so far, for showing progress.
    private(set) var bytesDownloaded = 0

    func isSea(_ key: Key) -> Bool {
        FileManager.default.fileExists(atPath: seaURL(key).path)
    }

    /// A tile at `level` or finer: from the phone if there, otherwise downloaded. Nil for
    /// open sea, where the bucket has no tile.
    func tile(_ key: Key, level: Level) async throws -> ElevationTile? {
        if isSea(key) { return nil }
        if let have = cachedLevel(key), have <= level {
            return try ElevationTile(contentsOf: tileURL(key, have))
        }
        return try await download(key, level: level)
    }

    private func tileURL(_ key: Key, _ level: Level) -> URL {
        // Version 0.1 kept full tiles without a level in the name.
        if level == 0, FileManager.default.fileExists(atPath: demDirectory.appendingPathComponent(key.name + ".pkdem").path) {
            return demDirectory.appendingPathComponent(key.name + ".pkdem")
        }
        return demDirectory.appendingPathComponent("\(key.name).L\(level).pkdem")
    }

    private func seaURL(_ key: Key) -> URL {
        demDirectory.appendingPathComponent(key.name + ".sea")
    }

    private func download(_ key: Key, level: Level) async throws -> ElevationTile? {
        let ns = key.south >= 0 ? "N" : "S", ew = key.west >= 0 ? "E" : "W"
        let stem = String(format: "Copernicus_DSM_COG_10_%@%02d_00_%@%03d_00_DEM", ns, abs(key.south), ew, abs(key.west))
        let url = URL(string: "https://copernicus-dem-30m.s3.amazonaws.com/\(stem)/\(stem).tif")!

        // The image directories sit at the start of the file.
        let (head, status) = try await fetch(url, range: 0..<16_384)
        if status == 403 || status == 404 {
            FileManager.default.createFile(atPath: seaURL(key).path, contents: nil)
            return nil
        }
        guard status == 200 || status == 206 else { throw Failure.download("terrain (HTTP \(status))") }

        let tile: ElevationTile
        if status == 206, let layout = try? GeoTIFF.layout([UInt8](head)) {
            let lvl = min(level, layout.images.count - 1)
            let range = layout.images[lvl].byteRange
            let (body, bodyStatus) = try await fetch(url, range: range)
            switch bodyStatus {
            case 206: tile = try GeoTIFF.decode(layout, level: lvl, bytes: [UInt8](body), base: range.lowerBound)
            case 200: tile = try GeoTIFF.decode(layout, level: lvl, bytes: [UInt8](body), base: 0)
            default: throw Failure.download("terrain (HTTP \(bodyStatus))")
            }
            try tile.write(to: tileURL(key, lvl))
        } else {
            // Not cloud-optimized, or the server ignored the range: use the whole file.
            var whole = head
            if status != 200 {
                let (data, wholeStatus) = try await fetch(url, range: nil)
                guard wholeStatus == 200 else { throw Failure.download("terrain (HTTP \(wholeStatus))") }
                whole = data
            }
            tile = try GeoTIFF.elevationTile(whole)
            try tile.write(to: tileURL(key, 0))
        }
        return tile
    }

    private func fetch(_ url: URL, range: Range<Int>?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        bytesDownloaded += data.count
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: Peaks

    /// Named peaks from OpenStreetMap, cached for a month. Falls back to an older cache, or
    /// no peaks, when there is no connection.
    func peaks(latitude: Double, longitude: Double, radius: Double) async -> [Peak] {
        // Cache by a 0.25° grid cell so nearby spots share one download.
        let cellLat = (latitude * 4).rounded() / 4, cellLon = (longitude * 4).rounded() / 4
        let cache = peakDirectory.appendingPathComponent(String(format: "%.2f_%.2f_%d.json", cellLat, cellLon, Int(radius / 1000)))
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if age < 30 * 86_400, let data = try? Data(contentsOf: cache), let peaks = try? Overpass.peaks(fromJSON: data) {
            return peaks
        }
        // A little beyond the radius, around the cell's center, so the whole circle is covered.
        let r = radius + 20_000
        let dlat = r / 111_000, dlon = r / (111_000 * max(cos(cellLat * .pi / 180), 0.05))
        var request = URLRequest(url: Overpass.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Peak/0.3 (iPhone app; github.com/Fry19/peak)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let query = Overpass.peaksQuery(south: cellLat - dlat, west: cellLon - dlon, north: cellLat + dlat, east: cellLon + dlon)
        request.httpBody = Data(("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).utf8)
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let peaks = try? Overpass.peaks(fromJSON: data) {
            try? data.write(to: cache)
            return peaks
        }
        if let data = try? Data(contentsOf: cache), let peaks = try? Overpass.peaks(fromJSON: data) { return peaks }
        return []
    }
}

import Foundation
import PeakCore

/// Downloads terrain and peaks around a point and keeps them on the phone, so a place
/// visited once works offline afterwards.
actor DataStore {
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
    nonisolated static func tiles(latitude: Double, longitude: Double, radius: Double) -> [(south: Int, west: Int)] {
        let dlat = radius / 111_000
        let dlon = radius / (111_000 * max(cos(latitude * .pi / 180), 0.05))
        var tiles: [(Int, Int)] = []
        for south in Int((latitude - dlat).rounded(.down))...Int((latitude + dlat).rounded(.down)) where south >= -90 && south < 90 {
            for west in Int((longitude - dlon).rounded(.down))...Int((longitude + dlon).rounded(.down)) {
                tiles.append((south, (west + 540) % 360 - 180))
            }
        }
        return tiles
    }

    nonisolated static func tileName(_ south: Int, _ west: Int) -> String {
        String(format: "%@%02d%@%03d", south >= 0 ? "N" : "S", abs(south), west >= 0 ? "E" : "W", abs(west))
    }

    /// Copernicus GLO-30 tiles from the public AWS bucket, converted and cached.
    func terrain(latitude: Double, longitude: Double, radius: Double,
                 progress: @escaping @Sendable (String) -> Void) async throws -> Terrain {
        let needed = Self.tiles(latitude: latitude, longitude: longitude, radius: radius)
        var loaded: [ElevationTile] = []
        let missing = needed.filter { !FileManager.default.fileExists(atPath: tileURL($0.south, $0.west).path)
                                      && !FileManager.default.fileExists(atPath: seaURL($0.south, $0.west).path) }
        for (n, tile) in missing.enumerated() {
            progress("Downloading terrain \(n + 1) of \(missing.count)…")
            try await download(tile.south, tile.west)
        }
        progress("Loading terrain…")
        for tile in needed where FileManager.default.fileExists(atPath: tileURL(tile.south, tile.west).path) {
            loaded.append(try ElevationTile(contentsOf: tileURL(tile.south, tile.west)))
        }
        return Terrain(tiles: loaded)
    }

    private func tileURL(_ south: Int, _ west: Int) -> URL {
        demDirectory.appendingPathComponent(Self.tileName(south, west) + ".pkdem")
    }

    /// Marks a tile that doesn't exist in the bucket (open sea).
    private func seaURL(_ south: Int, _ west: Int) -> URL {
        demDirectory.appendingPathComponent(Self.tileName(south, west) + ".sea")
    }

    private func download(_ south: Int, _ west: Int) async throws {
        let ns = south >= 0 ? "N" : "S", ew = west >= 0 ? "E" : "W"
        let stem = String(format: "Copernicus_DSM_COG_10_%@%02d_00_%@%03d_00_DEM", ns, abs(south), ew, abs(west))
        let url = URL(string: "https://copernicus-dem-30m.s3.amazonaws.com/\(stem)/\(stem).tif")!
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 404 {
            FileManager.default.createFile(atPath: seaURL(south, west).path, contents: nil)
            return
        }
        guard status == 200 else { throw Failure.download("terrain (HTTP \(status))") }
        let tile = try GeoTIFF.elevationTile(try Data(contentsOf: file, options: .alwaysMapped))
        try tile.write(to: tileURL(south, west))
    }

    /// Named peaks from OpenStreetMap, cached for a month. Falls back to an older cache, or
    /// no peaks, when there is no connection.
    func peaks(latitude: Double, longitude: Double, radius: Double) async -> [Peak] {
        let tiles = Self.tiles(latitude: latitude, longitude: longitude, radius: radius)
        let south = tiles.map(\.south).min()!, north = tiles.map(\.south).max()! + 1
        let west = tiles.map(\.west).min()!, east = tiles.map(\.west).max()! + 1
        let cache = peakDirectory.appendingPathComponent("\(Self.tileName(south, west))-\(Self.tileName(north, east)).json")
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if age < 30 * 86_400, let data = try? Data(contentsOf: cache), let peaks = try? Overpass.peaks(fromJSON: data) {
            return peaks
        }
        var request = URLRequest(url: Overpass.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Peak/0.1 (iPhone app; github.com/Fry19/peak)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let query = Overpass.peaksQuery(south: Double(south), west: Double(west), north: Double(north), east: Double(east))
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

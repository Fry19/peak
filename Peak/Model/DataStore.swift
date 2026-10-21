import Foundation
import PeakCore

/// Downloads terrain, peaks, hikes and facts, and keeps them on the phone, so a place
/// visited once works offline afterwards.
///
/// Copernicus tiles are cloud-optimized GeoTIFFs with built-in lower-resolution copies, so
/// a tile can be fetched at 240 m (about 0.6 MB), 120 m (2 MB) or 60 m (8 MB) with one range
/// request. The full 30 m image is stored in 16 blocks of about 2.5 MB, so just the blocks
/// around you can be fetched at full detail.
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

    static let userAgent = "Peak/0.5 (iPhone app; github.com/Fry19/peak)"

    let baseDirectory: URL
    private let demDirectory: URL
    private let peakDirectory: URL
    private let trailDirectory: URL
    private let factDirectory: URL
    /// Tile headers read this session, by tile.
    private var layouts: [Key: GeoTIFF.Layout] = [:]

    init() {
        baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peak", isDirectory: true)
        demDirectory = baseDirectory.appendingPathComponent("DEM", isDirectory: true)
        peakDirectory = baseDirectory.appendingPathComponent("Peaks", isDirectory: true)
        trailDirectory = baseDirectory.appendingPathComponent("Trails", isDirectory: true)
        factDirectory = baseDirectory.appendingPathComponent("Facts", isDirectory: true)
        for dir in [demDirectory, peakDirectory, trailDirectory, factDirectory] {
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

    /// The finest whole level of a tile already on the phone, or nil if none is.
    func cachedLevel(_ key: Key) -> Level? {
        (0...3).first { FileManager.default.fileExists(atPath: tileURL(key, $0).path) }
    }

    /// Bytes downloaded so far, for showing progress.
    private(set) var bytesDownloaded = 0

    func isSea(_ key: Key) -> Bool {
        FileManager.default.fileExists(atPath: seaURL(key).path)
    }

    /// A whole tile at `level` or finer: from the phone if there, otherwise downloaded. Nil
    /// for open sea, where the bucket has no tile.
    func tile(_ key: Key, level: Level) async throws -> ElevationTile? {
        if isSea(key) { return nil }
        if let have = cachedLevel(key), have <= level {
            return try ElevationTile(contentsOf: tileURL(key, have))
        }
        guard let layout = try await layout(key) else { return nil }
        let lvl = min(level, layout.images.count - 1)
        let range = layout.images[lvl].byteRange
        let (body, status) = try await fetch(remoteURL(key), range: range)
        let tile: ElevationTile
        switch status {
        case 206: tile = try GeoTIFF.decode(layout, level: lvl, bytes: [UInt8](body), base: range.lowerBound)
        case 200: tile = try GeoTIFF.decode(layout, level: lvl, bytes: [UInt8](body), base: 0)
        default: throw Failure.download("terrain (HTTP \(status))")
        }
        try tile.write(to: tileURL(key, lvl))
        return tile
    }

    /// The part of a tile at `level` within `radius` meters of a point, fetched block by
    /// block (blocks already on the phone aren't fetched again). Nil for open sea or when
    /// the area misses the tile.
    func patch(_ key: Key, level: Level, latitude: Double, longitude: Double, radius: Double) async throws -> ElevationTile? {
        if isSea(key) { return nil }
        // A whole tile at this level or finer makes a patch pointless.
        if let have = cachedLevel(key), have <= level { return nil }
        guard let layout = try await layout(key), layout.images.indices.contains(level) else { return nil }
        let dlat = radius / 111_000, dlon = radius / (111_000 * max(cos(latitude * .pi / 180), 0.05))
        let blocks = layout.blocks(level: level, south: latitude - dlat, north: latitude + dlat,
                                   west: longitude - dlon, east: longitude + dlon)
        guard !blocks.isEmpty else { return nil }
        let url = remoteURL(key)
        var parts: [ElevationTile] = []
        try await withThrowingTaskGroup(of: ElevationTile.self) { group in
            for block in blocks {
                let file = blockURL(key, level, block)
                if let cached = try? ElevationTile(contentsOf: file) {
                    parts.append(cached)
                    continue
                }
                let range = layout.images[level].byteRange(ofBlock: block)
                group.addTask {
                    let (data, status) = try await self.fetch(url, range: range)
                    guard status == 206 else { throw Failure.download("terrain (HTTP \(status))") }
                    let bytes = [UInt8](data)
                    let tile = try GeoTIFF.decode(layout, level: level, blocks: [block]) { _ in bytes[...] }
                    try tile.write(to: file)
                    return tile
                }
            }
            for try await tile in group { parts.append(tile) }
        }
        return ElevationTile(merging: parts)
    }

    /// The tile's image directories, from the phone or the first 16 KB of the file. Nil
    /// for open sea.
    private func layout(_ key: Key) async throws -> GeoTIFF.Layout? {
        if let layout = layouts[key] { return layout }
        let file = demDirectory.appendingPathComponent(key.name + ".head")
        if let data = try? Data(contentsOf: file), let layout = try? GeoTIFF.layout([UInt8](data)) {
            layouts[key] = layout
            return layout
        }
        let (head, status) = try await fetch(remoteURL(key), range: 0..<16_384)
        if status == 403 || status == 404 {
            FileManager.default.createFile(atPath: seaURL(key).path, contents: nil)
            return nil
        }
        guard status == 206 || status == 200 else { throw Failure.download("terrain (HTTP \(status))") }
        let layout = try GeoTIFF.layout([UInt8](head.prefix(16_384)))
        try? head.prefix(16_384).write(to: file)
        layouts[key] = layout
        return layout
    }

    private func remoteURL(_ key: Key) -> URL {
        let ns = key.south >= 0 ? "N" : "S", ew = key.west >= 0 ? "E" : "W"
        let stem = String(format: "Copernicus_DSM_COG_10_%@%02d_00_%@%03d_00_DEM", ns, abs(key.south), ew, abs(key.west))
        return URL(string: "https://copernicus-dem-30m.s3.amazonaws.com/\(stem)/\(stem).tif")!
    }

    private func tileURL(_ key: Key, _ level: Level) -> URL {
        // Version 0.1 kept full tiles without a level in the name.
        if level == 0, FileManager.default.fileExists(atPath: demDirectory.appendingPathComponent(key.name + ".pkdem").path) {
            return demDirectory.appendingPathComponent(key.name + ".pkdem")
        }
        return demDirectory.appendingPathComponent("\(key.name).L\(level).pkdem")
    }

    private func blockURL(_ key: Key, _ level: Level, _ block: Int) -> URL {
        demDirectory.appendingPathComponent("\(key.name).L\(level).b\(block).pkdem")
    }

    private func seaURL(_ key: Key) -> URL {
        demDirectory.appendingPathComponent(key.name + ".sea")
    }

    private func fetch(_ url: URL, range: Range<Int>?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        bytesDownloaded += data.count
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: OpenStreetMap

    /// Overpass servers, tried in turn when one is busy or down (the main one often answers
    /// 502 or 504 under load).
    private static let overpassServers = [
        Overpass.endpoint,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
    ]

    private func overpass(_ query: String) async throws -> Data {
        var lastError: Error = Failure.download("map data")
        for server in Self.overpassServers {
            var request = URLRequest(url: server)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).utf8)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                bytesDownloaded += data.count
                if (response as? HTTPURLResponse)?.statusCode == 200 { return data }
                lastError = Failure.download("map data (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// A cached file younger than `maxAge` seconds, if there is one.
    private func cached(_ url: URL, maxAge: TimeInterval) -> Data? {
        let age = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        return age < maxAge ? try? Data(contentsOf: url) : nil
    }

    /// Named peaks from OpenStreetMap, cached for a month. Falls back to an older cache, or
    /// no peaks, when there is no connection.
    func peaks(latitude: Double, longitude: Double, radius: Double) async -> [Peak] {
        // Cache by a 0.25° grid cell so nearby spots share one download.
        let cellLat = (latitude * 4).rounded() / 4, cellLon = (longitude * 4).rounded() / 4
        let cache = peakDirectory.appendingPathComponent(String(format: "%.2f_%.2f_%d.json", cellLat, cellLon, Int(radius / 1000)))
        if let data = cached(cache, maxAge: 30 * 86_400), let peaks = try? Overpass.peaks(fromJSON: data) { return peaks }
        // A little beyond the radius, around the cell's center, so the whole circle is covered.
        let r = radius + 20_000
        let dlat = r / 111_000, dlon = r / (111_000 * max(cos(cellLat * .pi / 180), 0.05))
        let query = Overpass.peaksQuery(south: cellLat - dlat, west: cellLon - dlon, north: cellLat + dlat, east: cellLon + dlon)
        if let data = try? await overpass(query), let peaks = try? Overpass.peaks(fromJSON: data) {
            try? data.write(to: cache)
            return peaks
        }
        if let data = try? Data(contentsOf: cache), let peaks = try? Overpass.peaks(fromJSON: data) { return peaks }
        return []
    }

    /// Hiking routes and paths within 5 km of a peak, or 10 km when there are none that
    /// close (small peaks often have none of their own). Cached for a month.
    func trails(near peak: Peak) async throws -> [Trail] {
        let cache = trailDirectory.appendingPathComponent("\(peak.id).json")
        if let data = cached(cache, maxAge: 30 * 86_400), let trails = try? Overpass.trails(fromJSON: data) { return trails }
        do {
            var data = Data()
            var trails: [Trail] = []
            for radius in [5_000.0, 10_000] {
                let query = Overpass.trailsQuery(latitude: peak.latitude, longitude: peak.longitude,
                                                 radius: radius, clip: radius + 10_000)
                data = try await overpass(query)
                trails = try Overpass.trails(fromJSON: data)
                if !trails.isEmpty { break }
            }
            try? data.write(to: cache)
            return trails
        } catch {
            if let data = try? Data(contentsOf: cache), let trails = try? Overpass.trails(fromJSON: data) { return trails }
            throw error
        }
    }

    // MARK: Wikidata and Wikipedia

    /// Facts about a peak, cached for a month. Nil when it has no Wikidata or Wikipedia link.
    func facts(for peak: Peak) async throws -> PeakFacts? {
        guard peak.wikidata != nil || peak.wikipedia != nil else { return nil }
        let cache = factDirectory.appendingPathComponent("\(peak.id).json")
        if let data = cached(cache, maxAge: 30 * 86_400), let facts = try? JSONDecoder().decode(PeakFacts.self, from: data) {
            return facts
        }
        do {
            var facts = PeakFacts()
            if let id = peak.wikidata {
                facts = try Wikidata.facts(fromJSON: try await get(Wikidata.entityURL(id)), id: id)
                let ids = facts.linkedIDs
                if !ids.isEmpty, let labels = try? Wikidata.labels(fromJSON: try await get(Wikidata.labelsURL(ids))) {
                    facts.range = facts.rangeID.flatMap { labels[$0] }
                    facts.parent = facts.parentID.flatMap { labels[$0] }
                    facts.countries = facts.countryIDs.compactMap { labels[$0] }
                }
            }
            if let article = Wikipedia.article(facts: facts, osmTag: peak.wikipedia),
               let url = Wikipedia.summaryURL(language: article.language, title: article.title),
               let data = try? await get(url) {
                try? Wikipedia.addSummary(fromJSON: data, to: &facts)
            }
            if let data = try? JSONEncoder().encode(facts) { try? data.write(to: cache) }
            return facts
        } catch {
            if let data = try? Data(contentsOf: cache), let facts = try? JSONDecoder().decode(PeakFacts.self, from: data) {
                return facts
            }
            throw error
        }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        bytesDownloaded += data.count
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download("facts") }
        return data
    }

    // MARK: Storage

    /// Bytes of everything kept on the phone.
    func storageUsed() -> Int {
        let files = FileManager.default.enumerator(at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = files?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Deletes everything downloaded.
    func clear() {
        for dir in [demDirectory, peakDirectory, trailDirectory, factDirectory] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        layouts.removeAll()
    }
}

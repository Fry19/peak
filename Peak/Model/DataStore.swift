import Foundation
import PeakCore

/// A place saved for use without a signal: the terrain and peaks that can be seen from
/// anywhere in it, and the hikes of its peaks.
struct OfflineArea: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// Meters around the center.
    var radius: Double
    var saved = Date()
    var bytes = 0
    /// Everything downloaded; false while downloading or when it stopped partway.
    var complete = false

    var center: LatLon { LatLon(latitude, longitude) }

    /// A box around the area, `margin` meters beyond its circle.
    func box(margin: Double) -> (south: Double, west: Double, north: Double, east: Double) {
        let r = radius + margin
        let dlat = r / 111_000, dlon = r / (111_000 * max(cos(latitude * .pi / 180), 0.05))
        return (latitude - dlat, longitude - dlon, latitude + dlat, longitude + dlon)
    }

    /// The terrain tiles it uses: everything that can be seen from it.
    var tiles: [DataStore.Key] {
        DataStore.tiles(latitude: latitude, longitude: longitude, radius: radius + TerrainScene.radius)
    }

    func contains(_ point: LatLon) -> Bool {
        point.distance(to: center) <= radius
    }

    /// Roughly how many bytes saving an area downloads (as `AppModel.download` fetches it):
    /// Copernicus tiles are 3600 pixels a side at 30 m (fewer columns toward the poles),
    /// half that at each coarser level, kept in 1024-pixel blocks of about 2.5 bytes a pixel
    /// for mountains.
    static func estimatedBytes(latitude: Double, longitude: Double, radius: Double) -> Int {
        func pixels(level: Int, margin: Double, wholeTiles: Bool) -> Double {
            let r = radius + margin
            let dlat = r / 111_000, dlon = r / (111_000 * max(cos(latitude * .pi / 180), 0.05))
            // Pixels in the blocks along one side of a tile touched by [lo, hi] (fractions of it).
            func span(_ lo: Double, _ hi: Double, _ count: Int) -> Double {
                let a = max(0, min(1, lo)), b = max(0, min(1, hi))
                guard b > a else { return 0 }
                let first = Int(a * Double(count)) / 1024, last = (Int((b * Double(count)).rounded(.up)) - 1) / 1024
                return Double(min((last + 1) * 1024, count) - first * 1024)
            }
            var total = 0.0
            for key in DataStore.tiles(latitude: latitude, longitude: longitude, radius: r) {
                let band = abs(Double(key.south) + 0.5)
                let fullCols = band < 50 ? 3600 : band < 60 ? 2400 : band < 70 ? 1800 : band < 80 ? 1200 : band < 85 ? 720 : 360
                let rows = 3600 >> level, cols = fullCols >> level
                if wholeTiles {
                    total += Double(rows * cols)
                } else {
                    let north = Double(key.south + 1), west = Double(key.west)
                    total += span(north - (latitude + dlat), north - (latitude - dlat), rows) *
                             span(longitude - dlon - west, longitude + dlon - west, cols)
                }
            }
            return total
        }
        let terrain = pixels(level: 2, margin: TerrainScene.radius, wholeTiles: true) +
                      pixels(level: 1, margin: AppModel.areaMediumDetail, wholeTiles: false) +
                      pixels(level: 0, margin: AppModel.areaFullDetail, wholeTiles: false)
        return Int(terrain * 2.5) + 3_000_000
    }
}

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
        case busy

        var errorDescription: String? {
            switch self {
            case let .download(what): return "Couldn't download \(what). Check your connection."
            case .busy: return "The OpenStreetMap server is busy. Try again in a minute."
            }
        }
    }

    static let userAgent = "Peak/0.8 (iPhone app; github.com/Fry19/peak)"

    let baseDirectory: URL
    private let demDirectory: URL
    private let peakDirectory: URL
    private let trailDirectory: URL
    private let factDirectory: URL
    private let areaDirectory: URL
    /// Tile headers read this session, by tile.
    private var layouts: [Key: GeoTIFF.Layout] = [:]

    init() {
        baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peak", isDirectory: true)
        demDirectory = baseDirectory.appendingPathComponent("DEM", isDirectory: true)
        peakDirectory = baseDirectory.appendingPathComponent("Peaks", isDirectory: true)
        trailDirectory = baseDirectory.appendingPathComponent("Trails", isDirectory: true)
        factDirectory = baseDirectory.appendingPathComponent("Facts", isDirectory: true)
        areaDirectory = baseDirectory.appendingPathComponent("Areas", isDirectory: true)
        for dir in [demDirectory, peakDirectory, trailDirectory, factDirectory, areaDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Everything here can be downloaded again: keep it out of iCloud backups, which it
        // could fill.
        var base = baseDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
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

    /// The bucket said it has no such tile, not too long ago (then it's asked again).
    func isSea(_ key: Key) -> Bool {
        let url = seaURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if age(of: url) < CopernicusBucket.seaLifetime { return true }
        try? FileManager.default.removeItem(at: url)
        return false
    }

    /// A whole tile at `level` or finer: from the phone if there, otherwise downloaded. Nil
    /// for open sea, where the bucket has no tile.
    func tile(_ key: Key, level: Level) async throws -> ElevationTile? {
        if isSea(key) { return nil }
        while let have = cachedLevel(key), have <= level {
            let file = tileURL(key, have)
            if let tile = try? ElevationTile(contentsOf: file) { return tile }
            // Unreadable (cut short, or damaged): download it again.
            try? FileManager.default.removeItem(at: file)
        }
        guard let layout = try await layout(key) else { return nil }
        let lvl = min(level, layout.images.count - 1)
        let range = layout.images[lvl].byteRange
        let (body, response) = try await fetch(remoteURL(key), range: range)
        let status = response?.statusCode ?? 0
        let tile: ElevationTile
        switch status {
        case 206: tile = try GeoTIFF.decode(layout, level: lvl, bytes: [UInt8](body), base: range.lowerBound)
        case 200: tile = try GeoTIFF.decode(layout, level: lvl, bytes: [UInt8](body), base: 0)
        default: throw Failure.download("terrain (HTTP \(status))")
        }
        // A full disk only means it isn't kept: the tile is good for now.
        try? tile.write(to: tileURL(key, lvl))
        return tile
    }

    /// The part of a tile at `level` within `radius` meters of a point, fetched block by
    /// block (blocks already on the phone aren't fetched again). Nil for open sea or when
    /// the area misses the tile. Blocks that can't be fetched are left out, unless `strict`.
    func patch(_ key: Key, level: Level, latitude: Double, longitude: Double, radius: Double,
               strict: Bool = false) async throws -> ElevationTile? {
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
        var failure: Error?
        await withTaskGroup(of: Result<ElevationTile, Error>.self) { group in
            for block in blocks {
                let file = blockURL(key, level, block)
                if let cached = try? ElevationTile(contentsOf: file) {
                    parts.append(cached)
                    continue
                }
                try? FileManager.default.removeItem(at: file)   // unreadable, if there at all
                let range = layout.images[level].byteRange(ofBlock: block)
                group.addTask {
                    do {
                        let (data, response) = try await self.fetch(url, range: range)
                        let status = response?.statusCode ?? 0
                        guard status == 206 else { throw Failure.download("terrain (HTTP \(status))") }
                        let bytes = [UInt8](data)
                        let tile = try GeoTIFF.decode(layout, level: level, blocks: [block]) { _ in bytes[...] }
                        try? tile.write(to: file)   // not kept if the disk is full, but good for now
                        return .success(tile)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case let .success(tile): parts.append(tile)
                case let .failure(error): failure = error
                }
            }
        }
        if let failure, strict || parts.isEmpty { throw failure }
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
        let (head, response) = try await fetch(remoteURL(key), range: 0..<16_384)
        let status = response?.statusCode ?? 0
        switch CopernicusBucket.answer(status: status, server: response?.value(forHTTPHeaderField: "Server"), body: head) {
        case .sea:
            FileManager.default.createFile(atPath: seaURL(key).path, contents: nil)
            return nil
        case .error:
            throw Failure.download("terrain (HTTP \(status))")
        case .data:
            break
        }
        let layout = try GeoTIFF.layout([UInt8](head.prefix(16_384)))
        try? head.prefix(16_384).write(to: file, options: .atomic)
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

    private func fetch(_ url: URL, range: Range<Int>?) async throws -> (body: Data, response: HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        bytesDownloaded += data.count
        return (data, response as? HTTPURLResponse)
    }

    // MARK: OpenStreetMap

    /// Overpass servers, tried in turn when one is busy or down (the main one often answers
    /// 502 or 504 under load, or queues a query for most of a minute). OpenStreetMap France's
    /// has the whole world and is often the quicker of the first two.
    private static let overpassServers = [
        Overpass.endpoint,
        URL(string: "https://overpass.openstreetmap.fr/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
    ]

    /// Runs an Overpass query, asking the servers two at a time: the first good answer
    /// wins, and the next two are asked only if both fail. A server that answers but reports
    /// the query failed (it ran out of time) counts as failing. Busy servers often queue a
    /// query for most of a minute before answering, so `timeout` is generous.
    private func overpass(_ query: String, timeout: TimeInterval = 75) async throws -> Data {
        let body = Data(("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).utf8)
        let servers = Self.overpassServers
        var lastError: Error = Failure.download("map data")
        for first in stride(from: 0, to: servers.count, by: 2) {
            let pair = servers[first..<min(first + 2, servers.count)]
            do {
                let data = try await withThrowingTaskGroup(of: Data.self) { group in
                    for server in pair {
                        group.addTask { try await Self.ask(server, body: body, timeout: timeout) }
                    }
                    var error: Error = Failure.download("map data")
                    while let result = await group.nextResult() {
                        switch result {
                        case let .success(data):
                            group.cancelAll()
                            return data
                        case let .failure(e):
                            error = e
                        }
                    }
                    throw error
                }
                bytesDownloaded += data.count
                return data
            } catch {
                lastError = error
            }
            try Task.checkCancellation()
        }
        throw lastError
    }

    private static func ask(_ server: URL, body: Data, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: server)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw status == 429 || status == 503 || status == 504 ? Failure.busy : Failure.download("map data (HTTP \(status))")
        }
        // A query that ran out of time or memory: the server is overloaded.
        if Overpass.failure(inJSON: data) != nil { throw Failure.busy }
        return data
    }

    /// How long ago a file was written, seconds; infinity when there's none.
    private func age(of url: URL) -> TimeInterval {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
    }

    /// A cached file younger than `maxAge` seconds, if there is one.
    private func cached(_ url: URL, maxAge: TimeInterval) -> Data? {
        age(of: url) < maxAge ? try? Data(contentsOf: url) : nil
    }

    /// The peaks in a cached Overpass answer. Before 0.8 the answer to a query the server
    /// gave up on was kept too, with no peaks in it; that doesn't count.
    private func cachedPeaks(_ url: URL) -> [Peak]? {
        guard let data = try? Data(contentsOf: url), Overpass.failure(inJSON: data) == nil else { return nil }
        return try? Overpass.peaks(fromJSON: data)
    }

    /// Named peaks from OpenStreetMap, cached for a month. Inside an area saved for offline
    /// use, the area's peaks; when the servers can't be reached, an older cache or what saved
    /// areas nearby have. Throws when there's none of that, so the caller can try again.
    func peaks(latitude: Double, longitude: Double, radius: Double) async throws -> [Peak] {
        // Cache by a 0.25° grid cell so nearby spots share one download.
        let cellLat = (latitude * 4).rounded() / 4, cellLon = (longitude * 4).rounded() / 4
        let cache = peakDirectory.appendingPathComponent(String(format: "%.2f_%.2f_%d.json", cellLat, cellLon, Int(radius / 1000)))
        // None at all is more likely a download gone wrong than a place without peaks, so
        // ask again after a day.
        if let peaks = cachedPeaks(cache), age(of: cache) < (peaks.isEmpty ? 86_400 : 30 * 86_400) { return peaks }
        let here = LatLon(latitude, longitude)
        if let saved = areaPeaks(around: here, radius: radius, coveredOnly: true) { return saved }
        do {
            return try await downloadPeaks(cellLat: cellLat, cellLon: cellLon, radius: radius, to: cache)
        } catch {
            if let peaks = cachedPeaks(cache) { return peaks }
            if let saved = areaPeaks(around: here, radius: radius, coveredOnly: false) { return saved }
            throw error
        }
    }

    /// Peak downloads under way, by cache file: a second load for the same place waits for
    /// the first instead of asking the servers again.
    private var peakDownloads: [URL: Task<[Peak], Error>] = [:]

    private func downloadPeaks(cellLat: Double, cellLon: Double, radius: Double, to cache: URL) async throws -> [Peak] {
        if let running = peakDownloads[cache] { return try await running.value }
        // A little beyond the radius, around the cell's center, so the whole circle is covered.
        let r = radius + 20_000
        let dlat = r / 111_000, dlon = r / (111_000 * max(cos(cellLat * .pi / 180), 0.05))
        let query = Overpass.peaksQuery(south: cellLat - dlat, west: cellLon - dlon, north: cellLat + dlat, east: cellLon + dlon)
        let download = Task {
            let data = try await self.overpass(query, timeout: 90)
            let peaks = try Overpass.peaks(fromJSON: data)
            try? data.write(to: cache, options: .atomic)
            return peaks
        }
        peakDownloads[cache] = download
        defer { peakDownloads[cache] = nil }
        return try await download.value
    }

    /// How far from a summit hikes are looked for, meters.
    static let hikeRadius = 8_000.0

    /// Hiking routes and paths within `hikeRadius` of a peak. Cached for a month (a day when
    /// there are none, in case someone maps some); a peak in an area saved for offline use
    /// gets the area's.
    func trails(near peak: Peak) async throws -> [Trail] {
        let cache = trailDirectory.appendingPathComponent("\(peak.id).json")
        if let data = try? Data(contentsOf: cache), let trails = try? Overpass.trails(fromJSON: data) {
            let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if age < (trails.isEmpty ? 86_400 : 30 * 86_400) { return nearby(trails, peak) }
        }
        if let saved = areaTrails(near: peak) { return saved }
        do {
            let data = try await overpass(Overpass.trailsQuery(latitude: peak.latitude, longitude: peak.longitude,
                                                               radius: Self.hikeRadius))
            let trails = try Overpass.trails(fromJSON: data)
            try? data.write(to: cache, options: .atomic)
            return nearby(trails, peak)
        } catch {
            if let data = try? Data(contentsOf: cache), let trails = try? Overpass.trails(fromJSON: data) { return nearby(trails, peak) }
            throw error
        }
    }

    private func nearby(_ trails: [Trail], _ peak: Peak) -> [Trail] {
        trails.filter { $0.distance(to: peak.position) <= Self.hikeRadius }
    }

    // MARK: Areas saved for offline use
    //
    // An area keeps the peaks that can be seen from anywhere in it and the hikes of every
    // peak in it (in Areas/), and its terrain in the shared terrain cache.

    /// Peaks and trails of saved areas, read once.
    private var areaPeakCache: [UUID: [Peak]] = [:]
    private var areaTrailCache: [UUID: [Trail]] = [:]

    func loadAreas() -> [OfflineArea] {
        guard let data = try? Data(contentsOf: areaDirectory.appendingPathComponent("areas.json")),
              let areas = try? JSONDecoder().decode([OfflineArea].self, from: data) else { return [] }
        return areas
    }

    nonisolated func saveAreas(_ areas: [OfflineArea]) {
        if let data = try? JSONEncoder().encode(areas) {
            try? data.write(to: areaDirectory.appendingPathComponent("areas.json"), options: .atomic)
        }
    }

    private func areaFile(_ area: OfflineArea, _ kind: String) -> URL {
        areaDirectory.appendingPathComponent("\(area.id.uuidString).\(kind).json")
    }

    /// Downloads the named peaks that can be seen from anywhere in an area.
    func downloadAreaPeaks(_ area: OfflineArea) async throws {
        let box = area.box(margin: TerrainScene.radius + 10_000)
        let data = try await overpass(Overpass.peaksQuery(south: box.south, west: box.west, north: box.north, east: box.east),
                                      timeout: 150)
        areaPeakCache[area.id] = try Overpass.peaks(fromJSON: data)
        try data.write(to: areaFile(area, "peaks"), options: .atomic)
    }

    /// Downloads the hiking routes and named paths for every peak in an area.
    func downloadAreaTrails(_ area: OfflineArea) async throws {
        let box = area.box(margin: Self.hikeRadius)
        let query = Overpass.trailsQuery(south: box.south, west: box.west, north: box.north, east: box.east, timeout: 180)
        let data = try await overpass(query, timeout: 200)
        areaTrailCache[area.id] = try Overpass.trails(fromJSON: data)
        try data.write(to: areaFile(area, "trails"), options: .atomic)
    }

    /// Deletes an area's peaks and hikes, and the terrain no other area (and not the place
    /// you are now) uses.
    func deleteArea(_ area: OfflineArea, keeping others: [OfflineArea], near here: LatLon?) {
        for kind in ["peaks", "trails"] { try? FileManager.default.removeItem(at: areaFile(area, kind)) }
        areaPeakCache[area.id] = nil
        areaTrailCache[area.id] = nil
        var kept = Set(others.flatMap(\.tiles))
        if let here { kept.formUnion(Self.tiles(latitude: here.latitude, longitude: here.longitude, radius: TerrainScene.radius)) }
        let names = Set(area.tiles.filter { !kept.contains($0) }.map(\.name))
        let files = (try? FileManager.default.contentsOfDirectory(at: demDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where names.contains(String(file.lastPathComponent.prefix(7))) {
            try? FileManager.default.removeItem(at: file)
        }
        for key in layouts.keys where names.contains(key.name) { layouts[key] = nil }
    }

    /// Bytes an area takes on the phone (terrain shared with other areas counts for each).
    func size(of area: OfflineArea) -> Int {
        let names = Set(area.tiles.map(\.name))
        var files = (try? FileManager.default.contentsOfDirectory(at: demDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        files = files.filter { names.contains(String($0.lastPathComponent.prefix(7))) }
        files += [areaFile(area, "peaks"), areaFile(area, "trails")]
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func savedAreas() -> [OfflineArea] {
        loadAreas().filter(\.complete)
    }

    private func savedPeaks(of area: OfflineArea) -> [Peak]? {
        if let peaks = areaPeakCache[area.id] { return peaks }
        guard let data = try? Data(contentsOf: areaFile(area, "peaks")), let peaks = try? Overpass.peaks(fromJSON: data) else { return nil }
        areaPeakCache[area.id] = peaks
        return peaks
    }

    private func savedTrails(of area: OfflineArea) -> [Trail]? {
        if let trails = areaTrailCache[area.id] { return trails }
        guard let data = try? Data(contentsOf: areaFile(area, "trails")), let trails = try? Overpass.trails(fromJSON: data) else { return nil }
        areaTrailCache[area.id] = trails
        return trails
    }

    /// Peaks within `radius` of a point from the saved areas. With `coveredOnly`, nil unless
    /// one area has every peak there (you're inside it); otherwise whatever they have, or nil.
    private func areaPeaks(around here: LatLon, radius: Double, coveredOnly: Bool) -> [Peak]? {
        var areas = savedAreas()
        if coveredOnly {
            // An area has the peaks within its radius plus `TerrainScene.radius` + 10 km.
            guard let area = areas.first(where: { here.distance(to: $0.center) + radius <= $0.radius + TerrainScene.radius + 10_000 })
            else { return nil }
            areas = [area]
        }
        var seen = Set<Int64>()
        var peaks: [Peak] = []
        for area in areas {
            for p in savedPeaks(of: area) ?? [] where !seen.contains(p.id) && here.distance(to: p.position) <= radius + 20_000 {
                seen.insert(p.id)
                peaks.append(p)
            }
        }
        return peaks.isEmpty && !coveredOnly ? nil : peaks
    }

    /// Hikes near a peak in a saved area, or nil when no area has all of them.
    private func areaTrails(near peak: Peak) -> [Trail]? {
        guard let area = savedAreas().first(where: { peak.position.distance(to: $0.center) <= $0.radius }),
              let trails = savedTrails(of: area) else { return nil }
        return nearby(trails, peak)
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
            if let data = try? JSONEncoder().encode(facts) { try? data.write(to: cache, options: .atomic) }
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
        for dir in [demDirectory, peakDirectory, trailDirectory, factDirectory, areaDirectory] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        layouts.removeAll()
    }
}

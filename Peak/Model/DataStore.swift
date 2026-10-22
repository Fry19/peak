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
        // Land cover: about 60 KB a cell kept in the Alps.
        let cells = DataStore.landCoverCells(OfflineArea(name: "", latitude: latitude, longitude: longitude, radius: radius)).count
        return Int(terrain * 2.5) + cells * 60_000 + 3_000_000
    }
}

/// Downloads terrain, peaks, hikes, land cover and facts, and keeps them on the phone, so a
/// place visited once works offline afterwards.
///
/// Copernicus tiles are cloud-optimized GeoTIFFs with built-in lower-resolution copies, so
/// a tile can be fetched at 240 m (about 0.6 MB), 120 m (2 MB) or 60 m (8 MB) with one range
/// request. The full 30 m image is stored in 16 blocks of about 2.5 MB, so just the blocks
/// around you can be fetched at full detail.
///
/// Where USGS has it (the United States and its territories), the bare ground under trails
/// comes from USGS 3DEP's 1/3 arc-second (about 10 m) terrain model, fetched the same way
/// in its 512-pixel blocks of about 0.8 MB (`Source.usgs`, `Terrain.ground`). Its heights
/// are NAVD88 (local datums in some territories), within a meter or two of Copernicus's
/// EGM2008 heights in the lower 48, and its positions NAD83, within about 1.5 m of WGS 84.
/// Both are left as they are: a fraction of a pixel, and close to the whole meters heights
/// are kept in.
actor DataStore {
    /// Pixel size: 0 is the full 30 m, 1 is 60 m, 2 is 120 m, 3 is 240 m.
    typealias Level = Int

    /// Where terrain comes from: Copernicus's surface model everywhere, or USGS 3DEP's bare
    /// ground where USGS has a tile (only its full 10 m level is used).
    enum Source: Sendable {
        case copernicus, usgs
    }

    struct Key: Hashable, Sendable {
        var south: Int
        var west: Int
        var name: String { DataStore.tileName(south, west) }
    }

    enum Failure: LocalizedError {
        case download(String)
        /// The file on the server isn't the one whose header is on the phone any more.
        case changed
        case busy
        /// The server has no such page.
        case missing

        var errorDescription: String? {
            switch self {
            case let .download(what): return "Couldn't download \(what). Check your connection."
            case .changed: return "The terrain was updated on the server. Trying again."
            case .busy: return "The OpenStreetMap server is busy. Try again in a minute."
            case .missing: return "Not found."
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
    private let coverDirectory: URL
    /// USGS 3DEP's bare ground, apart from Copernicus's terrain.
    private let groundDirectory: URL
    private struct LayoutKey: Hashable {
        var key: Key
        var source: Source
    }
    /// Tile headers read this session, by tile and source.
    private var layouts: [LayoutKey: GeoTIFF.Layout] = [:]
    /// Which version (S3's ETag) of a USGS file each header read this session is from.
    private var versions: [LayoutKey: String] = [:]

    init() {
        baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peak", isDirectory: true)
        demDirectory = baseDirectory.appendingPathComponent("DEM", isDirectory: true)
        peakDirectory = baseDirectory.appendingPathComponent("Peaks", isDirectory: true)
        trailDirectory = baseDirectory.appendingPathComponent("Trails", isDirectory: true)
        factDirectory = baseDirectory.appendingPathComponent("Facts", isDirectory: true)
        areaDirectory = baseDirectory.appendingPathComponent("Areas", isDirectory: true)
        coverDirectory = baseDirectory.appendingPathComponent("LandCover", isDirectory: true)
        groundDirectory = baseDirectory.appendingPathComponent("Ground", isDirectory: true)
        for dir in [demDirectory, peakDirectory, trailDirectory, factDirectory, areaDirectory, coverDirectory, groundDirectory] {
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

    /// The bucket said it has no such tile, not too long ago (then it's asked again). For
    /// Copernicus that's open sea; USGS just has no bare ground there, which says nothing
    /// about what's there.
    func isSea(_ key: Key, source: Source = .copernicus) -> Bool {
        age(of: seaURL(key, source)) < CopernicusBucket.seaLifetime
    }

    /// The bucket said it has no such tile, however long ago: what to go by when it can't
    /// be asked again (no signal), rather than having no terrain there.
    private func wasSea(_ key: Key, _ source: Source) -> Bool {
        FileManager.default.fileExists(atPath: seaURL(key, source).path)
    }

    /// A whole tile at `level` or finer: from the phone if there, otherwise downloaded. Nil
    /// for open sea, where the bucket has no tile. With `strict` (saving an area), a tile
    /// that can't be kept on the phone (the disk is full) is a failure.
    func tile(_ key: Key, level: Level, strict: Bool = false) async throws -> ElevationTile? {
        if isSea(key) { return nil }
        while let have = cachedLevel(key), have <= level {
            let file = tileURL(key, have)
            if let tile = try? ElevationTile(contentsOf: file) { return tile }
            // Unreadable (cut short, or damaged): download it again.
            try? FileManager.default.removeItem(at: file)
        }
        guard let layout = try await layout(key, strict: strict) else { return nil }
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
        // A full disk only means it isn't kept: the tile is good for now, but not for an area.
        do { try tile.write(to: tileURL(key, lvl)) } catch { if strict { throw error } }
        return tile
    }

    /// The part of a tile at `level` within `radius` meters of a point, fetched block by
    /// block (blocks already on the phone aren't fetched again). Nil for open sea or when
    /// the area misses the tile, and from USGS where it has no tile. Blocks that can't be
    /// fetched are left out, unless `strict` (saving an area), when blocks that can't be
    /// fetched or kept are a failure.
    func patch(_ key: Key, level: Level, latitude: Double, longitude: Double, radius: Double,
               source: Source = .copernicus, strict: Bool = false) async throws -> ElevationTile? {
        if isSea(key, source: source) { return nil }
        // A whole tile at this level or finer makes a patch pointless.
        if source == .copernicus, let have = cachedLevel(key), have <= level { return nil }
        let dlat = radius / 111_000, dlon = radius / (111_000 * max(cos(latitude * .pi / 180), 0.05))
        let layout: GeoTIFF.Layout
        do {
            guard let found = try await self.layout(key, source: source, strict: strict),
                  found.images.indices.contains(level) else { return nil }
            layout = found
        } catch {
            // No header on the phone and no signal: the blocks that are here still do.
            if !strict, let blocks = cachedBlocks(key, level, source, south: latitude - dlat, north: latitude + dlat,
                                                  west: longitude - dlon, east: longitude + dlon) {
                return blocks
            }
            throw error
        }
        let blocks = layout.blocks(level: level, south: latitude - dlat, north: latitude + dlat,
                                   west: longitude - dlon, east: longitude + dlon)
        guard !blocks.isEmpty else { return nil }
        let url = remoteURL(key, source)
        // USGS replaces its tiles in place as new surveys come in: blocks are asked for only
        // from the version whose header is on the phone, and none without knowing it.
        let version = versions[LayoutKey(key: key, source: source)]
        var parts: [ElevationTile] = []
        var failure: Error?
        var versionChanged = false
        await withTaskGroup(of: Result<ElevationTile, Error>.self) { group in
            for block in blocks {
                let file = blockURL(key, level, block, source)
                if let cached = try? ElevationTile(contentsOf: file) {
                    parts.append(cached)
                    continue
                }
                try? FileManager.default.removeItem(at: file)   // unreadable, if there at all
                if source == .usgs, version == nil { continue }
                let range = layout.images[level].byteRange(ofBlock: block)
                group.addTask {
                    do {
                        let (data, response) = try await self.fetch(url, range: range, ifMatch: version)
                        let status = response?.statusCode ?? 0
                        if status == 412 { throw Failure.changed }
                        guard status == 206 else { throw Failure.download("terrain (HTTP \(status))") }
                        let bytes = [UInt8](data)
                        let tile = try GeoTIFF.decode(layout, level: level, blocks: [block]) { _ in bytes[...] }
                        // Not kept if the disk is full: good for now, but not for an area.
                        do { try tile.write(to: file) } catch { if strict { throw error } }
                        return .success(tile)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case let .success(tile): parts.append(tile)
                case let .failure(error):
                    if case .changed? = error as? Failure { versionChanged = true }
                    failure = error
                }
            }
        }
        if versionChanged {
            // Start over with the new version next time: its header and all of its blocks.
            forget(key, level, source)
        }
        if let failure, strict || parts.isEmpty { throw failure }
        return ElevationTile(merging: parts)
    }

    /// Deletes a tile's header and blocks at `level` on the phone.
    private func forget(_ key: Key, _ level: Level, _ source: Source) {
        layouts[LayoutKey(key: key, source: source)] = nil
        versions[LayoutKey(key: key, source: source)] = nil
        for file in [headURL(key, source), versionURL(key, source)] { try? FileManager.default.removeItem(at: file) }
        let first = blockURL(key, level, 0, source)
        let prefix = String(first.lastPathComponent.dropLast("0.pkdem".count))
        let files = (try? FileManager.default.contentsOfDirectory(at: first.deletingLastPathComponent(),
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
    }

    /// The blocks of a tile at `level` on the phone that overlap a box, joined; nil when
    /// there are none. For when the tile's header (which says which blocks there are) is
    /// missing and can't be fetched.
    private func cachedBlocks(_ key: Key, _ level: Level, _ source: Source,
                              south: Double, north: Double, west: Double, east: Double) -> ElevationTile? {
        let first = blockURL(key, level, 0, source)
        let prefix = String(first.lastPathComponent.dropLast("0.pkdem".count))
        let files = (try? FileManager.default.contentsOfDirectory(at: first.deletingLastPathComponent(),
                                                                  includingPropertiesForKeys: nil)) ?? []
        let parts = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "pkdem" }
            .compactMap { try? ElevationTile(contentsOf: $0) }
            .filter { t in
                let top = t.originLatitude, bottom = top - Double(t.rows - 1) * t.stepLatitude
                let left = t.originLongitude, right = left + Double(t.cols - 1) * t.stepLongitude
                return bottom <= north && top >= south && left <= east && right >= west
            }
        return parts.isEmpty ? nil : ElevationTile(merging: parts)
    }

    /// The tile's image directories, from the phone or the first 16 KB of the file. Nil
    /// for open sea. With `strict`, a header that can't be kept on the phone is a failure,
    /// so a saved area never needs the network for it.
    private func layout(_ key: Key, source: Source = .copernicus, strict: Bool = false) async throws -> GeoTIFF.Layout? {
        let id = LayoutKey(key: key, source: source)
        if let layout = layouts[id] {
            if strict, !FileManager.default.fileExists(atPath: headURL(key, source).path) {
                layouts[id] = nil   // read this session but not kept: fetch and keep it
            } else {
                return layout
            }
        }
        let file = headURL(key, source)
        // A USGS header without the version it's from can't vouch for blocks fetched now: it's
        // asked for again, and used for the blocks on the phone only while it can't be.
        var unversioned: GeoTIFF.Layout?
        if let data = try? Data(contentsOf: file), let layout = try? GeoTIFF.layout([UInt8](data)) {
            if source == .copernicus {
                layouts[id] = layout
                return layout
            }
            if let tag = try? String(contentsOf: versionURL(key, source), encoding: .utf8), !tag.isEmpty {
                layouts[id] = layout
                versions[id] = tag
                return layout
            }
            unversioned = layout
        }
        let head: Data, response: HTTPURLResponse?
        do {
            (head, response) = try await fetch(remoteURL(key, source), range: 0..<16_384)
        } catch {
            // No signal: open sea stays sea, however long ago the bucket said so.
            if wasSea(key, source) { return nil }
            if !strict, let unversioned { return unversioned }
            throw error
        }
        let status = response?.statusCode ?? 0
        // USGS's bucket is on S3 too, and says it has no tile the same way.
        switch CopernicusBucket.answer(status: status, server: response?.value(forHTTPHeaderField: "Server"), body: head) {
        case .sea:
            if !FileManager.default.createFile(atPath: seaURL(key, source).path, contents: nil), strict {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            return nil
        case .error:
            throw Failure.download("terrain (HTTP \(status))")
        case .data:
            break
        }
        let layout = try GeoTIFF.layout([UInt8](head.prefix(16_384)))
        try? FileManager.default.removeItem(at: seaURL(key, source))
        let tag = source == .usgs ? response?.value(forHTTPHeaderField: "ETag") : nil
        // USGS blocks on the phone are kept only if they're known to be of this version.
        if source == .usgs, (try? String(contentsOf: versionURL(key, source), encoding: .utf8)) != tag { forget(key, 0, source) }
        versions[id] = tag
        do {
            try head.prefix(16_384).write(to: file, options: .atomic)
            // Which version of the file the header is from (S3's ETag), for asking for its blocks.
            if let tag { try tag.write(to: versionURL(key, source), atomically: true, encoding: .utf8) }
        } catch { if strict { throw error } }
        layouts[id] = layout
        return layout
    }

    private func headURL(_ key: Key, _ source: Source = .copernicus) -> URL {
        switch source {
        case .copernicus: demDirectory.appendingPathComponent(key.name + ".head")
        case .usgs: groundDirectory.appendingPathComponent("USGS13_\(key.name).head")
        }
    }

    private func remoteURL(_ key: Key, _ source: Source = .copernicus) -> URL {
        switch source {
        case .copernicus:
            let ns = key.south >= 0 ? "N" : "S", ew = key.west >= 0 ? "E" : "W"
            let stem = String(format: "Copernicus_DSM_COG_10_%@%02d_00_%@%03d_00_DEM", ns, abs(key.south), ew, abs(key.west))
            return URL(string: "https://copernicus-dem-30m.s3.amazonaws.com/\(stem)/\(stem).tif")!
        case .usgs:
            // Named after the tile's north-west corner: n36w084 is 35–36°N, 84–83°W.
            let north = key.south + 1
            let stem = String(format: "%@%02d%@%03d", north >= 0 ? "n" : "s", abs(north), key.west >= 0 ? "e" : "w", abs(key.west))
            return URL(string: "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current/\(stem)/USGS_13_\(stem).tif")!
        }
    }

    private func tileURL(_ key: Key, _ level: Level) -> URL {
        // Version 0.1 kept full tiles without a level in the name.
        if level == 0, FileManager.default.fileExists(atPath: demDirectory.appendingPathComponent(key.name + ".pkdem").path) {
            return demDirectory.appendingPathComponent(key.name + ".pkdem")
        }
        return demDirectory.appendingPathComponent("\(key.name).L\(level).pkdem")
    }

    private func blockURL(_ key: Key, _ level: Level, _ block: Int, _ source: Source = .copernicus) -> URL {
        switch source {
        case .copernicus: demDirectory.appendingPathComponent("\(key.name).L\(level).b\(block).pkdem")
        case .usgs: groundDirectory.appendingPathComponent("USGS13_\(key.name).L\(level).b\(block).pkdem")
        }
    }

    /// The version (ETag) of the file a USGS tile's header came from.
    private func versionURL(_ key: Key, _ source: Source) -> URL {
        headURL(key, source).appendingPathExtension("etag")
    }

    /// Marks a tile the bucket doesn't have.
    private func seaURL(_ key: Key, _ source: Source = .copernicus) -> URL {
        switch source {
        case .copernicus: demDirectory.appendingPathComponent(key.name + ".sea")
        case .usgs: groundDirectory.appendingPathComponent("USGS13_\(key.name).none")
        }
    }

    /// With `ifMatch`, the server answers 412 rather than the bytes when the file isn't that
    /// version any more.
    private func fetch(_ url: URL, range: Range<Int>?, ifMatch: String? = nil) async throws -> (body: Data, response: HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
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
    /// use, the area's peaks; when the servers can't be reached, an older cache, a nearby
    /// cell's cache that reaches here, or what saved areas nearby have. Throws when there's
    /// none of that, so the caller can try again.
    func peaks(latitude: Double, longitude: Double, radius: Double) async throws -> [Peak] {
        // Cache by a 0.25° grid cell so nearby spots share one download.
        let cell = PeakCell(latitude: latitude, longitude: longitude, radius: radius)
        let cache = peakDirectory.appendingPathComponent(cell.fileName)
        // None at all is more likely a download gone wrong than a place without peaks, so
        // ask again after a day.
        if let peaks = cachedPeaks(cache), age(of: cache) < (peaks.isEmpty ? 86_400 : 30 * 86_400) { return peaks }
        let here = LatLon(latitude, longitude)
        if let saved = areaPeaks(around: here, radius: radius, coveredOnly: true) { return saved }
        do {
            return try await downloadPeaks(cell, to: cache)
        } catch {
            if let peaks = cachedPeaks(cache) { return peaks }
            // Walked from one cell into the next with no signal: the first one's peaks reach
            // well past it.
            if let peaks = coveringPeaks(here, radius: radius) { return peaks }
            if let saved = areaPeaks(around: here, radius: radius, coveredOnly: false) { return saved }
            throw error
        }
    }

    /// The peaks of the cached cell nearest a point whose box has the point in it.
    private func coveringPeaks(_ here: LatLon, radius: Double) -> [Peak]? {
        let files = (try? FileManager.default.contentsOfDirectory(at: peakDirectory, includingPropertiesForKeys: nil)) ?? []
        var cells = files.compactMap { file in PeakCell(fileName: file.lastPathComponent).map { (cell: $0, file: file) } }
        while let best = PeakCell.nearestCovering(here, radius: radius, among: cells.map(\.cell)) {
            let file = cells.first { $0.cell == best }!.file
            if let peaks = cachedPeaks(file), !peaks.isEmpty { return peaks }
            cells.removeAll { $0.cell == best }
        }
        return nil
    }

    /// Peak downloads under way, by cache file: a second load for the same place waits for
    /// the first instead of asking the servers again.
    private var peakDownloads: [URL: Task<[Peak], Error>] = [:]

    private func downloadPeaks(_ cell: PeakCell, to cache: URL) async throws -> [Peak] {
        if let running = peakDownloads[cache] { return try await running.value }
        // A little beyond the radius, around the cell's center, so the whole circle is covered.
        let box = cell.box
        let query = Overpass.peaksQuery(south: box.south, west: box.west, north: box.north, east: box.east)
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
        if let saved = areaTrails(near: peak, whole: true) { return saved }
        do {
            let data = try await overpass(Overpass.trailsQuery(latitude: peak.latitude, longitude: peak.longitude,
                                                               radius: Self.hikeRadius))
            let trails = try Overpass.trails(fromJSON: data)
            try? data.write(to: cache, options: .atomic)
            return nearby(trails, peak)
        } catch {
            if let data = try? Data(contentsOf: cache), let trails = try? Overpass.trails(fromJSON: data) { return nearby(trails, peak) }
            // An area whose hikes were only partly saved: better than none.
            if let saved = areaTrails(near: peak, whole: false) { return saved }
            throw error
        }
    }

    /// The hikes within `hikeRadius` of a peak, and of the paths without a name only those
    /// near its summit (an area has them for all its peaks).
    private func nearby(_ trails: [Trail], _ peak: Peak) -> [Trail] {
        trails.filter {
            $0.distance(to: peak.position) <= ($0.id.hasPrefix("u") ? Self.summitPathRadius : Self.hikeRadius)
        }
    }

    /// How far from a summit paths without a name are looked for (`trailsQuery`'s
    /// `summitRadius`), with a little to spare, meters.
    static let summitPathRadius = 450.0

    // MARK: Land cover

    /// How long kept land cover is good for before it's fetched again (with a signal):
    /// glaciers and lakes change slowly.
    static let landCoverLifetime: TimeInterval = 90 * 86_400

    /// Land cover cells read this session.
    private var coverCells: [LandCoverCell: [LandCoverArea]] = [:]
    /// Land cover downloads under way, by cell: a second request for a cell waits for the
    /// first instead of asking the servers again.
    private var coverDownloads: [LandCoverCell: Task<Void, Error>] = [:]

    /// Glaciers, water, bare rock and scree in a box, from the phone. With `fetch`, the
    /// cells that aren't on the phone (or are old) are downloaded first; one that can't be
    /// is left out, and `complete` is false.
    func landCover(in box: GeoBox, fetch: Bool) async -> (areas: [LandCoverArea], complete: Bool) {
        let cells = LandCoverCell.covering(box)
        if fetch {
            try? await fetchCover(cells.filter { age(of: coverURL($0)) >= Self.landCoverLifetime }, strict: false)
        }
        var seen = Set<Int64>()
        var areas: [LandCoverArea] = []
        var complete = true
        for cell in cells {
            guard let found = savedCover(cell) else {
                complete = false
                continue
            }
            for area in found where seen.insert(area.id).inserted && area.bounds.intersects(box) { areas.append(area) }
        }
        return (areas, complete)
    }

    private func coverURL(_ cell: LandCoverCell) -> URL {
        coverDirectory.appendingPathComponent(cell.fileName)
    }

    /// A cell's land cover on the phone, however old; nil when it isn't there.
    private func savedCover(_ cell: LandCoverCell) -> [LandCoverArea]? {
        if let areas = coverCells[cell] { return areas }
        guard let data = try? Data(contentsOf: coverURL(cell)), let areas = try? LandCoverArea.decode(data) else { return nil }
        // An Alpine cell is a few hundred kilobytes read: keep the last few dozen.
        if coverCells.count >= 48 { coverCells.removeAll() }
        coverCells[cell] = areas
        return areas
    }

    /// Downloads cells, a block of up to 3 by 3 per query and one block at a time (the
    /// servers allow few queries at once). Cells already being downloaded are waited for.
    /// Throws the last failure, once every block has been tried.
    private func fetchCover(_ cells: [LandCoverCell], strict: Bool) async throws {
        var waits = Set(cells.compactMap { coverDownloads[$0] })
        let new = cells.filter { coverDownloads[$0] == nil }
        if !new.isEmpty {
            let batches = LandCoverCell.batches(new)
            let task = Task {
                var failure: Error?
                for batch in batches {
                    try Task.checkCancellation()
                    do { try await self.downloadCover(batch, strict: strict) } catch { failure = error }
                }
                if let failure { throw failure }
            }
            for cell in new { coverDownloads[cell] = task }
            waits.insert(task)
            defer { for cell in new where coverDownloads[cell] == task { coverDownloads[cell] = nil } }
            var failure: Error?
            for wait in waits {
                do { try await wait.value } catch { failure = error }
            }
            if let failure { throw failure }
        } else {
            for wait in waits { try await wait.value }
        }
    }

    /// One query for a block of cells, kept cell by cell: each keeps every area that
    /// reaches into it, whole. With `strict` (saving an area), a cell that can't be kept on
    /// the phone (the disk is full) is a failure.
    private func downloadCover(_ cells: [LandCoverCell], strict: Bool) async throws {
        guard let box = LandCoverCell.box(cells) else { return }
        let data = try await overpass(Overpass.landCoverQuery(south: box.south, west: box.west, north: box.north, east: box.east),
                                      timeout: 100)
        let areas = try Overpass.landCover(fromJSON: data)
        let bounds = areas.map(\.bounds)
        for cell in cells {
            let inCell = areas.indices.filter { bounds[$0].intersects(cell.box) }.map { areas[$0] }
            do {
                try LandCoverArea.encode(inCell).write(to: coverURL(cell), options: .atomic)
            } catch {
                if strict { throw error }
            }
            coverCells[cell] = inCell
        }
    }

    /// The land cover cells an area keeps: around every hike of its peaks, with room for
    /// the maps of them (`AppModel.coverMargin`).
    nonisolated static func landCoverCells(_ area: OfflineArea) -> [LandCoverCell] {
        let box = area.box(margin: hikeRadius + AppModel.coverMargin)
        return LandCoverCell.covering(GeoBox(south: box.south, west: box.west, north: box.north, east: box.east))
    }

    /// Downloads the land cover of an area that isn't on the phone yet.
    func downloadAreaLandCover(_ area: OfflineArea) async throws {
        let missing = Self.landCoverCells(area).filter { !FileManager.default.fileExists(atPath: coverURL($0).path) }
        try await fetchCover(missing, strict: true)
    }

    // MARK: Areas saved for offline use
    //
    // An area keeps the peaks that can be seen from anywhere in it and the hikes of every
    // peak in it (in Areas/), and its terrain and land cover in the shared caches.

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

    /// Every file of an area's peaks and hikes, including the parts of hikes saved so far.
    private func areaFiles(_ area: OfflineArea) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: areaDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(area.id.uuidString + ".") }
    }

    /// Downloads the named peaks that can be seen from anywhere in an area, unless they're
    /// on the phone already (resuming a download that stopped).
    func downloadAreaPeaks(_ area: OfflineArea) async throws {
        if savedPeaks(of: area) != nil { return }
        let box = area.box(margin: TerrainScene.radius + 10_000)
        let data = try await overpass(Overpass.peaksQuery(south: box.south, west: box.west, north: box.north, east: box.east),
                                      timeout: 150)
        let peaks = try Overpass.peaks(fromJSON: data)
        try data.write(to: areaFile(area, "peaks"), options: .atomic)
        areaPeakCache[area.id] = peaks
    }

    /// The boxes an area's hikes are fetched in, at most 30 km across: one query for a
    /// 50 km area in the Alps runs out of time on the server.
    nonisolated static func trailBoxes(_ area: OfflineArea) -> [GeoBox] {
        let box = area.box(margin: hikeRadius)
        return GeoBox(south: box.south, west: box.west, north: box.north, east: box.east).split(side: 30_000)
    }

    /// Downloads the hiking routes and paths for every peak in an area (with the paths
    /// without a name up to each summit, as for a single peak), box by box. Boxes already
    /// on the phone (resuming) aren't fetched again; one that fails doesn't stop the rest.
    /// `progress` gets the boxes done and their number.
    func downloadAreaTrails(_ area: OfflineArea, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws {
        if FileManager.default.fileExists(atPath: areaFile(area, "trails").path) { return }
        let boxes = Self.trailBoxes(area)
        var failure: Error?
        for (i, box) in boxes.enumerated() {
            await progress(i, boxes.count)
            try Task.checkCancellation()
            let file = areaFile(area, "trails.\(i)")
            if FileManager.default.fileExists(atPath: file.path) { continue }
            do {
                let query = Overpass.trailsQuery(south: box.south, west: box.west, north: box.north, east: box.east,
                                                 everySummit: true, timeout: 90)
                let data = try await overpass(query, timeout: 100)
                _ = try Overpass.trails(fromJSON: data)
                try data.write(to: file, options: .atomic)
                areaTrailCache[area.id] = nil   // the parts so far, read again with this one
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        let parts = boxes.indices.map { areaFile(area, "trails.\($0)") }
        let merged = try Overpass.merge(try parts.map { try Data(contentsOf: $0) })
        let trails = try Overpass.trails(fromJSON: merged)
        try merged.write(to: areaFile(area, "trails"), options: .atomic)
        for part in parts { try? FileManager.default.removeItem(at: part) }
        areaTrailCache[area.id] = trails
    }

    /// Deletes an area's peaks and hikes, and the terrain and land cover no other area (and
    /// not the place you are now) uses.
    func deleteArea(_ area: OfflineArea, keeping others: [OfflineArea], near here: LatLon?) {
        for file in areaFiles(area) { try? FileManager.default.removeItem(at: file) }
        areaPeakCache[area.id] = nil
        areaTrailCache[area.id] = nil
        var kept = Set(others.flatMap(\.tiles))
        if let here { kept.formUnion(Self.tiles(latitude: here.latitude, longitude: here.longitude, radius: TerrainScene.radius)) }
        let names = Set(area.tiles.filter { !kept.contains($0) }.map(\.name))
        let files = (try? FileManager.default.contentsOfDirectory(at: demDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where names.contains(String(file.lastPathComponent.prefix(7))) {
            try? FileManager.default.removeItem(at: file)
        }
        for id in layouts.keys where id.source == .copernicus && names.contains(id.key.name) { layouts[id] = nil }
        var keptCells = Set(others.flatMap(Self.landCoverCells))
        if let here { keptCells.formUnion(LandCoverCell.covering(GeoBox(around: here, radius: Self.hikeRadius + AppModel.coverMargin))) }
        for cell in Self.landCoverCells(area) where !keptCells.contains(cell) {
            try? FileManager.default.removeItem(at: coverURL(cell))
            coverCells[cell] = nil
        }
    }

    /// Bytes an area takes on the phone (terrain shared with other areas counts for each).
    func size(of area: OfflineArea) -> Int {
        let names = Set(area.tiles.map(\.name))
        var files = (try? FileManager.default.contentsOfDirectory(at: demDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        files = files.filter { names.contains(String($0.lastPathComponent.prefix(7))) }
        files += areaFiles(area)
        files += Self.landCoverCells(area).map(coverURL)
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func savedPeaks(of area: OfflineArea) -> [Peak]? {
        if let peaks = areaPeakCache[area.id] { return peaks }
        guard let data = try? Data(contentsOf: areaFile(area, "peaks")), let peaks = try? Overpass.peaks(fromJSON: data) else { return nil }
        areaPeakCache[area.id] = peaks
        return peaks
    }

    /// An area's hikes, or nil when they aren't saved. With `whole` false, those of the
    /// boxes saved so far when the download stopped partway.
    private func savedTrails(of area: OfflineArea, whole: Bool) -> [Trail]? {
        let file = areaFile(area, "trails")
        if FileManager.default.fileExists(atPath: file.path) {
            if let trails = areaTrailCache[area.id] { return trails }
            guard let data = try? Data(contentsOf: file), let trails = try? Overpass.trails(fromJSON: data) else { return nil }
            areaTrailCache[area.id] = trails
            return trails
        }
        guard !whole else { return nil }
        let parts = areaFiles(area).filter { $0.lastPathComponent.contains(".trails.") }.compactMap { try? Data(contentsOf: $0) }
        guard !parts.isEmpty, let merged = try? Overpass.merge(parts) else { return nil }
        return try? Overpass.trails(fromJSON: merged)
    }

    /// Peaks within `radius` of a point from the saved areas, also those whose download
    /// stopped partway (their peaks come first, and are often all there is offline). With
    /// `coveredOnly`, nil unless one area has every peak there (you're inside it);
    /// otherwise whatever they have, or nil.
    private func areaPeaks(around here: LatLon, radius: Double, coveredOnly: Bool) -> [Peak]? {
        var areas = loadAreas()
        if coveredOnly {
            // An area has the peaks within its radius plus `TerrainScene.radius` + 10 km.
            guard let area = areas.first(where: {
                here.distance(to: $0.center) + radius <= $0.radius + TerrainScene.radius + 10_000 && savedPeaks(of: $0) != nil
            }) else { return nil }
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

    /// Hikes near a peak in a saved area, or nil when no area has them (with `whole`, all
    /// of them; otherwise also an area whose hikes were saved only partly).
    private func areaTrails(near peak: Peak, whole: Bool) -> [Trail]? {
        for area in loadAreas() where peak.position.distance(to: area.center) <= area.radius {
            if let trails = savedTrails(of: area, whole: whole) { return nearby(trails, peak) }
        }
        return nil
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
            // Some of it couldn't be fetched (no signal for the second request): shown, but
            // kept only an hour, so it's completed soon rather than in a month.
            var partial = false
            if let id = peak.wikidata {
                facts = try Wikidata.facts(fromJSON: try await get(Wikidata.entityURL(id)), id: id)
                let ids = facts.linkedIDs
                if !ids.isEmpty {
                    if let labels = try? Wikidata.labels(fromJSON: try await get(Wikidata.labelsURL(ids))) {
                        facts.range = facts.rangeID.flatMap { labels[$0] }
                        facts.parent = facts.parentID.flatMap { labels[$0] }
                        facts.countries = facts.countryIDs.compactMap { labels[$0] }
                    } else {
                        partial = true
                    }
                }
            }
            if let article = Wikipedia.article(facts: facts, osmTag: peak.wikipedia),
               let url = Wikipedia.summaryURL(language: article.language, title: article.title) {
                do {
                    try Wikipedia.addSummary(fromJSON: try await get(url), to: &facts)
                } catch Failure.missing {
                    // No such article: nothing to add, now or later.
                } catch {
                    partial = true
                }
            }
            if let data = try? JSONEncoder().encode(facts), (try? data.write(to: cache, options: .atomic)) != nil, partial {
                // Dated so that it's a month old in an hour.
                try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600 - 30 * 86_400)],
                                                       ofItemAtPath: cache.path)
            }
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw Failure.missing }
        guard status == 200 else { throw Failure.download("facts") }
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
        for dir in [demDirectory, peakDirectory, trailDirectory, factDirectory, areaDirectory, coverDirectory, groundDirectory] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        layouts.removeAll()
        coverCells.removeAll()
    }
}

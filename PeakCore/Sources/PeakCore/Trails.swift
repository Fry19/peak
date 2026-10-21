import Foundation

/// A position in degrees.
public struct LatLon: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in meters (mean Earth radius; plenty for trail lengths).
    public func distance(to other: LatLon) -> Double {
        let p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dp = p2 - p1, dl = (other.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * 6_371_008.8 * asin(min(1, a.squareRoot()))
    }
}

/// Hiking difficulty on the SAC scale, which OpenStreetMap tags as `sac_scale`.
public enum Difficulty: Int, Codable, Sendable, Comparable, CaseIterable {
    case hiking = 1, mountainHiking, demandingMountainHiking, alpineHiking, demandingAlpineHiking, difficultAlpineHiking

    public init?(sacScale: String) {
        switch sacScale.trimmingCharacters(in: .whitespaces).lowercased() {
        case "hiking", "t1": self = .hiking
        case "mountain_hiking", "t2": self = .mountainHiking
        case "demanding_mountain_hiking", "t3": self = .demandingMountainHiking
        case "alpine_hiking", "t4": self = .alpineHiking
        case "demanding_alpine_hiking", "t5": self = .demandingAlpineHiking
        case "difficult_alpine_hiking", "t6": self = .difficultAlpineHiking
        default: return nil
        }
    }

    public static func < (a: Difficulty, b: Difficulty) -> Bool { a.rawValue < b.rawValue }

    /// "T1" to "T6".
    public var grade: String { "T\(rawValue)" }

    public var title: String {
        switch self {
        case .hiking: return "Easy hike"
        case .mountainHiking: return "Mountain hike"
        case .demandingMountainHiking: return "Demanding mountain hike"
        case .alpineHiking: return "Alpine route"
        case .demandingAlpineHiking: return "Demanding alpine route"
        case .difficultAlpineHiking: return "Difficult alpine route"
        }
    }

    /// What to expect, after the SAC's own descriptions.
    public var summary: String {
        switch self {
        case .hiking: return "Well-made path, flat or gently sloping. No particular dangers."
        case .mountainHiking: return "Continuous path with even steps; steep in places. Some sure-footedness needed."
        case .demandingMountainHiking: return "Path not always visible; exposed spots may have ropes or chains. Sure-footed, good boots."
        case .alpineHiking: return "Often pathless; hands needed in places. Steep, exposed terrain. Alpine experience needed."
        case .demandingAlpineHiking: return "Pathless, exposed and demanding scrambling. Familiarity with ice axe and rope useful."
        case .difficultAlpineHiking: return "Often exposed, tricky climbing up to grade II. For experienced alpinists only."
        }
    }
}

/// A hiking trail near a peak: an OpenStreetMap hiking route, or a named path.
public struct Trail: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A `route=hiking` (or `foot`) relation: a signposted, named route.
        case route
        /// Ways of a named path, joined.
        case path
    }

    /// "r123" for a route relation, "p:" and the name for a named path.
    public var id: String
    public var name: String
    public var kind: Kind
    /// The trail as lines of connected ways. Most trails are one line; routes with gaps or
    /// branches have more.
    public var lines: [[LatLon]]
    public var difficulty: Difficulty?
    /// Route network: "lwn" local, "rwn" regional, "nwn" national, "iwn" international.
    public var network: String?
    public var ref: String?
    public var from: String?
    public var to: String?
    public var note: String?
    public var operatorName: String?
    public var website: String?
    /// Part of the route lies outside the area fetched (a long-distance route).
    public var isPartial: Bool
    /// Length from the route's own `distance` tag, meters.
    public var taggedLength: Double?

    public init(id: String, name: String, kind: Kind, lines: [[LatLon]], difficulty: Difficulty? = nil,
                network: String? = nil, ref: String? = nil, from: String? = nil, to: String? = nil,
                note: String? = nil, operatorName: String? = nil, website: String? = nil,
                isPartial: Bool = false, taggedLength: Double? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lines = lines
        self.difficulty = difficulty
        self.network = network
        self.ref = ref
        self.from = from
        self.to = to
        self.note = note
        self.operatorName = operatorName
        self.website = website
        self.isPartial = isPartial
        self.taggedLength = taggedLength
    }

    /// Length of the lines, meters.
    public var mappedLength: Double { lines.reduce(0) { $0 + Self.length(of: $1) } }

    /// Best length: the tagged one for a route only partly fetched, else the mapped one.
    public var length: Double { isPartial ? (taggedLength ?? mappedLength) : mappedLength }

    /// Closest the trail comes to a point, meters.
    public func distance(to point: LatLon) -> Double {
        var best = Double.infinity
        for line in lines {
            if line.count == 1 { best = min(best, line[0].distance(to: point)) }
            for (a, b) in zip(line, line.dropFirst()) { best = min(best, Self.distance(from: point, toSegment: a, b)) }
        }
        return best
    }

    /// The longest line, which the elevation profile follows.
    public var mainLine: [LatLon] { lines.max { Self.length(of: $0) < Self.length(of: $1) } ?? [] }

    /// The lines with extra points so that no two neighbors are more than `spacing` meters apart.
    public func densified(spacing: Double) -> [[LatLon]] {
        lines.map { Self.densify($0, spacing: spacing) }
    }

    static func length(of line: [LatLon]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func densify(_ line: [LatLon], spacing: Double) -> [LatLon] {
        guard var last = line.first else { return [] }
        var out = [last]
        for p in line.dropFirst() {
            let n = Int((last.distance(to: p) / spacing).rounded(.up))
            if n > 1 {
                for k in 1..<n {
                    let f = Double(k) / Double(n)
                    out.append(LatLon(last.latitude + (p.latitude - last.latitude) * f,
                                      last.longitude + (p.longitude - last.longitude) * f))
                }
            }
            out.append(p)
            last = p
        }
        return out
    }

    /// Distance from `p` to the segment a–b, on a local flat projection.
    static func distance(from p: LatLon, toSegment a: LatLon, _ b: LatLon) -> Double {
        let k = cos(p.latitude * .pi / 180) * 111_195
        let ax = (a.longitude - p.longitude) * k, ay = (a.latitude - p.latitude) * 111_195
        let bx = (b.longitude - p.longitude) * k, by = (b.latitude - p.latitude) * 111_195
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
        let x = ax + t * dx, y = ay + t * dy
        return (x * x + y * y).squareRoot()
    }

    /// Joins lines that share end points into as few lines as possible, longest first.
    /// OpenStreetMap ways of one route meet at shared nodes, so their ends match exactly.
    public static func chain(_ parts: [[LatLon]]) -> [[LatLon]] {
        let remaining = parts.filter { $0.count >= 2 }
        guard !remaining.isEmpty else { return [] }
        func key(_ p: LatLon) -> [Int] { [Int((p.latitude * 1e6).rounded()), Int((p.longitude * 1e6).rounded())] }
        var used = [Bool](repeating: false, count: remaining.count)
        var byEnd: [[Int]: [Int]] = [:]
        for (i, part) in remaining.enumerated() {
            byEnd[key(part.first!), default: []].append(i)
            byEnd[key(part.last!), default: []].append(i)
        }
        let order = remaining.indices.sorted { length(of: remaining[$0]) > length(of: remaining[$1]) }
        var chains: [[LatLon]] = []
        for start in order where !used[start] {
            used[start] = true
            var line = remaining[start]
            // Grow at the end, then at the start, while some unused part touches it.
            for _ in 0..<2 {
                while let next = byEnd[key(line.last!)]?.first(where: { !used[$0] }) {
                    used[next] = true
                    let part = remaining[next]
                    line += key(part.first!) == key(line.last!) ? Array(part.dropFirst()) : Array(part.reversed().dropFirst())
                }
                line.reverse()
            }
            chains.append(line)
        }
        return chains
    }
}

/// Elevations along a trail from the terrain model.
public struct TrailProfile: Sendable {
    public struct Point: Sendable {
        /// Distance along the trail from its start, meters.
        public var distance: Double
        public var elevation: Double
        public var position: LatLon
    }

    /// Points along the main line, from its lower end.
    public var points: [Point]
    /// Total climb and descent over all lines, each walked from its lower end, meters.
    public var gain: Double
    public var loss: Double
    public var highest: Double
    public var lowest: Double

    /// The lower end of the main line: where a hike up usually starts.
    public var trailhead: LatLon? { points.first?.position }
}

extension Trail {
    /// Samples the terrain every `spacing` meters along the trail. Climbs smaller than
    /// `threshold` meters are ignored as noise. Nil when the terrain doesn't cover it.
    public func profile(on terrain: Terrain, spacing: Double = 25, threshold: Double = 3) -> TrailProfile? {
        func sample(_ line: [LatLon]) -> [TrailProfile.Point] {
            var out: [TrailProfile.Point] = []
            var along = 0.0
            var last: LatLon?
            for p in Self.densify(line, spacing: spacing) {
                if let last { along += last.distance(to: p) }
                last = p
                let h = terrain.height(latitude: p.latitude, longitude: p.longitude)
                if h.isFinite { out.append(.init(distance: along, elevation: h, position: p)) }
            }
            // Start at the lower end.
            if let first = out.first, let end = out.last, end.elevation < first.elevation {
                let total = end.distance
                out = out.reversed().map { .init(distance: total - $0.distance, elevation: $0.elevation, position: $0.position) }
            }
            return out
        }
        func climb(_ points: [TrailProfile.Point]) -> (Double, Double) {
            guard var anchor = points.first?.elevation else { return (0, 0) }
            var up = 0.0, down = 0.0
            for p in points.dropFirst() {
                let d = p.elevation - anchor
                if d >= threshold { up += d; anchor = p.elevation } else if d <= -threshold { down -= d; anchor = p.elevation }
            }
            return (up, down)
        }
        let main = sample(mainLine)
        guard main.count >= 2 else { return nil }
        var gain = 0.0, loss = 0.0, highest = -Double.infinity, lowest = Double.infinity
        for line in lines {
            let points = sample(line)
            let (up, down) = climb(points)
            gain += up
            loss += down
            for p in points {
                highest = max(highest, p.elevation)
                lowest = min(lowest, p.elevation)
            }
        }
        return TrailProfile(points: main, gain: gain, loss: loss, highest: highest, lowest: lowest)
    }
}

extension Overpass {
    /// Hiking routes and named paths within `radius` meters of a peak (a box around it),
    /// and paths without a name within `summitRadius` of it (often the way up).
    public static func trailsQuery(latitude: Double, longitude: Double, radius: Double, summitRadius: Double = 400) -> String {
        let dlat = radius / 111_000, dlon = radius / (111_000 * max(cos(latitude * .pi / 180), 0.05))
        return trailsQuery(south: latitude - dlat, west: longitude - dlon, north: latitude + dlat, east: longitude + dlon,
                           summit: LatLon(latitude, longitude), summitRadius: summitRadius)
    }

    /// Hiking routes and named paths in a box (degrees), with their geometry clipped to it;
    /// with a `summit`, also paths without a name near it. Boxes are what Overpass indexes,
    /// so this is much quicker than searching around a point.
    public static func trailsQuery(south: Double, west: Double, north: Double, east: Double,
                                   summit: LatLon? = nil, summitRadius: Double = 400, timeout: Int = 25) -> String {
        let box = String(format: "%.5f,%.5f,%.5f,%.5f", south, west, north, east)
        let unnamed = summit.map {
            String(format: "\n  way[\"highway\"~\"^(path|footway|steps|bridleway)$\"][!\"name\"](around:%.0f,%.6f,%.6f);",
                   summitRadius, $0.latitude, $0.longitude)
        } ?? ""
        return """
        [out:json][timeout:\(timeout)];
        relation["route"~"^(hiking|foot)$"](\(box))->.routes;
        .routes out tags geom(\(box));
        way(r.routes)["sac_scale"];
        out tags;
        (
          way["highway"~"^(path|bridleway)$"]["name"](\(box));
          way["highway"~"^(footway|steps|track)$"]["name"]["sac_scale"](\(box));\(unnamed)
        );
        out tags geom(\(box));
        """
    }

    /// The error an Overpass server reports in an otherwise normal response (it answers
    /// 200 with a "remark" when a query runs out of time or memory), or nil.
    public static func failure(inJSON data: Data) -> String? {
        struct Response: Decodable { var remark: String? }
        guard let remark = (try? JSONDecoder().decode(Response.self, from: data))?.remark,
              remark.lowercased().contains("error") else { return nil }
        return remark
    }

    /// Trails in an Overpass response to `trailsQuery`. Named paths that belong to a route
    /// are left to the route; trails shorter than `minLength` meters are dropped.
    public static func trails(fromJSON data: Data, minLength: Double = 300) throws -> [Trail] {
        struct Point: Decodable {
            var lat: Double
            var lon: Double
        }
        struct Member: Decodable {
            var type: String
            var ref: Int64
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

        let elements = try JSONDecoder().decode(Response.self, from: data).elements
        // Splits a way's geometry where points were clipped away.
        func pieces(_ geometry: [Point?]) -> [[LatLon]] {
            var out: [[LatLon]] = [], current: [LatLon] = []
            for p in geometry {
                if let p { current.append(LatLon(p.lat, p.lon)) } else if !current.isEmpty { out.append(current); current = [] }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        func meters(_ raw: String?) -> Double? {
            guard var s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
            let miles = s.hasSuffix("mi")
            let meters = s.hasSuffix("m") && !s.hasSuffix("km")
            s = String(s.prefix { $0.isNumber || $0 == "." || $0 == "," }).replacingOccurrences(of: ",", with: ".")
            guard let v = Double(s), v > 0 else { return nil }
            return miles ? v * 1_609.344 : meters ? v : v * 1_000
        }

        var wayDifficulty: [Int64: Difficulty] = [:]
        for e in elements where e.type == "way" {
            if let d = e.tags?["sac_scale"].flatMap(Difficulty.init(sacScale:)) { wayDifficulty[e.id] = d }
        }

        var trails: [Trail] = []
        var routeWays = Set<Int64>()
        for e in elements where e.type == "relation" {
            let tags = e.tags ?? [:]
            let ways = (e.members ?? []).filter { $0.type == "way" }
            guard !ways.isEmpty else { continue }   // a route of routes
            ways.forEach { routeWays.insert($0.ref) }
            var parts: [[LatLon]] = []
            var partial = false
            for m in ways {
                let geometry = m.geometry ?? []
                if geometry.isEmpty || geometry.contains(where: { $0 == nil }) { partial = true }
                parts += pieces(geometry)
            }
            let lines = Trail.chain(parts)
            guard !lines.isEmpty else { continue }
            let name = tags["name"] ?? tags["ref"].map { "Route \($0)" } ?? [tags["from"], tags["to"]].compactMap { $0 }.joined(separator: " – ")
            let difficulty = tags["sac_scale"].flatMap(Difficulty.init(sacScale:)) ?? ways.compactMap { wayDifficulty[$0.ref] }.max()
            trails.append(Trail(id: "r\(e.id)", name: name.isEmpty ? "Hiking route" : name, kind: .route, lines: lines,
                                difficulty: difficulty, network: tags["network"], ref: tags["ref"], from: tags["from"],
                                to: tags["to"], note: tags["description"], operatorName: tags["operator"],
                                website: tags["website"] ?? tags["url"], isPartial: partial,
                                taggedLength: meters(tags["distance"])))
        }

        // Named paths that aren't part of any route, grouped by name.
        var byName: [String: [Element]] = [:]
        for e in elements where e.type == "way" && e.geometry != nil && !routeWays.contains(e.id) {
            if let name = e.tags?["name"], !name.isEmpty { byName[name, default: []].append(e) }
        }
        for (name, ways) in byName {
            let parts = ways.flatMap { pieces($0.geometry ?? []) }
            let lines = Trail.chain(parts)
            guard !lines.isEmpty else { continue }
            let partial = ways.contains { $0.geometry?.contains(where: { $0 == nil }) ?? false }
            trails.append(Trail(id: "p:" + name, name: name, kind: .path, lines: lines,
                                difficulty: ways.compactMap { wayDifficulty[$0.id] }.max(),
                                operatorName: ways.lazy.compactMap { $0.tags?["operator"] }.first, isPartial: partial))
        }
        // Paths without a name (fetched only near the summit), joined where they meet.
        let unnamed = elements.filter {
            $0.type == "way" && $0.geometry != nil && !routeWays.contains($0.id) && ($0.tags?["name"] ?? "").isEmpty
        }
        let unnamedParts = unnamed.map { (way: $0, pieces: pieces($0.geometry ?? [])) }
        for line in Trail.chain(unnamedParts.flatMap(\.pieces)) {
            let points = Set(line.map { [Int(($0.latitude * 1e6).rounded()), Int(($0.longitude * 1e6).rounded())] })
            let ways = unnamedParts.filter { part in
                part.pieces.contains { piece in piece.contains { points.contains([Int(($0.latitude * 1e6).rounded()), Int(($0.longitude * 1e6).rounded())]) } }
            }.map(\.way)
            let difficulty = ways.compactMap { wayDifficulty[$0.id] }.max()
            let id = ways.map(\.id).min().map { "u\($0)" } ?? "u"
            trails.append(Trail(id: id, name: "Unnamed path" + (difficulty.map { " (\($0.grade))" } ?? ""), kind: .path,
                                lines: [line], difficulty: difficulty,
                                isPartial: ways.contains { $0.geometry?.contains(where: { $0 == nil }) ?? false }))
        }
        return trails.filter { $0.mappedLength >= minLength }
    }
}

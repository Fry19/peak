import Foundation

/// A named summit from OpenStreetMap (`natural=peak` or `natural=volcano`).
public struct Peak: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// Elevation from the peak database, meters. Never from GPS. For peaks the database
    /// has no elevation for, the terrain's (see `estimatedElevation`).
    public var elevation: Double
    /// The elevation is the terrain model's, since OpenStreetMap has none for this peak.
    public var estimatedElevation = false
    /// Topographic prominence when OpenStreetMap has it, meters.
    public var prominence: Double?
    /// Wikidata item ("Q1374") and Wikipedia article ("en:Matterhorn"), for facts.
    public var wikidata: String?
    public var wikipedia: String?

    public init(id: Int64, name: String, latitude: Double, longitude: Double, elevation: Double,
                prominence: Double? = nil, wikidata: String? = nil, wikipedia: String? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.prominence = prominence
        self.wikidata = wikidata
        self.wikipedia = wikipedia
    }

    public var position: LatLon { LatLon(latitude, longitude) }

    public var point: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude, height: elevation) }
}

/// Peaks from the OpenStreetMap Overpass API.
public enum Overpass {
    public static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Query for named peaks inside a bounding box (degrees). Volcanoes such as Rainier,
    /// Fuji and Kilimanjaro are tagged `natural=volcano` rather than `peak`.
    public static func peaksQuery(south: Double, west: Double, north: Double, east: Double) -> String {
        let box = String(format: "%.4f,%.4f,%.4f,%.4f", south, west, north, east)
        return "[out:json][timeout:90];node[\"natural\"~\"^(peak|volcano)$\"][\"name\"](\(box));out body;"
    }

    /// Peaks in an Overpass JSON response. Peaks without a usable elevation are kept with
    /// `estimatedElevation` set (and elevation 0) for the terrain to fill in.
    public static func peaks(fromJSON data: Data) throws -> [Peak] {
        struct Response: Decodable {
            struct Element: Decodable {
                var id: Int64
                var lat: Double?
                var lon: Double?
                var tags: [String: String]?
            }
            var elements: [Element]
        }
        return try JSONDecoder().decode(Response.self, from: data).elements.compactMap { e in
            guard let lat = e.lat, let lon = e.lon, let tags = e.tags, let name = tags["name"], !name.isEmpty else { return nil }
            let ele = tags["ele"].flatMap(parseElevation)
            let wikidata = tags["wikidata"].flatMap { $0.hasPrefix("Q") ? $0 : nil }
            var peak = Peak(id: e.id, name: name, latitude: lat, longitude: lon, elevation: ele ?? 0,
                            prominence: tags["prominence"].flatMap(parseElevation), wikidata: wikidata,
                            wikipedia: tags["wikipedia"])
            peak.estimatedElevation = ele == nil
            return peak
        }
    }

    /// Parses OSM `ele` values: "4478", "4478.5", "4,478", "4478,5", "4 478 m", "14505 ft",
    /// "~3000", "ca. 3000", "1200 ft (approx)". Nil for anything that isn't a height above 0.
    public static func parseElevation(_ raw: String) -> Double? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["~", "ca.", "ca", "c.", "approx.", "approx", "about"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // The number, with spaces (plain, no-break or thin) allowed between digit groups.
        let spaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}", "\u{2009}"]
        var number = String(s.prefix { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") || spaces.contains($0) })
        let rest = s.dropFirst(number.count)
        let groups = number.split(whereSeparator: { spaces.contains($0) }).map(String.init)
        guard let first = groups.first else { return nil }
        // "4 478" groups thousands; otherwise only the first group is the number.
        let grouped = groups.count > 1 && groups.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
        number = grouped ? groups.joined() : first
        let unit = grouped || groups.count == 1 ? String(rest) : String(s.dropFirst(first.count))
        let feet = unit.contains("ft") || unit.contains("feet") || unit.contains("foot") || unit.contains("'")
        let comma = number.lastIndex(of: ","), dot = number.lastIndex(of: ".")
        if let comma, let dot {
            // Both: the last one is the decimal point ("4,478.5", "4.478,5").
            number = comma > dot ? number.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                                 : number.replacingOccurrences(of: ",", with: "")
        } else if let comma {
            // "4,478" groups thousands; "4478,5" is a decimal comma.
            let after = number[number.index(after: comma)...]
            number = after.count == 3
                ? number.replacingOccurrences(of: ",", with: "")
                : number.replacingOccurrences(of: ",", with: ".")
        }
        guard let v = Double(number), v > 0, v < 9000 * (feet ? 3.3 : 1) else { return nil }
        return feet ? v * 0.3048 : v
    }
}

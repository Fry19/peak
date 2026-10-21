import Foundation

/// A named summit from OpenStreetMap (`natural=peak`).
public struct Peak: Codable, Sendable, Hashable {
    public var id: Int64
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// Elevation from the peak database, meters. Never from GPS.
    public var elevation: Double
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

    /// Query for named peaks inside a bounding box (degrees).
    public static func peaksQuery(south: Double, west: Double, north: Double, east: Double) -> String {
        let box = String(format: "%.4f,%.4f,%.4f,%.4f", south, west, north, east)
        return "[out:json][timeout:90];node[\"natural\"=\"peak\"][\"name\"](\(box));out body;"
    }

    /// Peaks in an Overpass JSON response. Peaks without a usable elevation are left out,
    /// since labels show it and the line-of-sight test needs it.
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
            guard let lat = e.lat, let lon = e.lon, let tags = e.tags, let name = tags["name"], !name.isEmpty,
                  let ele = tags["ele"].flatMap(parseElevation) else { return nil }
            let wikidata = tags["wikidata"].flatMap { $0.hasPrefix("Q") ? $0 : nil }
            return Peak(id: e.id, name: name, latitude: lat, longitude: lon, elevation: ele,
                        prominence: tags["prominence"].flatMap(parseElevation), wikidata: wikidata,
                        wikipedia: tags["wikipedia"])
        }
    }

    /// Parses OSM `ele` values: "4478", "4478.5", "4,478", "4478 m", "14505 ft", "4478,5".
    public static func parseElevation(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let feet = s.hasSuffix("ft") || s.hasSuffix("'") || s.hasSuffix("feet")
        s = String(s.prefix { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" })
        if let comma = s.firstIndex(of: ",") {
            // "4,478" groups thousands; "4478,5" is a decimal comma.
            let after = s[s.index(after: comma)...]
            s = after.count == 3 && !after.contains(",") && !s.contains(".")
                ? s.replacingOccurrences(of: ",", with: "")
                : s.replacingOccurrences(of: ",", with: ".")
        }
        guard let v = Double(s), v > -500, v < 9000 * (feet ? 3.3 : 1) else { return nil }
        return feet ? v * 0.3048 : v
    }
}

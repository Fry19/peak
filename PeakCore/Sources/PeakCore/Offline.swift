import Foundation

/// A box in degrees.
public struct GeoBox: Sendable, Hashable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    /// The box `radius` meters around a point (east and west at the point's latitude).
    public init(around center: LatLon, radius: Double) {
        let dlat = radius / 111_000, dlon = radius / (111_000 * max(cos(center.latitude * .pi / 180), 0.05))
        self.init(south: center.latitude - dlat, west: center.longitude - dlon,
                  north: center.latitude + dlat, east: center.longitude + dlon)
    }

    public func contains(_ p: LatLon) -> Bool {
        p.latitude >= south && p.latitude <= north && p.longitude >= west && p.longitude <= east
    }

    /// The box split into a grid of equal boxes no more than `side` meters across, rows
    /// from south to north. Overpass answers a few small boxes where one large one runs
    /// out of time.
    public func split(side: Double) -> [GeoBox] {
        let mid = (south + north) / 2
        let height = (north - south) * 111_000
        let width = (east - west) * 111_000 * max(cos(mid * .pi / 180), 0.05)
        let rows = max(1, Int((height / side).rounded(.up))), cols = max(1, Int((width / side).rounded(.up)))
        let dlat = (north - south) / Double(rows), dlon = (east - west) / Double(cols)
        var out: [GeoBox] = []
        for r in 0..<rows {
            for c in 0..<cols {
                // Shared edges are the same numbers, so neighbors meet exactly.
                out.append(GeoBox(south: r == 0 ? south : south + Double(r) * dlat,
                                  west: c == 0 ? west : west + Double(c) * dlon,
                                  north: r == rows - 1 ? north : south + Double(r + 1) * dlat,
                                  east: c == cols - 1 ? east : west + Double(c + 1) * dlon))
            }
        }
        return out
    }
}

/// The 0.25° grid cell peaks are cached by, so nearby spots share one download. A cell's
/// file has the peaks in a box `radius` + 20 km around the cell's center.
public struct PeakCell: Sendable, Hashable {
    /// The cell's center, a multiple of 0.25°.
    public var latitude: Double
    public var longitude: Double
    /// The radius the peaks were fetched for, whole kilometers.
    public var radiusKm: Int

    /// How far beyond the radius a cell's peaks reach, meters.
    public static let margin = 20_000.0

    /// The cell a point is in.
    public init(latitude: Double, longitude: Double, radius: Double) {
        // Adding zero turns -0.0 (from rounding a small negative number) into 0.0, so the
        // same cell doesn't get both "-0.00" and "0.00" files.
        self.latitude = (latitude * 4).rounded() / 4 + 0
        self.longitude = (longitude * 4).rounded() / 4 + 0
        radiusKm = Int(radius / 1000)
    }

    /// "v2": since volcanoes are fetched too, so caches without them are fetched again.
    public var fileName: String {
        String(format: "%.2f_%.2f_%d_v2.json", latitude + 0, longitude + 0, radiusKm)
    }

    /// The cell a cache file is for, or nil for a file that isn't one.
    public init?(fileName: String) {
        guard fileName.hasSuffix("_v2.json") else { return nil }
        let parts = fileName.dropLast("_v2.json".count).split(separator: "_")
        guard parts.count == 3, let lat = Double(parts[0]), let lon = Double(parts[1]), let km = Int(parts[2]) else { return nil }
        latitude = lat + 0
        longitude = lon + 0
        radiusKm = km
    }

    public var center: LatLon { LatLon(latitude, longitude) }

    /// The box the cell's peaks were fetched for.
    public var box: GeoBox { GeoBox(around: center, radius: Double(radiusKm) * 1000 + Self.margin) }

    /// Of cached cells for the same radius, the one with the nearest center whose box has
    /// `point` in it: the best stand-in when the cell `point` is in has no file.
    public static func nearestCovering(_ point: LatLon, radius: Double, among cells: [PeakCell]) -> PeakCell? {
        let km = Int(radius / 1000)
        return cells.filter { $0.radiusKm == km && $0.box.contains(point) }
            .min { $0.center.distance(to: point) < $1.center.distance(to: point) }
    }
}

extension Overpass {
    /// Joins Overpass responses for neighboring boxes into one, as if it were the answer
    /// for all of them: an element in several (a path or route crossing a box edge) is kept
    /// once, with the points each answer had (answers clipped to a box leave the others out,
    /// as nulls) put together.
    public static func merge(_ responses: [Data]) throws -> Data {
        var order: [String] = []
        var byKey: [String: [String: Any]] = [:]
        for data in responses {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = object["elements"] as? [[String: Any]] else {
                throw CocoaError(.coderReadCorrupt)
            }
            for e in elements {
                let key = "\(e["type"] ?? "")/\(e["id"] ?? "")"
                if let old = byKey[key] {
                    byKey[key] = mergeElement(old, e)
                } else {
                    order.append(key)
                    byKey[key] = e
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: ["elements": order.map { byKey[$0]! }])
    }

    private static func mergeElement(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b where out[k] == nil { out[k] = v }
        if let g = mergeGeometry(a["geometry"], b["geometry"]) { out["geometry"] = g }
        if let ma = a["members"] as? [[String: Any]], let mb = b["members"] as? [[String: Any]], ma.count == mb.count {
            out["members"] = zip(ma, mb).map { x, y -> [String: Any] in
                var m = x
                if let g = mergeGeometry(x["geometry"], y["geometry"]) { m["geometry"] = g }
                return m
            }
        }
        return out
    }

    /// Point by point, whichever answer has the point; nil when neither has a geometry.
    private static func mergeGeometry(_ a: Any?, _ b: Any?) -> [Any]? {
        let ga = a as? [Any], gb = b as? [Any]
        guard let ga, let gb else { return ga ?? gb }
        func known(_ g: [Any]) -> Int { g.filter { !($0 is NSNull) }.count }
        // The same way has the same points; if not (edited between the queries), the
        // fuller one.
        guard ga.count == gb.count else { return known(ga) >= known(gb) ? ga : gb }
        return zip(ga, gb).map { $0 is NSNull ? $1 : $0 }
    }
}

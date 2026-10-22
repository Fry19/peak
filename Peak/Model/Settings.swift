import Foundation
import PeakCore

/// What the user can change, kept between launches.
struct AppSettings: Codable, Equatable {
    enum Units: String, Codable, CaseIterable, Identifiable {
        case metric, imperial
        var id: String { rawValue }
        var title: String { self == .metric ? "Meters" : "Feet" }
    }

    /// How the map from above draws the ground.
    enum MapStyle: String, Codable, CaseIterable, Identifiable {
        /// Apple's satellite imagery, while there's a connection; the terrain without one.
        case satellite
        /// Drawn from the terrain itself, in the walk in 3D's colors. Works offline.
        case terrain
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum LabelDensity: String, Codable, CaseIterable, Identifiable {
        case fewer, normal, more
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var maxLabels: Int {
            switch self {
            case .fewer: return 6
            case .normal: return 10
            case .more: return 18
            }
        }
    }

    var units: Units = Locale.current.measurementSystem == .us ? .imperial : .metric
    var labels: LabelDensity = .normal
    /// Ridges in front of the skyline, not just the skyline.
    var showRidges = true
    var haptics = true
    /// A trail's stretches behind nearer ridges, drawn dashed as if seen through them.
    var trailXRay = false
    /// Fetch the sharpest terrain on mobile data too, not just on Wi-Fi.
    var detailOnMobile = true
    var showDiagnostics = false
    /// Today's sun path, dotted across the sky in the camera view.
    var showSunPath = false
    /// The map from above: satellite imagery or the terrain's own shading.
    var mapStyle: MapStyle = .satellite
    /// The peak to remind about 20 minutes before alpenglow (last light on its summit).
    var alpenglow: Peak?

    private static let key = "settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension AppSettings {
    /// Settings saved before a newer one was added keep their values; what's missing takes
    /// its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        units = try c.decodeIfPresent(Units.self, forKey: .units) ?? units
        labels = try c.decodeIfPresent(LabelDensity.self, forKey: .labels) ?? labels
        showRidges = try c.decodeIfPresent(Bool.self, forKey: .showRidges) ?? showRidges
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? haptics
        trailXRay = try c.decodeIfPresent(Bool.self, forKey: .trailXRay) ?? trailXRay
        detailOnMobile = try c.decodeIfPresent(Bool.self, forKey: .detailOnMobile) ?? detailOnMobile
        showDiagnostics = try c.decodeIfPresent(Bool.self, forKey: .showDiagnostics) ?? showDiagnostics
        showSunPath = try c.decodeIfPresent(Bool.self, forKey: .showSunPath) ?? showSunPath
        mapStyle = try c.decodeIfPresent(MapStyle.self, forKey: .mapStyle) ?? mapStyle
        alpenglow = try c.decodeIfPresent(Peak.self, forKey: .alpenglow)
    }
}

/// Numbers as the user wants to read them, written the way their region writes numbers
/// ("4,478 m" in the US, "4.478 m" in Germany; "12.3 km" or "12,3 km").
enum Format {
    /// Whole numbers, grouped.
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Up to one decimal, without a trailing zero: "12.3", "25".
    private static let tenths: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

    private static func whole(_ v: Double) -> String {
        grouped.string(from: NSNumber(value: v.rounded())) ?? String(Int(v.rounded()))
    }

    /// A number with up to one decimal, "12.3" or "25", in the user's region's way.
    static func decimal(_ v: Double) -> String {
        tenths.string(from: NSNumber(value: (v * 10).rounded() / 10)) ?? String(v)
    }

    /// "4,478 m" or "14,692 ft".
    static func elevation(_ meters: Double, _ units: AppSettings.Units) -> String {
        units == .metric ? whole(meters) + " m" : whole(meters / 0.3048) + " ft"
    }

    /// Its number alone, "1,000", where the unit is given once nearby.
    static func elevationNumber(_ meters: Double, _ units: AppSettings.Units) -> String {
        units == .metric ? whole(meters) : whole(meters / 0.3048)
    }

    /// A peak's elevation: "4,478 m", or "≈ 1,234 m" when it's the terrain's estimate.
    static func elevation(of peak: Peak, _ units: AppSettings.Units) -> String {
        (peak.estimatedElevation ? "≈ " : "") + elevation(peak.elevation, units)
    }

    /// "+2,350 m" for a height difference.
    static func climb(_ meters: Double, _ units: AppSettings.Units) -> String {
        (meters >= 0 ? "+" : "−") + elevation(abs(meters), units)
    }

    /// "850 m", "12.3 km", "25 km", "650 ft" or "7.6 mi".
    static func distance(_ meters: Double, _ units: AppSettings.Units) -> String {
        switch units {
        case .metric:
            if meters < 1_000 { return whole((meters / 10).rounded() * 10) + " m" }
            return (meters < 100_000 ? decimal(meters / 1_000) : whole(meters / 1_000)) + " km"
        case .imperial:
            let miles = meters / 1_609.344
            if miles < 0.2 { return whole((meters / 0.3048 / 10).rounded() * 10) + " ft" }
            return (miles < 100 ? decimal(miles) : whole(miles)) + " mi"
        }
    }

    /// "2.5×" for a zoom.
    static func zoom(_ factor: Double) -> String {
        decimal(factor) + "×"
    }

    /// "236° SW".
    static func bearing(_ azimuth: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let a = normalizedAzimuth(azimuth)
        return whole(a.rounded() == 360 ? 0 : a) + "° " + names[Int((a / 45).rounded()) % 8]
    }

    /// "1.2 GB" or "350 MB".
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

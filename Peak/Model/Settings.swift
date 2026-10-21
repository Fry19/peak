import Foundation
import PeakCore

/// What the user can change, kept between launches.
struct AppSettings: Codable, Equatable {
    enum Units: String, Codable, CaseIterable, Identifiable {
        case metric, imperial
        var id: String { rawValue }
        var title: String { self == .metric ? "Meters" : "Feet" }
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
    /// Fetch the sharpest terrain on mobile data too, not just on Wi-Fi.
    var detailOnMobile = true
    var showDiagnostics = false

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

/// Numbers as the user wants to read them.
enum Format {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static func whole(_ v: Double) -> String {
        grouped.string(from: NSNumber(value: v.rounded())) ?? String(Int(v.rounded()))
    }

    /// "4,478 m" or "14,692 ft".
    static func elevation(_ meters: Double, _ units: AppSettings.Units) -> String {
        units == .metric ? whole(meters) + " m" : whole(meters / 0.3048) + " ft"
    }

    /// "+2,350 m" for a height difference.
    static func climb(_ meters: Double, _ units: AppSettings.Units) -> String {
        (meters >= 0 ? "+" : "−") + elevation(abs(meters), units)
    }

    /// "850 m", "12.3 km", "650 ft" or "7.6 mi".
    static func distance(_ meters: Double, _ units: AppSettings.Units) -> String {
        switch units {
        case .metric:
            if meters < 1_000 { return whole((meters / 10).rounded() * 10) + " m" }
            return meters < 100_000 ? String(format: "%.1f km", meters / 1_000) : whole(meters / 1_000) + " km"
        case .imperial:
            let miles = meters / 1_609.344
            if miles < 0.2 { return whole((meters / 0.3048 / 10).rounded() * 10) + " ft" }
            return miles < 100 ? String(format: "%.1f mi", miles) : whole(miles) + " mi"
        }
    }

    /// "236° SW".
    static func bearing(_ azimuth: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let a = normalizedAzimuth(azimuth)
        return String(format: "%.0f° %@", a.rounded() == 360 ? 0 : a, names[Int((a / 45).rounded()) % 8])
    }

    /// "1.2 GB" or "350 MB".
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

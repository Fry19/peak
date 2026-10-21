import Charts
import MapKit
import PeakCore
import SwiftUI

/// A hike's card: the route on a map, its numbers, the climb, and a button to draw it on
/// the mountain.
struct TrailDetailView: View {
    let model: AppModel
    let link: TrailLink

    var body: some View {
        Group {
            if let peak = model.peak(link.peakID), let hike = model.details(for: peak).hikes.first(where: { $0.id == link.trailID }) {
                content(peak, hike)
            } else {
                ContentUnavailableView("Hike not found", systemImage: "figure.hiking")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ peak: Peak, _ hike: PeakDetails.Hike) -> some View {
        let units = model.settings.units
        let trail = hike.trail
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trail.name)
                        .font(.system(size: 24, weight: .bold))
                    Text(kind(trail))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

                TrailMap(trail: trail, peak: peak, start: hike.profile?.trailhead)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                StatGrid(stats: stats(hike, units))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                Button {
                    model.showOnMountain(trail, peakID: peak.id)
                } label: {
                    Label("Show on the mountain", systemImage: "mountain.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1, green: 0.72, blue: 0.28))
                .foregroundStyle(.black)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if let profile = hike.profile, profile.points.count > 2 {
                Section("Elevation") {
                    ProfileChart(profile: profile, units: units)
                        .frame(height: 160)
                }
            }

            if let d = trail.difficulty {
                Section("Difficulty") {
                    HStack(alignment: .top, spacing: 10) {
                        DifficultyBadge(difficulty: d)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.title).font(.system(size: 15, weight: .semibold))
                            Text(d.summary).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if let start = hike.profile?.trailhead {
                    Button {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)))
                        item.name = "Start of \(trail.name)"
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
                    } label: {
                        Label("Directions to the start", systemImage: "car")
                    }
                }
                if let url = osmURL(trail) {
                    Link(destination: url) { Label("View on OpenStreetMap", systemImage: "map") }
                }
                if let site = trail.website.flatMap({ URL(string: $0) }), site.scheme?.hasPrefix("http") == true {
                    Link(destination: site) { Label("Website", systemImage: "safari") }
                }
            }

            if trail.note != nil || trail.from != nil || trail.operatorName != nil {
                Section("Details") {
                    if let from = trail.from, let to = trail.to { LabeledContent("Route", value: "\(from) – \(to)") }
                    if let op = trail.operatorName { LabeledContent("Maintained by", value: op) }
                    if let note = trail.note { Text(note).font(.callout) }
                }
            }

            Section {
                Text(trail.isPartial
                     ? "Part of a longer route; the map shows the part near \(peak.name)."
                     : "Route © OpenStreetMap contributors. Climb from the Copernicus terrain model.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func kind(_ trail: Trail) -> String {
        let network: String
        switch trail.network {
        case "iwn": network = "International hiking route"
        case "nwn": network = "National hiking route"
        case "rwn": network = "Regional hiking route"
        case "lwn": network = "Local hiking route"
        default: network = trail.kind == .route ? "Hiking route" : "Trail"
        }
        return trail.ref.map { "\(network) · \($0)" } ?? network
    }

    private func stats(_ hike: PeakDetails.Hike, _ units: AppSettings.Units) -> [Stat] {
        var stats = [Stat(title: hike.trail.isPartial ? "Length (route)" : "Length", value: Format.distance(hike.trail.length, units))]
        if let p = hike.profile {
            stats.append(Stat(title: "Climb", value: Format.elevation(p.gain, units)))
            stats.append(Stat(title: "Descent", value: Format.elevation(p.loss, units)))
            stats.append(Stat(title: "Highest point", value: Format.elevation(p.highest, units)))
            if let start = p.trailhead, let here = model.scene?.position {
                stats.append(Stat(title: "Start from you", value: Format.distance(here.distance(to: start), units)))
            }
        }
        if let d = hike.trail.difficulty { stats.append(Stat(title: "Difficulty", value: "\(d.grade) · \(d.title)")) }
        stats.append(Stat(title: "To the summit", value: hike.reachesSummit ? "Yes" : Format.distance(hike.distanceFromPeak, units) + " away"))
        return stats
    }

    private func osmURL(_ trail: Trail) -> URL? {
        guard trail.id.hasPrefix("r"), let id = Int64(trail.id.dropFirst()) else { return nil }
        return URL(string: "https://www.openstreetmap.org/relation/\(id)")
    }
}

/// The trail on a satellite map with the summit and the start marked.
private struct TrailMap: View {
    let trail: Trail
    let peak: Peak
    let start: LatLon?

    var body: some View {
        Map(initialPosition: .rect(region)) {
            ForEach(Array(trail.lines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(Color(red: 1, green: 0.72, blue: 0.28), lineWidth: 3)
            }
            Marker(peak.name, systemImage: "mountain.2.fill", coordinate: CLLocationCoordinate2D(latitude: peak.latitude, longitude: peak.longitude))
                .tint(.indigo)
            if let start {
                Marker("Start", systemImage: "figure.hiking", coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude))
                    .tint(.orange)
            }
            UserAnnotation()
        }
        .mapStyle(.hybrid(elevation: .realistic))
    }

    private var region: MKMapRect {
        var rect = MKMapRect.null
        let points = trail.lines.flatMap { $0 } + [peak.position]
        for p in points {
            let m = MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
            rect = rect.union(MKMapRect(x: m.x, y: m.y, width: 0, height: 0))
        }
        let pad = max(rect.width, rect.height) * 0.15 + 500
        return rect.insetBy(dx: -pad, dy: -pad)
    }
}

/// Elevation along the trail from its start.
private struct ProfileChart: View {
    let profile: TrailProfile
    let units: AppSettings.Units

    var body: some View {
        let scale = units == .metric ? 1.0 : 1 / 0.3048
        let along = units == .metric ? 1_000.0 : 1_609.344
        let low = (profile.lowest * scale / 50).rounded(.down) * 50
        let high = max(low + 100, (profile.highest * scale / 50).rounded(.up) * 50)
        return Chart(profile.points, id: \.distance) { p in
            AreaMark(x: .value("Distance", p.distance / along),
                     yStart: .value("Base", low),
                     yEnd: .value("Elevation", p.elevation * scale))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.28).opacity(0.35), .clear],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Distance", p.distance / along), y: .value("Elevation", p.elevation * scale))
                .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.28))
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: low...high)
        .chartXAxisLabel(units == .metric ? "km" : "mi")
        .chartYAxisLabel(units == .metric ? "m" : "ft")
    }
}

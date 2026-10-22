import PeakCore
import SwiftUI

/// A peak's card: how high and how far, a few facts, and the hikes nearby.
struct PeakDetailView: View {
    let model: AppModel
    let peakID: Int64
    /// The scene the peak is seen in when it's a photo's, not the live view's.
    var place: TerrainScene? = nil
    @State private var details: PeakDetails?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let peak {
                content(peak)
            } else {
                ContentUnavailableView("Peak not found", systemImage: "mountain.2")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { close() }
            }
        }
        .onAppear {
            if place == nil { model.selectedPeakID = peakID }
            if details == nil, let peak { details = model.details(for: peak, place: place) }
        }
    }

    private var scene: TerrainScene? { place ?? model.scene }
    private var peak: Peak? { place.map { $0.allPeaks[peakID]?.peak } ?? model.peak(peakID) }

    private func close() {
        if place == nil { model.sheet = nil } else { dismiss() }
    }

    private func content(_ peak: Peak) -> some View {
        let units = model.settings.units
        let view = scene?.allPeaks[peak.id]
        let facts = details?.facts
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(peak.name)
                        .font(.title.bold())
                    Text(facts?.description?.capitalizedFirst ?? subtitle(view))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

                if let url = facts?.pictureURL {
                    // A photo that doesn't load leaves no empty box behind.
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().aspectRatio(contentMode: .fill)
                                .frame(height: 180)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        case .failure:
                            EmptyView()
                        default:
                            RoundedRectangle(cornerRadius: 14).fill(Color.sheetSurface)
                                .frame(height: 180)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                StatGrid(stats: stats(peak, view, facts, units))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                Button {
                    if place == nil { model.selectedPeakID = peak.id }
                    close()
                } label: {
                    Label(place != nil ? "Show in the photo" : view?.isVisible == false ? "Show where it is" : "Find in view",
                          systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.amber)
                .foregroundStyle(.black)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .sheetSection()

            Section {
                PeakSunRow(model: model, peak: peak)
            }
            .sheetSection()

            if let summary = facts?.summary {
                Section("About") {
                    Text(summary)
                        .font(.callout)
                    if let url = facts?.articleURL {
                        Link(destination: url) {
                            Label("Read more on Wikipedia", systemImage: "book")
                        }
                    }
                }
                .sheetSection()
            }

            Section {
                hikes(peak, units)
            } header: {
                Text("Hikes nearby")
            } footer: {
                Text("Trails from OpenStreetMap within \(Format.distance(DataStore.hikeRadius, units)) of the summit. Climbs and lengths come from the terrain model; check conditions before you go.")
            }
            .sheetSection()

            Section {
                Text("Elevation from OpenStreetMap. Facts from Wikidata (CC0) and Wikipedia (CC BY-SA).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .sheetSection()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.sheetBackground)
    }

    private func subtitle(_ view: TerrainScene.PeakView?) -> String {
        guard let view else { return "Peak" }
        if view.isUncertain { return "May be in view: the terrain here is coarse" }
        return view.isVisible ? "In view from here" : "Hidden behind nearer terrain"
    }

    private func stats(_ peak: Peak, _ view: TerrainScene.PeakView?, _ facts: PeakFacts?, _ units: AppSettings.Units) -> [Stat] {
        var stats = [Stat(title: peak.estimatedElevation ? "Elevation (terrain)" : "Elevation", value: Format.elevation(of: peak, units))]
        if let prominence = peak.prominence ?? facts?.prominence {
            stats.append(Stat(title: "Prominence", value: Format.elevation(prominence, units)))
        }
        if let view {
            stats.append(Stat(title: "Distance", value: Format.distance(view.distance, units)))
            stats.append(Stat(title: "Bearing", value: Format.bearing(view.azimuth)))
        }
        if let observer = scene?.observer {
            let above = peak.elevation - observer.height
            let title = place != nil ? (above >= 0 ? "Above the photo spot" : "Below the photo spot") : (above >= 0 ? "Above you" : "Below you")
            stats.append(Stat(title: title, value: Format.elevation(abs(above), units)))
        }
        if let range = facts?.range { stats.append(Stat(title: "Range", value: range)) }
        if let year = facts?.firstAscentYear { stats.append(Stat(title: "First ascent", value: String(year))) }
        if let countries = facts?.countries, !countries.isEmpty {
            stats.append(Stat(title: countries.count > 1 ? "Countries" : "Country", value: countries.joined(separator: ", ")))
        }
        if let parent = facts?.parent { stats.append(Stat(title: "Parent peak", value: parent)) }
        return stats
    }

    @ViewBuilder private func hikes(_ peak: Peak, _ units: AppSettings.Units) -> some View {
        switch details?.hikesState ?? .loading {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Searching OpenStreetMap for hikes…").foregroundStyle(.secondary)
                    Text("Its servers can take up to a minute when they're busy.").font(.caption).foregroundStyle(.tertiary)
                }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button("Try again") {
                    details?.loadHikes(store: model.store, terrain: { [weak model, place] in place?.terrain ?? model?.scene?.terrain })
                }
            }
        case .loaded:
            if let hikes = details?.hikes, !hikes.isEmpty {
                ForEach(hikes) { hike in
                    NavigationLink(value: TrailLink(peakID: peak.id, trailID: hike.id)) {
                        HikeRow(hike: hike, units: units, from: scene?.position)
                    }
                }
            } else {
                Text("No hikes mapped within \(Format.distance(DataStore.hikeRadius, units)) of this peak.").foregroundStyle(.secondary)
            }
        }
    }
}

/// One hike in a peak's list.
struct HikeRow: View {
    let hike: PeakDetails.Hike
    let units: AppSettings.Units
    let from: LatLon?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(hike.trail.name)
                    .font(.headline)
                    .lineLimit(2)
                if hike.reachesSummit {
                    Image(systemName: "flag.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.amber)
                        .accessibilityLabel("Reaches the summit")
                }
            }
            HStack(spacing: 10) {
                if let d = hike.trail.difficulty { DifficultyBadge(difficulty: d) }
                Label(Format.distance(hike.trail.length, units), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                if let p = hike.profile {
                    Label(Format.elevation(p.gain, units), systemImage: "arrow.up.right")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())
            if let from, let start = hike.profile?.trailhead {
                Text("Start \(Format.distance(from.distance(to: start), units)) from you")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "T3" in a color from green to black, like the SAC scale's trail markings.
struct DifficultyBadge: View {
    let difficulty: Difficulty

    var body: some View {
        Text(difficulty.grade)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(difficulty.rawValue >= 5 ? Color.white : Color.black)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(difficulty.title)
    }

    private var color: Color {
        switch difficulty {
        case .hiking: return Color(red: 0.95, green: 0.85, blue: 0.3)
        case .mountainHiking, .demandingMountainHiking: return Color(red: 0.95, green: 0.4, blue: 0.35)
        case .alpineHiking: return Color(red: 0.45, green: 0.65, blue: 1.0)
        case .demandingAlpineHiking, .difficultAlpineHiking: return Color(red: 0.2, green: 0.3, blue: 0.75)
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct Stat: Identifiable {
    var title: String
    var value: String
    var id: String { title }
}

/// Numbers in tiles, two or three to a row.
struct StatGrid: View {
    let stats: [Stat]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stat.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(stat.value)
                        .font(.headline)
                        .monospacedDigit()
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.sheetSurface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

extension String {
    /// "mountain in the Alps" → "Mountain in the Alps".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

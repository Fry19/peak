import PeakCore
import SwiftUI

/// Every named peak around you, those in view first, with search.
struct PeakListView: View {
    let model: AppModel
    @State private var query = ""
    @State private var order = Order.distance

    enum Order: String, CaseIterable, Identifiable {
        case distance = "Nearest"
        case elevation = "Highest"
        var id: String { rawValue }
    }

    var body: some View {
        let units = model.settings.units
        let all = sorted(model.scene.map { Array($0.allPeaks.values) } ?? [])
        let matching = query.isEmpty ? all : all.filter { $0.peak.name.localizedCaseInsensitiveContains(query) }
        // Peaks the coarse base layer can't settle are listed with those in view.
        let visible = matching.filter { $0.isVisible || $0.isUncertain }
        let hidden = matching.filter { !$0.isVisible && !$0.isUncertain }
        return List {
            if model.scene == nil {
                Text("Peaks appear once the terrain around you has loaded.")
                    .foregroundStyle(.secondary)
            }
            if !visible.isEmpty {
                Section("In view") {
                    ForEach(visible.prefix(200), id: \.peak.id) { row($0, units) }
                }
                .sheetSection()
            }
            if !hidden.isEmpty {
                Section("Hidden behind nearer terrain") {
                    ForEach(hidden.prefix(200), id: \.peak.id) { row($0, units) }
                }
                .sheetSection()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.sheetBackground)
        .overlay {
            if model.scene != nil, !query.isEmpty, matching.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Search peaks")
        .navigationTitle("Peaks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("Order", selection: $order) {
                    ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { model.sheet = nil }
            }
        }
    }

    private func sorted(_ peaks: [TerrainScene.PeakView]) -> [TerrainScene.PeakView] {
        switch order {
        case .distance: return peaks.sorted { $0.distance < $1.distance }
        case .elevation: return peaks.sorted { $0.peak.elevation > $1.peak.elevation }
        }
    }

    private func row(_ v: TerrainScene.PeakView, _ units: AppSettings.Units) -> some View {
        NavigationLink(value: PeakLink(id: v.peak.id)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.peak.name)
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(Format.distance(v.distance, units)) · \(Format.bearing(v.azimuth))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Format.elevation(of: v.peak, units))
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

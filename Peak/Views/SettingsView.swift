import PeakCore
import PhotosUI
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmClear = false
    @State private var picked: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                // Only the picked photo is shared with Peak: no access to the library is needed.
                PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .current) {
                    Label("Label a photo", systemImage: "photo.on.rectangle.angled")
                }
            } footer: {
                Text("Pick a mountain photo with its location saved, and Peak names the peaks in it.")
            }

            Section("Display") {
                Picker("Units", selection: $model.settings.units) {
                    ForEach(AppSettings.Units.allCases) { Text($0.title).tag($0) }
                }
                Picker("Labels", selection: $model.settings.labels) {
                    ForEach(AppSettings.LabelDensity.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Ridges in front of the skyline", isOn: $model.settings.showRidges)
                Toggle("Tick when a peak crosses the middle", isOn: $model.settings.haptics)
                Toggle("Today's sun path", isOn: $model.settings.showSunPath)
            }

            Section {
                NavigationLink {
                    OfflineAreasView(model: model)
                } label: {
                    LabeledContent("Offline areas") {
                        if model.areaProgress != nil {
                            ProgressView()
                        } else {
                            Text(model.areas.isEmpty ? "None" : "\(model.areas.count)")
                        }
                    }
                }
                Toggle("Sharpest terrain on mobile data", isOn: $model.settings.detailOnMobile)
                LabeledContent("Stored on this iPhone", value: model.storageBytes.map(Format.bytes) ?? "…")
                Button("Delete downloaded data", role: .destructive) { confirmClear = true }
            } header: {
                Text("Terrain and offline use")
            } footer: {
                Text("Peak keeps the terrain, peaks and hikes it downloads, so places you've been work without a signal. Going somewhere without one? Save it in Offline areas before you go.")
            }

            Section {
                Toggle("Show diagnostics", isOn: $model.settings.showDiagnostics)
            } footer: {
                Text("Long-press the status pill to show or hide them. A screenshot of them helps when the lines don't line up.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("Terrain: Copernicus DEM GLO-30 © DLR e.V. 2010–2014 and © Airbus Defence and Space GmbH 2014–2018, provided under COPERNICUS by the European Union and ESA.")
                Text("Peaks and trails: © OpenStreetMap contributors, under the Open Database License.")
                Text("Facts: Wikidata (CC0) and Wikipedia (CC BY-SA).")
                Link("Source code", destination: URL(string: "https://github.com/Fry19/peak")!)
            }
            .font(.footnote)
        }
        .scrollContentBackground(.hidden)
        .background(.sheetBackground)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { model.sheet = nil }
            }
        }
        .onAppear { model.refreshStorage() }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            model.labelPhoto { try await item.loadTransferable(type: Data.self) }
        }
        .confirmationDialog("Delete all downloaded terrain, peaks and hikes, and your offline areas?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.clearDownloads() }
        }
    }
}

import CoreLocation
import MapKit
import PeakCore
import SwiftUI

/// Areas saved for use without a signal, and a way to save another.
struct OfflineAreasView: View {
    @Bindable var model: AppModel
    @State private var confirmDelete: OfflineArea?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SaveAreaView(model: model)
                } label: {
                    Label("Save an area", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("Pick a place on the map before you go. Peak downloads its terrain, the peaks you can see from it and their hikes, so the view, peak details and hikes all work there without a signal.")
            }

            if !model.areas.isEmpty {
                Section("Saved") {
                    ForEach(model.areas) { area in
                        AreaRow(model: model, area: area)
                            .swipeActions {
                                Button("Delete", role: .destructive) { confirmDelete = area }
                            }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Offline areas")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(confirmDelete.map { "Delete \($0.name)?" } ?? "",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let area = confirmDelete { model.deleteArea(area) }
                confirmDelete = nil
            }
        } message: {
            Text("Terrain another area uses, or that's around you now, is kept.")
        }
    }
}

private struct AreaRow: View {
    let model: AppModel
    let area: OfflineArea

    var body: some View {
        HStack(spacing: 14) {
            AreaThumbnail(area: area)
            VStack(alignment: .leading, spacing: 4) {
                Text(area.name).font(.headline).lineLimit(1)
                if let progress = model.areaProgress, progress.id == area.id {
                    ProgressView(value: progress.fraction)
                    Text("Downloading · \(progress.step)").font(.caption).foregroundStyle(.secondary)
                } else if model.isQueued(area) {
                    Text("Waiting for the download before it").font(.caption).foregroundStyle(.secondary)
                } else if area.complete {
                    Text("\(Format.distance(area.radius, model.settings.units)) around · \(Format.bytes(area.bytes))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Saved \(area.saved.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.areaFailures[area.id] ?? "Not finished downloading.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                    Button("Resume download") { model.download(area) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A small map of an area.
private struct AreaThumbnail: View {
    let area: OfflineArea

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: area.latitude, longitude: area.longitude)
        Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: area.radius * 2.4,
                                                        longitudinalMeters: area.radius * 2.4)),
            interactionModes: []) {
            MapCircle(center: center, radius: area.radius)
                .foregroundStyle(Color.accentColor.opacity(0.2))
                .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// Picks a place and radius on the map, and saves it.
struct SaveAreaView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    /// The circle's radius, meters: a round number of kilometers or miles.
    @State private var radius: Double
    /// How many points a meter is on the map now, for the scale bar.
    @State private var pointsPerMeter: Double?
    @State private var mapWidth = 0.0
    @State private var name = ""
    /// The name was typed or came from a search, so the map moving doesn't replace it.
    @State private var nameChosen = false
    @State private var query = ""
    @State private var searching = false
    @State private var results: [MKMapItem] = []
    @State private var geocoder = CLGeocoder()

    init(model: AppModel) {
        self.model = model
        let start = model.location?.coordinate ?? CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35)
        let span = model.location == nil ? 3_000_000.0 : 25_000 * 2.8
        _center = State(initialValue: start)
        _radius = State(initialValue: model.settings.units == .metric ? 25_000 : 15 * 1_609.344)
        _position = State(initialValue: .region(MKCoordinateRegion(center: start, latitudinalMeters: span, longitudinalMeters: span)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $position) {
                ForEach(model.areas) { area in
                    MapCircle(center: CLLocationCoordinate2D(latitude: area.latitude, longitude: area.longitude), radius: area.radius)
                        .foregroundStyle(.white.opacity(0.12))
                        .stroke(.white.opacity(0.6), lineWidth: 1)
                }
                MapCircle(center: center, radius: radius)
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                    .stroke(Color.accentColor, lineWidth: 2)
                UserAnnotation()
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { mapWidth = $0 }
            .onMapCameraChange(frequency: .continuous) { context in
                center = context.region.center
                // MapKit's own scale follows the phone's region; this one follows the app's units.
                let across = context.region.span.longitudeDelta * 111_320 * cos(context.region.center.latitude * .pi / 180)
                pointsPerMeter = across > 0 && mapWidth > 0 ? mapWidth / across : nil
            }
            .overlay(alignment: .topLeading) {
                if let pointsPerMeter {
                    ScaleBar(pointsPerMeter: pointsPerMeter, units: model.settings.units)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                nameFromMap(context.region.center)
            }
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .allowsHitTesting(false)
            }

            panel
        }
        .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search parks, peaks and places")
        .searchSuggestions {
            ForEach(results, id: \.self) { item in
                Button {
                    pick(item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Place").foregroundStyle(.primary)
                        if let detail = item.placemark.title, detail != item.name {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .task(id: query) { await search() }
        .navigationTitle("Save an area")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var panel: some View {
        let estimate = OfflineArea.estimatedBytes(latitude: center.latitude, longitude: center.longitude, radius: radius)
        return VStack(alignment: .leading, spacing: 14) {
            TextField("Name", text: Binding(get: { name }, set: { name = $0; nameChosen = true }))
                .font(.headline)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Radius")
                Slider(value: radiusSteps, in: model.settings.units == .metric ? 5...50 : 5...30, step: 5)
                Text(Format.distance(radius, model.settings.units))
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .trailing)
            }
            Text("About \(Format.bytes(estimate)): terrain, peaks and hikes for the circle and the mountains you can see from it. Best on Wi-Fi, with Peak open.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                save()
            } label: {
                Text("Download").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .background(.regularMaterial)
        .onChange(of: radius) {
            // Keep the whole circle in view.
            let span = radius * 2.8
            withAnimation { position = .region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)) }
        }
    }

    /// The slider's value: the radius in kilometers or miles, as the app's units say.
    private var radiusSteps: Binding<Double> {
        let unit = model.settings.units == .metric ? 1_000.0 : 1_609.344
        return Binding(get: { (radius / unit).rounded() }, set: { radius = $0 * unit })
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? String(format: "%.3f, %.3f", center.latitude, center.longitude) : trimmed
        model.saveArea(name: title, latitude: center.latitude, longitude: center.longitude, radius: radius)
        dismiss()
    }

    private func pick(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        center = coordinate
        let span = radius * 2.8
        position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span))
        name = item.name ?? name
        nameChosen = true
        query = ""
        searching = false
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            return
        }
        // Wait for a pause in typing.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        if let response = try? await MKLocalSearch(request: request).start(), !Task.isCancelled {
            results = Array(response.mapItems.prefix(8))
        }
    }

    /// Names the area after the place at the middle of the map, until a name is chosen.
    private func nameFromMap(_ coordinate: CLLocationCoordinate2D) {
        guard !nameChosen else { return }
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) { placemarks, _ in
            guard !nameChosen, let place = placemarks?.first else { return }
            if let found = place.areasOfInterest?.first ?? place.locality ?? place.subAdministrativeArea ?? place.administrativeArea {
                name = found
            }
        }
    }
}

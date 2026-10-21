import PeakCore
import SwiftUI

/// Camera first: the live picture fills the screen with the labels over it. Below it, the
/// status pill (tap to pause the view) between the peak list and settings. Tap a label for
/// the peak's card.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CameraScreen(model: model)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                if let trail = model.arTrail {
                    TrailChip(model: model, trail: trail)
                }
                if model.settings.showDiagnostics {
                    DebugPanel(model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                Spacer()
                HStack(alignment: .center, spacing: 12) {
                    RoundButton(systemImage: "list.bullet", label: "Peaks") { model.sheet = .list }
                    StatusPill(model: model)
                    RoundButton(systemImage: "gearshape", label: "Settings") { model.sheet = .settings }
                }
                Text("Terrain © Copernicus DEM (DLR, Airbus) · Map data © OpenStreetMap contributors")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
            .padding(.horizontal, 12)
        }
        .background(Color.black)
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            // Permission prompts make the app briefly inactive; only the background stops it.
            if phase == .active { model.setActive(true) } else if phase == .background { model.setActive(false) }
        }
        .onChange(of: model.settings) { _, settings in settings.save() }
        .sheet(item: $model.sheet) { sheet in
            SheetContent(model: model, sheet: sheet)
        }
    }
}

/// What a sheet shows, with its own navigation.
private struct SheetContent: View {
    let model: AppModel
    let sheet: AppModel.Sheet

    var body: some View {
        switch sheet {
        case let .peak(id):
            NavigationStack {
                PeakDetailView(model: model, peakID: id)
                    .navigationDestination(for: TrailLink.self) { TrailDetailView(model: model, link: $0) }
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationBackground(.regularMaterial)
        case .list:
            NavigationStack {
                PeakListView(model: model)
                    .navigationDestination(for: PeakLink.self) { PeakDetailView(model: model, peakID: $0.id) }
                    .navigationDestination(for: TrailLink.self) { TrailDetailView(model: model, link: $0) }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.regularMaterial)
        case .settings:
            NavigationStack {
                SettingsView(model: model)
            }
            .presentationBackground(.regularMaterial)
        }
    }
}

struct PeakLink: Hashable {
    var id: Int64
}

struct TrailLink: Hashable {
    var peakID: Int64
    var trailID: String
}

/// A round glass button for the bottom bar.
struct RoundButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .accessibilityLabel(label)
    }
}

/// The trail drawn on the mountain: tap for its card, × to clear it.
private struct TrailChip: View {
    let model: AppModel
    let trail: AppModel.ARTrail

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.hiking")
                .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.28))
            VStack(alignment: .leading, spacing: 1) {
                Text(trail.trail.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(trail.runs == nil ? "Laying it on the terrain…" : trail.runs!.isEmpty ? "Not in sight from here" : "Drawn where it's in sight")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 4)
            Button {
                model.clearTrail()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("Stop showing the trail")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .contentShape(Capsule())
        .onTapGesture { model.select(trail.peakID) }
    }
}

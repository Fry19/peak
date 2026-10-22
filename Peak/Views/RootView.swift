import PeakCore
import SwiftUI

/// Camera first: the live picture fills the screen with the labels over it. Below it, the
/// status pill (tap to pause the view) between the peak list and settings. Tap a label for
/// the peak's card.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// Where the chips at the top and the controls at the bottom are, for labels to keep clear of.
    @State private var topControls = CGRect.zero
    @State private var bottomControls = CGRect.zero

    var body: some View {
        ZStack {
            CameraScreen(model: model, keepClear: [topControls, bottomControls])
                .ignoresSafeArea()
            VStack(spacing: 10) {
                VStack(spacing: 10) {
                    if model.aligning {
                        AlignBanner(model: model)
                    } else if let trail = model.arTrail {
                        TrailChip(model: model, trail: trail)
                    }
                    if model.zoom > 1.05 {
                        Button {
                            model.setZoom(1)
                        } label: {
                            Text(Format.zoom(model.zoom))
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .environment(\.colorScheme, .dark)
                                .tapArea(minWidth: 64, minHeight: 44)
                        }
                        .accessibilityLabel("Zoomed \(Format.decimal(model.zoom)) times; tap to zoom out")
                    }
                    if model.settings.showDiagnostics {
                        DebugPanel(model: model)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { topControls = $0 }
                Spacer()
                VStack(spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        if showsBarButtons {
                            RoundButton(systemImage: "list.bullet", label: "Peaks") { model.sheet = .list }
                        }
                        StatusPill(model: model)
                        if model.frozen?.pixels != nil, !model.aligning {
                            // Paused: save or share the view, labeled.
                            RoundButton(systemImage: "square.and.arrow.up", label: "Save or share this view") {
                                model.capturePausedView()
                            }
                            RoundButton(systemImage: "gearshape", label: "Settings") { model.sheet = .settings }
                        } else if showsBarButtons {
                            RoundButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right", label: "Line up by hand") {
                                model.startAligning()
                            }
                            RoundButton(systemImage: "gearshape", label: "Settings") { model.sheet = .settings }
                        }
                    }
                    Text("Terrain © Copernicus DEM (DLR, Airbus) · Map data © OpenStreetMap contributors")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bottomControls = $0 }
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
            .padding(.horizontal, 12)
        }
        .overlay {
            if model.showsFromAbove, let trail = model.arTrail {
                TrailFromAboveView(model: model, trail: trail)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showsFromAbove)
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
        .fullScreenCover(item: $model.photo) { photo in
            PhotoView(model: model, photo: photo)
        }
    }

    /// The peak list, lining up and settings sit beside the pill once the view is working;
    /// while something's wrong, the pill's message gets the whole width.
    private var showsBarButtons: Bool {
        guard !model.aligning else { return false }
        if model.frozen != nil { return true }
        if case .ready = model.status { return true }
        return false
    }
}

extension View {
    /// Grows where a tap lands to at least the given size, centered, without changing the
    /// layout or the look.
    func tapArea(minWidth: CGFloat = 44, minHeight: CGFloat = 44) -> some View {
        modifier(TapArea(minWidth: minWidth, minHeight: minHeight))
    }
}

private struct TapArea: ViewModifier {
    let minWidth: CGFloat
    let minHeight: CGFloat
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        let dx = max(0, (minWidth - size.width) / 2), dy = max(0, (minHeight - size.height) / 2)
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .padding(.horizontal, dx)
            .padding(.vertical, dy)
            .contentShape(Rectangle())
            .padding(.horizontal, -dx)
            .padding(.vertical, -dy)
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
            // Tapping another label swaps the card's content in place; the sheet stays up.
            .id(id)
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

/// Instructions and buttons while lining the view up by hand.
private struct AlignBanner: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Text("Drag the lines onto the mountains. Turn with two fingers to level them.")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Reset") { model.resetAlignment() }
                    .buttonStyle(.bordered)
                Button("Done") { model.finishAligning() }
                    .buttonStyle(.borderedProminent)
            }
            .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}

/// The trail drawn on the mountain: tap for its card, the cube to see it through the
/// ridges in front of it, the map to see it from above, × to clear it.
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
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                model.settings.trailXRay.toggle()
            } label: {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(xRay ? .black : .white)
                    .frame(width: 28, height: 28)
                    .background(xRay ? AnyShapeStyle(Color(red: 1, green: 0.72, blue: 0.28)) : AnyShapeStyle(.white.opacity(0.15)),
                                in: Circle())
                    .tapArea()
            }
            .accessibilityLabel("See through the ridges")
            .accessibilityValue(xRay ? "On" : "Off")
            Button {
                model.showsFromAbove = true
            } label: {
                Image(systemName: "map")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
                    .tapArea()
            }
            .accessibilityLabel("See the trail from above")
            Button {
                model.clearTrail()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
                    .tapArea()
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

    private var xRay: Bool { model.settings.trailXRay }

    private var status: String {
        guard trail.runs != nil else { return "Laying it on the terrain…" }
        switch (trail.someInSight, trail.someHidden) {
        case (true, true): return xRay ? "Dashed where ridges hide it" : "Drawn where it's in sight"
        case (true, false): return "All of it in sight"
        case (false, true): return xRay ? "Behind the ridges, seen through them" : "Hidden behind the ridges"
        case (false, false): return "Not in sight from here"
        }
    }
}

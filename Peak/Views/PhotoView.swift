import PeakCore
import SwiftUI

/// A labeled still picture, full screen: the paused view or a photo from the library, with
/// the lines and labels drawn as they'll be saved. Labels or lines only, line it up by hand,
/// save it or share it; tap a label for the peak's card.
struct PhotoView: View {
    let model: AppModel
    @Bindable var photo: LabeledPhoto
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var card: PeakLink?
    @State private var lastDrag = CGSize.zero
    @State private var lastTwist = Angle.zero
    @State private var saving = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = photo.image {
                picture(image)
                    .ignoresSafeArea()
                    .opacity(isLoading ? 0.45 : 1)
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if let toast {
                Text(toast)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.2), value: toast)
        .animation(.easeInOut(duration: 0.2), value: photo.adjusting)
        .sheet(item: $card, onDismiss: { photo.selectedID = nil }) { link in
            NavigationStack {
                PeakDetailView(model: model, peakID: link.id, place: photo.scene)
                    .navigationDestination(for: TrailLink.self) { TrailDetailView(model: model, link: $0, place: photo.scene) }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.regularMaterial)
        }
    }

    private var isLoading: Bool {
        if case .loading = photo.stage { return true }
        return false
    }

    private func overlay(selected: Bool = true) -> PhotoOverlay? {
        photo.overlay(units: model.settings.units, ridges: model.settings.showRidges, maxLabels: model.settings.labels.maxLabels,
                      selected: selected)
    }

    // MARK: The picture

    private func picture(_ image: CGImage) -> some View {
        GeometryReader { geo in
            let size = CGSize(width: image.width, height: image.height)
            let scale = min(geo.size.width / size.width, geo.size.height / size.height)
            let shown = CGSize(width: size.width * scale, height: size.height * scale)
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: shown.width, height: shown.height)
                if photo.stage == .ready, let base = overlay() {
                    let labels = base.labels()
                    let overlay = { var o = base; o.deviceScale = scale * displayScale; return o }()
                    Canvas { context, _ in
                        context.withCGContext { cg in
                            cg.scaleBy(x: scale, y: scale)
                            overlay.draw(in: cg, labels: labels)
                        }
                    }
                    .frame(width: shown.width, height: shown.height)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: shown.width, height: shown.height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tapped($0.location, scale: scale) })
            .simultaneousGesture(drag(scale: scale))
            .simultaneousGesture(twist)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    /// A label under the finger opens its peak's card.
    private func tapped(_ location: CGPoint, scale: Double) {
        guard !photo.adjusting, let overlay = overlay() else { return }
        let p = CGPoint(x: location.x / scale, y: location.y / scale)
        let reach = 12 * overlay.unit
        guard let hit = overlay.labels().first(where: { $0.hitRect.insetBy(dx: -reach, dy: -reach).contains(p) }) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        photo.selectedID = hit.id
        card = PeakLink(id: hit.id)
    }

    /// While lining up: the lines follow the finger.
    private func drag(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard photo.adjusting else { return }
                let d = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                photo.adjust(dx: d.width / scale, dy: d.height / scale, twist: 0)
            }
            .onEnded { _ in lastDrag = .zero }
    }

    private var twist: some Gesture {
        RotateGesture()
            .onChanged { value in
                guard photo.adjusting else { return }
                let d = value.rotation - lastTwist
                lastTwist = value.rotation
                photo.adjust(dx: 0, dy: 0, twist: d.radians)
            }
            .onEnded { _ in lastTwist = .zero }
    }

    // MARK: Controls

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundButton(systemImage: "xmark", label: "Close") { dismiss() }
            Spacer(minLength: 0)
            if let status {
                HStack(spacing: 8) { status }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var status: AnyView? {
        switch photo.stage {
        case let .loading(text):
            return AnyView(Group {
                ProgressView().controlSize(.small).tint(.white)
                Text(text)
            })
        case .failed:
            return nil
        case .ready:
            if photo.snapping {
                return AnyView(Group {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Matching the skyline…")
                })
            }
            let dot: Color, text: String
            switch photo.fit {
            case .live: return nil
            case .matched: (dot, text) = (.green, "Matched to the skyline")
            case .linedUp: (dot, text) = (.cyan, "Lined up by hand")
            case .byHand: (dot, text) = (.orange, "Line it up by hand")
            }
            return AnyView(Group {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(text)
            })
        }
    }

    @ViewBuilder private var bottomBar: some View {
        switch photo.stage {
        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "mountain.2").font(.system(size: 28))
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.center)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .environment(\.colorScheme, .dark)
            Spacer()
        case .loading:
            EmptyView()
        case .ready:
            if photo.adjusting {
                adjustBanner
            } else {
                actions
            }
        }
    }

    private var adjustBanner: some View {
        VStack(spacing: 10) {
            if case let .byHand(why) = photo.fit {
                Text(why)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Text("Drag the lines onto the mountains. Turn with two fingers to level them.")
                .font(.system(size: 14, weight: .medium))
            HStack(spacing: 12) {
                Button("Cancel") { photo.cancelAdjusting() }
                    .buttonStyle(.bordered)
                Button("Done") { photo.finishAdjusting() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
            }
            .tint(.white)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let note = photo.note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            Picker("Style", selection: $photo.variant) {
                ForEach(PhotoOverlay.Variant.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .environment(\.colorScheme, .dark)
            HStack(spacing: 14) {
                RoundButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right", label: "Line up by hand") {
                    photo.startAdjusting()
                }
                Button {
                    save()
                } label: {
                    Group {
                        if saving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 17, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
                }
                .disabled(saving)
                .accessibilityLabel("Save to Photos")
                if let overlay = overlay(selected: false), let image = photo.image {
                    ShareLink(item: SharedPhoto(photo: photo, overlay: overlay),
                              preview: SharePreview(shareTitle, image: Image(decorative: image, scale: 1))) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .accessibilityLabel("Share")
                }
            }
        }
    }

    /// The most prominent peak labeled, to name what's shared.
    private var shareTitle: String {
        guard let overlay = overlay(selected: false), let first = overlay.labels().first,
              let peak = photo.scene?.allPeaks[first.id]?.peak else { return "Mountains" }
        return peak.name
    }

    private func save() {
        guard let overlay = overlay(selected: false) else { return }
        saving = true
        Task { @MainActor in
            do {
                try await photo.save(overlay)
                show("Saved to Photos")
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? "Couldn't save the picture.")
            }
            saving = false
        }
    }

    private func show(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if toast == message { toast = nil }
        }
    }
}

extension PeakLink: Identifiable {}

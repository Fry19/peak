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
    /// A label being dragged onto its summit, and where the summit is from the finger, in
    /// the picture's pixels; `dragging` once a drag has begun.
    @State private var pinDrag: (id: Int64, offset: CGVector)?
    @State private var dragging = false
    @State private var lastDragEnd = Date.distantPast
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
                    .glassBackground(in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.2), value: toast)
        .animation(.easeInOut(duration: 0.2), value: photo.adjusting)
        .sheet(item: $card, onDismiss: { photo.selectedID = nil }) { link in
            NavigationStack {
                // Opened only from a tap on the peak's label in the photo.
                PeakDetailView(model: model, peakID: link.id, place: photo.scene, fromLabel: true)
                    .navigationDestination(for: TrailLink.self) { TrailDetailView(model: model, link: $0, place: photo.scene) }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.sheetBackground)
            .tint(.amber)
        }
    }

    private var isLoading: Bool {
        if case .loading = photo.stage { return true }
        return false
    }

    private func overlay(selected: Bool = true) -> PhotoOverlay? {
        var o = photo.overlay(units: model.settings.units, ridges: model.settings.showRidges,
                              maxLabels: model.settings.labels.maxLabels, selected: selected)
        if selected { o?.pinned = Set(photo.pins.pins.map(\.id)) }
        return o
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
                        drawPins(in: context, scale: scale)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(photo.adjusting ? "Picture being lined up" : "Picture")
            .accessibilityActions {
                if photo.adjusting {
                    Button("Name the peak in the middle") {
                        photo.pickSummit(at: CGPoint(x: size.width / 2, y: size.height / 2))
                    }
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    /// Pinned summits as amber rings, and a dashed one on a spot waiting to be named, in
    /// points over the picture shown `scale` times its pixels.
    private func drawPins(in context: GraphicsContext, scale: Double) {
        guard photo.adjusting, let k = photo.camera?.intrinsics else { return }
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.7), radius: 2))
        for pin in photo.pins.pins {
            let p = pin.pixel(k)
            let c = CGPoint(x: p.x * scale, y: p.y * scale)
            shadowed.stroke(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(.amber),
                            lineWidth: 2)
            shadowed.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(.amber))
        }
        if let pick = photo.summitPick?.point {
            let c = CGPoint(x: pick.x * scale, y: pick.y * scale)
            shadowed.stroke(Path(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)), with: .color(.white),
                            style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
    }

    /// The label within reach of `p` (the picture's pixels).
    private func label(at p: CGPoint) -> PhotoOverlay.Placed? {
        guard let overlay = overlay() else { return nil }
        let reach = 12 * overlay.unit
        return overlay.labels().first { $0.hitRect.insetBy(dx: -reach, dy: -reach).contains(p) }
    }

    /// A label under the finger opens its peak's card; lining up, a tap marks a summit to name.
    private func tapped(_ location: CGPoint, scale: Double) {
        // The end of a drag isn't a tap.
        guard !dragging, Date().timeIntervalSince(lastDragEnd) > 0.3 else { return }
        let p = CGPoint(x: location.x / scale, y: location.y / scale)
        if photo.adjusting {
            photo.pickSummit(at: p)
            return
        }
        guard let hit = label(at: p) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        photo.selectedID = hit.id
        card = PeakLink(id: hit.id)
    }

    /// A drag that starts on a label puts that summit where it's dropped (and starts lining
    /// up); otherwise, while lining up, the lines follow the finger.
    private func drag(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                    pinDrag = photo.stage == .ready ? label(at: start).map {
                        ($0.id, CGVector(dx: $0.point.x - start.x, dy: $0.point.y - start.y))
                    } : nil
                }
                if let pinDrag {
                    photo.pin(pinDrag.id, at: CGPoint(x: value.location.x / scale + pinDrag.offset.dx,
                                                      y: value.location.y / scale + pinDrag.offset.dy))
                    return
                }
                // Pinned summits hold the lines; a drag that misses a label mustn't undo them.
                guard photo.adjusting, photo.pins.isEmpty else { return }
                let d = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                photo.adjust(dx: d.width / scale, dy: d.height / scale, twist: 0)
            }
            .onEnded { _ in
                lastDrag = .zero
                dragging = false
                lastDragEnd = Date()
                pinDrag = nil
            }
    }

    private var twist: some Gesture {
        RotateGesture()
            .onChanged { value in
                guard photo.adjusting, pinDrag == nil, photo.pins.isEmpty else { return }
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
                    .glassBackground(in: Capsule())
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
            if photo.adjusting {
                return AnyView(Group {
                    Circle().fill(Color.cyan).frame(width: 7, height: 7)
                    Text("Lining up by hand")
                })
            }
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
            .glassBackground(in: RoundedRectangle(cornerRadius: 20))
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
            SummitPinsBanner(pins: photo.pins.pins, misfit: photo.pinsMisfit, tilt: photo.pinsTilt) { photo.unpin($0) }
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
        .glassBackground(in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
        .sheet(item: $photo.summitPick) { pick in
            SummitPicker(pick: pick, units: model.settings.units) { photo.pin($0.id, at: pick.point) }
                .presentationDetents([.medium, .large])
                .presentationBackground(.sheetBackground)
                .tint(.amber)
        }
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
                    .glassBackground(in: Circle())
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
                            .glassBackground(in: Circle())
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

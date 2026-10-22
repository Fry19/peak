import PeakCore
import SwiftUI

/// The row on a peak's card that opens the map of where the summit can be seen from.
struct ViewshedRow: View {
    let model: AppModel
    let peak: Peak
    /// The scene the card belongs to: the live view's or a photo's.
    let scene: TerrainScene?
    /// The scene is a photo's, so its position is the photo spot, not you.
    let isPhoto: Bool
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "eye")
                    .foregroundStyle(.amber)
                    .accessibilityHidden(true)
                Text("Where you can see it from")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .fullScreenCover(isPresented: $showing) {
            ViewshedView(peak: peak, terrain: scene?.terrain, you: scene?.position,
                         youLabel: isPhoto ? "Photo spot" : "You", units: model.settings.units)
        }
    }
}

/// Everywhere a person standing on the ground can see a summit from, over the dark relief
/// map: those places tinted softly, terrain that isn't loaded greyed, the summit and you.
/// Tap a spot for how far the summit is and how high it stands from there. Drawn from the
/// terrain on the phone, so it works without a signal.
struct ViewshedView: View {
    let peak: Peak
    let terrain: Terrain?
    let you: LatLon?
    let youLabel: String
    let units: AppSettings.Units

    @Environment(\.dismiss) private var dismiss
    @State private var map: ViewshedMap?
    @State private var building = true
    @State private var camera = MapCamera()
    @State private var lastTranslation = CGSize.zero
    @State private var lastMagnification = 1.0
    @State private var probe: Probe?

    static let tint = Color(red: 1, green: 0.78, blue: 0.42)
    static let unknownColor = Color(white: 0.55)

    /// A tapped spot and how the summit looks from there (nil: no terrain there).
    struct Probe: Equatable {
        var at: SIMD2<Double>
        var sight: Viewshed.Sight?

        static func == (a: Probe, b: Probe) -> Bool { a.at == b.at && a.sight?.distance == b.sight?.distance }
    }

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            let content = EdgeInsets(top: safe.top + 76, leading: 12, bottom: safe.bottom + 92, trailing: 12)
            ZStack {
                Color.sheetBackground
                    .ignoresSafeArea()
                if let map {
                    GeometryReader { screen in
                        let viewport = ViewshedViewport(size: screen.size, span: map.span, content: content)
                        ViewshedLayer(map: map, viewport: viewport, camera: camera, peak: peak, youLabel: youLabel,
                                      units: units, probe: probe)
                            .contentShape(Rectangle())
                            .gesture(pan(viewport).simultaneously(with: pinch(viewport)))
                            .onTapGesture { location in tap(location, viewport, in: map) }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                } else if !building {
                    ContentUnavailableView("No terrain around this summit yet", systemImage: "mountain.2",
                                           description: Text("The map is drawn from the terrain loaded on the phone. Open the camera near \(peak.name), or save an offline area around it."))
                        .environment(\.colorScheme, .dark)
                }
                VStack(spacing: 0) {
                    chip
                        .padding(.top, 8)
                        .padding(.horizontal, 12)
                    Spacer()
                    if let probe, let map {
                        ProbeCard(probe: probe, map: map, peak: peak, units: units)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let map {
                        bottomBar(map, ViewshedViewport(size: CGSize(width: geo.size.width + safe.leading + safe.trailing,
                                                                     height: geo.size.height + safe.top + safe.bottom),
                                                        span: map.span, content: content))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: probe)
            }
        }
        .preferredColorScheme(.dark)
        .task { await build() }
    }

    private var chip: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye")
                .foregroundStyle(Self.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Where you can see \(peak.name) from")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
                    .tapArea()
            }
            .accessibilityLabel("Close")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .glassBackground(in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private var subtitle: String {
        guard let map else { return building ? "Tracing lines of sight…" : "No terrain loaded" }
        let area = map.viewshed.visibleArea
        let size = units == .metric ? Format.decimal(area / 1e6 >= 100 ? (area / 1e6).rounded() : area / 1e6) + " km²"
                                    : Format.decimal(area / 2_589_988 >= 100 ? (area / 2_589_988).rounded() : area / 2_589_988) + " sq mi"
        return "Seen from \(size) within \(Format.distance(map.viewshed.radius, units)) · tap a spot"
    }

    private func bottomBar(_ map: ViewshedMap, _ viewport: ViewshedViewport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                ScaleBar(pointsPerMeter: viewport.pointsPerMeter(camera), units: units)
                Spacer(minLength: 4)
                if camera != MapCamera() {
                    RoundButton(systemImage: "scope", label: "Back to the whole area") {
                        withAnimation(.easeInOut(duration: 0.35)) { camera = MapCamera() }
                    }
                    .transition(.opacity)
                }
                Text("N")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .glassBackground(in: Circle())
                    .environment(\.colorScheme, .dark)
                    .accessibilityLabel("North is up")
            }
            .animation(.easeInOut(duration: 0.2), value: camera == MapCamera())
            HStack(spacing: 14) {
                LegendSwatch(color: Self.tint.opacity(0.75), label: "Summit in sight")
                if map.viewshed.knownShare < 0.995 {
                    LegendSwatch(color: Self.unknownColor.opacity(0.6), label: "No terrain loaded")
                }
            }
            Text("For someone standing on open ground. Trees and buildings aren't in the terrain. Terrain © Copernicus DEM (DLR, Airbus) · Map data © OpenStreetMap contributors")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func pan(_ viewport: ViewshedViewport) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let step = CGSize(width: value.translation.width - lastTranslation.width,
                                  height: value.translation.height - lastTranslation.height)
                lastTranslation = value.translation
                camera = viewport.panned(camera, by: step)
            }
            .onEnded { _ in lastTranslation = .zero }
    }

    private func pinch(_ viewport: ViewshedViewport) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let step = value.magnification / lastMagnification
                lastMagnification = value.magnification
                camera = viewport.zoomed(camera, by: step, around: value.startLocation)
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    /// Tapping the spot already shown hides its card.
    private func tap(_ location: CGPoint, _ viewport: ViewshedViewport, in map: ViewshedMap) {
        if let shown = probe {
            let p = viewport.screen(shown.at, camera)
            if hypot(p.x - location.x, p.y - location.y) < 22 {
                probe = nil
                return
            }
        }
        let point = viewport.mapPoint(location, camera)
        let viewshed = map.viewshed, terrain = map.terrain
        let place = viewshed.projection.latLon(point)
        Task {
            let sight = await Task.detached(priority: .userInitiated) { viewshed.sight(from: place, terrain: terrain) }.value
            probe = Probe(at: point, sight: sight)
        }
    }

    private func build() async {
        guard let terrain else {
            building = false
            return
        }
        let peak = self.peak, you = self.you
        let built = await Task.detached(priority: .utility) {
            ViewshedMap.build(peak: peak, terrain: terrain, you: you)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            map = built
            building = false
        }
    }
}

/// A small colored square and what it means.
private struct LegendSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// What a tapped spot sees: whether the summit is in sight, how far and how high.
private struct ProbeCard: View {
    let probe: ViewshedView.Probe
    let map: ViewshedMap
    let peak: Peak
    let units: AppSettings.Units

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .glassBackground(in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private var cell: Viewshed.Cell { probe.sight?.cell ?? .unknown }

    private var title: String {
        switch cell {
        case .visible: return "\(peak.name) is in sight from here"
        case .hidden: return "Hidden behind nearer terrain"
        case .unknown: return "No terrain loaded here"
        case .outside: return "Beyond \(Format.distance(map.viewshed.radius, units))"
        }
    }

    private var detail: String? {
        guard let sight = probe.sight else { return nil }
        let angle = Format.decimal(abs(sight.elevation)) + "°"
        let height = sight.elevation >= 0 ? "\(angle) above the horizon" : "\(angle) below the horizon"
        let where_ = cell == .visible ? "appears \(height)" : "would be \(height)"
        return "\(Format.distance(sight.distance, units)) to the summit · \(where_), look \(Format.bearing(sight.azimuth))"
    }

    private var icon: String {
        switch cell {
        case .visible: return "eye"
        case .hidden: return "eye.slash"
        case .unknown, .outside: return "questionmark.circle"
        }
    }

    private var color: Color {
        cell == .visible ? ViewshedView.tint : .white.opacity(0.6)
    }
}

/// How map meters land on the screen: the whole circle fits inside the content area (the
/// screen less the chip and the bottom bar), north up.
struct ViewshedViewport {
    let size: CGSize
    /// Width and height of the area to fit, meters.
    let span: Double
    let content: EdgeInsets

    private var area: CGRect {
        CGRect(x: content.leading, y: content.top,
               width: max(1, size.width - content.leading - content.trailing),
               height: max(1, size.height - content.top - content.bottom))
    }

    func pointsPerMeter(_ camera: MapCamera) -> Double { min(area.width, area.height) / span * camera.zoom }

    func screen(_ p: SIMD2<Double>, _ camera: MapCamera) -> CGPoint {
        let k = pointsPerMeter(camera)
        return CGPoint(x: area.midX + (p.x - camera.center.x) * k, y: area.midY - (p.y - camera.center.y) * k)
    }

    func mapPoint(_ s: CGPoint, _ camera: MapCamera) -> SIMD2<Double> {
        let k = pointsPerMeter(camera)
        return SIMD2(camera.center.x + (s.x - area.midX) / k, camera.center.y - (s.y - area.midY) / k)
    }

    func transform(_ camera: MapCamera) -> CGAffineTransform {
        let k = pointsPerMeter(camera)
        return CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: area.midX - camera.center.x * k, ty: area.midY + camera.center.y * k)
    }

    func panned(_ camera: MapCamera, by step: CGSize) -> MapCamera {
        var c = camera
        let k = pointsPerMeter(camera)
        c.center.x -= step.width / k
        c.center.y += step.height / k
        return clamped(c)
    }

    /// Zoomed by `factor`, keeping the map point under `anchor` where it is on screen.
    func zoomed(_ camera: MapCamera, by factor: Double, around anchor: CGPoint) -> MapCamera {
        let fixed = mapPoint(anchor, camera)
        var c = camera
        // Closer than the trail map: a 150 m cell is still a few points across at the limit.
        c.zoom = min(16, max(MapCamera.zoomRange.lowerBound, camera.zoom * factor))
        let k = pointsPerMeter(c)
        c.center = SIMD2(fixed.x - (anchor.x - area.midX) / k, fixed.y + (anchor.y - area.midY) / k)
        return clamped(c)
    }

    private func clamped(_ camera: MapCamera) -> MapCamera {
        var c = camera
        let half = span / 2
        c.center = pointwiseMax(SIMD2(-half, -half), pointwiseMin(SIMD2(half, half), c.center))
        return c
    }
}

/// Everything drawn, built once off the main thread. Positions are map meters east and
/// north of the summit.
struct ViewshedMap: @unchecked Sendable {
    let viewshed: Viewshed
    let terrain: Terrain
    let shade: CGImage
    let shadeRect: CGRect
    /// Visible ground tinted, unknown ground greyed, the world past the radius dimmed.
    let overlay: CGImage
    let overlayRect: CGRect
    let you: SIMD2<Double>?
    /// Size of the area to fit on screen at first, meters.
    var span: Double { 2 * viewshed.radius * 1.04 }

    static func build(peak: Peak, terrain: Terrain, you: LatLon?) -> ViewshedMap? {
        guard terrain.height(latitude: peak.latitude, longitude: peak.longitude).isFinite else { return nil }
        let viewshed = Viewshed.compute(terrain: terrain, summit: peak.point)
        guard viewshed.radius > 1_000 else { return nil }
        let half = Double(viewshed.cols / 2) * viewshed.cellSize
        // The relief a little sharper than the viewshed, at most 1,600 points across.
        let cell = max(60, 2 * half / 1_600)
        let relief = ReliefMap(terrain: terrain, extent: MapExtent(center: peak.position, width: 2 * half, height: 2 * half), cellSize: cell)
        guard let shade = shadeImage(relief), let overlay = overlayImage(viewshed) else { return nil }
        let size = relief.size
        let edge = half + viewshed.cellSize / 2
        return ViewshedMap(viewshed: viewshed, terrain: terrain, shade: shade,
                           shadeRect: CGRect(x: -size.x / 2 - cell / 2, y: -size.y / 2 - cell / 2,
                                             width: size.x + cell, height: size.y + cell),
                           overlay: overlay, overlayRect: CGRect(x: -edge, y: -edge, width: 2 * edge, height: 2 * edge),
                           you: you.map { viewshed.projection.point($0) })
    }

    /// The hillshade in the trail map's colors: dark, faintly blue, high ground a touch lighter.
    private static func shadeImage(_ relief: ReliefMap) -> CGImage? {
        let shade = relief.hillshade(exaggeration: 1.3)
        let known = relief.heights.filter(\.isFinite)
        guard let low = known.min(), let high = known.max() else { return nil }
        let range = max(1, high - low)
        var pixels = [UInt8](repeating: 0, count: relief.rows * relief.cols * 4)
        for i in 0..<(relief.rows * relief.cols) where shade[i].isFinite {
            let s = shade[i], e = (relief.heights[i] - low) / range
            let light = 0.03 + 0.21 * s * s + 0.05 * e
            pixels[4 * i] = UInt8(min(255, 255 * light * 0.84))
            pixels[4 * i + 1] = UInt8(min(255, 255 * light * 0.93))
            pixels[4 * i + 2] = UInt8(min(255, 255 * light * 1.08))
            pixels[4 * i + 3] = 255
        }
        return image(pixels, width: relief.cols, height: relief.rows)
    }

    private static func overlayImage(_ v: Viewshed) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: v.rows * v.cols * 4)
        // Premultiplied RGBA for each kind of cell.
        func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> (UInt8, UInt8, UInt8, UInt8) {
            (UInt8(255 * r * a), UInt8(255 * g * a), UInt8(255 * b * a), UInt8(255 * a))
        }
        let visible = color(1, 0.78, 0.42, 0.42)
        let unknown = color(0.55, 0.57, 0.6, 0.35)
        let outside = color(0, 0, 0, 0.55)
        for i in 0..<(v.rows * v.cols) {
            let c: (UInt8, UInt8, UInt8, UInt8)
            switch v.cells[i] {
            case .visible: c = visible
            case .unknown: c = unknown
            case .outside: c = outside
            case .hidden: continue
            }
            pixels[4 * i] = c.0
            pixels[4 * i + 1] = c.1
            pixels[4 * i + 2] = c.2
            pixels[4 * i + 3] = c.3
        }
        return image(pixels, width: v.cols, height: v.rows)
    }

    private static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The map for one camera. Animatable, so recentering glides.
private struct ViewshedLayer: View, Animatable {
    let map: ViewshedMap
    let viewport: ViewshedViewport
    var camera: MapCamera
    let peak: Peak
    let youLabel: String
    let units: AppSettings.Units
    let probe: ViewshedView.Probe?

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(camera.center.x, camera.center.y), log(camera.zoom)) }
        set {
            camera.center = SIMD2(newValue.first.first, newValue.first.second)
            camera.zoom = exp(newValue.second)
        }
    }

    var body: some View {
        let t = viewport.transform(camera)
        let shadeRect = map.shadeRect.applying(t), overlayRect = map.overlayRect.applying(t)
        ZStack {
            Image(decorative: map.shade, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: shadeRect.width, height: shadeRect.height)
                .position(x: shadeRect.midX, y: shadeRect.midY)
            Image(decorative: map.overlay, scale: 1)
                .resizable()
                .interpolation(.medium)
                .frame(width: overlayRect.width, height: overlayRect.height)
                .position(x: overlayRect.midX, y: overlayRect.midY)
            Canvas { context, _ in
                let r = map.viewshed.radius
                let ring = Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).applying(t)
                context.stroke(ring, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
                if let probe {
                    let p = viewport.screen(probe.at, camera), s = viewport.screen(.zero, camera)
                    var line = Path()
                    line.move(to: p)
                    line.addLine(to: s)
                    let seen = probe.sight?.cell == .visible
                    context.stroke(line, with: .color((seen ? ViewshedView.tint : .white).opacity(seen ? 0.7 : 0.3)),
                                   style: StrokeStyle(lineWidth: 1, dash: seen ? [] : [2, 3]))
                    let dot = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                    context.fill(dot, with: .color(Color.sheetBackground))
                    context.stroke(dot, with: .color(seen ? ViewshedView.tint : .white.opacity(0.8)), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
            radiusLabel
            summit
            if let you = map.you {
                let p = viewport.screen(you, camera)
                if viewport.size.width > 0, CGRect(origin: .zero, size: viewport.size).insetBy(dx: 8, dy: 8).contains(p) {
                    ZStack {
                        Circle().fill(Color(red: 0.35, green: 0.65, blue: 1).opacity(0.22)).frame(width: 26, height: 26)
                        Circle().fill(.white).frame(width: 13, height: 13)
                        Circle().fill(Color(red: 0.25, green: 0.58, blue: 1)).frame(width: 9, height: 9)
                    }
                    .position(p)
                    .allowsHitTesting(false)
                    .accessibilityLabel(youLabel == "You" ? "You are here" : youLabel)
                }
            }
        }
    }

    /// The radius, written on the ring at its top.
    private var radiusLabel: some View {
        let top = viewport.screen(SIMD2(0, map.viewshed.radius), camera)
        return Text(Format.distance(map.viewshed.radius, units))
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.sheetBackground.opacity(0.8), in: Capsule())
            .position(top)
            .allowsHitTesting(false)
    }

    private var summit: some View {
        let p = viewport.screen(.zero, camera)
        let leftward = p.x > viewport.size.width * 0.6
        return Circle()
            .fill(.white)
            .frame(width: 7, height: 7)
            .shadow(color: .white.opacity(0.6), radius: 4)
            .overlay(alignment: leftward ? .trailing : .leading) {
                VStack(alignment: leftward ? .trailing : .leading, spacing: 0) {
                    Text(peak.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(Format.elevation(of: peak, units))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
                .fixedSize()
                .offset(x: leftward ? -12 : 12)
            }
            .position(p)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(peak.name), \(Format.elevation(of: peak, units))")
    }
}

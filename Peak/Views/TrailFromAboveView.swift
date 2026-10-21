import PeakCore
import SwiftUI

/// The trail seen from straight above, north up, over the terrain's ridgelines: a dark
/// hillshade, the crests glowing faintly (main ridges brightest), the trail in orange, the
/// summit and you. Drawn from the terrain already on the phone, so it works without a
/// signal. Pinch and drag to look around; double-tap to zoom in.
struct TrailFromAboveView: View {
    let model: AppModel
    let trail: AppModel.ARTrail

    @State private var map: OverheadMap?
    /// The trail the map was built for: a new trail starts from the whole trail again, while
    /// sharper terrain for the same one keeps where you're looking.
    @State private var builtFor: String?
    @State private var building = true
    @State private var camera = MapCamera()
    @State private var lastTranslation = CGSize.zero
    @State private var lastMagnification = 1.0
    /// Walking the trail in 3D, over this view.
    @State private var walking = false

    static let background = Color(red: 0.035, green: 0.043, blue: 0.058)
    static let trailColor = Color(red: 1, green: 0.72, blue: 0.28)

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            // The map fills the screen; the trail fits between the chip and the bottom bar.
            let full = CGSize(width: geo.size.width + safe.leading + safe.trailing, height: geo.size.height + safe.top + safe.bottom)
            let content = EdgeInsets(top: safe.top + 84, leading: 20, bottom: safe.bottom + 64, trailing: 20)
            ZStack {
                Self.background
                    .ignoresSafeArea()
                if let map {
                    GeometryReader { screen in
                        let viewport = Viewport(size: screen.size, map: map, content: content)
                        MapLayer(map: map, viewport: viewport, camera: camera, units: model.settings.units,
                                 onSummit: { model.select(trail.peakID) })
                            .contentShape(Rectangle())
                            .gesture(pan(viewport).simultaneously(with: pinch(viewport)))
                            .onTapGesture(count: 2) { location in
                                withAnimation(.easeInOut(duration: 0.3)) { camera = viewport.zoomed(camera, by: 2, around: location) }
                            }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                } else if !building {
                    ContentUnavailableView("No terrain here yet", systemImage: "mountain.2",
                                           description: Text("The view from above is drawn from the terrain around you, once it's loaded."))
                        .environment(\.colorScheme, .dark)
                }
                VStack(spacing: 0) {
                    FromAboveChip(model: model, trail: trail, map: map)
                        .padding(.top, 8)
                        .padding(.horizontal, 12)
                    Spacer()
                    if let map { bottomBar(Viewport(size: full, map: map, content: content)) }
                }
            }
            // Built again when the terrain sharpens, you've moved or the screen turned.
            .task(id: BuildKey(trail: trail.trail.id, terrain: model.scene.map { ObjectIdentifier($0.terrain) },
                               width: Int(full.width), height: Int(full.height))) {
                await build(screen: full, content: content)
            }
        }
        .overlay {
            if walking {
                TrailWalkView(model: model, trail: trail) { walking = false }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: walking)
    }

    private func bottomBar(_ viewport: Viewport) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                ScaleBar(pointsPerMeter: viewport.pointsPerMeter(camera), units: model.settings.units)
                Spacer(minLength: 8)
                Button {
                    walking = true
                } label: {
                    Label("Walk in 3D", systemImage: "view.3d")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                }
                .accessibilityLabel("Walk the trail in 3D")
                Spacer(minLength: 8)
                if camera != MapCamera() {
                    RoundButton(systemImage: "scope", label: "Back to the whole trail") {
                        withAnimation(.easeInOut(duration: 0.35)) { camera = MapCamera() }
                    }
                    .transition(.opacity)
                }
                Text("N")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
                    .accessibilityLabel("North is up")
            }
            .animation(.easeInOut(duration: 0.2), value: camera == MapCamera())
            Text("Terrain © Copernicus DEM (DLR, Airbus) · Map data © OpenStreetMap contributors")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func pan(_ viewport: Viewport) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let step = CGSize(width: value.translation.width - lastTranslation.width,
                                  height: value.translation.height - lastTranslation.height)
                lastTranslation = value.translation
                camera = viewport.panned(camera, by: step)
            }
            .onEnded { _ in lastTranslation = .zero }
    }

    private func pinch(_ viewport: Viewport) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let step = value.magnification / lastMagnification
                lastMagnification = value.magnification
                camera = viewport.zoomed(camera, by: step, around: value.startLocation)
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    private struct BuildKey: Equatable {
        var trail: String
        var terrain: ObjectIdentifier?
        var width: Int
        var height: Int
    }

    private func build(screen: CGSize, content: EdgeInsets) async {
        guard let terrain = model.scene?.terrain else {
            building = false
            return
        }
        let route = trail.trail, peak = model.peak(trail.peakID), here = model.scene?.position
        let fresh = builtFor != route.id
        if fresh { building = true }
        let built = await Task.detached(priority: .userInitiated) {
            OverheadMap.build(trail: route, peak: peak, observer: here, terrain: terrain, screen: screen, content: content)
        }.value
        guard !Task.isCancelled else { return }
        if fresh {
            withAnimation(.easeOut(duration: 0.3)) {
                map = built
                camera = MapCamera()
            }
        } else if let built {
            map = built
        }
        builtFor = route.id
        building = false
    }
}

/// Where the map is looked at: its center in map meters (east, north of the map's center)
/// and how far it's zoomed in from showing the whole trail.
struct MapCamera: Equatable {
    var center = SIMD2<Double>(0, 0)
    var zoom = 1.0

    static let zoomRange = 0.7...10.0
}

/// How map meters land on the screen for a camera: the trail's frame fits inside the
/// content area (the screen less the chip and the bottom bar), north up.
struct Viewport {
    let size: CGSize
    let map: OverheadMap
    let content: EdgeInsets

    private var area: CGRect {
        CGRect(x: content.leading, y: content.top,
               width: max(1, size.width - content.leading - content.trailing),
               height: max(1, size.height - content.top - content.bottom))
    }

    private var fit: Double {
        min(area.width / map.frame.x, area.height / map.frame.y)
    }

    func pointsPerMeter(_ camera: MapCamera) -> Double { fit * camera.zoom }

    func screen(_ p: SIMD2<Double>, _ camera: MapCamera) -> CGPoint {
        let k = pointsPerMeter(camera)
        return CGPoint(x: area.midX + (p.x - camera.center.x) * k, y: area.midY - (p.y - camera.center.y) * k)
    }

    func mapPoint(_ s: CGPoint, _ camera: MapCamera) -> SIMD2<Double> {
        let k = pointsPerMeter(camera)
        return SIMD2(camera.center.x + (s.x - area.midX) / k, camera.center.y - (s.y - area.midY) / k)
    }

    /// From map meters to screen points.
    func transform(_ camera: MapCamera) -> CGAffineTransform {
        let k = pointsPerMeter(camera)
        return CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: area.midX - camera.center.x * k, ty: area.midY + camera.center.y * k)
    }

    /// The area to keep things on screen within, for the arrow to you.
    var inner: CGRect { area.insetBy(dx: -8, dy: -8) }

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
        c.zoom = min(MapCamera.zoomRange.upperBound, max(MapCamera.zoomRange.lowerBound, camera.zoom * factor))
        let k = pointsPerMeter(c)
        c.center = SIMD2(fixed.x - (anchor.x - area.midX) / k, fixed.y + (anchor.y - area.midY) / k)
        return clamped(c)
    }

    /// Keeps the middle of the screen over the terrain that was drawn.
    private func clamped(_ camera: MapCamera) -> MapCamera {
        var c = camera
        let half = map.size / 2
        c.center = pointwiseMax(-half, pointwiseMin(half, c.center))
        return c
    }
}

/// Everything drawn from above, built once off the main thread. Positions are map meters:
/// east and north of the map's center.
struct OverheadMap: @unchecked Sendable {
    /// Ridge crests by how much they stand out, from the main ridges down.
    struct Band {
        var path: Path
        var opacity: Double
        var width: CGFloat
        var glow: CGFloat
    }

    /// The hillshade, one pixel per grid point, and where its pixels' edges lie on the map.
    let shade: CGImage
    let shadeRect: CGRect
    /// Size of the area with terrain, meters.
    let size: SIMD2<Double>
    /// The area that fits the screen at first: the trail and the summit (and you, if near).
    let frame: SIMD2<Double>
    let bands: [Band]
    let trail: Path
    let trailhead: SIMD2<Double>?
    let summit: SIMD2<Double>?
    let peak: Peak?
    let observer: SIMD2<Double>?
    /// Climb along the trail, meters.
    let gain: Double?

    static let bandSteps: [(relief: Double, opacity: Double, width: CGFloat, glow: CGFloat)] = [
        (400, 0.92, 1.4, 5), (150, 0.58, 1.0, 4), (60, 0.32, 0.8, 0), (0, 0.18, 0.7, 0),
    ]

    /// Built for a screen of `screen` points, with the trail fitting inside `content`.
    static func build(trail: Trail, peak: Peak?, observer: LatLon?, terrain: Terrain,
                      screen: CGSize, content: EdgeInsets) -> OverheadMap? {
        guard let frame = frame(trail: trail, around: [peak?.position, observer].compactMap { $0 }) else { return nil }
        // Terrain for the whole screen when zoomed out as far as it goes, and a little more to
        // look around; at the terrain's own 30 m at most, and no more than 900 points across.
        let area = CGRect(x: content.leading, y: content.top,
                          width: max(1, screen.width - content.leading - content.trailing),
                          height: max(1, screen.height - content.top - content.bottom))
        let fit = min(area.width / frame.width, area.height / frame.height) * MapCamera.zoomRange.lowerBound
        let width = min(120_000, 2.2 * max(area.midX, screen.width - area.midX) / fit)
        let height = min(120_000, 2.2 * max(area.midY, screen.height - area.midY) / fit)
        let cell = max(30, max(width, height) / 900)
        let relief = ReliefMap(terrain: terrain, extent: MapExtent(center: frame.center, width: width, height: height), cellSize: cell)
        let projection = relief.projection
        guard let shade = image(relief, shade: relief.hillshade(exaggeration: 1.3)) else { return nil }

        var bands = bandSteps.map { Band(path: Path(), opacity: $0.opacity, width: $0.width, glow: $0.glow) }
        // On a map of a wide area, short spurs are only clutter.
        for line in relief.crestLines(minLength: max(300, 10 * cell)) {
            guard let k = bandSteps.firstIndex(where: { line.relief >= $0.relief }) else { continue }
            bands[k].path.addLines(line.points.map { CGPoint(x: $0.x, y: $0.y) })
        }
        var path = Path()
        for line in trail.lines where line.count > 1 {
            path.addLines(line.map { p in
                let xy = projection.point(p)
                return CGPoint(x: xy.x, y: xy.y)
            })
        }
        let profile = trail.profile(on: terrain)
        let size = relief.size, pixel = relief.cellSize
        return OverheadMap(shade: shade,
                           shadeRect: CGRect(x: -size.x / 2 - pixel / 2, y: -size.y / 2 - pixel / 2,
                                             width: size.x + pixel, height: size.y + pixel),
                           size: size,
                           frame: SIMD2(frame.width, frame.height),
                           bands: bands,
                           trail: path,
                           trailhead: profile?.trailhead.map(projection.point),
                           summit: peak.map { projection.point($0.position) },
                           peak: peak,
                           observer: observer.map(projection.point),
                           gain: profile?.gain)
    }

    /// The area to fit on screen: the trail, plus the summit and you where they're close by.
    /// When one is far off, an arrow at the edge points to it instead, so the trail isn't
    /// shrunk to a speck.
    static func frame(trail: Trail, around extras: [LatLon]) -> MapExtent? {
        var points = trail.lines.flatMap { $0 }
        guard var frame = MapExtent.around(points.isEmpty ? extras : points, padding: 0.12, minimumSize: 1_500) else { return nil }
        let area = frame.width * frame.height
        for extra in extras {
            if let wider = MapExtent.around(points + [extra], padding: 0.12, minimumSize: 1_500), wider.width * wider.height < 3 * area {
                points.append(extra)
                frame = wider
            }
        }
        return frame
    }

    /// The hillshade as a dark, faintly blue picture; higher ground a touch lighter, like snow.
    private static func image(_ relief: ReliefMap, shade: [Float]) -> CGImage? {
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
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: relief.cols, height: relief.rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: relief.cols * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The map for one camera. Animatable, so recentering and double-tap zooms glide.
private struct MapLayer: View, Animatable {
    let map: OverheadMap
    let viewport: Viewport
    var camera: MapCamera
    let units: AppSettings.Units
    let onSummit: () -> Void

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(camera.center.x, camera.center.y), log(camera.zoom)) }
        set {
            camera.center = SIMD2(newValue.first.first, newValue.first.second)
            camera.zoom = exp(newValue.second)
        }
    }

    private static let tint = Color(red: 0.86, green: 0.94, blue: 1.0)

    var body: some View {
        let t = viewport.transform(camera)
        let shadeRect = map.shadeRect.applying(t)
        ZStack {
            Image(decorative: map.shade, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: shadeRect.width, height: shadeRect.height)
                .position(x: shadeRect.midX, y: shadeRect.midY)
            Canvas { context, _ in
                // Faint ridges first and the main ones over them; under each line a wide faint
                // stroke makes the glow.
                for band in map.bands.reversed() {
                    let path = band.path.applying(t)
                    if band.glow > 0 {
                        context.stroke(path, with: .color(Self.tint.opacity(band.opacity * 0.2)),
                                       style: StrokeStyle(lineWidth: band.glow, lineCap: .round, lineJoin: .round))
                    }
                    context.stroke(path, with: .color(Self.tint.opacity(band.opacity)),
                                   style: StrokeStyle(lineWidth: band.width, lineCap: .round, lineJoin: .round))
                }
                let trail = map.trail.applying(t)
                context.stroke(trail, with: .color(TrailFromAboveView.trailColor.opacity(0.32)),
                               style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                context.stroke(trail, with: .color(TrailFromAboveView.trailColor),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if let start = map.trailhead {
                    let p = viewport.screen(start, camera)
                    let ring = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                    context.fill(ring, with: .color(TrailFromAboveView.background))
                    context.stroke(ring, with: .color(TrailFromAboveView.trailColor), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
            if let summit = map.summit, let peak = map.peak {
                let p = viewport.screen(summit, camera)
                if viewport.inner.contains(p) {
                    // The name goes beside the dot on the side with more room.
                    SummitMarker(peak: peak, units: units, leftward: p.x > viewport.size.width * 0.6, action: onSummit)
                        .position(p)
                } else {
                    EdgeArrow(viewport: viewport, camera: camera, at: summit, title: peak.name, color: .white, units: units)
                        .onTapGesture(perform: onSummit)
                }
            }
            if let observer = map.observer {
                You(viewport: viewport, camera: camera, at: observer, units: units)
            }
        }
    }
}

/// The summit: a dot with the peak's name and elevation beside it. Tap for its card.
private struct SummitMarker: View {
    let peak: Peak
    let units: AppSettings.Units
    let leftward: Bool
    let action: () -> Void

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 7, height: 7)
            .shadow(color: .white.opacity(0.6), radius: 4)
            .overlay(alignment: leftward ? .trailing : .leading) {
                Button(action: action) {
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
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .offset(x: leftward ? -8 : 8)
                .accessibilityLabel("\(peak.name), \(Format.elevation(of: peak, units)). Show its card")
            }
    }
}

/// You: a dot where you are, or an arrow at the edge pointing your way with how far.
private struct You: View {
    let viewport: Viewport
    let camera: MapCamera
    let at: SIMD2<Double>
    let units: AppSettings.Units

    var body: some View {
        let p = viewport.screen(at, camera)
        let inner = viewport.inner
        if inner.contains(p) {
            ZStack {
                Circle().fill(Color(red: 0.35, green: 0.65, blue: 1).opacity(0.22)).frame(width: 26, height: 26)
                Circle().fill(.white).frame(width: 13, height: 13)
                Circle().fill(Color(red: 0.25, green: 0.58, blue: 1)).frame(width: 9, height: 9)
            }
            .position(p)
            .accessibilityLabel("You are here")
        } else {
            EdgeArrow(viewport: viewport, camera: camera, at: at, title: "You", color: Color(red: 0.45, green: 0.72, blue: 1), units: units)
        }
    }
}

/// Something off the map: an arrow at the edge pointing its way, with its name and how far.
private struct EdgeArrow: View {
    let viewport: Viewport
    let camera: MapCamera
    let at: SIMD2<Double>
    let title: String
    let color: Color
    let units: AppSettings.Units

    var body: some View {
        let p = viewport.screen(at, camera)
        let inner = viewport.inner
        // Where the line from the middle to it leaves the screen.
        let c = CGPoint(x: inner.midX, y: inner.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        let s = min(inner.width / 2 / max(abs(dx), 1e-6), inner.height / 2 / max(abs(dy), 1e-6))
        let edge = CGPoint(x: c.x + dx * s, y: c.y + dy * s)
        let center = viewport.mapPoint(c, camera)
        let distance = ((at - center) * (at - center)).sum().squareRoot()
        HStack(spacing: 4) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.radians(atan2(dx, -dy)))
                .foregroundStyle(color)
            Text("\(title) · \(Format.distance(distance, units))")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .position(x: min(max(edge.x, inner.minX + 60), inner.maxX - 60), y: min(max(edge.y, inner.minY + 12), inner.maxY - 12))
        .accessibilityLabel("\(title), \(Format.distance(distance, units)) away, off the map")
    }
}

/// A thin bar of a round length, about a hundred points long.
private struct ScaleBar: View {
    let pointsPerMeter: Double
    let units: AppSettings.Units

    var body: some View {
        let (meters, label) = Self.length(upTo: 110 / pointsPerMeter, units)
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
            Path { p in
                let w = meters * pointsPerMeter
                p.move(to: CGPoint(x: 0.5, y: 0))
                p.addLine(to: CGPoint(x: 0.5, y: 5))
                p.addLine(to: CGPoint(x: w - 0.5, y: 5))
                p.addLine(to: CGPoint(x: w - 0.5, y: 0))
            }
            .stroke(.white.opacity(0.75), lineWidth: 1)
            .frame(width: meters * pointsPerMeter, height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scale: \(label)")
    }

    /// The longest round length up to `limit` meters, and how to write it.
    static func length(upTo limit: Double, _ units: AppSettings.Units) -> (Double, String) {
        let steps = [1.0, 2, 5]
        switch units {
        case .metric:
            let candidates = (0...5).flatMap { e in steps.map { $0 * pow(10, Double(e)) } }
            let m = candidates.last { $0 <= limit } ?? 1
            return (m, m < 1_000 ? "\(Int(m)) m" : "\(Int(m / 1_000)) km")
        case .imperial:
            let feet = [50.0, 100, 200, 500, 1_000, 2_000].map { ($0 * 0.3048, "\(Int($0)) ft") }
            let miles = [0.5, 1, 2, 5, 10, 20, 50].map { ($0 * 1_609.344, $0 < 1 ? "½ mi" : "\(Int($0)) mi") }
            return (feet + miles).last { $0.0 <= limit } ?? feet[0]
        }
    }
}

/// The trail's name and numbers, and the way back to the camera.
private struct FromAboveChip: View {
    let model: AppModel
    let trail: AppModel.ARTrail
    let map: OverheadMap?

    var body: some View {
        let units = model.settings.units
        HStack(spacing: 10) {
            Image(systemName: "figure.hiking")
                .foregroundStyle(TrailFromAboveView.trailColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(trail.trail.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(map == nil ? "Drawing the terrain…" :
                        [Format.distance(trail.trail.length, units), map?.gain.map { Format.climb($0, units) }]
                            .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 4)
            Button {
                model.showsFromAbove = false
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("Back to the camera")
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

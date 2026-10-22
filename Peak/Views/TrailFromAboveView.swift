import PeakCore
import SwiftUI

/// The trail seen from straight above, north up, over the terrain's ridgelines: a dark
/// hillshade, the crests glowing faintly (main ridges brightest), the trail in orange, the
/// summit and you. Drawn from the terrain already on the phone, so it works without a
/// signal; with one, satellite imagery can go underneath instead. Pinch and drag to look
/// around; double-tap to zoom in.
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
    /// Satellite imagery of the whole map, and sharper imagery of where you've zoomed in.
    @State private var imagery: MapImagery?
    @State private var closeUp: MapImagery?
    @State private var imageryState = ImageryState.idle

    enum ImageryState: Equatable {
        case idle, loading, failed
    }

    static let background = Color.sheetBackground
    static let trailColor = Color(red: 1, green: 0.72, blue: 0.28)

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            // The map fills the screen; the trail fits between the chip and the bottom bar.
            let full = CGSize(width: geo.size.width + safe.leading + safe.trailing, height: geo.size.height + safe.top + safe.bottom)
            let content = EdgeInsets(top: safe.top + 84, leading: 20, bottom: safe.bottom + 64, trailing: 20)
            let satellite = model.fromAboveSatellite
            ZStack {
                Self.background
                    .ignoresSafeArea()
                if let map {
                    GeometryReader { screen in
                        let viewport = Viewport(size: screen.size, map: map, content: content)
                        MapLayer(map: map, viewport: viewport, camera: camera, units: model.settings.units,
                                 you: model.tracker.youOnMap(trail.trail).map(map.projection.point),
                                 trailhead: trailhead(on: map), imagery: satellite ? [imagery, closeUp].compactMap { $0 } : [],
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
                if satellite, imagery != nil {
                    // Imagery is bright in places (snow, glaciers): shade the edges so the
                    // scale and the credits stay readable.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: safe.top + 90)
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                            .frame(height: safe.bottom + 130)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                VStack(spacing: 0) {
                    FromAboveChip(model: model, trail: trail, drawn: map != nil)
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
            .task(id: ImageryKey(on: satellite, center: map?.projection.center, rect: map?.shadeRect)) {
                await loadImagery(screen: full, content: content)
            }
            .task(id: CloseUpKey(on: satellite && imagery != nil, camera: camera, width: Int(full.width), height: Int(full.height))) {
                await loadCloseUp(screen: full, content: content)
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

    /// Where the hike starts, as its card has it.
    private func trailhead(on map: OverheadMap) -> SIMD2<Double>? {
        model.hike(trail.trail.id, peakID: trail.peakID)?.profile?.trailhead.map(map.projection.point)
    }

    private func bottomBar(_ viewport: Viewport) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                ScaleBar(pointsPerMeter: viewport.pointsPerMeter(camera), units: model.settings.units)
                Spacer(minLength: 8)
                Button {
                    walking = true
                } label: {
                    Label("Walk in 3D", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .imageScale(.small)
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
                if model.online || model.fromAboveSatellite {
                    satelliteButton
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
            if imageryState == .failed, model.fromAboveSatellite {
                Text("The satellite imagery didn't load.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text(model.fromAboveSatellite && imagery != nil
                 ? "Imagery © Apple Maps · Terrain © Copernicus DEM (DLR, Airbus) · Map data © OpenStreetMap contributors"
                 : "Terrain © Copernicus DEM (DLR, Airbus) · Map data © OpenStreetMap contributors")
                .font(.system(size: 9))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(model.fromAboveSatellite && imagery != nil ? 0.7 : 0.45))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// Satellite imagery under the lines, or the terrain's shading.
    private var satelliteButton: some View {
        let on = model.fromAboveSatellite
        return Button {
            model.fromAboveSatellite.toggle()
            if !model.fromAboveSatellite { imageryState = .idle }
        } label: {
            ZStack {
                if on, imageryState == .loading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.black)
                } else {
                    Image(systemName: "square.2.layers.3d")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(on ? .black : .white.opacity(0.85))
            .frame(width: 30, height: 30)
            .background {
                if on { Circle().fill(.white.opacity(0.9)) } else { Circle().fill(.ultraThinMaterial) }
            }
            .environment(\.colorScheme, .dark)
            .tapArea()
        }
        .accessibilityLabel("Satellite imagery")
        .accessibilityAddTraits(on ? .isSelected : [])
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

    private struct ImageryKey: Equatable {
        var on: Bool
        var center: LatLon?
        var rect: CGRect?
    }

    private struct CloseUpKey: Equatable {
        var on: Bool
        var camera: MapCamera
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

    /// Imagery of the whole map, about two pixels a point with the whole trail in view.
    private func loadImagery(screen: CGSize, content: EdgeInsets) async {
        guard model.fromAboveSatellite, let map else { return }
        let rect = map.shadeRect
        if let imagery, imagery.center == map.projection.center, imagery.rect == rect { return }
        // Imagery of a map around another center would land in the wrong place.
        if imagery?.center != map.projection.center {
            imagery = nil
            closeUp = nil
        }
        imageryState = .loading
        let k = Viewport(size: screen, map: map, content: content).pointsPerMeter(MapCamera())
        let scale = min(2 * k, 3_000 / max(rect.width, rect.height))
        do {
            let loaded = try await MapImagery.load(projection: map.projection, rect: rect, width: max(1, Int(rect.width * scale)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { imagery = loaded }
            imageryState = .idle
        } catch {
            guard !Task.isCancelled else { return }
            imageryState = .failed
        }
    }

    /// Zoomed in past what the whole map's imagery holds: once the map stops moving, sharper
    /// imagery of what's on screen.
    private func loadCloseUp(screen: CGSize, content: EdgeInsets) async {
        guard model.fromAboveSatellite, let map, let imagery else { return }
        let viewport = Viewport(size: screen, map: map, content: content)
        let k = viewport.pointsPerMeter(camera)
        guard Double(imagery.image.width) / imagery.rect.width < 1.5 * k else { return }
        if let closeUp, closeUp.center == map.projection.center, Double(closeUp.image.width) / closeUp.rect.width >= 1.5 * k,
           closeUp.rect.contains(viewport.visible(camera)) { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let seen = viewport.visible(camera)
        let rect = seen.insetBy(dx: -0.1 * seen.width, dy: -0.1 * seen.height).intersection(map.shadeRect)
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return }
        let scale = min(3 * k, 3_000 / max(rect.width, rect.height))
        guard let loaded = try? await MapImagery.load(projection: map.projection, rect: rect, width: max(1, Int(rect.width * scale))),
              !Task.isCancelled, loaded.center == self.map?.projection.center else { return }
        closeUp = loaded
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

    /// The whole screen in map meters.
    func visible(_ camera: MapCamera) -> CGRect {
        let a = mapPoint(.zero, camera), b = mapPoint(CGPoint(x: size.width, y: size.height), camera)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
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
    let summit: SIMD2<Double>?
    let peak: Peak?
    let observer: SIMD2<Double>?
    /// From latitude and longitude to map meters.
    let projection: MapProjection

    static let bandSteps: [(relief: Double, opacity: Double, width: CGFloat, glow: CGFloat)] = [
        (400, 0.92, 1.4, 5), (150, 0.58, 1.0, 4), (60, 0.32, 0.8, 0), (0, 0.18, 0.7, 0),
    ]

    /// Built for a screen of `screen` points, with the trail fitting inside `content`. With
    /// `lookAround` off it's a still picture: just what's on screen with the whole trail in view.
    static func build(trail: Trail, peak: Peak?, observer: LatLon?, terrain: Terrain,
                      screen: CGSize, content: EdgeInsets, lookAround: Bool = true) -> OverheadMap? {
        let area = CGRect(x: content.leading, y: content.top,
                          width: max(1, screen.width - content.leading - content.trailing),
                          height: max(1, screen.height - content.top - content.bottom))
        guard let frame = frame(trail: trail, around: [peak?.position, observer].compactMap { $0 },
                                aspect: area.width / area.height, arrowRoom: 34 / area.height) else { return nil }
        // Terrain for the whole screen when zoomed out as far as it goes, and a little more to
        // look around; at the terrain's own 30 m at most, and no more than 900 points across.
        let fit = min(area.width / frame.width, area.height / frame.height) * (lookAround ? MapCamera.zoomRange.lowerBound : 1)
        let margin = lookAround ? 2.2 : 2.1
        let width = min(120_000, margin * max(area.midX, screen.width - area.midX) / fit)
        let height = min(120_000, margin * max(area.midY, screen.height - area.midY) / fit)
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
        let size = relief.size, pixel = relief.cellSize
        return OverheadMap(shade: shade,
                           shadeRect: CGRect(x: -size.x / 2 - pixel / 2, y: -size.y / 2 - pixel / 2,
                                             width: size.x + pixel, height: size.y + pixel),
                           size: size,
                           frame: SIMD2(frame.width, frame.height),
                           bands: bands,
                           trail: path,
                           summit: peak.map { projection.point($0.position) },
                           peak: peak,
                           observer: observer.map(projection.point),
                           projection: projection)
    }

    /// The area to fit on screen: the trail, plus the summit and you where they're close by.
    /// One is taken in only if the trail still shows at least two thirds as large on a screen
    /// `aspect` wide to 1 high; when one is farther, an arrow at the edge points to it instead,
    /// so the trail isn't shrunk to a squiggle in a corner. A kilometer across at least: the
    /// terrain's 30 m grid gets soft beyond that.
    /// `arrowRoom` is how much of the screen's height an arrow along the top or bottom takes;
    /// the frame grows that way to leave room for the arrows to what's left out.
    static func frame(trail: Trail, around extras: [LatLon], aspect: Double, arrowRoom: Double = 0) -> MapExtent? {
        func around(_ points: [LatLon]) -> MapExtent? { MapExtent.around(points, padding: 0.12, minimumSize: 1_000) }
        // How large the trail shows: points per meter, for a screen 1 high.
        func scale(_ e: MapExtent) -> Double { min(aspect / e.width, 1 / e.height) }
        var points = trail.lines.flatMap { $0 }
        guard var frame = around(points.isEmpty ? extras : points) else { return nil }
        let trailOnly = scale(frame)
        var left: [LatLon] = []
        for extra in extras {
            if let wider = around(points + [extra]), scale(wider) >= trailOnly / 1.5 {
                points.append(extra)
                frame = wider
            } else {
                left.append(extra)
            }
        }
        guard arrowRoom > 0, !left.isEmpty else { return frame }
        // On the screen the frame fills its height, or less when it's wide.
        let shown = min(1, aspect * frame.height / frame.width)
        let room = arrowRoom / shown * frame.height
        let projection = MapProjection(center: frame.center)
        let north = left.contains { projection.point($0).y > 0 }, south = left.contains { projection.point($0).y <= 0 }
        let grow = (north ? room : 0) + (south ? room : 0)
        let shift = (north ? room / 2 : 0) - (south ? room / 2 : 0)
        return MapExtent(center: projection.latLon(SIMD2(0, shift)), width: frame.width, height: frame.height + grow)
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
    /// Where you are now, when the phone knows; else where the view was built.
    let you: SIMD2<Double>?
    /// Where the hike starts, on the map.
    let trailhead: SIMD2<Double>?
    /// Satellite imagery to draw over the shading, coarse first; none for the shading alone.
    let imagery: [MapImagery]
    let onSummit: () -> Void

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(camera.center.x, camera.center.y), log(camera.zoom)) }
        set {
            camera.center = SIMD2(newValue.first.first, newValue.first.second)
            camera.zoom = exp(newValue.second)
        }
    }

    private static let tint = Color(red: 0.86, green: 0.94, blue: 1.0)

    /// With the summit and you both off the map the same way, your arrow moves in a row so
    /// the two don't overlap.
    private var youShift: CGFloat {
        guard let summit = map.summit, let observer = you ?? map.observer else { return 0 }
        let inner = viewport.inner
        guard !inner.contains(viewport.screen(summit, camera)), !inner.contains(viewport.screen(observer, camera)) else { return 0 }
        let a = EdgeArrow.anchor(viewport, camera, summit), b = EdgeArrow.anchor(viewport, camera, observer)
        guard abs(a.x - b.x) < 150, abs(a.y - b.y) < 30 else { return 0 }
        return b.y > inner.midY ? -32 : 32
    }

    var body: some View {
        let t = viewport.transform(camera)
        let shadeRect = map.shadeRect.applying(t)
        ZStack {
            Image(decorative: map.shade, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: shadeRect.width, height: shadeRect.height)
                .position(x: shadeRect.midX, y: shadeRect.midY)
            // Toned down a little to sit with the dark interface, and the orange trail stands out.
            ForEach(Array(imagery.enumerated()), id: \.offset) { _, picture in
                let r = picture.rect.applying(t)
                Image(decorative: picture.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .saturation(0.8)
                    .brightness(-0.07)
            }
            Canvas { context, _ in
                // Faint ridges first and the main ones over them; under each line a wide faint
                // stroke makes the glow. Over imagery, which shows the ridges itself, fainter.
                let ridges = imagery.isEmpty ? 1.0 : 0.45
                for band in map.bands.reversed() {
                    let path = band.path.applying(t)
                    if band.glow > 0 {
                        context.stroke(path, with: .color(Self.tint.opacity(band.opacity * 0.2 * ridges)),
                                       style: StrokeStyle(lineWidth: band.glow, lineCap: .round, lineJoin: .round))
                    }
                    context.stroke(path, with: .color(Self.tint.opacity(band.opacity * ridges)),
                                   style: StrokeStyle(lineWidth: band.width, lineCap: .round, lineJoin: .round))
                }
                let trail = map.trail.applying(t)
                if imagery.isEmpty {
                    context.stroke(trail, with: .color(TrailFromAboveView.trailColor.opacity(0.32)),
                                   style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                } else {
                    // A dark edge holds the line apart from snow and pale rock.
                    context.stroke(trail, with: .color(.black.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                context.stroke(trail, with: .color(TrailFromAboveView.trailColor),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if let start = trailhead {
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
            if let observer = you ?? map.observer {
                You(viewport: viewport, camera: camera, at: observer, units: units, shift: youShift)
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
    var shift: CGFloat = 0

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
            EdgeArrow(viewport: viewport, camera: camera, at: at, title: "You", color: Color(red: 0.45, green: 0.72, blue: 1), units: units,
                      shift: shift)
        }
    }
}

/// Something off the map: an arrow pointing its way, with its name and how far. It sits along
/// the top or bottom edge, where the map leaves room for it (`OverheadMap.frame`), rather
/// than on a side, where it would cover the trail.
private struct EdgeArrow: View {
    let viewport: Viewport
    let camera: MapCamera
    let at: SIMD2<Double>
    let title: String
    let color: Color
    let units: AppSettings.Units
    /// Moved this far down (up when negative), to keep clear of another arrow.
    var shift: CGFloat = 0

    /// Where the line from the middle toward it meets the top or bottom edge, kept clear of
    /// the corners.
    static func anchor(_ viewport: Viewport, _ camera: MapCamera, _ at: SIMD2<Double>) -> CGPoint {
        let p = viewport.screen(at, camera)
        let inner = viewport.inner
        let c = CGPoint(x: inner.midX, y: inner.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        let y = dy < 0 ? inner.minY + 12 : inner.maxY - 12
        let x = abs(dy) < 1e-6 ? (dx < 0 ? -CGFloat.infinity : .infinity) : c.x + dx * (y - c.y) / dy
        return CGPoint(x: min(max(x, inner.minX + 60), inner.maxX - 60), y: y)
    }

    var body: some View {
        let p = viewport.screen(at, camera)
        let inner = viewport.inner
        let c = CGPoint(x: inner.midX, y: inner.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        let spot = Self.anchor(viewport, camera, at)
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
        .position(x: spot.x, y: spot.y + shift)
        .accessibilityLabel("\(title), \(Format.distance(distance, units)) away, off the map")
    }
}

/// A thin bar of a round length, about a hundred points long.
struct ScaleBar: View {
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
    let drawn: Bool

    var body: some View {
        let units = model.settings.units
        let gain = model.hike(trail.trail.id, peakID: trail.peakID)?.profile?.gain
        HStack(spacing: 10) {
            Image(systemName: "figure.hiking")
                .foregroundStyle(TrailFromAboveView.trailColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(trail.trail.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(!drawn ? "Drawing the terrain…" :
                        [Format.distance(trail.trail.length, units), gain.map { Format.climb($0, units) }]
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
                    .tapArea()
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

/// The trail from above as a still picture on its card, drawn just as the map from above
/// is, so it works offline too. Tap to open that map.
struct TrailMapPreview: View {
    let model: AppModel
    let trail: Trail
    let peak: Peak
    /// Where the hike starts.
    let trailhead: LatLon?
    /// The scene of the photo the peak was picked in, rather than the live view's. The map
    /// is drawn from it, and tapping doesn't open the live map.
    var place: TerrainScene? = nil

    @State private var map: OverheadMap?
    @State private var failed = false

    private static let content = EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Button {
                model.showFromAbove(trail, peakID: peak.id)
            } label: {
                ZStack {
                    TrailFromAboveView.background
                    if let map {
                        MapLayer(map: map, viewport: Viewport(size: size, map: map, content: Self.content), camera: MapCamera(),
                                 units: model.settings.units,
                                 you: place == nil ? model.tracker.youOnMap(trail).map(map.projection.point) : nil,
                                 trailhead: trailhead.map(map.projection.point), imagery: [], onSummit: {})
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    } else if failed {
                        Text("The map appears once the terrain around you has loaded.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(24)
                    } else {
                        ProgressView()
                            .tint(.white.opacity(0.6))
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(map == nil || place != nil)
            .task(id: Key(trail: trail.id, terrain: (place ?? model.scene).map { ObjectIdentifier($0.terrain) },
                          width: Int(size.width), height: Int(size.height))) {
                await build(size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the trail from above")
        .accessibilityHint(place == nil ? "Opens the map" : "")
        .accessibilityAddTraits(place == nil ? .isButton : [])
    }

    private struct Key: Equatable {
        var trail: String
        var terrain: ObjectIdentifier?
        var width: Int
        var height: Int
    }

    private func build(_ size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        let scene = place ?? model.scene
        guard let terrain = scene?.terrain else {
            failed = true
            return
        }
        let route = trail, peak = self.peak, here = scene?.position, content = Self.content
        let built = await Task.detached(priority: .userInitiated) {
            OverheadMap.build(trail: route, peak: peak, observer: here, terrain: terrain, screen: size,
                              content: content, lookAround: false)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            map = built
            failed = built == nil
        }
    }
}

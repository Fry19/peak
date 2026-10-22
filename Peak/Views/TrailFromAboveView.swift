import PeakCore
import SwiftUI
import simd

/// The trail seen from straight above, north up: over satellite imagery while there's a
/// connection, or over the terrain drawn in the walk in 3D's colors (tinted where
/// OpenStreetMap has glaciers, water and bare rock, the crests glowing faintly), which works
/// without a signal and takes over whenever the imagery can't load. The trail in orange,
/// the summit and you. Pinch and drag to look around, out as far as where you are;
/// double-tap to zoom in.
struct TrailFromAboveView: View {
    let model: AppModel
    let trail: AppModel.ARTrail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// Satellite imagery of the whole map, and sharper imagery of where you've zoomed in, as
    /// shown, in the colors of Apple's aerial photos; and each as it loaded.
    @State private var imagery: MapImagery?
    @State private var closeUp: MapImagery?
    @State private var imageryLoaded: MapImagery?
    @State private var closeUpLoaded: MapImagery?
    @State private var terrainDetail: OverheadMap.Detail?
    /// Coarser terrain, and imagery, out to where you are when that's beyond the map, so
    /// zooming out shows you and the trail together.
    @State private var wide: OverheadMap.Detail?
    @State private var wideImagery: MapImagery?
    /// The wide imagery as it loaded, before it's put in the map imagery's colors.
    @State private var wideLoaded: MapImagery?
    @State private var imageryState = ImageryState.idle

    enum ImageryState: Equatable {
        case idle, loading, failed
    }

    static let background = Color.sheetBackground
    static let trailColor = Color.amber

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            // The map fills the screen; the trail fits between the chip and the bottom bar.
            let full = CGSize(width: geo.size.width + safe.leading + safe.trailing, height: geo.size.height + safe.top + safe.bottom)
            // The bottom keeps clear of the bar, so arrows along it don't sit on its buttons.
            let content = EdgeInsets(top: safe.top + 84, leading: 20, bottom: safe.bottom + 84, trailing: 20)
            let satellite = model.settings.mapStyle == .satellite
            ZStack {
                Self.background
                    .ignoresSafeArea()
                if let map {
                    GeometryReader { screen in
                        let you = here(on: map)
                        let viewport = Viewport(size: screen.size, map: map, content: content, reach: map.reach(you))
                        MapLayer(map: map, viewport: viewport, camera: camera, units: model.settings.units,
                                 wide: wide?.mapID == map.id ? wide : nil,
                                 terrainDetail: terrainDetail?.mapID == map.id ? terrainDetail : nil,
                                 you: you, trailhead: trailhead(on: map), imagery: shownImagery(on: map),
                                 onSummit: { model.select(trail.peakID) },
                                 onYou: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { camera = viewport.both ?? camera } })
                            .contentShape(Rectangle())
                            .gesture(pan(viewport).simultaneously(with: pinch(viewport)))
                            .onTapGesture(count: 2) { location in
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { camera = viewport.zoomed(camera, by: 2, around: location) }
                            }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                } else if !building {
                    ContentUnavailableView("No terrain here yet", systemImage: "mountain.2",
                                           description: Text("The view from above is drawn from the terrain around you, once it's loaded."))
                        .environment(\.colorScheme, .dark)
                }
                if !shownImagery(on: map).isEmpty {
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
            // Built again when the terrain sharpens, land cover arrives, you've moved or the
            // screen turned.
            .task(id: BuildKey(trail: trail.trail.id, terrain: model.scene.map { ObjectIdentifier($0.terrain) },
                               cover: model.covers[trail.trail.id]?.revision ?? 0,
                               width: Int(full.width), height: Int(full.height))) {
                await build(screen: full, content: content)
            }
            .task(id: CoverKey(trail: trail.trail.id, online: model.online)) {
                await model.fetchCover(trail.trail, peak: model.peak(trail.peakID))
            }
            // Tried again when the connection comes back; what's loaded stays without one.
            .task(id: ImageryKey(on: satellite, center: map?.projection.center, rect: map?.shadeRect, online: model.online)) {
                await loadImagery(screen: full, content: content)
            }
            .task(id: CloseUpKey(on: satellite, center: map?.projection.center, imagery: shownImagery(on: map).map(\.rect),
                                camera: camera, width: Int(full.width), height: Int(full.height), online: model.online)) {
                await loadCloseUp(screen: full, content: content)
            }
            .task(id: DetailKey(map: map?.id, camera: camera, imagery: shownImagery(on: map).map(\.rect), wide: wide?.rect)) {
                await loadTerrainDetail(screen: full, content: content)
            }
            // Again when you've moved a kilometer or so, in case it's now beyond what's drawn.
            .task(id: WideKey(map: map?.id, you: map.flatMap { here(on: $0) }.map { SIMD2(Int($0.x / 1_000), Int($0.y / 1_000)) },
                              width: Int(full.width), height: Int(full.height))) {
                await loadWide(screen: full, content: content)
            }
            .task(id: ImageryKey(on: satellite, center: map?.projection.center, rect: wide?.rect, online: model.online)) {
                await loadWideImagery(screen: full, content: content)
            }
            // Again when the map's own imagery arrives after it.
            .task(id: [wideLoaded.map { ObjectIdentifier($0.image) }, imagery.map { ObjectIdentifier($0.image) }]) {
                await matchWideImagery()
            }
            .task(id: CalibrationKey(imagery: imageryLoaded.map { ObjectIdentifier($0.image) }, online: model.online)) {
                await calibrateImagery()
            }
            .task(id: [closeUpLoaded.map { ObjectIdentifier($0.image) }, imagery.map { ObjectIdentifier($0.image) }]) {
                await matchCloseUp()
            }
            .onChange(of: satellite) { _, on in
                if !on { imageryState = .idle }
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

    /// Where you are now, when the phone knows; else where the view was built.
    private func here(on map: OverheadMap) -> SIMD2<Double>? {
        model.tracker.youOnMap(trail.trail).map(map.projection.point) ?? map.observer
    }

    /// The satellite imagery to draw, coarse first; none for the terrain alone, or while it
    /// hasn't loaded.
    private func shownImagery(on map: OverheadMap?) -> [MapImagery] {
        guard let map, model.settings.mapStyle == .satellite else { return [] }
        return [wideImagery, imagery, closeUp].compactMap { $0 }.filter { $0.center == map.projection.center }
    }

    private func bottomBar(_ viewport: Viewport) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                // Shorter where it's short of room, so the buttons keep theirs on a small phone.
                let k = viewport.pointsPerMeter(camera), units = model.settings.units
                ViewThatFits(in: .horizontal) {
                    ScaleBar(pointsPerMeter: k, units: units)
                    ScaleBar(pointsPerMeter: k, units: units, maxLength: 75)
                    ScaleBar(pointsPerMeter: k, units: units, maxLength: 45)
                }
                Spacer(minLength: 8)
                // The main thing to do here, so it's the one amber button.
                Button {
                    walking = true
                } label: {
                    Label("Walk in 3D", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .imageScale(.small)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Color.amber, in: Capsule())
                        .shadow(color: Color.amber.opacity(0.35), radius: 10)
                }
                .accessibilityLabel("Walk the trail in 3D")
                Spacer(minLength: 8)
                if camera != MapCamera() {
                    RoundButton(systemImage: "scope", label: "Back to the whole trail") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { camera = MapCamera() }
                    }
                    .transition(.opacity)
                }
                styleMenu
                // North is always up: a mark, not a button.
                VStack(spacing: 0) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 6))
                    Text("N")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .shadow(color: .black.opacity(0.7), radius: 2)
                .frame(width: 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("North is up")
            }
            .animation(.easeInOut(duration: 0.2), value: camera == MapCamera())
            let satellite = model.settings.mapStyle == .satellite
            let hasImagery = !shownImagery(on: map).isEmpty
            // Without imagery the terrain shows instead; say why, quietly.
            if satellite, !hasImagery, !model.online {
                note("Satellite imagery needs a connection, so this is the terrain.")
            } else if satellite, !hasImagery, imageryState == .failed {
                note("The satellite imagery didn't load, so this is the terrain.")
            }
            let usgs = model.scene?.terrain.hasGround(under: trail.trail) == true
            Text((hasImagery ? "Imagery © Apple Maps · " : "") + "Terrain © Copernicus DEM (DLR, Airbus)" + (usgs ? ", USGS 3DEP" : "") +
                 " · Map data © OpenStreetMap contributors")
                .font(.system(size: 9))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(hasImagery ? 0.7 : 0.45))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.7))
            .shadow(color: .black.opacity(0.7), radius: 2)
    }

    /// Satellite imagery or the terrain, picked by name; the choice is kept. Its icon shows
    /// which is on.
    private var styleMenu: some View {
        let style = model.settings.mapStyle
        return Menu {
            Picker("Map", selection: Binding(get: { model.settings.mapStyle }, set: { model.settings.mapStyle = $0 })) {
                Label("Satellite", systemImage: "globe.europe.africa.fill").tag(AppSettings.MapStyle.satellite)
                Label("Terrain", systemImage: "mountain.2.fill").tag(AppSettings.MapStyle.terrain)
            }
        } label: {
            ZStack {
                if style == .satellite, imageryState == .loading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: style == .satellite ? "globe.europe.africa.fill" : "mountain.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 30, height: 30)
            .background(Circle().fill(.ultraThinMaterial).overlay(Circle().fill(Color.glassTint)))
            .environment(\.colorScheme, .dark)
            // A menu's label takes taps only within its own frame (`tapArea` doesn't widen
            // it), so the frame is a full target around the smaller circle.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Map style")
        .accessibilityValue(style.title)
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
        var cover: Int
        var width: Int
        var height: Int
    }

    private struct ImageryKey: Equatable {
        var on: Bool
        var center: LatLon?
        var rect: CGRect?
        var online: Bool
    }

    private struct CalibrationKey: Equatable {
        var imagery: ObjectIdentifier?
        var online: Bool
    }

    private struct CloseUpKey: Equatable {
        var on: Bool
        var center: LatLon?
        var imagery: [CGRect]
        var camera: MapCamera
        var width: Int
        var height: Int
        var online: Bool
    }

    private struct DetailKey: Equatable {
        var map: UUID?
        var camera: MapCamera
        var imagery: [CGRect]
        var wide: CGRect?
    }

    private struct WideKey: Equatable {
        var map: UUID?
        var you: SIMD2<Int>?
        var width: Int
        var height: Int
    }

    /// Where there's terrain drawn, map meters: the map, and farther out the wide terrain.
    private func drawn(_ map: OverheadMap) -> CGRect {
        guard let wide, wide.mapID == map.id else { return map.shadeRect }
        return map.shadeRect.union(wide.rect)
    }

    /// Keep the broad map while moving, then resample the visible ground from the DEM.
    /// Magnifying the broad hillshade alone loses small gullies and spurs on longer hikes.
    /// Not where imagery covers the screen, which hides it; elsewhere it's what shows.
    private func loadTerrainDetail(screen: CGSize, content: EdgeInsets) async {
        guard let map, let terrain = model.scene?.terrain else { return }
        let visible = Viewport(size: screen, map: map, content: content).visible(camera)
        if shownImagery(on: map).contains(where: { $0.rect.contains(visible) }) { return }
        let seen = visible.intersection(drawn(map))
        guard !seen.isNull, seen.width > 0, seen.height > 0 else { return }
        let rect = seen.insetBy(dx: -seen.width * 0.15, dy: -seen.height * 0.15).intersection(drawn(map))
        let cell = max(15, max(rect.width, rect.height) / 1_400)
        // Finer than what's drawn there already, the map or, beyond it, the wide terrain.
        let beyond = wide.flatMap { $0.mapID == map.id ? $0.cellSize : nil } ?? 0
        let coarsest = map.shadeRect.contains(seen) ? map.cellSize : max(map.cellSize, beyond)
        guard cell < coarsest * 0.8 else { return }
        if let detail = terrainDetail, detail.mapID == map.id,
           detail.cellSize <= cell * 1.1, detail.rect.contains(seen) { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let cover = model.covers[trail.trail.id]
        let detail = await Task.detached(priority: .userInitiated) {
            map.detail(terrain: terrain, rect: rect, cellSize: cell, cover: cover)
        }.value
        guard !Task.isCancelled, self.map?.id == map.id else { return }
        terrainDetail = detail
    }

    private func build(screen: CGSize, content: EdgeInsets) async {
        guard let terrain = model.scene?.terrain else {
            building = false
            return
        }
        let route = trail.trail, peak = model.peak(trail.peakID), here = model.scene?.position
        let fresh = builtFor != route.id
        if fresh { building = true }
        let cover = await model.savedCover(route, peak: peak)
        guard !Task.isCancelled else { return }
        let built = await Task.detached(priority: .userInitiated) {
            OverheadMap.build(trail: route, peak: peak, observer: here, terrain: terrain, cover: cover, screen: screen,
                              content: content)
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
        guard model.settings.mapStyle == .satellite, let map else { return }
        let rect = map.shadeRect
        if let imagery, imagery.center == map.projection.center, imagery.rect == rect { return }
        // Imagery of a map around another center would land in the wrong place.
        if imagery?.center != map.projection.center { imagery = nil }
        if imageryLoaded?.center != map.projection.center { imageryLoaded = nil }
        if closeUp?.center != map.projection.center { closeUp = nil }
        if closeUpLoaded?.center != map.projection.center { closeUpLoaded = nil }
        if wideImagery?.center != map.projection.center { wideImagery = nil }
        if wideLoaded?.center != map.projection.center { wideLoaded = nil }
        imageryState = .loading
        let k = Viewport(size: screen, map: map, content: content).pointsPerMeter(MapCamera())
        let scale = min(2 * k, 3_000 / max(rect.width, rect.height))
        do {
            let loaded = try await MapImagery.load(projection: map.projection, rect: rect, width: max(1, Int(rect.width * scale)))
            guard !Task.isCancelled else { return }
            imageryLoaded = loaded
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
        guard let map, !shownImagery(on: map).isEmpty else { return }
        let viewport = Viewport(size: screen, map: map, content: content)
        let k = viewport.pointsPerMeter(camera)
        let seen = viewport.visible(camera)
        // A sharp picture elsewhere on the map doesn't help the ground on screen.
        if shownImagery(on: map).contains(where: {
            $0.rect.contains(seen) && Double($0.image.width) / $0.rect.width >= 1.5 * k
        }) { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let rect = seen.insetBy(dx: -0.1 * seen.width, dy: -0.1 * seen.height).intersection(drawn(map))
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return }
        let scale = min(3 * k, 3_000 / max(rect.width, rect.height))
        guard let loaded = try? await MapImagery.load(projection: map.projection, rect: rect, width: max(1, Int(rect.width * scale))),
              !Task.isCancelled, loaded.center == self.map?.projection.center else { return }
        closeUpLoaded = loaded
    }

    /// For all but a short trail, a point of the whole map's imagery covers more ground than
    /// Apple's aerial photos allow, so it's the coarser, greener mosaic, and zooming in onto the
    /// photos changes the colors: it's shown in the photos' colors, from a sample of them in the
    /// middle of the map, once that loads (as it loaded until then).
    private func calibrateImagery() async {
        guard let loaded = imageryLoaded, !loaded.aerial, let map, loaded.center == map.projection.center else { return }
        let limit = MapImagery.aerialMetersPerPoint(at: map.projection.center.latitude)
        let side = min(loaded.rect.width, loaded.rect.height, 1_536 * limit)
        let rect = CGRect(x: loaded.rect.midX - side / 2, y: loaded.rect.midY - side / 2, width: side, height: side)
        guard let sample = try? await MapImagery.load(projection: map.projection, rect: rect, width: Int((side / limit).rounded(.up))),
              !Task.isCancelled, sample.aerial, imageryLoaded?.image === loaded.image else { return }
        let matched = await Task.detached(priority: .utility) { loaded.matched(to: sample) }.value
        guard !Task.isCancelled, imageryLoaded?.image === loaded.image else { return }
        imagery = matched
    }

    /// A close-up not zoomed in far enough to be the aerial photos is shown in the colors of
    /// the whole map's imagery, which covers everywhere it can be (again when that changes).
    private func matchCloseUp() async {
        guard let loaded = closeUpLoaded else { return }
        var shown = loaded
        if !loaded.aerial, let reference = imagery, reference.center == loaded.center {
            shown = await Task.detached(priority: .utility) { loaded.matched(to: reference) }.value
            guard !Task.isCancelled, closeUpLoaded?.image === loaded.image else { return }
        }
        closeUp = shown
    }

    /// When you're farther out than the map reaches, coarser terrain for the whole screen
    /// zoomed out to show you and the trail together, with a little room to look around.
    private func loadWide(screen: CGSize, content: EdgeInsets) async {
        guard let map, let terrain = model.scene?.terrain else { return }
        let viewport = Viewport(size: screen, map: map, content: content, reach: map.reach(here(on: map)))
        guard let both = viewport.both else { return }
        let seen = viewport.visible(MapCamera(center: both.center, zoom: viewport.zoomRange.lowerBound))
        let needed = seen.insetBy(dx: -0.15 * seen.width, dy: -0.15 * seen.height)
        if map.shadeRect.contains(needed) { return }
        if let wide, wide.mapID == map.id, wide.rect.contains(needed) { return }
        // As finely as the map itself at most, and about a thousand points across.
        let cell = max(map.cellSize, max(needed.width, needed.height) / 1_000)
        let cover = model.covers[trail.trail.id]
        let built = await Task.detached(priority: .utility) {
            map.detail(terrain: terrain, rect: needed, cellSize: cell, cover: cover)
        }.value
        guard !Task.isCancelled, self.map?.id == map.id, let built else { return }
        withAnimation(.easeOut(duration: 0.3)) { wide = built }
    }

    /// Imagery under the wide terrain, about two pixels a point zoomed all the way out.
    private func loadWideImagery(screen: CGSize, content: EdgeInsets) async {
        guard model.settings.mapStyle == .satellite, let map, let wide, wide.mapID == map.id else { return }
        if let wideLoaded, wideLoaded.center == map.projection.center, wideLoaded.rect == wide.rect { return }
        let viewport = Viewport(size: screen, map: map, content: content, reach: map.reach(here(on: map)))
        let k = viewport.pointsPerMeter(MapCamera(zoom: viewport.zoomRange.lowerBound))
        let width = min(2_048, 2 * k * wide.rect.width, 2_048 * wide.rect.width / wide.rect.height)
        guard let loaded = try? await MapImagery.load(projection: map.projection, rect: wide.rect, width: max(1, Int(width))),
              !Task.isCancelled, loaded.center == self.map?.projection.center else { return }
        wideLoaded = loaded
    }

    /// The wide imagery is coarse enough to be Apple's greener mosaic, which beside the map's
    /// aerial photos reads as ground half loaded: it's shown in their colors where they overlap,
    /// as it loaded until they have.
    private func matchWideImagery() async {
        guard let loaded = wideLoaded else { return }
        var shown = loaded
        if let reference = imagery, reference.center == loaded.center {
            shown = await Task.detached(priority: .utility) { loaded.matched(to: reference) }.value
            guard !Task.isCancelled, wideLoaded?.image === loaded.image else { return }
        }
        if wideImagery == nil {
            withAnimation(.easeOut(duration: 0.3)) { wideImagery = shown }
        } else {
            wideImagery = shown
        }
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
    /// How far beyond the trail zooming out and panning may go: out to you
    /// (`OverheadMap.reach`), when you're beyond the trail.
    var reach: CGRect? = nil

    private var area: CGRect {
        CGRect(x: content.leading, y: content.top,
               width: max(1, size.width - content.leading - content.trailing),
               height: max(1, size.height - content.top - content.bottom))
    }

    private var fit: Double {
        min(area.width / map.frame.x, area.height / map.frame.y)
    }

    func pointsPerMeter(_ camera: MapCamera) -> Double { fit * camera.zoom }

    /// How far zooming out reaches the trail and you together.
    private var reachZoom: Double? {
        reach.map { min(area.width / $0.width, area.height / $0.height) / fit }
    }

    /// Zoomed in from the whole trail (1), or out a little to look around it, or as far as
    /// it takes to see you too.
    var zoomRange: ClosedRange<Double> {
        min(MapCamera.zoomRange.lowerBound, reachZoom ?? 1)...MapCamera.zoomRange.upperBound
    }

    /// Showing the trail and you together, when you're beyond the trail.
    var both: MapCamera? {
        guard let reach, let reachZoom else { return nil }
        return clamped(MapCamera(center: SIMD2(reach.midX, reach.midY), zoom: min(1, reachZoom)))
    }

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
        c.zoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, camera.zoom * factor))
        let k = pointsPerMeter(c)
        c.center = SIMD2(fixed.x - (anchor.x - area.midX) / k, fixed.y + (anchor.y - area.midY) / k)
        return clamped(c)
    }

    /// Keeps the middle of the screen over the terrain that was drawn, or between the trail
    /// and you.
    private func clamped(_ camera: MapCamera) -> MapCamera {
        var c = camera
        var bounds = CGRect(x: -map.size.x / 2, y: -map.size.y / 2, width: map.size.x, height: map.size.y)
        if let reach { bounds = bounds.union(reach) }
        c.center = SIMD2(min(max(c.center.x, bounds.minX), bounds.maxX), min(max(c.center.y, bounds.minY), bounds.maxY))
        return c
    }
}

/// Everything drawn from above, built once off the main thread. Positions are map meters:
/// east and north of the map's center.
struct OverheadMap: @unchecked Sendable {
    let id = UUID()
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
    let cellSize: Double
    let elevationRange: ClosedRange<Float>
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
    /// `cover` tints the terrain where there are glaciers, water and bare rock.
    static func build(trail: Trail, peak: Peak?, observer: LatLon?, terrain: Terrain, cover: AppModel.TrailCover?,
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
        // Use the tour's local elevation range as well as its palette, so opening the
        // walk doesn't recolor the same slope because the map extends farther away.
        let colorRelief = TrailTerrainStyle.extent(trail: trail, peak: peak).map {
            ReliefMap(terrain: terrain, extent: $0, cellSize: TrailTerrainStyle.cellSize(for: $0))
        } ?? relief
        let localHeights = colorRelief.heights.filter(\.isFinite)
        let known = localHeights.isEmpty ? relief.heights.filter(\.isFinite) : localHeights
        guard let low = known.min(), let high = known.max() else { return nil }
        let elevationRange = low...high
        let ground = cover.map { relief.landCover($0.areas, within: $0.box, fade: coverFade) }
        guard let shade = image(relief, cover: ground,
                                elevationRange: elevationRange) else { return nil }

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
                           cellSize: pixel, elevationRange: elevationRange,
                           size: size,
                           frame: SIMD2(frame.width, frame.height),
                           bands: bands,
                           trail: path,
                           summit: peak.map { projection.point($0.position) },
                           peak: peak,
                           observer: observer.map(projection.point),
                           projection: projection)
    }

    struct Detail: @unchecked Sendable {
        let mapID: UUID
        let image: CGImage
        let rect: CGRect
        let cellSize: Double
    }

    /// Sample the DEM's interpolated surface more closely before lighting it: a 30 m
    /// hillshade averages slopes across 60 m and loses narrow gullies. This preserves
    /// source detail without inventing heights. Shared colors keep the inset consistent.
    func detail(terrain: Terrain, rect: CGRect, cellSize: Double, cover: AppModel.TrailCover?) -> Detail? {
        let center = SIMD2(Double(rect.midX), Double(rect.midY))
        let relief = ReliefMap(terrain: terrain,
                               extent: MapExtent(center: projection.latLon(center), width: rect.width, height: rect.height),
                               cellSize: cellSize)
        let ground = cover.map { relief.landCover($0.areas, within: $0.box, fade: Self.coverFade) }
        guard let image = Self.image(relief, cover: ground,
                                     elevationRange: elevationRange) else { return nil }
        let size = relief.size + SIMD2(repeating: cellSize)
        return Detail(mapID: id, image: image,
                      rect: CGRect(x: center.x - size.x / 2, y: center.y - size.y / 2, width: size.x, height: size.y),
                      cellSize: cellSize)
    }

    /// The trail's frame and `you` together, with a little room, map meters: as far as
    /// zooming out goes. Nil when you're on the frame already. Out to 120 km at most, about
    /// as far as there's terrain around the trail; farther, the arrow still points your way.
    func reach(_ you: SIMD2<Double>?) -> CGRect? {
        let trail = CGRect(x: -frame.x / 2, y: -frame.y / 2, width: frame.x, height: frame.y)
        guard let you, !trail.contains(CGPoint(x: you.x, y: you.y)) else { return nil }
        var r = trail.union(CGRect(x: you.x, y: you.y, width: 0, height: 0))
        let most = 120_000.0
        // Bound the padding too: padding an overseas location before clipping could move
        // the entire capped rectangle beyond the trail. Leave room for the trail itself.
        let dx = min(0.08 * min(most, r.width), max(0, (most - trail.width) / 2))
        let dy = min(0.08 * min(most, r.height), max(0, (most - trail.height) / 2))
        r = r.insetBy(dx: -dx, dy: -dy)
        if r.width > most { r = CGRect(x: you.x > 0 ? r.minX : r.maxX - most, y: r.minY, width: most, height: r.height) }
        if r.height > most { r = CGRect(x: r.minX, y: you.y > 0 ? r.minY : r.maxY - most, width: r.width, height: most) }
        return r
    }

    /// The area to fit on screen: the trail, plus the summit and you where they're close by.
    /// One is taken in only if the trail still shows at least two fifths as large on a screen
    /// `aspect` wide to 1 high, since where the hike leads and where you are matter as much as
    /// its bends; when one is farther, an arrow at the edge points to it instead,
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
            if let wider = around(points + [extra]), scale(wider) >= trailOnly / 2.5 {
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

    /// How far land cover fades in from the edge of where it was fetched, meters, so it
    /// doesn't stop in a straight line.
    static let coverFade = 1_500.0

    /// The tour's slate, local relief, land cover, north-west lighting and contour spacing,
    /// evaluated on a flat raster so the map keeps its lightweight pan and zoom gestures.
    private static func image(_ relief: ReliefMap, cover: LandCoverGrid?,
                              elevationRange: ClosedRange<Float>) -> CGImage? {
        let fine = relief.relativeHeight(radius: max(90, 2 * relief.cellSize))
        let broad = relief.relativeHeight(radius: max(450, 4 * relief.cellSize))
        let lightDirection = simd_normalize(SIMD3<Float>(-1, 1, 0.99))
        let run = Float(2 * relief.cellSize)
        func height(_ r: Int, _ c: Int) -> Float {
            let h = relief.heights[max(0, min(relief.rows - 1, r)) * relief.cols + max(0, min(relief.cols - 1, c))]
            return h.isFinite ? h : elevationRange.lowerBound
        }
        func smooth(_ a: Float, _ b: Float, _ value: Float) -> Float {
            let t = min(1, max(0, (value - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        func channel(_ linear: Float) -> UInt8 {
            let v = max(0, linear)
            let srgb = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            return UInt8(min(255, max(0, 255 * srgb)))
        }
        var pixels = [UInt8](repeating: 0, count: relief.rows * relief.cols * 4)
        for i in relief.heights.indices where relief.heights[i].isFinite {
            let r = i / relief.cols, c = i % relief.cols
            let dx = height(r, c + 1) - height(r, c - 1)
            let dy = height(r - 1, c) - height(r + 1, c)
            let normal = simd_normalize(SIMD3(-dx / run, -dy / run, 1))
            let shade = TrailTerrainStyle.shade(height: relief.heights[i], normalUp: normal.z,
                                                 fine: fine[i], broad: broad[i], range: elevationRange)
            var color = TrailTerrainStyle.color(light: shade.light, form: shade.form,
                                                  rock: cover?.rock[i] ?? 0, ice: cover?.glacier[i] ?? 0, water: cover?.water[i] ?? 0)
            let sun = max(0, simd_dot(normal, lightDirection))
            color *= 1.4 * sun * SIMD3<Float>(1, 0.97, 0.93) + 0.045 * SIMD3<Float>(0.55, 0.65, 0.85)
            // The same 50/250 m contours as the tour, fading where the raster can't
            // separate them. Derivatives are in height per raster pixel.
            let w = max(0.0001, (abs(dx) + abs(dy)) / 2)
            func contour(_ spacing: Float, _ inner: Float, _ outer: Float, _ fadeStart: Float, _ fadeEnd: Float) -> Float {
                let h = relief.heights[i] / spacing
                let distance = abs(h - h.rounded()) * spacing / w
                return (1 - smooth(inner, outer, distance)) * smooth(fadeStart, fadeEnd, spacing / w)
            }
            let ink = max(0.018 * contour(50, 0.35, 1, 9, 22), 0.045 * contour(250, 0.45, 1.3, 7, 16))
            color += ink * SIMD3<Float>(0.86, 0.94, 1)
            pixels[4 * i] = channel(color.x)
            pixels[4 * i + 1] = channel(color.y)
            pixels[4 * i + 2] = channel(color.z)
            pixels[4 * i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: relief.cols, height: relief.rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: relief.cols * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension OverheadMap {
    /// Where the trail's lines begin and end, map meters.
    var trailEnds: [SIMD2<Double>] {
        var ends: [SIMD2<Double>] = []
        var last: CGPoint?
        trail.forEach { element in
            switch element {
            case let .move(to: p):
                if let last { ends.append(SIMD2(last.x, last.y)) }
                ends.append(SIMD2(p.x, p.y))
                last = p
            case let .line(to: p): last = p
            case let .quadCurve(to: p, control: _): last = p
            case let .curve(to: p, control1: _, control2: _): last = p
            case .closeSubpath: break
            }
        }
        if let last { ends.append(SIMD2(last.x, last.y)) }
        return ends
    }
}

/// The map for one camera. Animatable, so recentering and double-tap zooms glide.
private struct MapLayer: View, Animatable {
    let map: OverheadMap
    let viewport: Viewport
    var camera: MapCamera
    let units: AppSettings.Units
    /// Coarser terrain beyond the map, out to you, and sharper terrain where you've zoomed in.
    var wide: OverheadMap.Detail? = nil
    var terrainDetail: OverheadMap.Detail? = nil
    /// Where you are now, when the phone knows; else where the view was built.
    let you: SIMD2<Double>?
    /// Where the hike starts, on the map.
    let trailhead: SIMD2<Double>?
    /// Satellite imagery to draw over the shading, coarse first; none for the shading alone.
    let imagery: [MapImagery]
    let onSummit: () -> Void
    /// Tapping the arrow to you, when you're off the map.
    var onYou: (() -> Void)? = nil

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
            if let wide {
                picture(wide.image, wide.rect.applying(t))
            }
            picture(map.shade, shadeRect)
            // Where imagery covers it, it's hidden anyway; imagery may cover only part.
            if let detail = terrainDetail {
                picture(detail.image, detail.rect.applying(t))
            }
            // Its darkest shadows lifted a little and its colors muted, to sit with the dark
            // interface and let the orange trail stand out.
            ForEach(Array(sharpEnough.enumerated()), id: \.offset) { _, picture in
                self.picture(picture.image, picture.rect.applying(t))
                    .saturation(0.8)
                    .contrast(0.9)
                    .brightness(-0.01)
            }
            Canvas { context, _ in
                // Faint ridges first and the main ones over them; under each line a wide faint
                // stroke makes the glow. Over imagery, which shows the ridges itself, faint
                // lines without the glow.
                let ridges = imagery.isEmpty ? 0.45 : 0.12
                for band in map.bands.reversed() {
                    let path = band.path.applying(t)
                    if band.glow > 0, imagery.isEmpty {
                        context.stroke(path, with: .color(Self.tint.opacity(band.opacity * 0.2 * ridges)),
                                       style: StrokeStyle(lineWidth: band.glow, lineCap: .round, lineJoin: .round))
                    }
                    context.stroke(path, with: .color(Self.tint.opacity(band.opacity * ridges)),
                                   style: StrokeStyle(lineWidth: band.width, lineCap: .round, lineJoin: .round))
                }
                let trail = map.trail.applying(t)
                // A dark edge holds the line apart from the ground, snow and pale rock.
                context.stroke(trail, with: .color(.black.opacity(imagery.isEmpty ? 0.6 : 0.55)),
                               style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round))
                context.stroke(trail, with: .color(TrailFromAboveView.trailColor),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                // The far end: a small dot, unless the summit's marker is there already.
                if let end = trailEnd {
                    let p = viewport.screen(end, camera)
                    let dot = Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
                    context.fill(dot, with: .color(TrailFromAboveView.trailColor))
                    context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1.5)
                }
                // The start: a ring, named.
                if let start = trailhead {
                    let p = viewport.screen(start, camera)
                    let ring = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                    context.fill(ring, with: .color(TrailFromAboveView.background))
                    context.stroke(ring, with: .color(TrailFromAboveView.trailColor), lineWidth: 2.5)
                    let label = context.resolve(Text("Start").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                    let size = label.measure(in: CGSize(width: 200, height: 40))
                    let below = CGPoint(x: p.x, y: p.y + 10 + size.height / 2)
                    var shadow = context
                    shadow.addFilter(.shadow(color: .black.opacity(0.9), radius: 2))
                    shadow.draw(label, at: below)
                }
            }
            .allowsHitTesting(false)
            if let summit = map.summit, let peak = map.peak {
                let p = viewport.screen(summit, camera)
                if viewport.inner.contains(p) {
                    // The name goes beside the dot on the side with more room.
                    SummitMarker(peak: peak, units: units, leftward: p.x > viewport.size.width * 0.6, action: onSummit)
                        .position(p)
                }
            }
            if let observer = you ?? map.observer, viewport.inner.contains(viewport.screen(observer, camera)) {
                You(viewport: viewport, camera: camera, at: observer)
            }
            EdgeArrows(viewport: viewport, camera: camera, units: units, items: offMap)
        }
    }

    /// The imagery to draw, coarse first, up to the first that's sharp enough here. Apple's
    /// imagery at another scale can be from another season, so a sharper picture drawn over
    /// one that doesn't need it would show as a square of another color (and Apple's logo
    /// at its corner).
    private var sharpEnough: [MapImagery] {
        let k = viewport.pointsPerMeter(camera)
        let visible = viewport.visible(camera)
        guard let i = imagery.firstIndex(where: {
            $0.rect.contains(visible) && Double($0.image.width) / $0.rect.width >= 1.5 * k
        }) else { return imagery }
        return Array(imagery[...i])
    }

    /// A picture laid over `rect`, screen points.
    private func picture(_ image: CGImage, _ rect: CGRect) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    /// The summit and you, where they're off the map.
    private var offMap: [EdgeArrows.Item] {
        var items: [EdgeArrows.Item] = []
        if let summit = map.summit, let peak = map.peak, !viewport.inner.contains(viewport.screen(summit, camera)) {
            items.append(EdgeArrows.Item(title: peak.name, color: .white, at: summit, action: onSummit))
        }
        if let observer = you ?? map.observer, !viewport.inner.contains(viewport.screen(observer, camera)) {
            items.append(EdgeArrows.Item(title: "You", color: Color(red: 0.45, green: 0.72, blue: 1), at: observer, action: onYou))
        }
        return items
    }

    /// The trail's far end from where it starts, unless the summit is drawn right there. A
    /// trail comes in pieces; where two meet isn't an end, so only loose ends count.
    private var trailEnd: SIMD2<Double>? {
        let ends = map.trailEnds
        let loose = ends.indices.filter { i in
            !ends.indices.contains { j in j != i && simd_distance(ends[i], ends[j]) < 25 }
        }.map { ends[$0] }
        guard let start = trailhead ?? loose.first else { return nil }
        let far = loose.max { simd_distance($0, start) < simd_distance($1, start) }
        guard let far, simd_distance(far, start) > 50 else { return nil }
        if let summit = map.summit, simd_distance(far, summit) < 150 { return nil }
        return far
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

/// You: a dot where you are. Off the map, `EdgeArrows` points your way instead.
private struct You: View {
    let viewport: Viewport
    let camera: MapCamera
    let at: SIMD2<Double>

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.35, green: 0.65, blue: 1).opacity(0.22)).frame(width: 26, height: 26)
            Circle().fill(.white).frame(width: 13, height: 13)
            Circle().fill(Color(red: 0.25, green: 0.58, blue: 1)).frame(width: 9, height: 9)
        }
        .position(viewport.screen(at, camera))
        .accessibilityLabel("You are here")
    }
}

/// What's off the map: for each, an arrow pointing its way with its name and how far. They
/// sit along the top or bottom edge, where the map leaves room for them (`OverheadMap.frame`),
/// rather than on a side, where they would cover the trail; two near each other on one edge
/// sit side by side in a row.
private struct EdgeArrows: View {
    struct Item {
        var title: String
        var color: Color
        var at: SIMD2<Double>
        var action: (() -> Void)?
    }

    let viewport: Viewport
    let camera: MapCamera
    let units: AppSettings.Units
    let items: [Item]

    /// Where the line from the middle toward a point meets the top or bottom edge, kept clear
    /// of the corners.
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
        let placed = items.map { (item: $0, spot: Self.anchor(viewport, camera, $0.at)) }.sorted { $0.spot.x < $1.spot.x }
        let midY = viewport.inner.midY
        ZStack {
            row(placed.filter { $0.spot.y < midY })
            row(placed.filter { $0.spot.y >= midY })
        }
    }

    @ViewBuilder private func row(_ placed: [(item: Item, spot: CGPoint)]) -> some View {
        if let first = placed.first, let last = placed.last, placed.count > 1, last.spot.x - first.spot.x < 220 {
            // Close together: one row, centered where they point, kept on screen.
            let inner = viewport.inner
            let x = min(max(placed.map(\.spot.x).reduce(0, +) / CGFloat(placed.count), inner.minX + 120), inner.maxX - 120)
            HStack(spacing: 8) {
                ForEach(Array(placed.enumerated()), id: \.offset) { _, entry in pill(entry.item) }
            }
            .fixedSize()
            .position(x: x, y: first.spot.y)
        } else {
            ForEach(Array(placed.enumerated()), id: \.offset) { _, entry in
                pill(entry.item).position(entry.spot)
            }
        }
    }

    private func pill(_ item: Item) -> some View {
        let p = viewport.screen(item.at, camera)
        let inner = viewport.inner
        let c = CGPoint(x: inner.midX, y: inner.midY)
        let center = viewport.mapPoint(c, camera)
        let distance = ((item.at - center) * (item.at - center)).sum().squareRoot()
        return HStack(spacing: 4) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.radians(atan2(p.x - c.x, c.y - p.y)))
                .foregroundStyle(item.color)
            Text("\(item.title) · \(Format.distance(distance, units))")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassBackground(in: Capsule())
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .contentShape(Capsule())
        .tapArea()
        .onTapGesture { item.action?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(Format.distance(distance, units)) away, off the map")
        .accessibilityAddTraits(item.action == nil ? [] : .isButton)
        .accessibilityAction { item.action?() }
    }
}

/// A thin bar of a round length, up to about a hundred points long.
struct ScaleBar: View {
    let pointsPerMeter: Double
    let units: AppSettings.Units
    var maxLength = 110.0

    var body: some View {
        let (meters, label) = Self.length(upTo: maxLength / pointsPerMeter, units)
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
                Label("Camera", systemImage: "camera.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.white.opacity(0.15), in: Capsule())
                    .tapArea()
            }
            .accessibilityLabel("Back to the camera")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .glassBackground(in: Capsule())
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
                          cover: model.covers[trail.id]?.revision ?? 0, width: Int(size.width), height: Int(size.height))) {
                await build(size)
            }
            // The map from above and the walk in 3D, opened from here, have it too.
            .task(id: CoverKey(trail: trail.id, online: model.online)) {
                await model.fetchCover(trail, peak: peak)
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
        var cover: Int
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
        let cover = await model.savedCover(route, peak: peak)
        guard !Task.isCancelled else { return }
        let built = await Task.detached(priority: .userInitiated) {
            OverheadMap.build(trail: route, peak: peak, observer: here, terrain: terrain, cover: cover, screen: size,
                              content: content, lookAround: false)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            map = built
            failed = built == nil
        }
    }
}

/// Land cover around a trail is fetched again when the connection comes back.
struct CoverKey: Equatable {
    var trail: String
    var online: Bool
}

import PeakCore
import SceneKit
import SwiftUI
import UIKit

/// The map and walking tour share elevation, slope, land-cover and local-relief colors.
/// Values are linear RGB, as used by SceneKit's lighting.
enum TrailTerrainStyle {
    static func shade(height: Float, normalUp: Float, fine: Float, broad: Float,
                      range: ClosedRange<Float>) -> (light: Float, form: Float) {
        let t = pow(min(1, max(0, (height - range.lowerBound) / max(1, range.upperBound - range.lowerBound))), 1.3)
        var light = 0.016 + 0.10 * t
        let steep = min(1, max(0, (0.82 - normalUp) / 0.22))
        light *= 1 + 0.7 * steep
        let f = fine.isFinite ? fine : 0, b = broad.isFinite ? broad : 0
        let form = max(0.3, 1 + 0.4 * min(1, max(-1, f / 25)) + 0.3 * min(1, max(-1, b / 120)))
        return (light * form, form)
    }

    static func color(light: Float, form: Float, rock: Float = 0, ice: Float = 0, water: Float = 0) -> SIMD3<Float> {
        var color = SIMD3(light, light * 1.12, light * 1.45)
        if rock > 0 { color += (light * SIMD3(1.1, 1.35, 1.9) - color) * rock }
        if ice > 0 { color += ((0.13 * form + 1.3 * light) * SIMD3(0.5, 0.7, 1.12) - color) * ice }
        if water > 0 { color += (SIMD3(0.004, 0.011, 0.03) - color) * water }
        return color
    }

    static func extent(trail: Trail, peak: Peak?) -> MapExtent? {
        guard let frame = OverheadMap.frame(trail: trail, around: peak.map { [$0.position] } ?? [], aspect: 0.46) else { return nil }
        let side = min(26_000, max(10_000, max(frame.width, frame.height) + 6_000))
        return MapExtent(center: frame.center, width: side, height: side)
    }

    static func cellSize(for extent: MapExtent) -> Double { max(15, extent.width / 1_024) }
}

/// The trail in 3D: the terrain around it lit from the north-west, far ridges fading into
/// haze, glaciers, water and bare rock tinted where OpenStreetMap has them, and the trail in
/// orange. It opens looking straight down, as the map does, with the
/// ridge crests glowing faintly, then tilts down behind the start, the crests fading as it
/// nears the horizon, and walks the trail to its end.
/// Pause to look around (drag to orbit, pinch to zoom); the slider moves along the trail.
/// The summit and a few of the most prominent mountains around are named while in sight
/// (`WalkLabels`).
/// Drawn from the terrain already on the phone, so it works offline; with satellite as the
/// map's style and a connection, the imagery is laid over it instead of those colors.
struct TrailWalkView: View {
    let model: AppModel
    let trail: AppModel.ARTrail
    let onClose: () -> Void

    @State private var world: WalkWorld?
    @State private var player = WalkPlayer()
    @State private var failed = false
    /// Satellite imagery over the terrain and the ring around it, kept for a sharper
    /// rebuild of the same ground.
    @State private var nearImagery: MapImagery?
    @State private var farImagery: MapImagery?
    /// The sharper imagery around the walker, and the photos over the hills around, kept
    /// likewise.
    @State private var detailImagery: MapImagery?
    @State private var midImagery: MapImagery?
    @State private var draped = false
    /// Where the chip and the controls are, in window coordinates, for labels to keep clear of.
    @State private var chipFrame = CGRect.zero
    @State private var controlsFrame = CGRect.zero

    var body: some View {
        ZStack {
            TrailFromAboveView.background
                .ignoresSafeArea()
            if let world {
                WalkSceneView(world: world, player: player, you: model.tracker.youOnMap(trail.trail))
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else if failed {
                ContentUnavailableView("No terrain here yet", systemImage: "mountain.2",
                                       description: Text("The trail is drawn in 3D from the terrain around you, once it's loaded."))
                    .environment(\.colorScheme, .dark)
            } else {
                ProgressView()
                    .tint(.white)
            }
            if draped {
                // Imagery is bright in places (snow, the trail up close): shade the bottom so
                // the controls and the credits stay readable.
                VStack(spacing: 0) {
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 170)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            VStack(spacing: 0) {
                WalkChip(model: model, trail: trail, world: world, player: player, onClose: onClose)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chipFrame = $0 }
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                Spacer()
                if let world {
                    WalkControls(world: world, player: player, draped: draped,
                                 usgs: model.scene?.terrain.hasGround(under: trail.trail) == true)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controlsFrame = $0 }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .task(id: BuildKey(trail: trail.trail.id, terrain: model.scene.map { ObjectIdentifier($0.terrain) })) {
            await build()
        }
        .task(id: CoverKey(trail: trail.trail.id, online: model.online)) {
            await model.fetchCover(trail.trail, peak: model.peak(trail.peakID))
        }
        // Over satellite imagery when that's the map's style and it loads; in the terrain's own
        // colors otherwise, or until it does.
        .task(id: DrapeKey(world: world.map(ObjectIdentifier.init), satellite: model.settings.mapStyle == .satellite,
                           online: model.online)) {
            await drape()
        }
        // Sharper imagery under the part of the walk in view, once the imagery is laid.
        .task(id: DetailKey(world: world.map(ObjectIdentifier.init), draped: draped, online: model.online)) {
            await sharpen()
        }
        // Land cover that arrives once the walk is under way tints the terrain where it stands.
        .task(id: [model.covers[trail.trail.id]?.revision ?? -1, world == nil ? 0 : 1]) {
            if let world, let cover = model.covers[trail.trail.id] { await world.tint(with: cover) }
        }
        // The mountains around, to label: those the camera view knows, as they arrive.
        .task(id: LabelKey(world: world.map(ObjectIdentifier.init), peaks: model.scene?.allPeaks.count ?? 0)) {
            guard let world, let peaks = model.scene.map({ Array($0.allPeaks.values.map(\.peak)) }) else { return }
            let pool = await Task.detached(priority: .userInitiated) { world.peaksToLabel(from: peaks) }.value
            guard !Task.isCancelled else { return }
            world.labelPeaks = pool
        }
        .onChange(of: [chipFrame, controlsFrame], initial: true) { _, frames in player.keepClear = frames }
        .onDisappear { player.stop() }
    }

    private struct LabelKey: Equatable {
        var world: ObjectIdentifier?
        var peaks: Int
    }

    private struct BuildKey: Equatable {
        var trail: String
        var terrain: ObjectIdentifier?
    }

    private struct DrapeKey: Equatable {
        var world: ObjectIdentifier?
        var satellite: Bool
        var online: Bool
    }

    private struct DetailKey: Equatable {
        var world: ObjectIdentifier?
        var draped: Bool
        var online: Bool
    }

    /// Keeps sharper imagery under the part of the walk in view, loading it again as the walker
    /// moves on: one download at a time, waiting longer after each one that fails.
    private func sharpen() async {
        guard let world, draped else { return }
        if let detailImagery { world.show(detail: detailImagery) }
        var wait = 2.0
        while !Task.isCancelled {
            let center = world.detailCenter(at: player.shownDistance, walking: player.playing)
            if world.needsDetail(around: center) {
                do {
                    let loaded = try await world.loadDetail(around: center)
                    guard !Task.isCancelled, self.world === world else { return }
                    wait = 2
                    // A slow download may finish after scrubbing back to imagery we already
                    // have. Keep the picture nearest the part of the walk now in view.
                    let wanted = world.detailCenter(at: player.shownDistance, walking: player.playing)
                    if let shown = world.detail, shown.rect.width == loaded.rect.width {
                        let previous = SIMD2<Double>(shown.rect.midX, shown.rect.midY)
                        if simd_distance(previous, wanted) < simd_distance(center, wanted) { continue }
                    }
                    world.show(detail: loaded)
                    detailImagery = loaded
                } catch {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(wait))
                    wait = min(60, wait * 2)
                    continue
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Loads what imagery is missing, the terrain's before the ring's, and lays each on as
    /// it comes; a part that didn't load is tried again when the connection returns.
    private func drape() async {
        guard let world, model.settings.mapStyle == .satellite else { return }
        if !world.draped {
            if nearImagery.map({ !world.fits($0, ring: false) }) ?? true {
                guard let loaded = await world.loadNearImagery(), !Task.isCancelled, self.world === world else { return }
                nearImagery = loaded
            }
            await world.drape(near: nearImagery, far: nil)
            guard !Task.isCancelled, self.world === world else { return }
            draped = world.draped
        }
        if !world.ringDraped {
            if farImagery.map({ !world.fits($0, ring: true) }) ?? true {
                guard let loaded = await world.loadFarImagery(), !Task.isCancelled, self.world === world else { return }
                // Coarse enough to be Apple's greener mosaic: in the colors of the photos nearer.
                let near = nearImagery
                let matched = await Task.detached(priority: .userInitiated) { near.map(loaded.matched) ?? loaded }.value
                guard !Task.isCancelled, self.world === world else { return }
                farImagery = matched
            }
            await world.drape(near: nil, far: farImagery)
        }
        // Then the photos over the hills around, out to where the haze thickens.
        if world.ringDraped, !world.midShown, let rect = world.midRect {
            if midImagery.map({ $0.rect != rect || $0.center != world.center }) ?? true {
                guard let loaded = await world.loadMidImagery(rect), !Task.isCancelled, self.world === world else { return }
                midImagery = loaded
            }
            if let midImagery { world.show(mid: midImagery) }
        }
    }

    private func build() async {
        guard let terrain = model.scene?.terrain else {
            failed = true
            return
        }
        let route = trail.trail, peak = model.peak(trail.peakID), units = model.settings.units
        let cover = await model.savedCover(route, peak: peak)
        guard !Task.isCancelled else { return }
        let built = await Task.detached(priority: .userInitiated) {
            WalkWorld.build(trail: route, peak: peak, terrain: terrain, cover: cover, units: units)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            world = built
            failed = built == nil
            draped = false
        }
    }
}

// MARK: - The scene

/// Everything in 3D for one trail, built off the main thread. SceneKit's axes: x east,
/// y up, z south; map meters (x east, y north, z up) go to (x, z, −y).
final class WalkWorld: @unchecked Sendable {
    let scene: SCNScene
    let camera: SCNNode
    let walker: SCNNode
    /// You, where the phone puts you, in blue; hidden when not known or off the terrain.
    let you: SCNNode
    /// The hike's summit, labeled over the view (`WalkLabels`), and the mountains around that
    /// may be, best first (set on the main thread only).
    let summit: WalkPeak?
    var labelPeaks: [WalkPeak] = []
    let units: AppSettings.Units
    /// The ridge crest lines, faded by how steeply the camera looks down.
    let crests: SCNNode
    let walk: TrailWalk
    let relief: ReliefMap
    /// Elevation along the walk from the terrain model, by distance, for the readout.
    let profile: TrailProfile?
    /// Looking straight down over the trail, north up, as the map does: where it starts.
    let overhead: (eye: SIMD3<Double>, target: SIMD3<Double>)
    /// How far from the walker the camera follows, meters.
    let range: Double
    /// The sharp terrain around the trail, what its colors are made from, and the land cover
    /// they're tinted with (its revision).
    private let ground: SCNNode
    private let shades: GroundShades
    private var coverRevision: Int?
    /// The coarser terrain around it, out to the haze.
    private let ring: SCNNode
    private let far: ReliefMap
    /// Where the ring leaves the ground to the sharp terrain (map meters, lowest and highest corner).
    private let hole: (low: SIMD2<Double>, high: SIMD2<Double>)
    /// The steepest slope of the terrain drawn, rise over run.
    let steepestSlope: Double
    /// Satellite imagery laid over the sharp terrain, and over the ring around it, instead of
    /// their colors (changed on the main thread only). Each is laid once its imagery loads.
    private(set) var draped = false
    private(set) var ringDraped = false
    /// How strongly the crest lines show: fainter over imagery, which shows the ridges itself.
    private(set) var crestStrength: CGFloat = 1

    private init(scene: SCNScene, camera: SCNNode, walker: SCNNode, you: SCNNode, summit: WalkPeak?, units: AppSettings.Units,
                 crests: SCNNode, walk: TrailWalk,
                 relief: ReliefMap, profile: TrailProfile?, overhead: (eye: SIMD3<Double>, target: SIMD3<Double>), range: Double,
                 ground: SCNNode, shades: GroundShades, coverRevision: Int?, ring: SCNNode, far: ReliefMap,
                 hole: (low: SIMD2<Double>, high: SIMD2<Double>)) {
        self.scene = scene
        self.camera = camera
        self.walker = walker
        self.you = you
        self.summit = summit
        self.units = units
        self.crests = crests
        self.walk = walk
        self.relief = relief
        self.profile = profile
        self.overhead = overhead
        self.range = range
        self.ground = ground
        self.shades = shades
        self.coverRevision = coverRevision
        self.ring = ring
        self.far = far
        self.hole = hole
        steepestSlope = max(relief.steepestSlope, far.steepestSlope)
    }

    static let background = UIColor(red: 0.035, green: 0.043, blue: 0.058, alpha: 1)
    /// The sky, and the haze far terrain fades into.
    static let haze = UIColor(red: 0.055, green: 0.066, blue: 0.09, alpha: 1)
    /// Over satellite imagery, a daylight sky instead: the pale haze at the horizon, which far
    /// terrain fades into, and blue overhead.
    static let daylightHaze = SIMD3<Double>(0.78, 0.85, 0.92)
    static let daylightZenith = SIMD3<Double>(0.22, 0.44, 0.78)

    /// The daylight sky as a 2:1 latitude–longitude picture, which SceneKit wraps around the
    /// scene, so the horizon stays level as the camera tilts: blue overhead, paling toward the
    /// horizon, and haze below it, past the terrain's edge.
    static let daylightSky: CGImage? = {
        let width = 1_024, height = 512
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            // Degrees above the horizon at this row's middle.
            let elevation = 90 - 180 * (Double(row) + 0.5) / Double(height)
            let t = pow(max(0, elevation) / 90, 0.45)
            let c = daylightHaze + (daylightZenith - daylightHaze) * t
            for column in 0..<width {
                let i = 4 * (row * width + column)
                pixels[i] = UInt8((c.x * 255).rounded())
                pixels[i + 1] = UInt8((c.y * 255).rounded())
                pixels[i + 2] = UInt8((c.z * 255).rounded())
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        return provider.flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }()
    static let trailColor = UIColor(Color.amber)
    /// How far below its terrain the ring around the sharp terrain is drawn, meters.
    static let ringSink: Float = 15
    /// Vertical field of view, degrees.
    static let fieldOfView = 62.0

    static func scn(_ p: SIMD3<Double>) -> SCNVector3 { SCNVector3(Float(p.x), Float(p.z), Float(-p.y)) }

    /// The ground's height at a map position, meters.
    func ground(_ p: SIMD2<Double>) -> Double { relief.height(at: p) }

    /// The ground's height at a map position, meters: the sharp terrain's, or past it the
    /// ring's; NaN beyond both.
    func groundOrRing(_ p: SIMD2<Double>) -> Double {
        let h = relief.height(at: p)
        return h.isFinite ? h : far.height(at: p)
    }

    /// The lowest the camera may be at a map position, meters: 15 m over the highest ground
    /// within 25 m, so the near clipping plane (10 m out) stays out of the slopes around it.
    /// Off the sharp terrain, the ring's ground; nowhere, no limit.
    func lowestEye(at p: SIMD2<Double>) -> Double {
        var top = relief.highest(within: 25, of: p)
        if !top.isFinite { top = far.highest(within: 25, of: p) }
        return top.isFinite ? top + 15 : -.infinity
    }

    /// Whether a camera at `eye` (map meters) is over the ground and sees `subject` over what's
    /// in between, as the camera following the walker does: by up to 40 m near the camera,
    /// less close up, where 40 m would keep it from ever coming near.
    func isClear(_ eye: SIMD3<Double>, seeing subject: SIMD3<Double>) -> Bool {
        guard eye.z >= lowestEye(at: SIMD2(eye.x, eye.y)) else { return false }
        let clearance = min(40, simd_distance(eye, subject) / 10)
        return TrailWalk.raised(eye, toSee: subject, clearance: clearance, ground: groundOrRing).z <= eye.z + 0.01
    }

    /// How far the line from `eye` to a summit at `top` (map meters) passes over the terrain
    /// as drawn, at its lowest, meters; negative where a ridge hides the summit. Exact on the
    /// triangles drawn, the sharp terrain's and the lowered ring's outside the sharp square,
    /// along the whole line. The line ends on the summit's ground, so there, and only there,
    /// it may touch it: by 5 cm, for rounding, tapering to none a grid square out.
    func clearance(from eye: SIMD3<Double>, to top: SIMD3<Double>) -> Double {
        let half = relief.size / 2
        let sharp = abs(top.x) <= half.x && abs(top.y) <= half.y
        let contact = sharp ? relief.cellSize : far.cellSize
        return min(relief.clearance(from: eye, to: top, contact: contact, contactDepth: 0.05),
                   far.clearance(from: eye, to: top, contact: contact, contactDepth: 0.05, sink: Double(Self.ringSink), hole: hole))
    }

    /// Where a peak's summit is labeled, map meters: at its elevation, or on the terrain as
    /// drawn there if that's higher (the sharp terrain's, or the lowered ring's where it
    /// shows). Nil off the terrain.
    static func summitTop(_ peak: Peak, relief: ReliefMap, far: ReliefMap,
                          hole: (low: SIMD2<Double>, high: SIMD2<Double>)) -> SIMD3<Double>? {
        let xy = relief.projection.point(peak.position)
        let inHole = xy.x >= hole.low.x && xy.y >= hole.low.y && xy.x <= hole.high.x && xy.y <= hole.high.y
        let near = relief.surfaceHeight(at: xy)
        let ring = inHole ? .nan : far.surfaceHeight(at: xy) - Double(ringSink)
        let ground = [near, ring].filter(\.isFinite).max()
        return ground.map { SIMD3(xy.x, xy.y, max(peak.elevation, $0)) }
    }

    /// The mountains the walk may label, best first: those of `peaks` on its terrain, the
    /// sharp square or the ring around it, but the hike's own summit.
    func peaksToLabel(from peaks: [Peak]) -> [WalkPeak] {
        let center = SIMD2(0.0, 0.0)
        return peaks.compactMap { peak -> WalkPeak? in
            guard peak.id != summit?.peak.id, !peak.name.isEmpty else { return nil }
            guard let top = Self.summitTop(peak, relief: relief, far: far, hole: hole) else { return nil }
            let distance = simd_distance(SIMD2(top.x, top.y), center)
            return WalkPeak(peak: peak, top: top, score: PeakRanking.score(peak, rise: 0, distance: distance))
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.peak.id < $1.peak.id }
    }

    /// Following the walker low, near the horizon, so the slopes and the ranges ahead stand
    /// up in 3D; steep climbs tilt it down a little, and ridges in the way lift it.
    func follow(at distance: Double) -> (eye: SIMD3<Double>, target: SIMD3<Double>) {
        walk.camera(at: distance, range: range, pitch: 9, maxPitch: 30, lead: 0.3) { [relief] in relief.height(at: $0) }
    }

    /// Puts the you-are-here dot at `p` on the ground.
    func place(you p: LatLon?) {
        let xy = p.map { relief.projection.point($0) }
        let z = xy.map { relief.height(at: $0) } ?? .nan
        guard let xy, z.isFinite else {
            you.isHidden = true
            return
        }
        let position = Self.scn(SIMD3(xy.x, xy.y, z + 3))
        if !SCNVector3EqualToVector3(you.position, position) { you.position = position }
        you.isHidden = false
    }

    func walkerPosition(at distance: Double) -> SIMD3<Double> {
        walk.point(at: distance) + SIMD3(0, 0, 3)
    }

    static func build(trail: Trail, peak: Peak?, terrain: Terrain, cover: AppModel.TrailCover?,
                      units: AppSettings.Units) -> WalkWorld? {
        guard let frame = OverheadMap.frame(trail: trail, around: peak.map { [$0.position] } ?? [], aspect: 0.46) else { return nil }
        // Sample the interpolated DEM at 15–25 m so projecting its geographic grid onto
        // the mesh preserves the source's narrow ridges and gullies. Bound the mesh to
        // about a million vertices; the horizon uses a separate, coarser ring.
        guard let extent = TrailTerrainStyle.extent(trail: trail, peak: peak) else { return nil }
        let side = extent.width
        let relief = ReliefMap(terrain: terrain, extent: extent, cellSize: TrailTerrainStyle.cellSize(for: extent))
        let wide = ReliefMap(terrain: terrain, extent: MapExtent(center: frame.center, width: 70_000, height: 70_000),
                             cellSize: 150)
        let projection = relief.projection
        let known = relief.heights.filter(\.isFinite)
        guard let low = known.min(), let high = known.max() else { return nil }

        // The walk: the main line from its lower end, on the ground.
        let profile = trail.profile(on: terrain)
        var route: [SIMD3<Double>] = []
        if let profile, profile.points.count > 1 {
            route = profile.points.map { p in
                let xy = projection.point(p.position)
                let z = relief.height(at: xy)
                return SIMD3(xy.x, xy.y, z.isFinite ? z : p.elevation)
            }
        } else if let line = trail.densified(spacing: 25).max(by: { $0.count < $1.count }) {
            route = line.map { p in
                let xy = projection.point(p)
                return SIMD3(xy.x, xy.y, relief.height(at: xy))
            }
        }
        let walk = TrailWalk(points: route)
        guard walk.length > 0 else { return nil }
        let range = min(750, max(380, walk.length * 0.15))

        let scene = SCNScene()
        scene.background.contents = haze
        scene.fogColor = haze
        scene.fogStartDistance = 3_000
        scene.fogEndDistance = 30_000
        scene.fogDensityExponent = 1.2

        // The ring stops where the sharp terrain begins, a little inside its edge, and sits a
        // few meters lower, so the sharp terrain always covers the seam.
        let edge = side / 2 - 2 * wide.cellSize
        let hole = (low: SIMD2(-edge, -edge), high: SIMD2(edge, edge))
        let ground = terrainNode(relief, low: low, high: high, cover: cover.flatMap { landCover($0, on: relief) })
        scene.rootNode.addChildNode(ground.node)
        let ring = terrainNode(wide, low: low, high: high, hole: hole, sink: ringSink).node
        scene.rootNode.addChildNode(ring)
        let crests = SCNNode()
        for node in crestNodes(relief) + crestNodes(wide, outside: hole) { crests.addChildNode(node) }
        scene.rootNode.addChildNode(crests)
        for node in trailNodes(trail, relief, width: max(2, range / 180)) { scene.rootNode.addChildNode(node) }

        // Light from the north-west, low enough to model the slopes, and a cool fill.
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.intensity = 1_400
        sun.light!.color = UIColor(red: 1, green: 0.97, blue: 0.93, alpha: 1)
        // From the north-west and 35° up (SceneKit's z points south): low enough that the
        // light rakes across the slopes and shows their shapes.
        sun.position = SCNVector3(-1, 0.99, -1)
        sun.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(sun)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .ambient
        fill.light!.intensity = 45
        fill.light!.color = UIColor(red: 0.55, green: 0.65, blue: 0.85, alpha: 1)
        scene.rootNode.addChildNode(fill)

        // The walker: a small bright point that the bloom turns into a glow.
        let walker = SCNNode(geometry: SCNSphere(radius: 5))
        let glow = SCNMaterial()
        glow.lightingModel = .constant
        glow.diffuse.contents = UIColor.white
        glow.emission.contents = UIColor.white
        glow.emission.intensity = 2
        walker.geometry!.firstMaterial = glow
        walker.position = scn(walk.point(at: 0))
        scene.rootNode.addChildNode(walker)

        let you = SCNNode(geometry: SCNSphere(radius: 6))
        let blue = SCNMaterial()
        blue.lightingModel = .constant
        blue.diffuse.contents = UIColor(red: 0.3, green: 0.62, blue: 1, alpha: 1)
        blue.emission.contents = UIColor(red: 0.3, green: 0.62, blue: 1, alpha: 1)
        blue.emission.intensity = 1.6
        you.geometry!.firstMaterial = blue
        you.isHidden = true
        scene.rootNode.addChildNode(you)

        var summit: WalkPeak?
        if let peak {
            let xy = projection.point(peak.position)
            let top = summitTop(peak, relief: relief, far: wide, hole: hole) ?? SIMD3(xy.x, xy.y, peak.elevation)
            let dot = SCNNode(geometry: SCNSphere(radius: 6))
            dot.geometry!.firstMaterial = glow
            dot.position = scn(top)
            scene.rootNode.addChildNode(dot)
            summit = WalkPeak(peak: peak, top: top, score: .infinity)
        }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = fieldOfView
        camera.camera!.zNear = 10
        camera.camera!.zFar = 70_000
        camera.camera!.automaticallyAdjustsZRange = false
        camera.camera!.wantsHDR = true
        camera.camera!.wantsExposureAdaptation = false
        // Only the walker and the summit, brighter than anything else, glow.
        camera.camera!.bloomIntensity = 1.2
        camera.camera!.bloomThreshold = 0.95
        camera.camera!.bloomBlurRadius = 10
        camera.camera!.vignettingIntensity = 0.35
        camera.camera!.vignettingPower = 0.8
        scene.rootNode.addChildNode(camera)

        // Straight down over the trail and summit, high enough to take them in on a phone held
        // upright (about half as wide as tall).
        let center = SIMD2(0.0, 0.0)
        let half = tan(fieldOfView / 2 * .pi / 180)
        let altitude = max(frame.width / 2 / (half * 0.46), frame.height / 2 / half) * 1.1
        let floor = relief.height(at: center)
        let overhead = (eye: SIMD3(center.x, center.y, (floor.isFinite ? floor : Double(high)) + altitude),
                        target: SIMD3(center.x, center.y, floor.isFinite ? floor : Double(low)))
        return WalkWorld(scene: scene, camera: camera, walker: walker, you: you, summit: summit, units: units, crests: crests,
                         walk: walk, relief: relief,
                         profile: profile, overhead: overhead, range: range, ground: ground.node, shades: ground.shades,
                         coverRevision: cover?.revision, ring: ring, far: wide, hole: hole)
    }

    /// Land cover on the sharp terrain's grid. It fades out toward the terrain's edge, where
    /// the coarser ring around it, untinted, takes over.
    private static func landCover(_ cover: AppModel.TrailCover, on relief: ReliefMap) -> LandCoverGrid? {
        cover.box.intersection(relief.box).map { relief.landCover(cover.areas, within: $0, fade: OverheadMap.coverFade) }
    }

    /// Tints the terrain with land cover that arrived after it was built.
    @MainActor func tint(with cover: AppModel.TrailCover) async {
        guard !draped, cover.revision != coverRevision, let old = ground.geometry else { return }
        coverRevision = cover.revision
        let relief = self.relief, shades = self.shades
        let colors = await Task.detached(priority: .userInitiated) {
            Self.colors(shades, cover: Self.landCover(cover, on: relief))
        }.value
        // Imagery may have been laid over it meanwhile; that stays.
        guard !draped, ground.geometry === old else { return }
        let geometry = SCNGeometry(sources: old.sources.filter { $0.semantic != .color } + [Self.colorSource(colors)],
                                   elements: old.elements)
        geometry.firstMaterial = old.firstMaterial
        ground.geometry = geometry
    }

    /// Where a terrain grid's corner points lie, map meters: what imagery laid over it covers.
    static func imageryRect(_ relief: ReliefMap) -> CGRect {
        CGRect(x: -relief.size.x / 2, y: -relief.size.y / 2, width: relief.size.x, height: relief.size.y)
    }

    /// Imagery for the sharp terrain, sharp enough for the walker's view up close (a few
    /// meters a pixel on most hikes).
    @MainActor func loadNearImagery() async -> MapImagery? {
        let rect = Self.imageryRect(relief)
        return try? await MapImagery.load(projection: relief.projection, rect: rect, width: Int(min(3_072, rect.width / 2)))
    }

    /// Imagery for the ring around it, out to the haze.
    @MainActor func loadFarImagery() async -> MapImagery? {
        try? await MapImagery.load(projection: far.projection, rect: Self.imageryRect(far), width: 1_536)
    }

    /// Whether `imagery` was made for the sharp terrain (`ring` false) or the ring.
    func fits(_ imagery: MapImagery, ring: Bool) -> Bool {
        let grid = ring ? far : relief
        return imagery.rect == Self.imageryRect(grid) && imagery.center == grid.projection.center
    }

    /// Lays satellite imagery over the terrain in place of its colors, still lit by the sun
    /// so the slopes keep their shape. Part of it lights itself, so slopes facing away from
    /// the sun stay readable (the imagery has its own shadows), and even white stays below
    /// the brightness that glows. The contours go; the crest lines fade, as on the map.
    /// Either part may come alone; nothing changes if the task is cancelled first.
    @MainActor func drape(near: MapImagery?, far ringImagery: MapImagery?) async {
        func material(_ image: CGImage) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .lambert
            material.diffuse.contents = image
            material.diffuse.mipFilter = .linear
            material.diffuse.maxAnisotropy = 16
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            // The shader sets how bright it is, and lays the sharper imagery near the walker
            // over it once that loads.
            material.emission.contents = UIColor.black
            material.shaderModifiers = [.surface: Self.drapeShader]
            Self.setDetail(nil, on: material)
            return material
        }
        var parts: [(node: SCNNode, picture: MapImagery, ring: Bool)] = []
        if !draped, let near, fits(near, ring: false) { parts.append((ground, near, false)) }
        if !ringDraped, let ringImagery, fits(ringImagery, ring: true) { parts.append((ring, ringImagery, true)) }
        for part in parts {
            guard let old = part.node.geometry, let vertices = old.sources(for: .vertex).first else { continue }
            let rect = part.picture.rect
            // From each vertex's place (SceneKit's x east, z south) to the picture's: u west
            // to east, v north to south.
            let coordinates = await Task.detached(priority: .userInitiated) {
                Self.textureCoordinates(vertices, rect: rect)
            }.value
            guard !Task.isCancelled, part.node.geometry === old, !(part.ring ? ringDraped : draped) else { return }
            let geometry = SCNGeometry(sources: old.sources.filter { $0.semantic != .color } + [coordinates], elements: old.elements)
            geometry.firstMaterial = material(part.picture.image)
            part.node.geometry = geometry
            if part.ring {
                ringDraped = true
            } else {
                draped = true
                crestStrength = 0.35
                // Daylight over the imagery: a night sky over a sunny photo reads as a void.
                if let sky = Self.daylightSky {
                    scene.background.contents = sky
                    let h = Self.daylightHaze
                    scene.fogColor = UIColor(red: h.x, green: h.y, blue: h.z, alpha: 1)
                    // Pale haze shows more than the dark one: keep the middle distance clear.
                    scene.fogDensityExponent = 1.8
                }
            }
        }
    }

    /// The haze starts a few kilometers out, and further while looking down from high up;
    /// `range` is how far the camera is from what it looks at.
    func haze(range: Double) {
        let start = max(3_000, range * 1.2)
        // Only when it changes, so a still scene isn't drawn again.
        guard abs(scene.fogStartDistance - start) > 1 else { return }
        scene.fogStartDistance = start
        scene.fogEndDistance = start + 21_000
    }

    // MARK: Sharper imagery near the walker

    /// One picture for the whole terrain is 3–9 m a pixel, a smear on the ground in front of
    /// the camera. A sharper one covers a square around the part of the walk in view, and
    /// follows it: four times as wide as the camera follows from, 1.6 to 3 km, so about 0.8 m
    /// a pixel on short hikes, where the camera comes closest, and 1.5 m on long ones.
    var detailSide: Double { min(3_000, max(1_600, 4 * range)) }
    static let detailPixels = 2_048
    /// Ahead of the walker while it walks, a sixth of the square, so it covers the ground ahead
    /// and still the ground below the camera, behind it; and how far the wanted square moves
    /// before it's loaded again.
    var detailLead: Double { detailSide / 6 }

    /// The sharper imagery shown, if any (changed on the main thread only).
    private(set) var detail: MapImagery?

    /// Lays the imagery, lit by the sun and partly lighting itself, so slopes facing away from
    /// the sun stay readable (the imagery has its own shadows); at most 0.48 × 1.4 (the sun)
    /// + 0.25 + a little ambient, under the 0.95 bloom, so even white doesn't glow. Within the
    /// detail square, the sharper imagery replaces it, blending in over its edges.
    static let drapeShader = """
    #pragma arguments
    texture2d<float> detailImage;
    float4 detailRect;
    float detailOn;
    #pragma body
    float4 world = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float2 uv = float2((world.x - detailRect.x) * detailRect.z, (world.z - detailRect.y) * detailRect.w);
    constexpr sampler detailSampler(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(16));
    float3 sharp = detailImage.sample(detailSampler, uv).rgb;
    float2 edge = min(uv, 1.0 - uv);
    float w = smoothstep(0.0, 0.08, min(edge.x, edge.y)) * detailOn;
    float3 color = mix(_surface.diffuse.rgb, sharp, w);
    _surface.diffuse = float4(color * 0.48, 1.0);
    _surface.emission = float4(color * 0.25, 1.0);
    """

    /// A placeholder for the shader's detail picture until one loads.
    private static let blank: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }.cgImage

    /// Binds `imagery` (or none) to a draped material's shader. The picture and where it lies
    /// change together.
    private static func setDetail(_ imagery: MapImagery?, on material: SCNMaterial) {
        guard let image = imagery?.image ?? blank else { return }
        let picture = SCNMaterialProperty(contents: image)
        picture.mipFilter = .linear
        picture.maxAnisotropy = 16
        picture.wrapS = .clamp
        picture.wrapT = .clamp
        material.setValue(picture, forKey: "detailImage")
        // From SceneKit's x (east) and z (south) to the picture's u and v, as for the base.
        let rect = imagery?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        material.setValue(NSValue(scnVector4: SCNVector4(Float(rect.minX), Float(-rect.maxY), Float(1 / rect.width), Float(1 / rect.height))),
                          forKey: "detailRect")
        material.setValue(imagery == nil ? 0.0 : 1.0, forKey: "detailOn")
    }

    /// Where the sharper imagery should be centered, map meters: ahead of the walker while it
    /// walks, on it while paused to look around.
    func detailCenter(at distance: Double, walking: Bool) -> SIMD2<Double> {
        let p = walk.point(at: min(walk.length, distance + (walking ? detailLead : 0)))
        return SIMD2(p.x, p.y)
    }

    /// Whether the imagery shown is too far from `center`, or there's none yet.
    func needsDetail(around center: SIMD2<Double>) -> Bool {
        guard let detail, detail.center == relief.projection.center, detail.rect.width == detailSide else { return true }
        return simd_distance(SIMD2(detail.rect.midX, detail.rect.midY), center) > detailLead
    }

    @MainActor func loadDetail(around center: SIMD2<Double>) async throws -> MapImagery {
        let side = detailSide
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        return try await MapImagery.load(projection: relief.projection, rect: rect, width: Self.detailPixels)
    }

    /// Shows sharper imagery made for this terrain, replacing what was shown before.
    @MainActor func show(detail imagery: MapImagery) {
        guard draped, imagery.center == relief.projection.center, let material = ground.geometry?.firstMaterial else { return }
        Self.setDetail(imagery, on: material)
        detail = imagery
    }

    // MARK: The hills around

    /// Where the scene is centered.
    var center: LatLon { far.projection.center }

    /// How fine the imagery over the hills around is: as coarse as Apple's aerial photos go,
    /// drawn a pixel a point, since the ring's own picture, coarser, is its greener mosaic.
    var midMetersPerPixel: Double { MapImagery.aerialMetersPerPoint(at: center.latitude) }

    /// Where the photos over the hills around go: past the sharp terrain out to where the haze
    /// thickens, 8 km beyond each of its edges, at most 3,072 pixels across. Nil where they
    /// wouldn't reach well past the sharp terrain once blended in over their own edges (8%).
    var midRect: CGRect? {
        let sharp = Self.imageryRect(relief).width
        let side = min(sharp + 16_000, 3_072 * midMetersPerPixel)
        guard side * (0.5 - 0.08) > sharp / 2 + 1_000 else { return nil }
        return CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
    }

    @MainActor func loadMidImagery(_ rect: CGRect) async -> MapImagery? {
        try? await MapImagery.load(projection: far.projection, rect: rect,
                                   width: min(3_072, Int((rect.width / midMetersPerPixel).rounded(.up))), scale: 1)
    }

    /// Whether the photos over the hills around are laid (changed on the main thread only).
    private(set) var midShown = false

    /// Lays the photos over the ring's coarse imagery, nearer the middle, blending into it over
    /// their edges.
    @MainActor func show(mid imagery: MapImagery) {
        guard ringDraped, !midShown, imagery.center == center, imagery.rect == midRect,
              let material = ring.geometry?.firstMaterial else { return }
        Self.setDetail(imagery, on: material)
        midShown = true
    }

    private static func textureCoordinates(_ vertices: SCNGeometrySource, rect: CGRect) -> SCNGeometrySource {
        let count = vertices.vectorCount, stride = vertices.dataStride, offset = vertices.dataOffset
        var uvs = [Float](repeating: 0, count: 2 * count)
        vertices.data.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = offset + i * stride
                let x = Double(raw.loadUnaligned(fromByteOffset: base, as: Float.self))
                let z = Double(raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
                uvs[2 * i] = Float((x - rect.minX) / rect.width)
                uvs[2 * i + 1] = Float((rect.maxY + z) / rect.height)
            }
        }
        return SCNGeometrySource(data: uvs.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .texcoord, vectorCount: count,
                                 usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4,
                                 dataOffset: 0, dataStride: 8)
    }

    /// Faint contour lines on the ground, every 50 m with a stronger one every 250 m, drawn
    /// per pixel from the height so they stay crisp at any distance. They fade out where they
    /// would crowd together: far away and on cliffs.
    static let contourShader = """
    #pragma body
    float4 world = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float h = world.y;
    float w = max(fwidth(h), 0.0001);
    float minorDistance = abs(fract(h / 50.0 + 0.5) - 0.5) * 50.0 / w;
    float majorDistance = abs(fract(h / 250.0 + 0.5) - 0.5) * 250.0 / w;
    float minor = (1.0 - smoothstep(0.35, 1.0, minorDistance)) * smoothstep(9.0, 22.0, 50.0 / w);
    float major = (1.0 - smoothstep(0.45, 1.3, majorDistance)) * smoothstep(7.0, 16.0, 250.0 / w);
    _surface.emission.rgb += float3(0.86, 0.94, 1.0) * max(minor * 0.018, major * 0.045);
    """

    /// What the terrain's colors are made from, per vertex: how light the bare ground is, and
    /// how much the ridges and hollows around it lighten or darken it.
    struct GroundShades: Sendable {
        var light: [Float]
        var form: [Float]
    }

    /// The terrain, lit by the sun and colored per point: lighter higher up, as from above;
    /// rock faces lighter than the gentle ground around them; spurs and ridges lighter and
    /// gullies darker, at two scales, which brings out the small shapes the light alone
    /// leaves flat; and tinted by `cover`. Squares inside `hole` are left out; `sink` lowers
    /// it all, in meters.
    private static func terrainNode(_ relief: ReliefMap, low: Float, high: Float, cover: LandCoverGrid? = nil,
                                    hole: (low: SIMD2<Double>, high: SIMD2<Double>)? = nil,
                                    sink: Float = 0) -> (node: SCNNode, shades: GroundShades) {
        let mesh = relief.mesh(hole: hole)
        // One vertex per grid point, in grid order, so these line up with the vertices.
        let fine = relief.relativeHeight(radius: max(90, 2 * relief.cellSize))
        let broad = relief.relativeHeight(radius: max(450, 4 * relief.cellSize))
        var positions = [Float](), normals = [Float]()
        var shades = GroundShades(light: [], form: [])
        positions.reserveCapacity(mesh.positions.count * 3)
        normals.reserveCapacity(mesh.positions.count * 3)
        shades.light.reserveCapacity(mesh.positions.count)
        shades.form.reserveCapacity(mesh.positions.count)
        for i in mesh.positions.indices {
            let p = mesh.positions[i], n = mesh.normals[i]
            positions.append(p.x); positions.append(p.z - sink); positions.append(-p.y)
            normals.append(n.x); normals.append(n.z); normals.append(-n.y)
            let shade = TrailTerrainStyle.shade(height: mesh.heights[i], normalUp: n.z,
                                                 fine: fine[i], broad: broad[i], range: low...high)
            shades.light.append(shade.light)
            shades.form.append(shade.form)
        }
        let count = mesh.positions.count
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic, vectorCount: count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: 12)
        }
        let geometry = SCNGeometry(sources: [source(positions, .vertex), source(normals, .normal),
                                             colorSource(colors(shades, cover: cover))],
                                   elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = UIColor.white
        material.emission.contents = UIColor.black
        material.shaderModifiers = [.surface: contourShader]
        geometry.firstMaterial = material
        return (SCNNode(geometry: geometry), shades)
    }

    /// The terrain's colors, three linear values a vertex: a slate that's faintly blue, and
    /// where there's land cover, bare rock and scree a touch lighter and cooler, glaciers pale
    /// blue-white (the ridges and hollows in the ice still showing), water dark blue.
    private static func colors(_ shades: GroundShades, cover: LandCoverGrid?) -> [Float] {
        var colors = [Float]()
        colors.reserveCapacity(shades.light.count * 3)
        for i in shades.light.indices {
            let c = TrailTerrainStyle.color(light: shades.light[i], form: shades.form[i],
                                             rock: cover?.rock[i] ?? 0, ice: cover?.glacier[i] ?? 0, water: cover?.water[i] ?? 0)
            colors.append(c.x); colors.append(c.y); colors.append(c.z)
        }
        return colors
    }

    private static func colorSource(_ colors: [Float]) -> SCNGeometrySource {
        SCNGeometrySource(data: colors.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: colors.count / 3,
                          usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    }

    /// The ridge crests as thin pale lines laid along them, brighter the more a ridge stands
    /// out, adding light to the terrain so they glow faintly through the haze. On the wide
    /// ring only the bigger ridges outside `outside` are drawn, wider, so they still show
    /// far off, along the horizon.
    private static func crestNodes(_ relief: ReliefMap,
                                   outside hole: (low: SIMD2<Double>, high: SIMD2<Double>)? = nil) -> [SCNNode] {
        let steps = OverheadMap.bandSteps
        var bands = [(positions: [Float], indices: [UInt32])](repeating: ([], []), count: steps.count)
        func inside(_ p: SIMD2<Double>) -> Bool {
            guard let hole else { return false }
            return p.x > hole.low.x && p.y > hole.low.y && p.x < hole.high.x && p.y < hole.high.y
        }
        for line in relief.crestLines(minLength: max(300, 10 * relief.cellSize)) {
            guard let k = steps.firstIndex(where: { line.relief >= $0.relief }), hole == nil || k <= 1 else { continue }
            let width = hole == nil ? 0.8 + 0.9 * Double(steps[k].width) : 0.25 * relief.cellSize * Double(steps[k].width)
            // The stretches outside the hole, each its own band.
            var runs: [[SIMD2<Double>]] = [[]]
            for p in line.points {
                if inside(p) {
                    if !runs[runs.count - 1].isEmpty { runs.append([]) }
                } else {
                    runs[runs.count - 1].append(p)
                }
            }
            for run in runs where run.count > 1 {
                let band = TrailWalk.ribbon(run, width: width, lift: hole == nil ? 4 : 10) { relief.height(at: $0) }
                let base = UInt32(bands[k].positions.count / 3)
                for p in band.positions { bands[k].positions += [p.x, p.z, -p.y] }
                bands[k].indices += band.indices.map { $0 + base }
            }
        }
        return bands.indices.compactMap { k in
            guard !bands[k].indices.isEmpty else { return nil }
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor(red: 0.86, green: 0.94, blue: 1.0, alpha: 1)
            material.transparency = steps[k].opacity * 0.45
            material.blendMode = .add
            material.writesToDepthBuffer = false
            material.isDoubleSided = true
            let node = SCNNode(geometry: geometry(bands[k].positions, bands[k].indices, material))
            node.renderingOrder = 5
            return node
        }
    }

    private static func geometry(_ positions: [Float], _ indices: [UInt32], _ material: SCNMaterial) -> SCNGeometry {
        let source = SCNGeometrySource(data: positions.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex,
                                       vectorCount: positions.count / 3, usesFloatComponents: true, componentsPerVector: 3,
                                       bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let geometry = SCNGeometry(sources: [source], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.firstMaterial = material
        return geometry
    }

    /// The trail as an orange band laid on the slope, and the same band glowing faintly
    /// through the terrain where a ridge hides it.
    private static func trailNodes(_ trail: Trail, _ relief: ReliefMap, width: Double) -> [SCNNode] {
        var positions = [Float](), indices = [UInt32]()
        for line in trail.densified(spacing: 10) where line.count > 1 {
            let xy = line.map { relief.projection.point($0) }
            let band = TrailWalk.ribbon(xy, width: width, lift: 2.5) { relief.height(at: $0) }
            let base = UInt32(positions.count / 3)
            for p in band.positions { positions += [p.x, p.z, -p.y] }
            indices += band.indices.map { $0 + base }
        }
        guard !indices.isEmpty else { return [] }
        let bright = SCNMaterial()
        bright.lightingModel = .constant
        bright.diffuse.contents = trailColor
        bright.isDoubleSided = true
        let seen = geometry(positions, indices, bright)

        let faint = SCNMaterial()
        faint.lightingModel = .constant
        faint.diffuse.contents = trailColor
        faint.transparency = 0.22
        faint.readsFromDepthBuffer = false
        faint.writesToDepthBuffer = false
        faint.isDoubleSided = true
        let hidden = geometry(positions, indices, faint)
        let behind = SCNNode(geometry: hidden)
        behind.renderingOrder = 10
        return [SCNNode(geometry: seen), behind]
    }
}

// MARK: - Playback

/// Moves the walker and the camera, once per screen refresh on the main thread.
@Observable
final class WalkPlayer {
    enum Mode {
        /// Tilting from straight above down behind the start.
        case intro(started: CFTimeInterval)
        /// Following the walker.
        case follow
        /// Paused: the camera is free to look around.
        case free
    }

    /// How far along the walk, meters, as shown (updated a few times a second).
    private(set) var shownDistance = 0.0
    private(set) var playing = false
    private(set) var ended = false

    @ObservationIgnored private var distance = 0.0
    @ObservationIgnored private var mode: Mode = .intro(started: 0)
    @ObservationIgnored private weak var view: SCNView?
    @ObservationIgnored private var world: WalkWorld?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var last: CFTimeInterval?
    @ObservationIgnored private var lastShown: CFTimeInterval = 0
    @ObservationIgnored private var eye = SIMD3<Double>(0, 0, 0)
    @ObservationIgnored private var target = SIMD3<Double>(0, 0, 0)
    /// Where a blend into following starts from, and when.
    @ObservationIgnored private var blend: (eye: SIMD3<Double>, target: SIMD3<Double>, up: SIMD3<Double>, started: CFTimeInterval)?
    /// Looking around while paused: where the camera is around the walker (degrees clockwise
    /// from north, degrees above level, meters), and how fast a flick still turns it (degrees
    /// a second, around and up).
    @ObservationIgnored private var orbit = (azimuth: 0.0, elevation: 20.0, distance: 600.0)
    @ObservationIgnored private var spin = SIMD2<Double>(0, 0)
    @ObservationIgnored private var gestures: Gestures?
    @ObservationIgnored private var labels: WalkLabels?
    /// The controls over the view, in window coordinates, which labels keep clear of.
    @ObservationIgnored var keepClear: [CGRect] = [] {
        didSet { labels?.keepClear = keepClear }
    }

    static let introSeconds = 2.8
    /// How far a drag of one point turns the camera, degrees.
    static let degreesPerPoint = 0.3

    /// Walking speed, meters per second: a short trail takes half a minute, a long one two.
    var speed: Double {
        guard let world else { return 100 }
        return world.walk.length / min(120, max(30, world.walk.length / 100))
    }

    func attach(_ view: SCNView, world: WalkWorld) {
        self.view = view
        self.world = world
        distance = 0
        shownDistance = 0
        eye = world.overhead.eye
        target = world.overhead.target
        place(eye: eye, target: target, up: SIMD3(0, 1, 0))
        mode = .intro(started: CACurrentMediaTime())
        playing = true
        ended = false
        view.allowsCameraControl = false
        if gestures == nil {
            // Paused, drag to look around the walker and pinch to come closer or go further.
            let gestures = Gestures(self)
            let pan = UIPanGestureRecognizer(target: gestures, action: #selector(Gestures.pan(_:)))
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: gestures, action: #selector(Gestures.pinch(_:))))
            self.gestures = gestures
        }
        if labels == nil {
            let labels = WalkLabels(frame: view.bounds)
            labels.keepClear = keepClear
            view.addSubview(labels)
            self.labels = labels
        }
        link?.invalidate()
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Sharper downloads replace the ground without restarting the walk or an orbit.
    func replaceWorld(_ world: WalkWorld, in view: SCNView) {
        guard let previous = self.world, previous !== world else { return }
        let fraction = distance / max(1, previous.walk.length)
        let pose = view.pointOfView?.presentation.simdWorldTransform
        self.world = world
        distance = min(world.walk.length, fraction * world.walk.length)
        shownDistance = distance
        view.scene = world.scene
        view.pointOfView = world.camera
        if let pose { world.camera.simdWorldTransform = pose }
        if case .free = mode { pointOrbit() }
        moveWalker()
    }

    func togglePlay() {
        guard let world else { return }
        if playing {
            pause()
        } else {
            if ended || distance >= world.walk.length - 1 { distance = 0 }
            ended = false
            playing = true
            startFollowing()
        }
    }

    /// Moves to a point along the walk (0 to 1), as the slider is dragged.
    func scrub(to fraction: Double) {
        guard let world else { return }
        distance = max(0, min(1, fraction)) * world.walk.length
        shownDistance = distance
        ended = false
        if case .intro = mode { mode = .follow }
        if case .free = mode {
            // Keep looking around from the new spot: the camera jumps to follow it.
            let pose = world.follow(at: distance)
            eye = pose.eye
            target = pose.target
            place(eye: eye, target: target, up: SIMD3(0, 0, 1))
            pointOrbit()
        }
        moveWalker()
    }

    private func pause() {
        playing = false
        mode = .free
        pointOrbit()
    }

    /// Lets the camera be dragged around the walker, from where it is. It turns to the walker
    /// on the first drag.
    private func pointOrbit() {
        guard let world else { return }
        // Scrubbing and rebuilding set the model pose immediately; the presentation pose
        // may still be the previous frame until SceneKit commits its transaction.
        let p = world.camera.simdWorldPosition
        let eye = SIMD3(Double(p.x), Double(-p.z), Double(p.y))
        let o = TrailWalk.orbitAngles(of: eye, around: world.walkerPosition(at: distance))
        orbit = (o.azimuth, min(89, max(-10, o.elevation)), min(Self.furthest, max(Self.closest, o.distance)))
        spin = .zero
    }

    /// Turns the camera around the walker by a drag, points: dragging right turns the ground
    /// right, dragging down lifts the camera to look down more.
    fileprivate func turn(by drag: SIMD2<Double>) {
        guard case .free = mode else { return }
        let previous = orbit
        spin = .zero
        orbit.azimuth = (orbit.azimuth + drag.x * Self.degreesPerPoint).truncatingRemainder(dividingBy: 360)
        orbit.elevation = min(89, max(-10, orbit.elevation + drag.y * Self.degreesPerPoint))
        orbitCamera(from: previous)
    }

    /// Keeps turning after a flick, slowing down, from its speed in points a second; not with
    /// Reduce Motion on, nor after a drag that was cancelled.
    fileprivate func coast(_ velocity: SIMD2<Double>) {
        guard case .free = mode, !UIAccessibility.isReduceMotionEnabled else { return }
        spin = velocity * Self.degreesPerPoint
    }

    fileprivate func stopCoasting() { spin = .zero }

    /// Brings the camera closer to the walker, or further, by a pinch's scale.
    fileprivate func zoom(by scale: Double) {
        guard case .free = mode, scale > 0 else { return }
        let previous = orbit
        spin = .zero
        orbit.distance = min(Self.furthest, max(Self.closest, orbit.distance / scale))
        orbitCamera(from: previous)
    }

    /// How close to the walker the camera comes, and how far it goes, looking around, meters.
    static let closest = 60.0
    static let furthest = 20_000.0

    /// Puts the camera where `orbit` says, looking at the walker. Swung toward a slope, it
    /// stops at the lowest angle where it's over the ground and sees the walker over what's in
    /// between, as following does, rather than going into the hill; a flick stops sinking there.
    /// Where no angle is clear, it stays where it was.
    private func orbitCamera(from previous: (azimuth: Double, elevation: Double, distance: Double)? = nil) {
        guard let world else { return }
        let walker = world.walkerPosition(at: distance)
        guard let lowest = TrailWalk.lowestClearElevation(around: walker, azimuth: orbit.azimuth, distance: orbit.distance,
                                                          from: orbit.elevation, isClear: { world.isClear($0, seeing: walker) }) else {
            if let previous { orbit = previous }
            spin = .zero
            return
        }
        if lowest > orbit.elevation {
            orbit.elevation = lowest
            spin.y = max(0, spin.y)
        }
        let eye = TrailWalk.orbit(around: walker, azimuth: orbit.azimuth, elevation: orbit.elevation, distance: orbit.distance)
        place(eye: eye, target: walker, up: SIMD3(0, 0, 1))
    }

    private func startFollowing() {
        guard let view, let world else { return }
        view.allowsCameraControl = false
        // Blend from wherever the camera was left into following.
        let node = view.pointOfView ?? world.camera
        let p = node.presentation.simdWorldPosition, f = node.presentation.simdWorldFront, u = node.presentation.simdWorldUp
        let from = SIMD3(Double(p.x), Double(-p.z), Double(p.y))
        let ahead = from + 300 * SIMD3(Double(f.x), Double(-f.z), Double(f.y))
        blend = (from, ahead, SIMD3(Double(u.x), Double(-u.z), Double(u.y)), CACurrentMediaTime())
        view.pointOfView = world.camera
        mode = .follow
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let world else { return }
        let now = link.timestamp
        let dt = min(0.1, last.map { now - $0 } ?? 0)
        last = now
        switch mode {
        case let .intro(started):
            let t = min(1, (now - started) / Self.introSeconds)
            let s = t * t * (3 - 2 * t)
            let end = world.follow(at: 0)
            // Rise a little on the way, so the tilt sweeps rather than dives.
            let lift = sin(s * .pi) * 0.15 * (world.overhead.eye.z - end.eye.z)
            eye = mix(world.overhead.eye, end.eye, s) + SIMD3(0, 0, lift)
            target = mix(world.overhead.target, end.target, s)
            place(eye: eye, target: target, up: mix(SIMD3(0, 1, 0), SIMD3(0, 0, 1), s))
            if t >= 1 { mode = .follow }
        case .follow:
            if playing {
                distance += speed * dt
                if distance >= world.walk.length {
                    distance = world.walk.length
                    playing = false
                    ended = true
                }
            }
            let goal = world.follow(at: distance)
            // Ease toward where the camera should be, so turns in the trail are smooth.
            let k = 1 - exp(-dt / 0.35)
            eye += (goal.eye - eye) * k
            target += (goal.target - target) * k
            if let b = blend {
                let t = min(1, (now - b.started) / 1.0), s = t * t * (3 - 2 * t)
                place(eye: mix(b.eye, eye, s), target: mix(b.target, target, s), up: mix(b.up, SIMD3(0, 0, 1), s))
                if t >= 1 { blend = nil }
            } else {
                place(eye: eye, target: target, up: SIMD3(0, 0, 1))
            }
            if ended {
                mode = .free
                pointOrbit()
            }
        case .free:
            if spin != .zero {
                let previous = orbit
                orbit.azimuth = (orbit.azimuth + spin.x * dt).truncatingRemainder(dividingBy: 360)
                orbit.elevation = min(89, max(-10, orbit.elevation + spin.y * dt))
                spin *= exp(-dt / 0.3)
                if (spin * spin).sum() < 1 { spin = .zero }
                orbitCamera(from: previous)
            }
        }
        moveWalker()
        if let pov = view?.pointOfView?.presentation {
            // The crest lines show the ridges on ground seen from above. Looking along it,
            // toward the horizon, the light and the skyline show them already, and the lines
            // only crowd the trail; they fade out between 55° and 30° down.
            let down = Double(asin(max(-1, min(1, -pov.simdWorldFront.y)))) * 180 / .pi
            let t = min(1, max(0, (down - 30) / 25))
            let opacity = CGFloat(t * t * (3 - 2 * t)) * world.crestStrength
            // Only what changed is set, so a still scene isn't drawn again.
            if abs(world.crests.opacity - opacity) > 1e-3 { world.crests.opacity = opacity }
            if world.crests.isHidden != (opacity < 0.01) { world.crests.isHidden = opacity < 0.01 }
        }
        let p = world.camera.simdWorldPosition
        labels?.update(world: world, eye: SIMD3(Double(p.x), Double(-p.z), Double(p.y)), now: now)
        if now - lastShown > 0.08 || !playing {
            lastShown = now
            if abs(shownDistance - distance) > 0.5 { shownDistance = distance }
        }
    }

    private func moveWalker() {
        guard let world else { return }
        let position = WalkWorld.scn(world.walkerPosition(at: distance))
        if !SCNVector3EqualToVector3(world.walker.position, position) { world.walker.position = position }
    }

    /// Puts the camera at `eye` looking at `target`, map meters, with `up` (map axes) up.
    private func place(eye: SIMD3<Double>, target: SIMD3<Double>, up: SIMD3<Double>) {
        guard let world else { return }
        world.camera.position = WalkWorld.scn(eye)
        world.camera.look(at: WalkWorld.scn(target), up: WalkWorld.scn(up), localFront: SCNVector3(0, 0, -1))
        world.haze(range: simd_distance(eye, target))
    }

    private func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }

    /// Holds the player weakly, since a display link holds its target.
    private final class Ticker: NSObject {
        weak var player: WalkPlayer?
        init(_ player: WalkPlayer) { self.player = player }
        @objc func tick(_ link: CADisplayLink) {
            guard let player else { return link.invalidate() }
            player.tick(link)
        }
    }

    /// Hands the look-around gestures to the player, which it holds weakly: the player keeps
    /// this, since a gesture doesn't keep its target.
    private final class Gestures: NSObject {
        weak var player: WalkPlayer?
        init(_ player: WalkPlayer) { self.player = player }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let player else { return }
            switch gesture.state {
            case .began, .changed:
                let t = gesture.translation(in: gesture.view)
                gesture.setTranslation(.zero, in: gesture.view)
                player.turn(by: SIMD2(Double(t.x), Double(t.y)))
            case .ended:
                let v = gesture.velocity(in: gesture.view)
                player.coast(SIMD2(Double(v.x), Double(v.y)))
            default:
                player.stopCoasting()
            }
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard let player, gesture.state == .began || gesture.state == .changed else { return }
            player.zoom(by: Double(gesture.scale))
            gesture.scale = 1
        }
    }
}

/// The SceneKit view.
private struct WalkSceneView: UIViewRepresentable {
    let world: WalkWorld
    let player: WalkPlayer
    let you: LatLon?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.backgroundColor = WalkWorld.background
        view.antialiasingMode = .multisampling4X
        // Drawn when something moves: the walk, or the camera dragged around. Paused and
        // left alone, it rests.
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 60
        view.scene = world.scene
        view.pointOfView = world.camera
        player.attach(view, world: world)
        world.place(you: you)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        player.replaceWorld(world, in: view)
        world.place(you: you)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: ()) {
        view.scene = nil
    }
}

// MARK: - Controls

/// The trail's name, how far along and how high, and the way back to the map.
private struct WalkChip: View {
    let model: AppModel
    let trail: AppModel.ARTrail
    let world: WalkWorld?
    let player: WalkPlayer
    let onClose: () -> Void

    var body: some View {
        let units = model.settings.units
        HStack(spacing: 10) {
            Image(systemName: "figure.hiking")
                .foregroundStyle(TrailFromAboveView.trailColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(trail.trail.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail(units))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "map")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
                    // A full target around the smaller circle: a button takes taps only
                    // within its label's frame. The chip's padding makes up for it, so the
                    // circle sits where it did.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to the view from above")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.vertical, 1)
        .frame(maxWidth: 420)
        .glassBackground(in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func detail(_ units: AppSettings.Units) -> String {
        guard let world else { return "Building the terrain…" }
        let d = player.shownDistance
        var parts = ["\(Format.distance(d, units)) of \(Format.distance(world.walk.length, units))"]
        let z = world.walk.point(at: d).z
        if z.isFinite { parts.append(Format.elevation(z, units)) }
        return parts.joined(separator: " · ")
    }
}

/// Play or pause, and a slider along the trail.
private struct WalkControls: View {
    let world: WalkWorld
    let player: WalkPlayer
    let draped: Bool
    /// Some of the ground is USGS 3DEP's, to credit.
    let usgs: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                RoundButton(systemImage: player.playing ? "pause.fill" : player.ended ? "arrow.counterclockwise" : "play.fill",
                            label: player.playing ? "Pause" : player.ended ? "Walk it again" : "Walk on") {
                    player.togglePlay()
                }
                Slider(value: Binding(get: { player.shownDistance / max(1, world.walk.length) },
                                      set: { player.scrub(to: $0) }))
                    .tint(TrailFromAboveView.trailColor)
                    .accessibilityLabel("Along the trail")
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .glassBackground(in: Capsule())
            .environment(\.colorScheme, .dark)
            Text(player.playing ? " " : "Drag to look around")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Text((draped ? "Imagery © Apple Maps · " : "") + "Terrain © Copernicus DEM (DLR, Airbus)" + (usgs ? ", USGS 3DEP" : "") +
                 " · Map data © OpenStreetMap contributors")
                .font(.system(size: 9))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(draped ? 0.7 : 0.45))
        }
    }
}

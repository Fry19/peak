import PeakCore
import SceneKit
import SwiftUI
import UIKit

/// The trail in 3D: the terrain around it lit from the north-west, far ridges fading into
/// haze, and the trail in orange. It opens looking straight down, as the map does, with the
/// ridge crests glowing faintly, then tilts down behind the start, the crests fading as it
/// nears the horizon, and walks the trail to its end.
/// Pause to look around (drag to orbit, pinch to zoom); the slider moves along the trail.
/// Drawn from the terrain already on the phone, so it works offline.
struct TrailWalkView: View {
    let model: AppModel
    let trail: AppModel.ARTrail
    let onClose: () -> Void

    @State private var world: WalkWorld?
    @State private var player = WalkPlayer()
    @State private var failed = false

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
            VStack(spacing: 0) {
                WalkChip(model: model, trail: trail, world: world, player: player, onClose: onClose)
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                Spacer()
                if let world {
                    WalkControls(world: world, player: player)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .task(id: trail.trail.id) { await build() }
        .onDisappear { player.stop() }
    }

    private func build() async {
        guard let terrain = model.scene?.terrain else {
            failed = true
            return
        }
        let route = trail.trail, peak = model.peak(trail.peakID), units = model.settings.units
        let built = await Task.detached(priority: .userInitiated) {
            WalkWorld.build(trail: route, peak: peak, terrain: terrain, units: units)
        }.value
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            world = built
            failed = built == nil
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
    let label: SCNNode?
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

    private init(scene: SCNScene, camera: SCNNode, walker: SCNNode, you: SCNNode, label: SCNNode?, crests: SCNNode, walk: TrailWalk,
                 relief: ReliefMap, profile: TrailProfile?, overhead: (eye: SIMD3<Double>, target: SIMD3<Double>), range: Double) {
        self.scene = scene
        self.camera = camera
        self.walker = walker
        self.you = you
        self.label = label
        self.crests = crests
        self.walk = walk
        self.relief = relief
        self.profile = profile
        self.overhead = overhead
        self.range = range
    }

    static let background = UIColor(red: 0.035, green: 0.043, blue: 0.058, alpha: 1)
    /// The sky, and the haze far terrain fades into.
    static let haze = UIColor(red: 0.055, green: 0.066, blue: 0.09, alpha: 1)
    static let trailColor = UIColor(Color.amber)
    /// Vertical field of view, degrees.
    static let fieldOfView = 62.0

    static func scn(_ p: SIMD3<Double>) -> SCNVector3 { SCNVector3(Float(p.x), Float(p.z), Float(-p.y)) }

    /// The ground's height at a map position, meters.
    func ground(_ p: SIMD2<Double>) -> Double { relief.height(at: p) }

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

    static func build(trail: Trail, peak: Peak?, terrain: Terrain, units: AppSettings.Units) -> WalkWorld? {
        guard let frame = OverheadMap.frame(trail: trail, around: peak.map { [$0.position] } ?? [], aspect: 0.46) else { return nil }
        // The trail with a few kilometers around it at the terrain's own 30 m where it can,
        // and around that a wide, coarser ring out to where the haze swallows it, so a view
        // toward the horizon shows the ranges beyond instead of the terrain's edge.
        let side = min(26_000, max(10_000, max(frame.width, frame.height) + 6_000))
        let relief = ReliefMap(terrain: terrain, extent: MapExtent(center: frame.center, width: side, height: side),
                               cellSize: max(30, side / 640))
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
        scene.rootNode.addChildNode(terrainNode(relief, low: low, high: high))
        scene.rootNode.addChildNode(terrainNode(wide, low: low, high: high, hole: hole, sink: 15))
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

        var label: SCNNode?
        if let peak {
            let xy = projection.point(peak.position)
            let ground = relief.height(at: xy)
            let top = SIMD3(xy.x, xy.y, max(peak.elevation, ground.isFinite ? ground : peak.elevation))
            let dot = SCNNode(geometry: SCNSphere(radius: 6))
            dot.geometry!.firstMaterial = glow
            dot.position = scn(top)
            scene.rootNode.addChildNode(dot)
            label = labelNode(peak, at: top, units: units)
            if let label { scene.rootNode.addChildNode(label) }
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
        return WalkWorld(scene: scene, camera: camera, walker: walker, you: you, label: label, crests: crests, walk: walk, relief: relief,
                         profile: profile, overhead: overhead, range: range)
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

    /// The terrain, lit by the sun and colored per point: lighter higher up, as from above;
    /// rock faces lighter than the gentle ground around them; spurs and ridges lighter and
    /// gullies darker, at two scales, which brings out the small shapes the light alone
    /// leaves flat. Squares inside `hole` are left out; `sink` lowers it all, in meters.
    private static func terrainNode(_ relief: ReliefMap, low: Float, high: Float,
                                    hole: (low: SIMD2<Double>, high: SIMD2<Double>)? = nil, sink: Float = 0) -> SCNNode {
        let mesh = relief.mesh(hole: hole)
        // One vertex per grid point, in grid order, so these line up with the vertices.
        let fine = relief.relativeHeight(radius: max(90, 2 * relief.cellSize))
        let broad = relief.relativeHeight(radius: max(450, 4 * relief.cellSize))
        var positions = [Float](), normals = [Float](), colors = [Float]()
        positions.reserveCapacity(mesh.positions.count * 3)
        normals.reserveCapacity(mesh.positions.count * 3)
        colors.reserveCapacity(mesh.positions.count * 3)
        let range = max(1, high - low)
        for i in mesh.positions.indices {
            let p = mesh.positions[i], n = mesh.normals[i]
            positions.append(p.x); positions.append(p.z - sink); positions.append(-p.y)
            normals.append(n.x); normals.append(n.z); normals.append(-n.y)
            // Linear values (SceneKit lights in linear color): dark slate low down.
            let t = pow(min(1, max(0, (mesh.heights[i] - low) / range)), 1.3)
            var v = 0.016 + 0.10 * t
            // Steeper than about 35°: bare rock, which catches more light.
            let steep = min(1, max(0, (0.82 - n.z) / 0.22))
            v *= 1 + 0.7 * steep
            let f = fine[i].isFinite ? fine[i] : 0, b = broad[i].isFinite ? broad[i] : 0
            let form = 0.4 * min(1, max(-1, f / 25)) + 0.3 * min(1, max(-1, b / 120))
            v *= max(0.3, 1 + form)
            colors.append(v); colors.append(v * 1.12); colors.append(v * 1.45)
        }
        let count = mesh.positions.count
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic, vectorCount: count,
                              usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: 4 * components)
        }
        let geometry = SCNGeometry(sources: [source(positions, .vertex, 3), source(normals, .normal, 3),
                                             source(colors, .color, 3)],
                                   elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = UIColor.white
        material.emission.contents = UIColor.black
        material.shaderModifiers = [.surface: contourShader]
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
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

    /// The summit's name and elevation on a card that always faces the camera.
    private static func labelNode(_ peak: Peak, at top: SIMD3<Double>, units: AppSettings.Units) -> SCNNode? {
        let name = peak.name as NSString, elevation = Format.elevation(of: peak, units) as NSString
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 6
        let big: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44, weight: .semibold),
                                                  .foregroundColor: UIColor.white, .shadow: shadow]
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 32),
                                                    .foregroundColor: UIColor.white.withAlphaComponent(0.75), .shadow: shadow]
        let w = max(name.size(withAttributes: big).width, elevation.size(withAttributes: small).width) + 24
        let size = CGSize(width: ceil(w), height: 104)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            name.draw(at: CGPoint(x: 12, y: 4), withAttributes: big)
            elevation.draw(at: CGPoint(x: 12, y: 58), withAttributes: small)
        }
        let plane = SCNPlane(width: size.width / size.height, height: 1)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.firstMaterial = material
        let card = SCNNode(geometry: plane)
        // Its left edge just right of the summit, and a little above it.
        card.pivot = SCNMatrix4MakeTranslation(Float(-size.width / size.height / 2) - 0.25, -0.7, 0)
        card.position = scn(top)
        card.constraints = [SCNBillboardConstraint()]
        card.renderingOrder = 20
        return card
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

    static let introSeconds = 2.8

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
            place(eye: eye, target: target, up: SIMD3(0, 1, 0))
            pointOrbit()
        }
        moveWalker()
    }

    private func pause() {
        playing = false
        mode = .free
        pointOrbit()
    }

    /// Lets the camera be dragged around the walker.
    private func pointOrbit() {
        guard let view, let world else { return }
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        view.defaultCameraController.target = WalkWorld.scn(world.walkerPosition(at: distance))
        view.defaultCameraController.inertiaEnabled = true
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
            break
        }
        moveWalker()
        if let pov = view?.pointOfView?.presentation {
            // Keep the summit's card the same size on screen.
            if let label = world.label {
                let d = Double(simd_distance(label.simdWorldPosition, pov.simdWorldPosition))
                let s = Float(d * 0.05)
                if abs(label.scale.x - s) > s * 1e-4 { label.scale = SCNVector3(s, s, s) }
            }
            // The crest lines show the ridges on ground seen from above. Looking along it,
            // toward the horizon, the light and the skyline show them already, and the lines
            // only crowd the trail; they fade out between 55° and 30° down.
            let down = Double(asin(max(-1, min(1, -pov.simdWorldFront.y)))) * 180 / .pi
            let t = min(1, max(0, (down - 30) / 25))
            let opacity = CGFloat(t * t * (3 - 2 * t))
            // Only what changed is set, so a still scene isn't drawn again.
            if abs(world.crests.opacity - opacity) > 1e-3 { world.crests.opacity = opacity }
            if world.crests.isHidden != (opacity < 0.01) { world.crests.isHidden = opacity < 0.01 }
        }
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
        // The haze starts a few kilometers out, and further while looking down from high up.
        let range = simd_distance(eye, target)
        world.scene.fogStartDistance = max(3_000, range * 1.2)
        world.scene.fogEndDistance = world.scene.fogStartDistance + 21_000
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
            }
            .accessibilityLabel("Back to the view from above")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
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
            Text("Terrain © Copernicus DEM (DLR, Airbus) · Map data © OpenStreetMap contributors")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

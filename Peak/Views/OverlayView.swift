import PeakCore
import SwiftUI
import UIKit

/// Thin glowing ridgelines, nearer ones brighter and farther ones fading like haze, a few
/// labels for the most prominent visible peaks, and a trail laid on the mountain. Laid out
/// for the frame on screen, with the phone's pose from the moment that frame was taken.
///
/// Nothing is drawn on the CPU each frame: the lines go to the GPU (Metal, with shape
/// layers as a fallback), and each label is drawn once into an image that is then only
/// moved. Laying them out takes about a millisecond, so the main thread stays free.
final class OverlayCanvas: UIView {
    weak var model: AppModel?
    weak var screen: CameraScreenView?
    private var link: CADisplayLink?
    /// Nothing is laid out (and nothing ticks) while a full-screen view covers the camera.
    var paused = false {
        didSet {
            link?.isPaused = paused
            if !paused { needsUpdate = true }
        }
    }
    private var needsUpdate = true
    private var smoothed: ViewCorrection?
    private var lastUpdate = Date()
    private var crossing = CenterCrossing()
    private var lastTick = Date.distantPast
    private var lastPrepare = Date.distantPast
    /// The heading correction last frame, to tell its moves from the phone's.
    private var lastCorrectionHeading: Double?
    private let haptics = UISelectionFeedbackGenerator()
    /// Peaks labeled last frame, which the next layout favors.
    private var labeled: Set<Int64> = []
    /// Frames of the controls over the view (the chips at the top, the buttons at the
    /// bottom), in window coordinates, which labels keep clear of.
    var keepClear: [CGRect] = [] {
        didSet { if keepClear != oldValue { needsUpdate = true } }
    }
    /// Where each label was placed, and the dots of peaks without one, for taps.
    private var labelHits: [(rect: CGRect, id: Int64)] = []
    private var dots: [(point: CGPoint, id: Int64)] = []
    /// The last layout's focal length in points, and which way is up in the world on
    /// screen (radians clockwise from the screen's up), for lining up by hand.
    private(set) var lastFocal: Double?
    private(set) var upAngle: CGFloat = 0

    /// Distance bands: (farthest distance in meters, opacity).
    private static let bands: [(Float, CGFloat)] = [(3_000, 0.95), (10_000, 0.75), (30_000, 0.55), (.infinity, 0.35)]
    private static let tint = UIColor(red: 0.86, green: 0.94, blue: 1.0, alpha: 1)
    private static let trailColor = UIColor(Color.amber)
    private static let accent = UIColor(red: 1.0, green: 0.84, blue: 0.45, alpha: 1)

    // Under each line a wide faint stroke makes the glow (cheaper than a blurred shadow).
    private let bandGlow = OverlayCanvas.bands.map { OverlayCanvas.stroke(OverlayCanvas.tint.withAlphaComponent($0.1 * 0.18), width: 4) }
    private let bandLine = OverlayCanvas.bands.map { OverlayCanvas.stroke(OverlayCanvas.tint.withAlphaComponent($0.1), width: 1) }
    private let skyGlow = OverlayCanvas.stroke(OverlayCanvas.tint.withAlphaComponent(0.3), width: 5)
    private let skyLine = OverlayCanvas.stroke(UIColor.white.withAlphaComponent(0.95), width: 1.4)
    private let trailGlow = OverlayCanvas.stroke(OverlayCanvas.trailColor.withAlphaComponent(0.3), width: 8)
    private let trailLine = OverlayCanvas.stroke(OverlayCanvas.trailColor, width: 2.5)
    private let hiddenTrailLine = OverlayCanvas.stroke(OverlayCanvas.trailColor.withAlphaComponent(0.6), width: 1.8)
    /// The part of the trail you've walked, and where you are on it, without Metal.
    private let walkedTrailLine = OverlayCanvas.stroke(OverlayCanvas.trailColor.withAlphaComponent(0.32), width: 2)
    private let youLayer = OverlayCanvas.stroke(UIColor.white.withAlphaComponent(0.85), width: 1.5)
    /// Today's sun path, without Metal.
    private let sunLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = UIColor(red: 1, green: 0.86, blue: 0.5, alpha: 0.7).cgColor
        l.strokeColor = UIColor(red: 1, green: 0.86, blue: 0.5, alpha: 0.8).cgColor
        l.lineWidth = 1.2
        return l
    }()
    /// The sun path's hour numbers, reused frame to frame.
    private let hourContainer = CALayer()
    private var hourLayers: [CATextLayer] = []
    private let dotLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = UIColor.white.withAlphaComponent(0.55).cgColor
        l.strokeColor = nil
        return l
    }()
    /// Risen above the ridges (`AppModel+Rise`), the camera picture can't come too: a plain
    /// night sky covers it, with the land below the skyline darker.
    private let backdrop: CALayer = {
        let l = CALayer()
        l.backgroundColor = OverlayCanvas.sky.cgColor
        l.opacity = 0
        return l
    }()
    private let landLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = OverlayCanvas.land.cgColor
        l.strokeColor = nil
        return l
    }()
    private var backdropShown = false
    /// The backdrop is still fading out until then, so the land is still drawn.
    private var backdropFading = Date.distantPast
    private static let sky = UIColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1)
    private static let land = UIColor(red: 0.02, green: 0.025, blue: 0.035, alpha: 1)
    /// The terrain in 3D under the view from above (`PanoramaMesh`): slopes from a dark slate
    /// away from the light to a pale one toward it, fading into the sky with distance.
    private static let terrainDark = SIMD3<Float>(0.045, 0.055, 0.075)
    private static let terrainLight = SIMD3<Float>(0.34, 0.39, 0.46)
    private static let terrainHaze: Float = 35_000
    /// How much the terrain in 3D shows, fading with the backdrop, and the height it was last
    /// seen from, for fading out from there.
    private var terrainOpacity: Float = 0
    private var terrainLift: Float = 0
    private var lastTerrainFrame = Date()
    /// Peaks in sight only from above, without Metal: open rings.
    private let revealedDotLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = nil
        l.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        l.lineWidth = 1
        return l
    }()
    /// Draws the lines on the GPU; nil if Metal isn't available, and the shape layers do.
    private let renderer = LineRenderer()
    /// Ridgelines (and the trail's glow), drawn brightest-of, and the trail and dots laid
    /// over them.
    private var lineSegments: [LineSegment] = []
    private var overlaySegments: [LineSegment] = []
    var drawsWithMetal: Bool { renderer != nil }

    /// Pixels per point; before the view is on screen the trait collection doesn't know yet.
    private var displayScale: CGFloat {
        let s = traitCollection.displayScale
        return s > 0 ? s : (window?.windowScene?.screen.scale ?? 3)
    }
    /// Line segments sent to the GPU for the last frame, for diagnostics.
    var segmentCount: Int { lineSegments.count + overlaySegments.count }
    private let labelContainer = CALayer()
    /// A peak's label layer: kept while it fades out, so labels come and go softly.
    private struct Slot {
        var layer: CALayer
        /// The image it shows, so an unchanged one isn't set again.
        var image: ObjectIdentifier?
        var shown = false
        var lastShown = Date()
    }
    private var slots: [Int64: Slot] = [:]
    private static let fade: CFTimeInterval = 0.15
    private let arrowLayer = CALayer()
    /// The chevron beside the edge tag, pointing at the selected peak.
    private let arrowHead: CAShapeLayer = {
        let l = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -3.5, y: -6))
        path.addLine(to: CGPoint(x: 3, y: 0))
        path.addLine(to: CGPoint(x: -3.5, y: 6))
        l.path = path
        l.strokeColor = OverlayCanvas.accent.cgColor
        l.fillColor = nil
        l.lineWidth = 2.2
        l.lineCap = .round
        l.lineJoin = .round
        l.shadowColor = UIColor.black.cgColor
        l.shadowOpacity = 0.6
        l.shadowRadius = 2
        l.shadowOffset = .zero
        return l
    }()

    /// A label drawn once: the image, where the peak's dot is in it, and the part to tap
    /// (relative to the dot).
    private struct LabelImage {
        var image: CGImage
        var size: CGSize
        var anchor: CGPoint
        var box: CGRect
    }
    /// Which label image: drawn once per peak, units and look, and kept while used.
    private struct LabelKey: Hashable {
        var id: Int64
        var units: AppSettings.Units
        var selected: Bool
        var hidden: Bool
        var below: Bool
        /// In sight only from above: its leader is dashed, as a hidden peak's.
        var revealed = false
    }
    private var images: [LabelKey: (image: LabelImage, used: Int)] = [:]
    private var imageClock = 0
    private static let imageCapacity = 200
    private var arrowImage: (key: String, image: LabelImage)?

    private static func stroke(_ color: UIColor, width: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.strokeColor = color.cgColor
        l.fillColor = nil
        l.lineWidth = width
        l.lineCap = .round
        l.lineJoin = .round
        return l
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // The backdrop when risen, ridges, the skyline over them, then the trail, dots and
        // labels on top.
        backdrop.addSublayer(landLayer)
        layer.addSublayer(backdrop)
        if let renderer {
            layer.addSublayer(renderer.layer)
        } else {
            for l in bandGlow + bandLine + [skyGlow, skyLine, hiddenTrailLine, walkedTrailLine, trailGlow, trailLine, youLayer, sunLayer, dotLayer, revealedDotLayer] { layer.addSublayer(l) }
        }
        layer.addSublayer(hourContainer)
        layer.addSublayer(labelContainer)
        layer.addSublayer(arrowLayer)
        layer.addSublayer(arrowHead)
        arrowHead.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The edge arrow is sized and placed by `update`; giving it the view's frame would
        // stretch its picture across the whole screen.
        for l in layer.sublayers ?? [] where l !== arrowLayer && l !== arrowHead { l.frame = bounds }
        landLayer.frame = backdrop.bounds
        renderer?.resize(to: bounds.size, scale: displayScale)
        CATransaction.commit()
        needsUpdate = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        if window != nil {
            // New frames update the overlay as they arrive; this catches everything else
            // (pinching, settings, the view paused or the camera not running yet). The link
            // holds its target until invalidated.
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            link.isPaused = paused
            self.link = link
        }
    }

    @objc private func tick() {
        if needsUpdate || Date().timeIntervalSince(screen?.lastFrameDate ?? .distantPast) > 0.1 { update() }
    }

    /// Lays the overlay out again at the next screen refresh.
    func setNeedsUpdate() {
        needsUpdate = true
    }

    /// The peak whose label or dot is at `point`, if any: a label first, else the nearest
    /// dot within reach of a finger.
    func peak(at point: CGPoint) -> Int64? {
        if let hit = labelHits.first(where: { $0.rect.insetBy(dx: -12, dy: -12).contains(point) }) { return hit.id }
        let near = dots.map { (d: hypot($0.point.x - point.x, $0.point.y - point.y), id: $0.id) }.min { $0.d < $1.d }
        return near.flatMap { $0.d < 28 ? $0.id : nil }
    }

    /// Lays everything out for the frame on screen now.
    func update() {
        guard !paused else { return }
        needsUpdate = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        labelHits = []
        // From above while the rise button is held, else the live view.
        guard let model, let scene = model.shownScene, bounds.width > 0 else {
            clear()
            return
        }
        let risen = model.risenView
        let frozen = model.frozen
        let now = Date()
        let shown = frozen?.shown ?? screen?.shown ?? fallbackShown(model)
        guard let pose = frozen?.pose ?? model.motion.pose(at: shown.time) ?? model.motion.pose else {
            clear()
            return
        }
        // The lens's offset changes with the picture when the lens switches, so it isn't eased.
        let correction = frozen?.correction
            ?? smoothedCorrection(model.viewCorrection(for: pose), zoom: model.zoom, at: now) + model.lensOffset(shown.lens, pose: pose)
        if frozen != nil { smoothed = correction }
        let correctionTurn = lastCorrectionHeading.map { azimuthDifference(correction.heading, $0) } ?? 0
        lastCorrectionHeading = correction.heading
        let orientation = screen?.interfaceOrientation ?? .portrait
        var camera = CameraGeometry.screenCamera(pose: pose, lens: shown.lens, portraitFrame: shown.portrait,
                                                 orientation: orientation, size: bounds.size, correction: correction)
        camera.intrinsics = camera.intrinsics.zoomed(by: model.screenZoom(for: shown))
        let projector = camera.projector
        let settings = model.settings
        // Labels stand upright in the world, whichever way the phone is held and even with
        // the screen's rotation locked.
        let axes = camera.attitude.axes
        upAngle = CGFloat(atan2(axes.right.z, -axes.down.z))
        lastFocal = camera.intrinsics.fx

        // How far around the view direction anything can be on screen, in azimuth: the
        // view's half-diagonal, widened toward the zenith where azimuths crowd together.
        let half = atan(Double(hypot(bounds.width, bounds.height)) / 2 / camera.intrinsics.fx) * 180 / .pi
        let top = abs(camera.attitude.pitch) + half
        let reach = top >= 85 ? 180 : Int(min(180, half / cos(top * .pi / 180) + 3))

        lineSegments.removeAll(keepingCapacity: true)
        overlaySegments.removeAll(keepingCapacity: true)
        showBackdrop(risen != nil, at: now)
        // From above, the terrain in 3D where the GPU can draw it, else the land filled in flat.
        let terrain = terrainCamera(risen.flatMap { _ in model.risenMesh }, lift: risen?.height, camera: camera, at: now)
        layoutLand(terrain == nil && (risen != nil || now < backdropFading) ? scene.horizon : nil, projector,
                   heading: camera.attitude.heading, reach: reach)
        // Increase Contrast: brighter lines over a darker halo.
        let contrast = UIAccessibility.isDarkerSystemColorsEnabled
        // Seen from above, the skyline can reach the edge of the terrain on the phone, which
        // isn't a skyline: it's left out over the terrain in 3D, which fades out before it, and
        // otherwise drawn as faintly as the farthest ridges.
        layoutRidges(scene, projector, heading: camera.attitude.heading, reach: reach, ridges: settings.showRidges,
                     contrast: contrast, edge: risen != nil ? Float(TerrainScene.radius) * 0.97 : nil, overTerrain: terrain != nil)
        // Dashes keep their size on the mountain while zooming, halving at each doubling,
        // so they're 9 to 18 points apart on screen.
        let dashScale = camera.intrinsics.fx / model.zoom * pow(2, floor(log2(max(1, model.zoom)))) * .pi / 180
        // The trail and the sun path are seen from the ground; risen, they wait.
        layoutTrail(risen == nil ? model.arTrail : nil, progress: model.tracker.progress, terrain: scene.terrain, projector,
                    xRay: settings.trailXRay, pointsPerDegree: dashScale)
        layoutSunPath(risen == nil && settings.showSunPath ? model.sun.path(scene: scene) : nil, projector)
        let placed = layoutLabels(scene, projector, heading: camera.attitude.heading, reach: reach, model: model,
                                  revealed: risen?.revealed ?? [], at: now)
        renderer?.draw(lines: lineSegments, overlay: overlaySegments, halo: contrast ? 0.5 : 0.28, terrain: terrain,
                       size: bounds.size, scale: displayScale)
        // A heading correction turning the view by δ slides everything the other way.
        let shift = -correctionTurn * camera.intrinsics.fx * .pi / 180
        // Zoomed in, labels sweep past faster: a crossing may span more of a frame's move.
        crossing.reach = 60 * max(1, model.zoom).squareRoot()
        crossing.prepareReach = 2 * crossing.reach
        tickIfCrossing(placed, correctionShift: shift, haptics: frozen == nil && settings.haptics, at: now)
    }

    private func clear() {
        for l in bandGlow + bandLine + [skyGlow, skyLine, hiddenTrailLine, walkedTrailLine, trailGlow, trailLine, youLayer, sunLayer, dotLayer, revealedDotLayer, landLayer] { l.path = nil }
        showBackdrop(false, at: Date())
        layoutSunPath(nil, nil)
        renderer?.draw(lines: [], size: bounds.size, scale: displayScale)
        for id in Array(slots.keys) { fade(id, in: false) }
        labeled = []
        arrowLayer.isHidden = true
        arrowHead.isHidden = true
        dots = []
    }

    /// Before the first frame: the latest lens, or a typical one.
    private func fallbackShown(_ model: AppModel) -> AppModel.Shown {
        let lens = model.camera.lens ?? CameraFeed.Lens(intrinsics: CameraIntrinsics(width: 1080, height: 1920, horizontalFOV: 38),
                                                        measured: false)
        return AppModel.Shown(time: model.motion.latestTime ?? 0, lens: lens, portrait: lens.intrinsics.height > lens.intrinsics.width)
    }

    /// Eases corrections in instead of jumping; more slowly zoomed in, where the same change
    /// moves the lines further (a third of a second at 1×, a second at 9× and up). Only
    /// corrections ease: turning the phone moves the lines at once.
    private func smoothedCorrection(_ target: ViewCorrection, zoom: Double, at now: Date) -> ViewCorrection {
        let dt = max(0, min(0.2, now.timeIntervalSince(lastUpdate)))
        lastUpdate = now
        guard let value = smoothed, abs(azimuthDifference(target.heading, value.heading)) < 30 else {
            smoothed = target
            return target
        }
        let f = 1 - exp(-dt / min(1, 0.35 * max(1, zoom).squareRoot()))
        let next = ViewCorrection(heading: value.heading + azimuthDifference(target.heading, value.heading) * f,
                                  pitch: value.pitch + (target.pitch - value.pitch) * f,
                                  roll: value.roll + (target.roll - value.roll) * f)
        smoothed = next
        return next
    }

    private func point(_ projector: Camera.Projector, _ azimuth: Double, _ elevation: Double) -> CGPoint? {
        projector.pixel(azimuth: azimuth, elevation: elevation).map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// How a kind of line looks on the GPU.
    private struct Style {
        var color: SIMD4<Float>
        var width: Float
        var glow: Float
        var glowAlpha: Float

        func segment(_ a: CGPoint, _ b: CGPoint) -> LineSegment {
            LineSegment(a: SIMD2(Float(a.x), Float(a.y)), b: SIMD2(Float(b.x), Float(b.y)), color: color,
                        width: width, glow: glow, glowAlpha: glowAlpha)
        }
    }

    private static let bandStyles = bands.map {
        Style(color: SIMD4(0.86, 0.94, 1.0, Float($0.1)), width: 1, glow: 3.5, glowAlpha: Float($0.1) * 0.22)
    }
    /// With Increase Contrast, far ridges fade less.
    private static let contrastBandStyles = bands.map {
        Style(color: SIMD4(0.9, 0.96, 1.0, min(1, Float($0.1) * 1.3 + 0.15)), width: 1.2, glow: 3.5, glowAlpha: Float($0.1) * 0.25)
    }
    private static let skylineStyle = Style(color: SIMD4(0.97, 0.99, 1.0, 0.95), width: 1.4, glow: 4.5, glowAlpha: 0.32)
    private static let contrastSkylineStyle = Style(color: SIMD4(1, 1, 1, 1), width: 1.7, glow: 4.5, glowAlpha: 0.32)
    /// The trail's glow goes with the ridgelines, so it doesn't double up where pieces
    /// meet; its line is laid over them, so it stays orange across a white ridge.
    private static let trailGlowStyle = Style(color: SIMD4(1.0, 0.72, 0.28, 0), width: 2.5, glow: 6, glowAlpha: 0.38)
    private static let trailStyle = Style(color: SIMD4(1.0, 0.72, 0.28, 1), width: 2.5, glow: 0, glowAlpha: 0)
    private static let hiddenTrailStyle = Style(color: SIMD4(1.0, 0.72, 0.28, 0.6), width: 1.8, glow: 3, glowAlpha: 0.14)
    /// Walking the trail: the part behind you, quieter.
    private static let walkedTrailStyle = Style(color: SIMD4(1.0, 0.72, 0.28, 0.32), width: 2, glow: 0, glowAlpha: 0)
    private static let youStyle = Style(color: SIMD4(1, 1, 1, 0.85), width: 1.5, glow: 3, glowAlpha: 0.2)
    /// A hidden stretch's dashes: `dashOn` points drawn of every `dashPeriod`, before the
    /// round caps.
    private static let dashPeriod: CGFloat = 9
    private static let dashOn: CGFloat = 3.5
    private static let dotStyle = Style(color: SIMD4(1, 1, 1, 0.55), width: 4, glow: 0, glowAlpha: 0)
    private static let revealedDotStyle = Style(color: SIMD4(1, 1, 1, 0.55), width: 1, glow: 0, glowAlpha: 0)

    /// Ridges this close are mostly the ground in front of you, houses and trees in
    /// reality; only the skyline is drawn there.
    private static let nearestRidge: Float = 1_000

    /// A path that joins segments end to end when they meet, so a ridge is one line
    /// rather than hundreds of pieces.
    private struct Polyline {
        let path = CGMutablePath()
        var last: CGPoint?

        mutating func add(_ a: CGPoint, _ b: CGPoint) {
            if let last, abs(last.x - a.x) < 0.5, abs(last.y - a.y) < 0.5 {
                path.addLine(to: b)
            } else {
                path.move(to: a)
                path.addLine(to: b)
            }
            last = b
        }
    }

    /// Skyline pieces at least `edge` meters away are drawn as the farthest ridges, or left
    /// out over the terrain in 3D (`overTerrain`), whose shading already shows the slopes, so
    /// the ridges in front of the skyline are quieter there.
    private func layoutRidges(_ scene: TerrainScene, _ projector: Camera.Projector, heading: Double, reach: Int, ridges: Bool,
                              contrast: Bool, edge: Float? = nil, overTerrain: Bool = false) {
        let gpu = renderer != nil
        // For the GPU, consecutive pieces of a line are merged into segments a few points
        // long: the panorama's 0.1° steps are only about a point apart on screen.
        var runs = [(start: CGPoint, end: CGPoint)?](repeating: nil, count: Self.bands.count + 1)
        var bandStyles = contrast ? Self.contrastBandStyles : Self.bandStyles
        if overTerrain && !contrast {
            bandStyles = bandStyles.map {
                var style = $0
                style.color.w *= 0.5
                style.glowAlpha *= 0.5
                return style
            }
        }
        let skylineStyle = contrast ? Self.contrastSkylineStyle : Self.skylineStyle
        func styleFor(_ style: Int) -> Style { style < Self.bands.count ? bandStyles[style] : skylineStyle }
        func emit(_ a: CGPoint, _ b: CGPoint, _ style: Int) {
            if let run = runs[style], abs(run.end.x - a.x) < 0.5, abs(run.end.y - a.y) < 0.5,
               hypot(b.x - run.start.x, b.y - run.start.y) < 4 {
                runs[style] = (run.start, b)
                return
            }
            if let run = runs[style] { lineSegments.append(styleFor(style).segment(run.start, run.end)) }
            runs[style] = (a, b)
        }
        var bands = Self.bands.map { _ in Polyline() }
        var skyline = Polyline()
        let center = Int(heading.rounded())
        let span = reach >= 180 ? -180...179 : -reach...reach
        let bounds = self.bounds.insetBy(dx: -40, dy: -40)
        for offset in span {
            for s in scene.segments[(center + offset + 720) % 360] where s.isSkyline || (ridges && s.distance >= Self.nearestRidge) {
                guard let a = point(projector, Double(s.azimuth0), Double(s.elevation0)),
                      let b = point(projector, Double(s.azimuth1), Double(s.elevation1)),
                      bounds.contains(a) || bounds.contains(b) else { continue }
                let atEdge = s.isSkyline && edge.map { s.distance >= $0 } == true
                if atEdge && overTerrain { continue }
                let band = s.isSkyline && !atEdge ? -1 : (Self.bands.firstIndex { s.distance < $0.0 } ?? Self.bands.count - 1)
                if gpu {
                    emit(a, b, band < 0 ? Self.bands.count : band)
                } else if band < 0 {
                    skyline.add(a, b)
                } else {
                    bands[band].add(a, b)
                }
            }
        }
        guard !gpu else {
            for (style, run) in runs.enumerated() {
                if let run { lineSegments.append(styleFor(style).segment(run.start, run.end)) }
            }
            return
        }
        for i in bands.indices {
            bandGlow[i].path = bands[i].path
            bandLine[i].path = bands[i].path
        }
        skyGlow.path = skyline.path
        skyLine.path = skyline.path
    }

    /// Fades the backdrop in when the view rises, and out when it comes down.
    private func showBackdrop(_ shown: Bool, at now: Date) {
        guard shown != backdropShown else { return }
        backdropShown = shown
        let duration = 0.2
        if !shown { backdropFading = now.addingTimeInterval(duration) }
        let from = backdrop.presentation()?.opacity ?? backdrop.opacity
        let to: Float = shown ? 1 : 0
        backdrop.opacity = to
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration * CFTimeInterval(abs(to - from))
        backdrop.add(animation, forKey: "fade")
    }

    /// The camera for the terrain in 3D (`mesh`, seen from `lift` meters above the live view's
    /// eye), fading in and out with the backdrop; nil when there's none to draw, or no Metal.
    private func terrainCamera(_ mesh: AppModel.RiseMesh?, lift: Double?, camera: Camera, at now: Date) -> TerrainCamera? {
        guard let renderer, renderer.drawsTerrain else { return nil }
        let dt = Float(max(0, min(0.1, now.timeIntervalSince(lastTerrainFrame))))
        lastTerrainFrame = now
        if let mesh, let lift {
            renderer.setTerrain(mesh.mesh, id: mesh.generation)
            terrainLift = Float(lift)
            terrainOpacity = min(1, terrainOpacity + dt / 0.2)
        } else {
            terrainOpacity = max(0, terrainOpacity - dt / 0.2)
        }
        guard terrainOpacity > 0 else {
            // Let the GPU's copy go once the views from above are let go.
            if model?.riseWork.mesh == nil, model?.riseWork.staleMeshes.isEmpty ?? true { renderer.setTerrain(nil, id: 0) }
            return nil
        }
        let axes = camera.attitude.axes, k = camera.intrinsics
        func float(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        let sky = Self.sky.cgColor.components ?? [0, 0, 0]
        return TerrainCamera(right: float(axes.right), down: float(axes.down), forward: float(axes.forward),
                             lens: SIMD4(Float(k.fx), Float(k.fy), Float(k.cx), Float(k.cy)), lift: terrainLift,
                             opacity: terrainOpacity, sky: SIMD3(Float(sky[0]), Float(sky[1]), Float(sky[2])),
                             dark: Self.terrainDark, light: Self.terrainLight, haze: Self.terrainHaze)
    }

    /// The land below the skyline, filled, across the view: from each stretch of skyline in
    /// front of the camera down past the bottom of the screen (the world's down).
    private func layoutLand(_ horizon: HorizonProfile?, _ projector: Camera.Projector, heading: Double, reach: Int) {
        guard let horizon else {
            landLayer.path = nil
            return
        }
        let path = CGMutablePath()
        let far = hypot(bounds.width, bounds.height) * 2
        let down = worldDown
        var run: [CGPoint] = []
        func close() {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.count > 1, let first = run.first, let last = run.last else { return }
            path.move(to: first)
            for p in run.dropFirst() { path.addLine(to: p) }
            path.addLine(to: CGPoint(x: last.x + down.x * far, y: last.y + down.y * far))
            path.addLine(to: CGPoint(x: first.x + down.x * far, y: first.y + down.y * far))
            path.closeSubpath()
        }
        let span = Double(min(reach, 179))
        var azimuth = heading - span
        while azimuth <= heading + span {
            if let p = point(projector, azimuth, horizon.elevation(atAzimuth: azimuth)) { run.append(p) } else { close() }
            azimuth += 0.2
        }
        close()
        landLayer.path = path
    }

    /// The trail laid on the slope: solid where it's in sight and, seeing through ridges
    /// (`xRay`), fainter and dashed where nearer terrain hides it. Dashes are spaced along
    /// the trail by angle, `pointsPerDegree`, not along the screen, so they stay put on the
    /// mountain as the phone turns. Walking it (`progress`), the part of the main line behind
    /// you is quieter, and a small ring marks where you are on it.
    private func layoutTrail(_ trail: AppModel.ARTrail?, progress: TrailProgress?, terrain: Terrain,
                             _ projector: Camera.Projector, xRay: Bool, pointsPerDegree: CGFloat) {
        guard let runs = trail?.runs else {
            trailGlow.path = nil
            trailLine.path = nil
            hiddenTrailLine.path = nil
            walkedTrailLine.path = nil
            youLayer.path = nil
            return
        }
        let gpu = renderer != nil
        var solid = Polyline()
        var walked = Polyline()
        let dashes = CGMutablePath()
        let area = bounds.insetBy(dx: -20, dy: -20)
        // The dashes along a→b, which spans s0 to s1 of the pattern.
        func dash(_ a: CGPoint, _ b: CGPoint, _ s0: CGFloat, _ s1: CGFloat) {
            guard s1 > s0, CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                .intersects(area) else { return }
            func at(_ s: CGFloat) -> CGPoint {
                let t = (s - s0) / (s1 - s0)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            var start = (s0 / Self.dashPeriod).rounded(.down) * Self.dashPeriod
            while start < s1 {
                let lo = max(start, s0), hi = min(start + Self.dashOn, s1)
                if hi > lo {
                    if gpu {
                        overlaySegments.append(Self.hiddenTrailStyle.segment(at(lo), at(hi)))
                    } else {
                        dashes.move(to: at(lo))
                        dashes.addLine(to: at(hi))
                    }
                }
                start += Self.dashPeriod
            }
        }
        for run in runs {
            var last: (point: CGPoint, inSight: Bool, along: CGFloat)?
            var previous: DrapedPoint?
            var along: CGFloat = 0
            for p in run {
                if let previous {
                    let across = CGFloat(azimuthDifference(Double(p.azimuth), Double(previous.azimuth)) * cos(Double(p.elevation) * .pi / 180))
                    along += hypot(across, CGFloat(p.elevation - previous.elevation)) * pointsPerDegree
                }
                previous = p
                guard let q = point(projector, Double(p.azimuth), Double(p.elevation)) else {
                    last = nil
                    continue
                }
                if let last {
                    if last.inSight && p.isInSight, let progress, p.line == 0, progress.isBehind(Double(p.along)) {
                        if gpu {
                            overlaySegments.append(Self.walkedTrailStyle.segment(last.point, q))
                        } else {
                            walked.add(last.point, q)
                        }
                    } else if last.inSight && p.isInSight {
                        if gpu {
                            lineSegments.append(Self.trailGlowStyle.segment(last.point, q))
                            overlaySegments.append(Self.trailStyle.segment(last.point, q))
                        } else {
                            solid.add(last.point, q)
                        }
                    } else if xRay {
                        dash(last.point, q, last.along, along)
                    }
                }
                last = (q, p.isInSight, along)
            }
        }
        // Where you are on the trail, seen from where the trail was laid out from: a ring on
        // the ground, if it's in view.
        let ring = CGMutablePath()
        if let progress, let observer = trail?.observer {
            let at = progress.position
            let ground = terrain.height(latitude: at.latitude, longitude: at.longitude)
            let look = LocalFrame(origin: observer).look(at: GeoPoint(latitude: at.latitude, longitude: at.longitude,
                                                                      height: ground.isFinite ? ground + 0.3 : observer.height - 1.6))
            if look.distance > 3, let q = point(projector, look.azimuth, look.elevation), bounds.contains(q) {
                let r: CGFloat = 6
                if gpu {
                    var previous = CGPoint(x: q.x + r, y: q.y)
                    for k in 1...16 {
                        let a = CGFloat(k) / 16 * 2 * .pi
                        let next = CGPoint(x: q.x + r * cos(a), y: q.y + r * sin(a))
                        overlaySegments.append(Self.youStyle.segment(previous, next))
                        previous = next
                    }
                } else {
                    ring.addEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
                }
            }
        }
        guard !gpu else { return }
        trailGlow.path = solid.path
        trailLine.path = solid.path
        walkedTrailLine.path = walked.path
        youLayer.path = ring
        hiddenTrailLine.path = xRay ? dashes : nil
    }

    private static let sunDotStyle = Style(color: SIMD4(1, 0.86, 0.5, 0.7), width: 2.2, glow: 0, glowAlpha: 0)
    private static let sunTickStyle = Style(color: SIMD4(1, 0.86, 0.5, 0.8), width: 1.2, glow: 0, glowAlpha: 0)

    /// Today's sun path, if turned on: a dotted line where the sun is above the terrain, a
    /// dot every two minutes, with a tick and the hour at each whole hour. Nothing shows
    /// unless the path is in the frame.
    private func layoutSunPath(_ points: [SunService.PathPoint]?, _ projector: Camera.Projector?) {
        var used = 0
        defer {
            for (i, l) in hourLayers.enumerated() { l.isHidden = i >= used }
        }
        guard let points, let projector else {
            sunLayer.path = nil
            return
        }
        let gpu = renderer != nil
        let path = CGMutablePath()
        let area = bounds.insetBy(dx: -10, dy: -10)
        let projected: [CGPoint?] = points.map { p in
            p.inSight ? point(projector, p.azimuth, p.elevation).flatMap { area.contains($0) ? $0 : nil } : nil
        }
        for (i, p) in points.enumerated() {
            guard let q = projected[i] else { continue }
            if gpu {
                overlaySegments.append(Self.sunDotStyle.segment(q, q))
            } else {
                path.addEllipse(in: CGRect(x: q.x - 1.1, y: q.y - 1.1, width: 2.2, height: 2.2))
            }
            guard let hour = p.hour else { continue }
            // Across the path, from its neighbors' direction.
            let before = i > 0 ? point(projector, points[i - 1].azimuth, points[i - 1].elevation) : nil
            let after = i + 1 < points.count ? point(projector, points[i + 1].azimuth, points[i + 1].elevation) : nil
            let a = before ?? q, b = after ?? q
            guard hypot(b.x - a.x, b.y - a.y) > 0.1 else { continue }
            let len = hypot(b.x - a.x, b.y - a.y)
            var normal = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
            // The hour goes on the side away from the ground.
            if normal.x * worldUp.x + normal.y * worldUp.y < 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
            let t0 = CGPoint(x: q.x - normal.x * 4, y: q.y - normal.y * 4), t1 = CGPoint(x: q.x + normal.x * 4, y: q.y + normal.y * 4)
            if gpu {
                overlaySegments.append(Self.sunTickStyle.segment(t0, t1))
            } else {
                path.move(to: t0)
                path.addLine(to: t1)
            }
            if used == hourLayers.count {
                let l = CATextLayer()
                l.fontSize = 10
                l.font = UIFont.systemFont(ofSize: 10, weight: .medium)
                l.foregroundColor = UIColor(red: 1, green: 0.9, blue: 0.65, alpha: 0.85).cgColor
                l.alignmentMode = .center
                l.contentsScale = displayScale
                l.shadowColor = UIColor.black.cgColor
                l.shadowOpacity = 0.6
                l.shadowRadius = 2
                l.shadowOffset = .zero
                l.bounds = CGRect(x: 0, y: 0, width: 24, height: 13)
                hourContainer.addSublayer(l)
                hourLayers.append(l)
            }
            let l = hourLayers[used]
            used += 1
            let text = String(hour)
            if (l.string as? String) != text { l.string = text }
            l.position = CGPoint(x: q.x + normal.x * 13, y: q.y + normal.y * 13)
            l.setAffineTransform(CGAffineTransform(rotationAngle: upAngle))
        }
        sunLayer.path = gpu ? nil : path
    }

    private static func attributes(size: CGFloat, weight: UIFont.Weight, color: UIColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        return [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .shadow: shadow]
    }

    private static let nameAttributes = attributes(size: 15, weight: .semibold, color: .white)
    private static let heightAttributes = attributes(size: 12, weight: .regular, color: UIColor.white.withAlphaComponent(0.75))
    private static let selectedAttributes = attributes(size: 16, weight: .bold, color: accent)
    private static let hiddenAttributes = attributes(size: 14, weight: .semibold, color: UIColor.white.withAlphaComponent(0.6))

    /// Screen directions of the world's up, right and down.
    private var worldUp: CGPoint { CGPoint(x: sin(upAngle), y: -cos(upAngle)) }
    private var worldRight: CGPoint { CGPoint(x: cos(upAngle), y: sin(upAngle)) }
    private var worldDown: CGPoint { CGPoint(x: -sin(upAngle), y: cos(upAngle)) }

    /// A screen offset in world-upright terms: (along the horizon, down).
    private func upright(_ d: CGPoint) -> CGPoint {
        CGPoint(x: d.x * worldRight.x + d.y * worldRight.y, y: d.x * worldDown.x + d.y * worldDown.y)
    }

    /// The controls over the view, and the status bar, in this view's coordinates.
    private var clearRects: [CGRect] {
        guard let window else { return [] }
        var rects = keepClear.map { convert($0, from: nil) }
        let top = window.safeAreaInsets.top
        if top > 0 { rects.append(convert(CGRect(x: 0, y: 0, width: window.bounds.width, height: top), from: nil)) }
        return rects.filter { !$0.isEmpty }
    }

    private static func screenRect(_ r: CGRect) -> ScreenRect {
        ScreenRect(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    private static func labelBox(_ box: CGRect) -> LabelBox {
        LabelBox(minX: Double(box.minX), minY: Double(box.minY), maxX: Double(box.maxX), maxY: Double(box.maxY))
    }

    /// Labels the selected peak, then the most prominent visible peaks, keeping last frame's
    /// labels where they still fit (`LabelLayout`); a selected peak out of view gets an
    /// arrow at the edge. Every other peak in sight gets a small dot, so it can be tapped
    /// too. Returns the labels' positions along the horizon from the middle, for haptics.
    /// Peaks `revealed` (in sight only from above) get dashed leaders, or open rings.
    private func layoutLabels(_ scene: TerrainScene, _ projector: Camera.Projector, heading: Double, reach: Int,
                              model: AppModel, revealed: Set<Int64>, at now: Date) -> [(id: Int64, x: Double)] {
        let units = model.settings.units
        // Zoomed in, peaks spread apart and there's room for more labels, a few at a time.
        let limit = LabelLayout.limit(base: model.settings.labels.maxLabels, zoom: model.zoom)
        let range = Double(min(reach, 90))
        let selectedID = model.selectedPeakID
        var candidates: [LabelLayout.Candidate] = []
        var points: [Int64: CGPoint] = [:]
        var peaks: [Int64: Peak] = [:]

        // The selected peak, wherever it projects, even off screen.
        var selected: (view: TerrainScene.PeakView, point: CGPoint?)?
        if let id = selectedID, let v = scene.allPeaks[id] {
            let p = abs(azimuthDifference(v.azimuth, heading)) < range + 10 ? point(projector, v.azimuth, v.elevation) : nil
            selected = (v, p)
            if let p {
                points[id] = p
                peaks[id] = v.peak
                let above = labelImage(v.peak, units, selected: true, hidden: !v.isVisible, below: false)
                let below = labelImage(v.peak, units, selected: true, hidden: !v.isVisible, below: true)
                candidates.append(LabelLayout.Candidate(id: id, x: Double(p.x), y: Double(p.y), score: .infinity,
                                                        box: Self.labelBox(above.box), flippedBox: Self.labelBox(below.box),
                                                        isSelected: true))
            }
        }

        // The rest, best first. Only the first few dozen (and those shown last frame) could
        // get a label, so only theirs are drawn; the others are dots.
        let view = bounds.insetBy(dx: 4, dy: 4)
        var labelable = 0
        for v in scene.peaks where v.id != selectedID {
            guard abs(azimuthDifference(v.azimuth, heading)) < range,
                  let p = point(projector, v.azimuth, v.elevation), view.contains(p) else { continue }
            // Peaks whose line of sight the coarse base layer can't settle get a dot only.
            let canLabel = (labelable < limit * 3 || labeled.contains(v.id)) && !scene.uncertain.contains(v.id)
            guard canLabel || candidates.count < 200 else { continue }
            var box: LabelBox?
            if canLabel {
                labelable += 1
                box = Self.labelBox(labelImage(v.peak, units, selected: false, hidden: false, below: false,
                                               revealed: revealed.contains(v.id)).box)
            }
            points[v.id] = p
            peaks[v.id] = v.peak
            candidates.append(LabelLayout.Candidate(id: v.id, x: Double(p.x), y: Double(p.y),
                                                    score: scene.scores[v.id] ?? 0, box: box))
        }

        let layout = LabelLayout(bounds: Self.screenRect(bounds), keepClear: clearRects.map(Self.screenRect),
                                 upX: Double(worldUp.x), upY: Double(worldUp.y), limit: limit,
                                 thresholds: LabelLayout.Thresholds().scaled(forZoom: model.zoom))
        let result = layout.place(candidates, previous: labeled)
        labeled = result.labeled

        // Label layers: each labeled peak's fades in, the rest fade out where they are.
        let turn = CGAffineTransform(rotationAngle: upAngle)
        for id in result.labels {
            guard let p = points[id], let peak = peaks[id] else { continue }
            let isSelected = id == selectedID
            let hidden = isSelected && selected?.view.isVisible == false
            let image = labelImage(peak, units, selected: isSelected, hidden: hidden,
                                   below: isSelected && result.selected == .below, revealed: revealed.contains(id))
            var slot = slots[id] ?? {
                let l = CALayer()
                l.contentsScale = displayScale
                l.opacity = 0
                labelContainer.addSublayer(l)
                return Slot(layer: l)
            }()
            let l = slot.layer
            if slot.image != ObjectIdentifier(image.image) {
                l.contents = image.image
                l.bounds = CGRect(origin: .zero, size: image.size)
                l.anchorPoint = CGPoint(x: image.anchor.x / image.size.width, y: image.anchor.y / image.size.height)
                slot.image = ObjectIdentifier(image.image)
            }
            l.position = p
            l.setAffineTransform(turn)
            slot.lastShown = now
            slots[id] = slot
            fade(id, in: true)
            labelHits.append((image.box.applying(CGAffineTransform(translationX: p.x, y: p.y).rotated(by: upAngle)), id))
        }
        for (id, slot) in slots where !labeled.contains(id) {
            if let p = points[id] { slot.layer.position = p }
            fade(id, in: false)
            // Faded out and out of view, or gone a while: let it go.
            let gone = now.timeIntervalSince(slot.lastShown)
            if gone > Self.fade + 0.05, points[id] == nil || gone > 2 {
                slot.layer.removeFromSuperlayer()
                slots[id] = nil
            }
        }

        // The selected peak off screen: a tag at the edge, pointing the way it is on screen,
        // or along the horizon when it's behind.
        arrowLayer.isHidden = true
        arrowHead.isHidden = true
        if let selected, result.selected == nil {
            let v = selected.view, p = selected.point
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            var dir: CGPoint
            if let p, hypot(p.x - center.x, p.y - center.y) > 1 {
                let d = hypot(p.x - center.x, p.y - center.y)
                dir = CGPoint(x: (p.x - center.x) / d, y: (p.y - center.y) / d)
            } else {
                dir = azimuthDifference(v.azimuth, heading) > 0 ? worldRight : CGPoint(x: -worldRight.x, y: -worldRight.y)
            }
            layoutEdgeArrow(name: v.peak.name, distance: Format.distance(v.distance, units), toward: dir, id: v.peak.id)
        }

        dots = result.dots.prefix(150).compactMap { id in points[id].map { (point: $0, id: id) } }
        let ring: CGFloat = 2
        if renderer != nil {
            for (p, id) in dots {
                guard revealed.contains(id) else {
                    overlaySegments.append(Self.dotStyle.segment(p, p))
                    continue
                }
                var previous = CGPoint(x: p.x + ring, y: p.y)
                for k in 1...8 {
                    let a = CGFloat(k) / 8 * 2 * .pi
                    let next = CGPoint(x: p.x + ring * cos(a), y: p.y + ring * sin(a))
                    overlaySegments.append(Self.revealedDotStyle.segment(previous, next))
                    previous = next
                }
            }
        } else {
            let dotPath = CGMutablePath(), ringPath = CGMutablePath()
            for (p, id) in dots {
                if revealed.contains(id) {
                    ringPath.addEllipse(in: CGRect(x: p.x - ring, y: p.y - ring, width: 2 * ring, height: 2 * ring))
                } else {
                    dotPath.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                }
            }
            dotLayer.path = dotPath
            revealedDotLayer.path = ringPath
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return result.labels.compactMap { id in
            points[id].map { (id, Double(upright(CGPoint(x: $0.x - center.x, y: $0.y - center.y)).x)) }
        }
    }

    /// Fades a label layer in or out over a moment, from wherever it is now.
    private func fade(_ id: Int64, in shown: Bool) {
        guard var slot = slots[id], slot.shown != shown else { return }
        slot.shown = shown
        slots[id] = slot
        let l = slot.layer
        let from = l.presentation()?.opacity ?? l.opacity
        let to: Float = shown ? 1 : 0
        l.opacity = to
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Self.fade * CFTimeInterval(abs(to - from))
        l.add(animation, forKey: "fade")
    }

    /// A peak's label, drawn once: a dot, a leader line up from it and the name and height
    /// above, or for the selected peak with no room above, all of it below.
    private func labelImage(_ peak: Peak, _ units: AppSettings.Units, selected: Bool, hidden: Bool, below: Bool,
                            revealed: Bool = false) -> LabelImage {
        let key = LabelKey(id: peak.id, units: units, selected: selected, hidden: hidden, below: below, revealed: revealed)
        imageClock += 1
        if let cached = images[key] {
            images[key]?.used = imageClock
            return cached.image
        }
        if images.count >= Self.imageCapacity {
            // Let the least recently used quarter go.
            let old = images.sorted { $0.value.used < $1.value.used }.prefix(Self.imageCapacity / 4)
            for (k, _) in old { images[k] = nil }
        }

        let detail = Format.elevation(of: peak, units) + (hidden ? " · hidden" : "")
        let title = NSAttributedString(string: peak.name,
                                       attributes: selected ? Self.selectedAttributes : hidden ? Self.hiddenAttributes : Self.nameAttributes)
        let height = NSAttributedString(string: detail, attributes: Self.heightAttributes)
        let titleSize = title.size(), heightSize = height.size()
        // Laid out around the dot at (0, 0): above it the title then the height, or below it
        // the title then the height.
        let titleOrigin: CGPoint, heightOrigin: CGPoint, leaderEnd: CGFloat, stem: CGRect
        if below {
            titleOrigin = CGPoint(x: -titleSize.width / 2, y: 36)
            heightOrigin = CGPoint(x: -heightSize.width / 2, y: titleOrigin.y + titleSize.height - 2)
            leaderEnd = 34
            stem = CGRect(x: -10, y: -10, width: 20, height: 46)
        } else {
            heightOrigin = CGPoint(x: -heightSize.width / 2, y: -36 - heightSize.height)
            titleOrigin = CGPoint(x: -titleSize.width / 2, y: heightOrigin.y - titleSize.height + 2)
            leaderEnd = -34
            stem = CGRect(x: -10, y: -36, width: 20, height: 46)
        }
        let box = CGRect(origin: titleOrigin, size: titleSize).union(CGRect(origin: heightOrigin, size: heightSize)).union(stem)
        let canvas = box.insetBy(dx: -5, dy: -5).integral
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: canvas.size, format: format).image { context in
            context.cgContext.translateBy(x: -canvas.minX, y: -canvas.minY)
            let leader = UIBezierPath()
            leader.move(to: CGPoint(x: 0, y: below ? 5 : -5))
            leader.addLine(to: CGPoint(x: 0, y: leaderEnd))
            leader.lineWidth = selected ? 1.5 : 1
            if hidden || revealed { leader.setLineDash([3, 3], count: 2, phase: 0) }
            (selected ? Self.accent : UIColor.white.withAlphaComponent(0.7)).setStroke()
            leader.stroke()
            (selected ? Self.accent : UIColor.white).setFill()
            let r: CGFloat = selected ? 3.5 : 2.5
            UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).fill()
            if selected {
                Self.accent.withAlphaComponent(0.6).setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(x: -9, y: -9, width: 18, height: 18))
                ring.lineWidth = 1
                ring.stroke()
            }
            height.draw(at: heightOrigin)
            title.draw(at: titleOrigin)
        }
        let image = LabelImage(image: rendered.cgImage!, size: canvas.size,
                               anchor: CGPoint(x: -canvas.minX, y: -canvas.minY), box: box)
        images[key] = (image, imageClock)
        return image
    }

    /// A small tag near the edge of the view, toward a selected peak out of view along
    /// `direction` on screen, with a chevron pointing there.
    private func layoutEdgeArrow(name: String, distance: String, toward direction: CGPoint, id: Int64) {
        let key = "\(name)|\(distance)|\(displayScale)"
        let image: LabelImage
        if let cached = arrowImage, cached.key == key {
            image = cached.image
        } else {
            let text = NSAttributedString(string: "\(name) · \(distance)", attributes: Self.selectedAttributes)
            let size = text.size()
            let box = CGRect(x: -size.width / 2 - 10, y: -size.height / 2 - 6, width: size.width + 20, height: size.height + 12)
            let canvas = box.integral
            let format = UIGraphicsImageRendererFormat()
            format.scale = displayScale
            format.opaque = false
            let rendered = UIGraphicsImageRenderer(size: canvas.size, format: format).image { context in
                context.cgContext.translateBy(x: -canvas.minX, y: -canvas.minY)
                UIColor.black.withAlphaComponent(0.45).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).fill()
                text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
            }
            image = LabelImage(image: rendered.cgImage!, size: canvas.size, anchor: CGPoint(x: -canvas.minX, y: -canvas.minY), box: box)
            arrowImage = (key, image)
        }
        // The room left between the edges and the controls.
        var free = bounds.insetBy(dx: 16, dy: 16)
        for r in clearRects {
            if r.midY < bounds.midY { free.origin.y = max(free.minY, r.maxY + 8) } else { free.size.height = min(free.maxY, r.minY - 8) - free.minY }
        }
        free.size.height = max(free.height, 1)
        let turn = CGAffineTransform(rotationAngle: upAngle)
        // The tag's extent on screen, turned upright, plus the chevron beyond it.
        let extent = image.box.applying(turn)
        let gap: CGFloat = 14
        let halfW = extent.width / 2 + gap * abs(direction.x), halfH = extent.height / 2 + gap * abs(direction.y)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        func room(_ d: CGFloat, _ lo: CGFloat, _ hi: CGFloat, _ c: CGFloat, _ half: CGFloat) -> CGFloat {
            if d > 0.01 { return (hi - half - c) / d }
            if d < -0.01 { return (lo + half - c) / d }
            return .infinity
        }
        let along = max(0, min(room(direction.x, free.minX, free.maxX, center.x, halfW),
                               room(direction.y, free.minY, free.maxY, center.y, halfH)))
        let tag = CGPoint(x: center.x + direction.x * along, y: center.y + direction.y * along)
        arrowLayer.contentsScale = displayScale
        arrowLayer.contents = image.image
        arrowLayer.bounds = CGRect(origin: .zero, size: image.size)
        arrowLayer.anchorPoint = CGPoint(x: image.anchor.x / image.size.width, y: image.anchor.y / image.size.height)
        arrowLayer.position = tag
        arrowLayer.setAffineTransform(turn)
        arrowLayer.isHidden = false
        // The chevron just outside the tag, where the line toward the peak leaves it.
        let reachX = abs(direction.x) > 0.01 ? extent.width / 2 / abs(direction.x) : .infinity
        let reachY = abs(direction.y) > 0.01 ? extent.height / 2 / abs(direction.y) : .infinity
        let out = min(reachX, reachY) + 8
        arrowHead.position = CGPoint(x: tag.x + direction.x * out, y: tag.y + direction.y * out)
        arrowHead.setAffineTransform(CGAffineTransform(rotationAngle: atan2(direction.y, direction.x)))
        arrowHead.isHidden = false
        labelHits.append((image.box.applying(CGAffineTransform(translationX: tag.x, y: tag.y).rotated(by: upAngle)), id))
    }

    /// A light tick when turning the phone carries a labeled peak across the middle of the
    /// screen; the haptic engine is woken as one comes near, so the tick isn't late.
    private func tickIfCrossing(_ labels: [(id: Int64, x: Double)], correctionShift: Double, haptics enabled: Bool, at now: Date) {
        let crossed = crossing.update(labels, correctionShift: correctionShift)
        guard enabled else { return }
        if crossing.isNear(labels), now.timeIntervalSince(lastPrepare) > 1 {
            haptics.prepare()
            lastPrepare = now
        }
        if crossed, now.timeIntervalSince(lastTick) > 0.15 {
            haptics.selectionChanged()
            lastTick = now
        }
    }
}

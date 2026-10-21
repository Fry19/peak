import PeakCore
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
    private var needsUpdate = true
    private var smoothed: ViewCorrection?
    private var lastUpdate = Date()
    private var lastSide: [Int64: Bool] = [:]
    private var lastTick = Date.distantPast
    private let haptics = UISelectionFeedbackGenerator()
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
    private static let trailColor = UIColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 1)
    private static let accent = UIColor(red: 1.0, green: 0.84, blue: 0.45, alpha: 1)

    // Under each line a wide faint stroke makes the glow (cheaper than a blurred shadow).
    private let bandGlow = OverlayCanvas.bands.map { OverlayCanvas.stroke(OverlayCanvas.tint.withAlphaComponent($0.1 * 0.18), width: 4) }
    private let bandLine = OverlayCanvas.bands.map { OverlayCanvas.stroke(OverlayCanvas.tint.withAlphaComponent($0.1), width: 1) }
    private let skyGlow = OverlayCanvas.stroke(OverlayCanvas.tint.withAlphaComponent(0.3), width: 5)
    private let skyLine = OverlayCanvas.stroke(UIColor.white.withAlphaComponent(0.95), width: 1.4)
    private let trailGlow = OverlayCanvas.stroke(OverlayCanvas.trailColor.withAlphaComponent(0.3), width: 8)
    private let trailLine = OverlayCanvas.stroke(OverlayCanvas.trailColor, width: 2.5)
    private let dotLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = UIColor.white.withAlphaComponent(0.55).cgColor
        l.strokeColor = nil
        return l
    }()
    /// Draws the lines on the GPU; nil if Metal isn't available, and the shape layers do.
    private let renderer = LineRenderer()
    private var segments: [LineSegment] = []
    var drawsWithMetal: Bool { renderer != nil }
    /// Line segments sent to the GPU for the last frame, for diagnostics.
    var segmentCount: Int { segments.count }
    private let labelContainer = CALayer()
    private var labelLayers: [Int64: CALayer] = [:]
    /// The image each label layer shows, so unchanged ones aren't set again.
    private var labelShows: [Int64: ObjectIdentifier] = [:]
    private let arrowLayer = CALayer()

    /// A label drawn once: the image, where the peak's dot is in it, and the part to tap
    /// (relative to the dot).
    private struct LabelImage {
        var image: CGImage
        var size: CGSize
        var anchor: CGPoint
        var box: CGRect
    }
    private var images: [String: LabelImage] = [:]

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
        // Ridges first, the skyline over them, then the trail, dots and labels on top.
        if let renderer {
            layer.addSublayer(renderer.layer)
        } else {
            for l in bandGlow + bandLine + [skyGlow, skyLine, trailGlow, trailLine, dotLayer] { layer.addSublayer(l) }
        }
        layer.addSublayer(labelContainer)
        layer.addSublayer(arrowLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in layer.sublayers ?? [] { l.frame = bounds }
        renderer?.resize(to: bounds.size, scale: traitCollection.displayScale)
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
        needsUpdate = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        labelHits = []
        guard let model, let scene = model.scene, bounds.width > 0 else {
            clear()
            return
        }
        let frozen = model.frozen
        let now = Date()
        let shown = frozen?.shown ?? screen?.shown ?? fallbackShown(model)
        guard let pose = frozen?.pose ?? model.motion.pose(at: shown.time) ?? model.motion.pose else {
            clear()
            return
        }
        let correction = frozen?.correction ?? smoothedCorrection(model.viewCorrection(for: pose), at: now)
        if frozen != nil { smoothed = correction }
        let orientation = screen?.interfaceOrientation ?? .portrait
        var camera = CameraGeometry.screenCamera(pose: pose, lens: shown.lens, portraitFrame: shown.portrait,
                                                 orientation: orientation, size: bounds.size, correction: correction)
        camera.intrinsics = camera.intrinsics.zoomed(by: model.zoom)
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

        segments.removeAll(keepingCapacity: true)
        layoutRidges(scene, projector, heading: camera.attitude.heading, reach: reach, ridges: settings.showRidges)
        layoutTrail(model.arTrail?.runs, projector)
        let placed = layoutLabels(scene, projector, heading: camera.attitude.heading, reach: reach, model: model)
        renderer?.draw(segments, size: bounds.size, scale: traitCollection.displayScale)
        if frozen == nil, settings.haptics { tickIfCrossing(placed, at: now) }
    }

    private func clear() {
        for l in bandGlow + bandLine + [skyGlow, skyLine, trailGlow, trailLine, dotLayer] { l.path = nil }
        renderer?.draw([], size: bounds.size, scale: traitCollection.displayScale)
        labelLayers.values.forEach { $0.isHidden = true }
        arrowLayer.isHidden = true
        dots = []
    }

    /// Before the first frame: the latest lens, or a typical one.
    private func fallbackShown(_ model: AppModel) -> AppModel.Shown {
        let lens = model.camera.lens ?? CameraFeed.Lens(intrinsics: CameraIntrinsics(width: 1080, height: 1920, horizontalFOV: 38),
                                                        measured: false)
        return AppModel.Shown(time: model.motion.latestTime ?? 0, lens: lens, portrait: lens.intrinsics.height > lens.intrinsics.width)
    }

    /// Eases corrections in instead of jumping.
    private func smoothedCorrection(_ target: ViewCorrection, at now: Date) -> ViewCorrection {
        let dt = max(0, min(0.2, now.timeIntervalSince(lastUpdate)))
        lastUpdate = now
        guard let value = smoothed, abs(azimuthDifference(target.heading, value.heading)) < 30 else {
            smoothed = target
            return target
        }
        let f = 1 - exp(-dt / 0.35)
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
    private static let skylineStyle = Style(color: SIMD4(0.97, 0.99, 1.0, 0.95), width: 1.4, glow: 4.5, glowAlpha: 0.32)
    private static let trailStyle = Style(color: SIMD4(1.0, 0.72, 0.28, 1), width: 2.5, glow: 6, glowAlpha: 0.38)
    private static let dotStyle = Style(color: SIMD4(1, 1, 1, 0.55), width: 4, glow: 0, glowAlpha: 0)

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

    private func layoutRidges(_ scene: TerrainScene, _ projector: Camera.Projector, heading: Double, reach: Int, ridges: Bool) {
        let gpu = renderer != nil
        // For the GPU, consecutive pieces of a line are merged into segments a few points
        // long: the panorama's 0.1° steps are only about a point apart on screen.
        var runs = [(start: CGPoint, end: CGPoint)?](repeating: nil, count: Self.bands.count + 1)
        func styleFor(_ style: Int) -> Style { style < Self.bands.count ? Self.bandStyles[style] : Self.skylineStyle }
        func emit(_ a: CGPoint, _ b: CGPoint, _ style: Int) {
            if let run = runs[style], abs(run.end.x - a.x) < 0.5, abs(run.end.y - a.y) < 0.5,
               hypot(b.x - run.start.x, b.y - run.start.y) < 4 {
                runs[style] = (run.start, b)
                return
            }
            if let run = runs[style] { segments.append(styleFor(style).segment(run.start, run.end)) }
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
                let band = s.isSkyline ? -1 : (Self.bands.firstIndex { s.distance < $0.0 } ?? Self.bands.count - 1)
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
                if let run { segments.append(styleFor(style).segment(run.start, run.end)) }
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

    /// The trail's visible stretches, laid on the slope.
    private func layoutTrail(_ runs: [[DrapedPoint]]?, _ projector: Camera.Projector) {
        guard let runs else {
            trailGlow.path = nil
            trailLine.path = nil
            return
        }
        let path = CGMutablePath()
        for run in runs {
            var last: CGPoint?
            for p in run {
                guard let q = point(projector, Double(p.azimuth), Double(p.elevation)) else {
                    last = nil
                    continue
                }
                if let last {
                    if renderer != nil { segments.append(Self.trailStyle.segment(last, q)) } else { path.addLine(to: q) }
                } else if renderer == nil {
                    path.move(to: q)
                }
                last = q
            }
        }
        guard renderer == nil else { return }
        trailGlow.path = path
        trailLine.path = path
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

    /// Screen directions of the world's right and down.
    private var worldRight: CGPoint { CGPoint(x: cos(upAngle), y: sin(upAngle)) }
    private var worldDown: CGPoint { CGPoint(x: -sin(upAngle), y: cos(upAngle)) }

    /// A screen offset in world-upright terms: (along the horizon, down).
    private func upright(_ d: CGPoint) -> CGPoint {
        CGPoint(x: d.x * worldRight.x + d.y * worldRight.y, y: d.x * worldDown.x + d.y * worldDown.y)
    }

    /// Labels the selected peak, then the biggest visible peaks, skipping any that would
    /// crowd a placed label; a selected peak out of view gets an arrow at the edge. Every
    /// other peak in sight gets a small dot, so it can be tapped too.
    private func layoutLabels(_ scene: TerrainScene, _ projector: Camera.Projector, heading: Double, reach: Int,
                              model: AppModel) -> [(Int64, CGFloat)] {
        let units = model.settings.units
        // Zoomed in, peaks spread apart and there's room for more labels.
        let maxLabels = model.settings.labels.maxLabels + (model.zoom > 1.5 ? 6 : 0)
        var placed: [(id: Int64, point: CGPoint)] = []
        var shownLabels: [(id: Int64, image: LabelImage, point: CGPoint)] = []
        // The label rises about 70 points above its peak, toward the world's up.
        func fits(_ p: CGPoint, margin: CGFloat) -> Bool {
            let top = CGPoint(x: p.x - 70 * worldDown.x, y: p.y - 70 * worldDown.y)
            let area = bounds.insetBy(dx: margin, dy: margin)
            return area.contains(p) && area.contains(top)
        }
        let limit = Double(min(reach, 90))

        arrowLayer.isHidden = true
        if let id = model.selectedPeakID, let v = scene.allPeaks[id] {
            if abs(azimuthDifference(v.azimuth, heading)) < limit + 10, let p = point(projector, v.azimuth, v.elevation),
               fits(p, margin: 8) {
                let image = labelImage(name: v.peak.name, detail: Format.elevation(of: v.peak, units) + (v.isVisible ? "" : " · hidden"),
                                       selected: true, hidden: !v.isVisible)
                shownLabels.append((id, image, p))
                placed.append((id, p))
            } else {
                layoutEdgeArrow(name: v.peak.name, distance: Format.distance(v.distance, units),
                                toRight: azimuthDifference(v.azimuth, heading) > 0, id: id)
            }
        }

        var candidates: [(id: Int64, point: CGPoint)] = []
        for v in scene.peaks where v.id != model.selectedPeakID {
            guard abs(azimuthDifference(v.azimuth, heading)) < limit,
                  let p = point(projector, v.azimuth, v.elevation), bounds.insetBy(dx: 4, dy: 4).contains(p) else { continue }
            if placed.count < maxLabels, fits(p, margin: 16),
               placed.allSatisfy({
                   let d = upright(CGPoint(x: $0.point.x - p.x, y: $0.point.y - p.y))
                   return abs(d.x) > 84 || abs(d.y) > 70
               }) {
                placed.append((v.id, p))
                shownLabels.append((v.id, labelImage(name: v.peak.name, detail: Format.elevation(of: v.peak, units),
                                                     selected: false, hidden: false), p))
            } else if candidates.count < 150 {
                candidates.append((v.id, p))
            }
        }

        // Label layers: reuse each peak's, hide the rest.
        var used = Set<Int64>()
        for (id, image, p) in shownLabels {
            used.insert(id)
            let l: CALayer
            if let existing = labelLayers[id] {
                l = existing
            } else {
                l = CALayer()
                l.contentsScale = traitCollection.displayScale
                labelContainer.addSublayer(l)
                labelLayers[id] = l
            }
            if labelShows[id] != ObjectIdentifier(image.image) {
                l.contents = image.image
                labelShows[id] = ObjectIdentifier(image.image)
            }
            l.bounds = CGRect(origin: .zero, size: image.size)
            l.anchorPoint = CGPoint(x: image.anchor.x / image.size.width, y: image.anchor.y / image.size.height)
            l.position = p
            l.setAffineTransform(CGAffineTransform(rotationAngle: upAngle))
            l.isHidden = false
            let turn = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: upAngle)
            labelHits.append((image.box.applying(turn), id))
        }
        for (id, l) in labelLayers where !used.contains(id) {
            l.removeFromSuperlayer()
            labelLayers[id] = nil
            labelShows[id] = nil
        }

        dots = candidates
            .filter { c in placed.allSatisfy { abs($0.point.x - c.point.x) > 10 || abs($0.point.y - c.point.y) > 10 } }
            .map { (point: $0.point, id: $0.id) }
        if renderer != nil {
            for (p, _) in dots { segments.append(Self.dotStyle.segment(p, p)) }
        } else {
            let dotPath = CGMutablePath()
            for (p, _) in dots { dotPath.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)) }
            dotLayer.path = dotPath
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return placed.map { ($0.id, upright(CGPoint(x: $0.point.x - center.x, y: $0.point.y - center.y)).x) }
    }

    /// A peak's label, drawn once: a dot, a leader line up from it and the name and height
    /// above.
    private func labelImage(name: String, detail: String, selected: Bool, hidden: Bool) -> LabelImage {
        let key = "\(name)|\(detail)|\(selected)|\(hidden)"
        if let cached = images[key] { return cached }
        if images.count > 200 { images.removeAll() }

        let title = NSAttributedString(string: name, attributes: selected ? Self.selectedAttributes : hidden ? Self.hiddenAttributes : Self.nameAttributes)
        let height = NSAttributedString(string: detail, attributes: Self.heightAttributes)
        let titleSize = title.size(), heightSize = height.size()
        // Laid out around the dot at (0, 0).
        let heightOrigin = CGPoint(x: -heightSize.width / 2, y: -36 - heightSize.height)
        let titleOrigin = CGPoint(x: -titleSize.width / 2, y: heightOrigin.y - titleSize.height + 2)
        let box = CGRect(origin: titleOrigin, size: titleSize).union(CGRect(origin: heightOrigin, size: heightSize))
            .union(CGRect(x: -10, y: -36, width: 20, height: 46))
        let canvas = box.insetBy(dx: -5, dy: -5).integral
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: canvas.size, format: format).image { context in
            context.cgContext.translateBy(x: -canvas.minX, y: -canvas.minY)
            let leader = UIBezierPath()
            leader.move(to: CGPoint(x: 0, y: -5))
            leader.addLine(to: CGPoint(x: 0, y: -34))
            leader.lineWidth = selected ? 1.5 : 1
            if hidden { leader.setLineDash([3, 3], count: 2, phase: 0) }
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
        images[key] = image
        return image
    }

    /// A small tag at the edge of the view, along the horizon, pointing toward a selected
    /// peak out of view.
    private func layoutEdgeArrow(name: String, distance: String, toRight: Bool, id: Int64) {
        let key = "arrow|\(name)|\(distance)|\(toRight)"
        let image: LabelImage
        if let cached = images[key] {
            image = cached
        } else {
            let text = NSAttributedString(string: toRight ? "\(name) · \(distance)  ›" : "‹  \(name) · \(distance)",
                                          attributes: Self.selectedAttributes)
            let size = text.size()
            let box = CGRect(x: -size.width / 2 - 10, y: -size.height / 2 - 6, width: size.width + 20, height: size.height + 12)
            let canvas = box.integral
            let format = UIGraphicsImageRendererFormat()
            format.scale = traitCollection.displayScale
            format.opaque = false
            let rendered = UIGraphicsImageRenderer(size: canvas.size, format: format).image { context in
                context.cgContext.translateBy(x: -canvas.minX, y: -canvas.minY)
                UIColor.black.withAlphaComponent(0.45).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).fill()
                text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
            }
            image = LabelImage(image: rendered.cgImage!, size: canvas.size, anchor: CGPoint(x: -canvas.minX, y: -canvas.minY), box: box)
            images[key] = image
        }
        // From the middle toward the world's right (or left), stopping short of the edge.
        let dir = toRight ? worldRight : CGPoint(x: -worldRight.x, y: -worldRight.y)
        let halfW = bounds.width / 2 - 24, halfH = bounds.height / 2 - 60
        let reach = min(abs(dir.x) > 0.01 ? halfW / abs(dir.x) : .infinity, abs(dir.y) > 0.01 ? halfH / abs(dir.y) : .infinity)
        let along = max(0, reach - image.size.width / 2 - 10)
        let center = CGPoint(x: bounds.midX + dir.x * along, y: bounds.midY + dir.y * along)
        arrowLayer.contentsScale = traitCollection.displayScale
        arrowLayer.contents = image.image
        arrowLayer.bounds = CGRect(origin: .zero, size: image.size)
        arrowLayer.anchorPoint = CGPoint(x: image.anchor.x / image.size.width, y: image.anchor.y / image.size.height)
        arrowLayer.position = center
        arrowLayer.setAffineTransform(CGAffineTransform(rotationAngle: upAngle))
        arrowLayer.isHidden = false
        labelHits.append((image.box.applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: upAngle)), id))
    }

    /// A light tick when a labeled peak crosses the middle of the screen. Positions are
    /// along the horizon from the middle.
    private func tickIfCrossing(_ labels: [(Int64, CGFloat)], at now: Date) {
        var sides: [Int64: Bool] = [:]
        var crossed = false
        for (id, x) in labels {
            let right = x > 0
            if let before = lastSide[id], before != right, abs(x) < 60 { crossed = true }
            sides[id] = right
        }
        lastSide = sides
        if crossed, now.timeIntervalSince(lastTick) > 0.15 {
            haptics.selectionChanged()
            lastTick = now
        }
    }
}

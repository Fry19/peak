import PeakCore
import UIKit

/// Thin glowing ridgelines, nearer ones brighter and farther ones fading like haze, a few
/// labels for the most prominent visible peaks, and a trail laid on the mountain. Drawn for
/// the frame on screen, with the phone's pose from the moment that frame was taken.
final class OverlayCanvas: UIView {
    weak var model: AppModel?
    weak var screen: CameraScreenView?
    private var link: CADisplayLink?
    private var smoothed: ViewCorrection?
    private var lastDraw = Date()
    private var lastSide: [Int64: Bool] = [:]
    private var lastTick = Date.distantPast
    private let haptics = UISelectionFeedbackGenerator()
    /// Where each label was drawn, for taps.
    private var labelHits: [(rect: CGRect, id: Int64)] = []

    /// Distance bands: (farthest distance in meters, opacity).
    private static let bands: [(Float, CGFloat)] = [(3_000, 0.95), (10_000, 0.75), (30_000, 0.55), (.infinity, 0.35)]
    private static let tint = UIColor(red: 0.86, green: 0.94, blue: 1.0, alpha: 1)
    private static let trailColor = UIColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 1)
    private static let accent = UIColor(red: 1.0, green: 0.84, blue: 0.45, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        if window != nil {
            // New frames redraw the overlay; this keeps it alive when none come (paused, or
            // the camera not running yet). The link holds its target until invalidated.
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick() {
        if Date().timeIntervalSince(screen?.lastFrameDate ?? .distantPast) > 0.1 { setNeedsDisplay() }
    }

    /// The peak whose label is at `point`, if any.
    func peak(at point: CGPoint) -> Int64? {
        labelHits.first { $0.rect.insetBy(dx: -12, dy: -12).contains(point) }?.id
    }

    override func draw(_ rect: CGRect) {
        labelHits = []
        guard let model, let ctx = UIGraphicsGetCurrentContext(), let scene = model.scene else { return }
        let frozen = model.frozen
        let now = Date()
        let shown = frozen?.shown ?? screen?.shown ?? fallbackShown(model)
        guard let pose = frozen?.pose ?? model.motion.pose(at: shown.time) ?? model.motion.pose else { return }
        let correction = frozen?.correction ?? smoothedCorrection(model.viewCorrection, at: now)
        let orientation = screen?.interfaceOrientation ?? .portrait
        let camera = CameraGeometry.screenCamera(pose: pose, lens: shown.lens, portraitFrame: shown.portrait,
                                                 orientation: orientation, size: bounds.size, correction: correction)
        let projector = camera.projector
        let settings = model.settings
        drawRidges(scene, projector, heading: camera.attitude.heading, ridges: settings.showRidges, in: ctx)
        if let runs = model.arTrail?.runs { drawTrail(runs, projector, in: ctx) }
        let placed = drawLabels(scene, projector, heading: camera.attitude.heading, model: model, in: ctx)
        if frozen == nil, settings.haptics { tickIfCrossing(placed, at: now) }
    }

    /// Before the first frame: the latest lens, or a typical one.
    private func fallbackShown(_ model: AppModel) -> AppModel.Shown {
        let lens = model.camera.lens ?? CameraFeed.Lens(intrinsics: CameraIntrinsics(width: 1080, height: 1920, horizontalFOV: 38),
                                                        measured: false)
        return AppModel.Shown(time: model.motion.latestTime ?? 0, lens: lens, portrait: lens.intrinsics.height > lens.intrinsics.width)
    }

    /// Eases corrections in instead of jumping.
    private func smoothedCorrection(_ target: ViewCorrection, at now: Date) -> ViewCorrection {
        let dt = max(0, min(0.2, now.timeIntervalSince(lastDraw)))
        lastDraw = now
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

    private func drawRidges(_ scene: TerrainScene, _ projector: Camera.Projector, heading: Double, ridges: Bool, in ctx: CGContext) {
        let paths = Self.bands.map { _ in CGMutablePath() }
        let skyline = CGMutablePath()
        let center = Int(heading.rounded())
        // ±70° covers the view's diagonal in either orientation.
        for offset in -70...70 {
            for s in scene.segments[(center + offset + 720) % 360] where ridges || s.isSkyline {
                guard let a = point(projector, Double(s.azimuth0), Double(s.elevation0)),
                      let b = point(projector, Double(s.azimuth1), Double(s.elevation1)) else { continue }
                let path = s.isSkyline ? skyline : paths[Self.bands.firstIndex { s.distance < $0.0 } ?? Self.bands.count - 1]
                path.move(to: a)
                path.addLine(to: b)
            }
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // A wide faint stroke under each line for the glow (cheaper than a blurred shadow),
        // ridges first and the skyline on top.
        for (i, path) in paths.enumerated() {
            let alpha = Self.bands[i].1
            stroke(path, in: ctx, color: Self.tint.withAlphaComponent(alpha * 0.18), width: 4)
            stroke(path, in: ctx, color: Self.tint.withAlphaComponent(alpha), width: 1)
        }
        stroke(skyline, in: ctx, color: Self.tint.withAlphaComponent(0.3), width: 5)
        stroke(skyline, in: ctx, color: UIColor.white.withAlphaComponent(0.95), width: 1.4)
    }

    /// The trail's visible stretches, laid on the slope.
    private func drawTrail(_ runs: [[DrapedPoint]], _ projector: Camera.Projector, in ctx: CGContext) {
        let path = CGMutablePath()
        for run in runs {
            var pen = false
            for p in run {
                guard let q = point(projector, Double(p.azimuth), Double(p.elevation)) else {
                    pen = false
                    continue
                }
                if pen { path.addLine(to: q) } else { path.move(to: q) }
                pen = true
            }
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        stroke(path, in: ctx, color: Self.trailColor.withAlphaComponent(0.3), width: 8)
        stroke(path, in: ctx, color: Self.trailColor, width: 2.5)
    }

    private func stroke(_ path: CGPath, in ctx: CGContext, color: UIColor, width: CGFloat) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.strokePath()
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

    /// Labels the selected peak, then the biggest visible peaks, skipping any that would
    /// crowd a placed label; a selected peak out of view gets an arrow at the edge.
    private func drawLabels(_ scene: TerrainScene, _ projector: Camera.Projector, heading: Double,
                            model: AppModel, in ctx: CGContext) -> [(Int64, CGFloat)] {
        let units = model.settings.units
        let maxLabels = model.settings.labels.maxLabels
        var placed: [(id: Int64, point: CGPoint)] = []
        let area = bounds.insetBy(dx: 12, dy: 60)

        if let id = model.selectedPeakID, let v = scene.allPeaks[id] {
            if abs(azimuthDifference(v.azimuth, heading)) < 80, let p = point(projector, v.azimuth, v.elevation),
               bounds.insetBy(dx: 8, dy: 40).contains(p) {
                drawLabel(name: v.peak.name, detail: Format.elevation(v.peak.elevation, units) + (v.isVisible ? "" : " · hidden"),
                          at: p, selected: true, hidden: !v.isVisible, id: id)
                placed.append((id, p))
            } else {
                drawEdgeArrow(name: v.peak.name, distance: Format.distance(v.distance, units),
                              toRight: azimuthDifference(v.azimuth, heading) > 0, id: id)
            }
        }

        for v in scene.peaks where placed.count < maxLabels && v.id != model.selectedPeakID {
            guard abs(azimuthDifference(v.azimuth, heading)) < 70,
                  let p = point(projector, v.azimuth, v.elevation), area.contains(p),
                  placed.allSatisfy({ abs($0.point.x - p.x) > 84 || abs($0.point.y - p.y) > 70 }) else { continue }
            placed.append((v.peak.id, p))
            drawLabel(name: v.peak.name, detail: Format.elevation(v.peak.elevation, units), at: p, selected: false, hidden: false, id: v.id)
        }
        return placed.map { ($0.id, $0.point.x) }
    }

    private func drawLabel(name: String, detail: String, at p: CGPoint, selected: Bool, hidden: Bool, id: Int64) {
        let leader = UIBezierPath()
        leader.move(to: CGPoint(x: p.x, y: p.y - 5))
        leader.addLine(to: CGPoint(x: p.x, y: p.y - 34))
        leader.lineWidth = selected ? 1.5 : 1
        if hidden { leader.setLineDash([3, 3], count: 2, phase: 0) }
        (selected ? Self.accent : UIColor.white.withAlphaComponent(0.7)).setStroke()
        leader.stroke()
        (selected ? Self.accent : UIColor.white).setFill()
        let r: CGFloat = selected ? 3.5 : 2.5
        UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
        if selected {
            Self.accent.withAlphaComponent(0.6).setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            ring.lineWidth = 1
            ring.stroke()
        }

        let title = NSAttributedString(string: name, attributes: selected ? Self.selectedAttributes : hidden ? Self.hiddenAttributes : Self.nameAttributes)
        let height = NSAttributedString(string: detail, attributes: Self.heightAttributes)
        let titleSize = title.size(), heightSize = height.size()
        let heightOrigin = CGPoint(x: p.x - heightSize.width / 2, y: p.y - 36 - heightSize.height)
        let titleOrigin = CGPoint(x: p.x - titleSize.width / 2, y: heightOrigin.y - titleSize.height + 2)
        height.draw(at: heightOrigin)
        title.draw(at: titleOrigin)
        let box = CGRect(origin: titleOrigin, size: titleSize).union(CGRect(origin: heightOrigin, size: heightSize))
            .union(CGRect(x: p.x - 6, y: p.y - 36, width: 12, height: 42))
        labelHits.append((box, id))
    }

    /// A small tag at the left or right edge pointing toward a selected peak out of view.
    private func drawEdgeArrow(name: String, distance: String, toRight: Bool, id: Int64) {
        let text = NSAttributedString(string: toRight ? "\(name) · \(distance)  ›" : "‹  \(name) · \(distance)",
                                      attributes: Self.selectedAttributes)
        let size = text.size()
        let x = toRight ? bounds.maxX - size.width - 20 : bounds.minX + 20
        let box = CGRect(x: x - 10, y: bounds.midY - size.height / 2 - 6, width: size.width + 20, height: size.height + 12)
        UIColor.black.withAlphaComponent(0.45).setFill()
        UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: x, y: bounds.midY - size.height / 2))
        labelHits.append((box, id))
    }

    /// A light tick when a labeled peak crosses the middle of the screen.
    private func tickIfCrossing(_ labels: [(Int64, CGFloat)], at now: Date) {
        let centerX = bounds.midX
        var sides: [Int64: Bool] = [:]
        var crossed = false
        for (id, x) in labels {
            let right = x > centerX
            if let before = lastSide[id], before != right, abs(x - centerX) < 60 { crossed = true }
            sides[id] = right
        }
        lastSide = sides
        if crossed, now.timeIntervalSince(lastTick) > 0.15 {
            haptics.selectionChanged()
            lastTick = now
        }
    }
}

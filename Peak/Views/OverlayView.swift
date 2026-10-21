import PeakCore
import SwiftUI
import UIKit

/// The ridgelines and labels over the camera picture.
struct OverlayView: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> OverlayCanvas {
        let view = OverlayCanvas()
        view.model = model
        return view
    }

    func updateUIView(_ view: OverlayCanvas, context: Context) {
        view.model = model
    }
}

/// Thin glowing ridgelines, nearer ones brighter and farther ones fading like haze, and a
/// few labels for the most prominent visible peaks. A display link redraws it on every
/// screen refresh from the phone's latest orientation, so the lines stay put on the
/// mountains as the phone moves.
final class OverlayCanvas: UIView {
    weak var model: AppModel?
    private var link: CADisplayLink?
    private var smoothed: Double?
    private var lastFrame = Date()
    private var lastSide: [Int64: Bool] = [:]
    private var lastTick = Date.distantPast
    private let haptics = UISelectionFeedbackGenerator()

    /// Distance bands: (farthest distance in meters, opacity).
    private static let bands: [(Float, CGFloat)] = [(3_000, 0.95), (10_000, 0.75), (30_000, 0.55), (.infinity, 0.35)]
    private static let tint = UIColor(red: 0.86, green: 0.94, blue: 1.0, alpha: 1)

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
            // The display link holds its target strongly; it is invalidated when the view leaves.
            let link = CADisplayLink(target: self, selector: #selector(frameTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func frameTick() {
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let model, let ctx = UIGraphicsGetCurrentContext(), let scene = model.scene else { return }
        let frozen = model.frozen
        guard let pose = frozen?.pose ?? model.motion.pose else { return }
        let now = Date()
        let correction = frozen?.heading ?? smoothedCorrection(model.headingCorrection, at: now)
        let camera = Camera(intrinsics: model.camera.screenIntrinsics(for: bounds.size),
                            attitude: CameraGeometry.attitude(pose, correction: correction))
        let projector = camera.projector
        drawRidges(scene, projector, heading: camera.attitude.heading, in: ctx)
        let placed = drawLabels(scene, projector, heading: camera.attitude.heading)
        if frozen == nil { tickIfCrossing(placed, at: now) }
    }

    /// Eases compass corrections in instead of jumping.
    private func smoothedCorrection(_ target: Double, at now: Date) -> Double {
        let dt = max(0, min(0.2, now.timeIntervalSince(lastFrame)))
        lastFrame = now
        guard let value = smoothed, abs(target - value) < 30 else {
            smoothed = target
            return target
        }
        let next = value + (target - value) * (1 - exp(-dt / 0.35))
        smoothed = next
        return next
    }

    private func point(_ projector: Camera.Projector, _ azimuth: Double, _ elevation: Double) -> CGPoint? {
        projector.pixel(azimuth: azimuth, elevation: elevation).map { CGPoint(x: $0.x, y: $0.y) }
    }

    private func drawRidges(_ scene: TerrainScene, _ projector: Camera.Projector, heading: Double, in ctx: CGContext) {
        let paths = Self.bands.map { _ in CGMutablePath() }
        let skyline = CGMutablePath()
        let center = Int(heading.rounded())
        for offset in -70...70 {
            for s in scene.segments[(center + offset + 720) % 360] {
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

    private func stroke(_ path: CGPath, in ctx: CGContext, color: UIColor, width: CGFloat) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static let nameAttributes: [NSAttributedString.Key: Any] = {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        return [.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.white, .shadow: shadow]
    }()

    private static let heightAttributes: [NSAttributedString.Key: Any] = {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        return [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.white.withAlphaComponent(0.75), .shadow: shadow]
    }()

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Labels the biggest visible peaks first, skipping any that would crowd a placed label.
    private func drawLabels(_ scene: TerrainScene, _ projector: Camera.Projector, heading: Double) -> [(Int64, CGFloat)] {
        let maxLabels = 10
        var placed: [(id: Int64, point: CGPoint)] = []
        let area = bounds.insetBy(dx: 12, dy: 60)
        for v in scene.peaks where placed.count < maxLabels {
            guard abs(azimuthDifference(v.azimuth, heading)) < 70,
                  let p = point(projector, v.azimuth, v.elevation), area.contains(p),
                  placed.allSatisfy({ abs($0.point.x - p.x) > 84 || abs($0.point.y - p.y) > 70 }) else { continue }
            placed.append((v.peak.id, p))

            let leader = UIBezierPath()
            leader.move(to: CGPoint(x: p.x, y: p.y - 5))
            leader.addLine(to: CGPoint(x: p.x, y: p.y - 34))
            UIColor.white.withAlphaComponent(0.7).setStroke()
            leader.lineWidth = 1
            leader.stroke()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()

            let name = NSAttributedString(string: v.peak.name, attributes: Self.nameAttributes)
            let height = NSAttributedString(
                string: (Self.formatter.string(from: NSNumber(value: v.peak.elevation.rounded())) ?? "\(Int(v.peak.elevation))") + " m",
                attributes: Self.heightAttributes)
            let nameSize = name.size(), heightSize = height.size()
            height.draw(at: CGPoint(x: p.x - heightSize.width / 2, y: p.y - 36 - heightSize.height))
            name.draw(at: CGPoint(x: p.x - nameSize.width / 2, y: p.y - 36 - heightSize.height - nameSize.height + 2))
        }
        return placed.map { ($0.id, $0.point.x) }
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

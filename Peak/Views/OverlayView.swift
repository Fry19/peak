import ARKit
import PeakCore
import SwiftUI

/// Thin glowing ridgelines, nearer ones brighter and farther ones fading like haze, and a
/// few labels for the most prominent visible peaks. Redrawn every display frame from
/// ARKit's latest camera, so the overlay moves with the picture.
struct OverlayView: View {
    let model: AppModel
    @State private var haptics = CenterHaptics()

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                guard let scene = model.scene,
                      let camera = model.frozen?.camera ?? model.session.currentFrame?.camera else { return }
                let projector = ScreenProjector(camera: camera, size: size, correction: model.correction.degrees)
                drawRidges(scene, projector, in: &context)
                let placed = drawLabels(scene, projector, in: &context)
                if model.frozen == nil { haptics.update(placed, centerX: size.width / 2) }
            }
        }
        .allowsHitTesting(false)
    }

    /// Distance bands: (farthest distance in meters, opacity).
    private static let bands: [(Float, Double)] = [(3_000, 0.95), (10_000, 0.75), (30_000, 0.55), (.infinity, 0.35)]

    private func drawRidges(_ scene: TerrainScene, _ projector: ScreenProjector, in context: inout GraphicsContext) {
        var paths = [Path](repeating: Path(), count: Self.bands.count)
        var skyline = Path()
        let center = Int(projector.heading.rounded())
        for offset in -60...60 {
            for s in scene.segments[(center + offset + 720) % 360] {
                guard let a = projector.point(azimuth: Double(s.azimuth0), elevation: Double(s.elevation0)),
                      let b = projector.point(azimuth: Double(s.azimuth1), elevation: Double(s.elevation1)) else { continue }
                if s.isSkyline {
                    skyline.move(to: a)
                    skyline.addLine(to: b)
                } else {
                    let band = Self.bands.firstIndex { s.distance < $0.0 } ?? Self.bands.count - 1
                    paths[band].move(to: a)
                    paths[band].addLine(to: b)
                }
            }
        }
        let tint = Color(red: 0.86, green: 0.94, blue: 1.0)
        // Glow underneath, then the thin line.
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 4))
            glow.stroke(skyline, with: .color(tint.opacity(0.55)), lineWidth: 5)
            for (i, path) in paths.enumerated() {
                glow.stroke(path, with: .color(tint.opacity(Self.bands[i].1 * 0.35)), lineWidth: 4)
            }
        }
        context.stroke(skyline, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        for (i, path) in paths.enumerated() {
            context.stroke(path, with: .color(tint.opacity(Self.bands[i].1)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    /// Labels the biggest visible peaks first, skipping any that would crowd a placed label.
    private func drawLabels(_ scene: TerrainScene, _ projector: ScreenProjector,
                            in context: inout GraphicsContext) -> [(Int64, CGFloat)] {
        let maxLabels = 10
        var placed: [(id: Int64, point: CGPoint)] = []
        let bounds = CGRect(origin: .zero, size: projector.size).insetBy(dx: 12, dy: 60)
        for v in scene.peaks where placed.count < maxLabels {
            guard abs(azimuthDifference(v.azimuth, projector.heading)) < 60,
                  let p = projector.point(azimuth: v.azimuth, elevation: v.elevation), bounds.contains(p),
                  placed.allSatisfy({ abs($0.point.x - p.x) > 84 || abs($0.point.y - p.y) > 70 }) else { continue }
            placed.append((v.peak.id, p))

            let top = CGPoint(x: p.x, y: p.y - 34)
            var leader = Path()
            leader.move(to: CGPoint(x: p.x, y: p.y - 5))
            leader.addLine(to: top)
            context.stroke(leader, with: .color(.white.opacity(0.7)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(.white))

            var text = context
            text.addFilter(.shadow(color: .black.opacity(0.6), radius: 3))
            text.draw(Text(v.peak.name).font(.system(size: 15, weight: .semibold)).foregroundColor(.white),
                      at: CGPoint(x: top.x, y: top.y - 16), anchor: .bottom)
            text.draw(Text(Self.elevation(v.peak.elevation)).font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.75)),
                      at: CGPoint(x: top.x, y: top.y - 2), anchor: .bottom)
        }
        return placed.map { ($0.id, $0.point.x) }
    }

    private static func elevation(_ meters: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: NSNumber(value: meters.rounded())) ?? "\(Int(meters))") + " m"
    }
}

/// A light tick when a labeled peak crosses the middle of the screen.
final class CenterHaptics {
    private var lastSide: [Int64: Bool] = [:]
    private var lastTick = Date.distantPast
    private let generator = UISelectionFeedbackGenerator()

    func update(_ labels: [(Int64, CGFloat)], centerX: CGFloat) {
        var sides: [Int64: Bool] = [:]
        var crossed = false
        for (id, x) in labels {
            let right = x > centerX
            if let before = lastSide[id], before != right, abs(x - centerX) < 60 { crossed = true }
            sides[id] = right
        }
        lastSide = sides
        if crossed, Date().timeIntervalSince(lastTick) > 0.15 {
            generator.selectionChanged()
            lastTick = Date()
        }
    }
}

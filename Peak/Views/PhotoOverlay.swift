import PeakCore
import UIKit

/// The ridgelines and labels over a still picture, in the live view's style, laid out in
/// the picture's own pixels. The same drawing is shown scaled down on screen and saved at
/// full size, so what's shared is exactly what was seen.
///
/// Sizes are in "units": one point of the live overlay, as if the picture filled a phone's
/// screen, so labels keep their share of the picture whatever its resolution.
struct PhotoOverlay {
    enum Variant: String, CaseIterable, Identifiable {
        case labels, clean
        var id: String { rawValue }
        var title: String { self == .labels ? "Labels" : "Lines only" }
    }

    /// A label placed on the picture: the peak's dot, and the label's extent around it.
    struct Placed {
        var id: Int64
        var point: CGPoint
        var title: NSAttributedString
        var detail: NSAttributedString
        var selected: Bool
        /// Name and elevation, relative to the dot.
        var box: CGRect
        var titleOrigin: CGPoint
        var detailOrigin: CGPoint

        /// Where a tap selects it, in the picture's pixels.
        var hitRect: CGRect { box.offsetBy(dx: point.x, dy: point.y) }
    }

    var scene: TerrainScene
    /// The camera for the picture, in its pixels.
    var camera: Camera
    var units: AppSettings.Units
    var variant = Variant.labels
    var ridges = true
    var maxLabels = 10
    /// Highlighted while its card is open (on screen only, never in what's saved).
    var selectedID: Int64?
    /// Summits pinned while lining up by hand: labeled whatever their rank, to show they're
    /// on their pins.
    var pinned: Set<Int64> = []
    /// Device pixels per picture pixel where it's drawn: shadows are blurred in device
    /// pixels, whatever the context's scale (1 when saving at full size).
    var deviceScale: CGFloat = 1

    static let attribution = "© OpenStreetMap contributors, Copernicus DEM"

    var size: CGSize { CGSize(width: camera.intrinsics.width, height: camera.intrinsics.height) }
    var unit: CGFloat { max(0.5, (size.width * size.height).squareRoot() / 560) }

    // The live overlay's look (see OverlayCanvas): distance bands, nearer brighter.
    private static let bands: [(Float, CGFloat)] = [(3_000, 0.95), (10_000, 0.75), (30_000, 0.55), (.infinity, 0.35)]
    private static let tint = UIColor(red: 0.86, green: 0.94, blue: 1.0, alpha: 1)
    private static let accent = UIColor(red: 1.0, green: 0.84, blue: 0.45, alpha: 1)
    private static let nearestRidge: Float = 1_000

    // MARK: Labels

    /// Which peaks get a label and where: the most prominent visible ones that fit without
    /// crowding, as in the live view. Peaks behind nearer ridges are never labeled.
    func labels() -> [Placed] {
        guard variant == .labels else { return [] }
        let u = unit
        let projector = camera.projector
        let bounds = CGRect(origin: .zero, size: size)
        let inside = bounds.insetBy(dx: 4 * u, dy: 4 * u)
        var candidates: [LabelLayout.Candidate] = []
        var drafts: [Int64: Placed] = [:]
        for v in scene.peaks where abs(azimuthDifference(v.azimuth, camera.attitude.heading)) < 90 {
            guard candidates.count < maxLabels * 4 || v.id == selectedID || pinned.contains(v.id),
                  let p = projector.pixel(azimuth: v.azimuth, elevation: v.elevation) else { continue }
            let point = CGPoint(x: p.x, y: p.y)
            guard inside.contains(point) else { continue }
            let draft = Self.place(v.peak, at: point, units: units, selected: v.id == selectedID, unit: u)
            drafts[v.id] = draft
            candidates.append(LabelLayout.Candidate(
                id: v.id, x: p.x, y: p.y,
                score: v.id == selectedID ? .infinity : pinned.contains(v.id) ? 1e9 : scene.scores[v.id] ?? 0,
                box: LabelBox(minX: draft.box.minX, minY: draft.box.minY, maxX: draft.box.maxX, maxY: draft.box.maxY),
                isSelected: v.id == selectedID))
        }
        var layout = LabelLayout(bounds: ScreenRect(x: 0, y: 0, width: size.width, height: size.height),
                                 keepClear: [Self.screenRect(attributionRect)], limit: maxLabels)
        // The layout's gaps and margins are in points; here they're in pixels.
        var t = layout.thresholds
        t.enterGap *= u; t.keepGap *= u; t.enterMargin *= u; t.keepMargin *= u
        t.enterClear *= u; t.keepClear *= u; t.dotClearance *= u; t.selectedMargin *= u
        layout.thresholds = t
        return layout.place(candidates, previous: []).labels.compactMap { drafts[$0] }
    }

    private static func screenRect(_ r: CGRect) -> ScreenRect {
        ScreenRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    /// A label above its dot: a leader line up, the name, and the elevation under it.
    private static func place(_ peak: Peak, at point: CGPoint, units: AppSettings.Units, selected: Bool, unit u: CGFloat) -> Placed {
        let title = NSAttributedString(string: peak.name, attributes: [
            .font: UIFont.systemFont(ofSize: (selected ? 16 : 15) * u, weight: selected ? .bold : .semibold),
            .foregroundColor: selected ? accent : UIColor.white,
        ])
        let detail = NSAttributedString(string: Format.elevation(of: peak, units), attributes: [
            .font: UIFont.systemFont(ofSize: 12 * u, weight: .regular),
            .foregroundColor: UIColor.white.withAlphaComponent(0.8),
        ])
        let ts = title.size(), ds = detail.size()
        let detailOrigin = CGPoint(x: -ds.width / 2, y: -36 * u - ds.height)
        let titleOrigin = CGPoint(x: -ts.width / 2, y: detailOrigin.y - ts.height + 2 * u)
        let stem = CGRect(x: -10 * u, y: -36 * u, width: 20 * u, height: 46 * u)
        let box = CGRect(origin: titleOrigin, size: ts).union(CGRect(origin: detailOrigin, size: ds)).union(stem)
        return Placed(id: peak.id, point: point, title: title, detail: detail, selected: selected, box: box,
                      titleOrigin: titleOrigin, detailOrigin: detailOrigin)
    }

    private var attributionText: NSAttributedString {
        NSAttributedString(string: Self.attribution, attributes: [
            .font: UIFont.systemFont(ofSize: 8.5 * unit, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.62),
            .kern: 0.2 * unit,
        ])
    }

    private var attributionRect: CGRect {
        let s = attributionText.size()
        let margin = 12 * unit
        return CGRect(x: size.width - margin - s.width, y: size.height - margin - s.height, width: s.width, height: s.height)
    }

    // MARK: Drawing

    /// Draws the lines, `labels` and the attribution into a context in the picture's pixels
    /// (y down), such as an image renderer's or a scaled-down one on screen.
    func draw(in ctx: CGContext, labels: [Placed]) {
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        drawRidges(ctx)
        for label in labels { draw(label, ctx) }
        drawText(attributionText, at: attributionRect.origin, ctx, halo: 0.5)
    }

    /// The picture with everything over it, at full size.
    func render(_ picture: CGImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let placed = labels()
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: picture).draw(in: CGRect(origin: .zero, size: size))
            draw(in: context.cgContext, labels: placed)
        }
    }

    private func drawRidges(_ ctx: CGContext) {
        let u = unit
        let projector = camera.projector
        let k = camera.intrinsics
        let half = atan(Double(hypot(size.width, size.height)) / 2 / k.fx) * 180 / .pi
        let top = min(85, abs(camera.attitude.pitch) + half)
        let reach = Int(min(180, half / cos(top * .pi / 180) + 3))
        let area = CGRect(origin: .zero, size: size).insetBy(dx: -40 * u, dy: -40 * u)
        // One path per distance band, and the skyline, each joined end to end.
        let paths = (0...Self.bands.count).map { _ in CGMutablePath() }
        var ends = [CGPoint?](repeating: nil, count: paths.count)
        let center = Int(camera.attitude.heading.rounded())
        for offset in -reach...reach {
            for s in scene.segments[((center + offset) % 360 + 360) % 360]
            where s.isSkyline || (ridges && s.distance >= Self.nearestRidge) {
                guard let a = projector.pixel(azimuth: Double(s.azimuth0), elevation: Double(s.elevation0)),
                      let b = projector.pixel(azimuth: Double(s.azimuth1), elevation: Double(s.elevation1)) else { continue }
                let pa = CGPoint(x: a.x, y: a.y), pb = CGPoint(x: b.x, y: b.y)
                guard area.contains(pa) || area.contains(pb) else { continue }
                let i = s.isSkyline ? Self.bands.count : (Self.bands.firstIndex { s.distance < $0.0 } ?? Self.bands.count - 1)
                if let end = ends[i], abs(end.x - pa.x) < 0.5 * u, abs(end.y - pa.y) < 0.5 * u {
                    paths[i].addLine(to: pb)
                } else {
                    paths[i].move(to: pa)
                    paths[i].addLine(to: pb)
                }
                ends[i] = pb
            }
        }
        // Width, glow spread and glow opacity per path, and the line's color.
        func style(_ i: Int) -> (width: CGFloat, glow: CGFloat, glowAlpha: CGFloat, color: UIColor) {
            if i == Self.bands.count { return (1.4, 4.5, 0.32, UIColor(red: 0.97, green: 0.99, blue: 1, alpha: 0.95)) }
            let a = Self.bands[i].1
            return (1, 3.5, a * 0.22, Self.tint.withAlphaComponent(a))
        }
        func stroke(_ path: CGPath, width: CGFloat, color: UIColor, blur: CGFloat = 0, shadow: UIColor? = nil) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(color.cgColor)
            if let shadow { ctx.setShadow(offset: .zero, blur: blur, color: shadow.cgColor) }
            ctx.strokePath()
            ctx.restoreGState()
        }
        // A faint dark halo under everything, so pale lines read on snow and bright sky.
        for (i, path) in paths.enumerated() where !path.isEmpty {
            let s = style(i)
            let alpha = 0.28 * min(1, s.color.cgColor.alpha + 0.2)
            stroke(path, width: (s.width + 2.5) * u, color: UIColor.black.withAlphaComponent(alpha), blur: 2.5 * u * deviceScale,
                   shadow: UIColor.black.withAlphaComponent(alpha * 0.5))
        }
        // Far ridges first, the skyline last, each a soft glow under a fine line.
        for (i, path) in paths.enumerated() where !path.isEmpty {
            let s = style(i)
            let glow = Self.tint.withAlphaComponent(s.glowAlpha)
            stroke(path, width: s.glow * u, color: glow, blur: s.glow * u * deviceScale, shadow: glow)
            stroke(path, width: s.width * u, color: s.color)
        }
    }

    private func draw(_ label: Placed, _ ctx: CGContext) {
        let u = unit
        ctx.saveGState()
        ctx.translateBy(x: label.point.x, y: label.point.y)
        let color = label.selected ? Self.accent : UIColor.white
        // Leader and dot, over a soft dark halo.
        ctx.setShadow(offset: .zero, blur: 3 * u * deviceScale, color: UIColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setStrokeColor((label.selected ? Self.accent : UIColor.white.withAlphaComponent(0.75)).cgColor)
        ctx.setLineWidth((label.selected ? 1.5 : 1) * u)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 0, y: -5 * u))
        ctx.addLine(to: CGPoint(x: 0, y: -34 * u))
        ctx.strokePath()
        let r = (label.selected ? 3.5 : 2.5) * u
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
        let origin = label.point
        drawText(label.detail, at: CGPoint(x: origin.x + label.detailOrigin.x, y: origin.y + label.detailOrigin.y), ctx, halo: 0.6)
        drawText(label.title, at: CGPoint(x: origin.x + label.titleOrigin.x, y: origin.y + label.titleOrigin.y), ctx, halo: 0.7)
    }

    /// Text with a halo for snow and bright sky: a tight dark shadow, and a wide soft one
    /// around both (the transparency layer gives the text and its tight shadow one shadow).
    private func drawText(_ text: NSAttributedString, at point: CGPoint, _ ctx: CGContext, halo: CGFloat) {
        let u = unit
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10 * u * deviceScale, color: UIColor.black.withAlphaComponent(halo * 0.45).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setShadow(offset: .zero, blur: 2.5 * u * deviceScale, color: UIColor.black.withAlphaComponent(halo).cgColor)
        text.draw(at: point)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

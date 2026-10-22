import PeakCore
import SceneKit
import UIKit

/// A peak the walk in 3D may label: its summit in the walk's map meters (x east, y north,
/// z up), and how much it deserves a label (`PeakRanking`).
struct WalkPeak: Sendable {
    let peak: Peak
    let top: SIMD3<Double>
    let score: Double
}

/// The names of the mountains around the walk in 3D, as the camera view labels them: a dot
/// on the summit, a thin line up to the name and the elevation, the most prominent peaks
/// first and only a few, none hidden behind nearer terrain from where the camera is, fading
/// into the haze with distance. The hike's own summit comes first, in amber, kept inside the
/// screen's edges, and likewise only while it's in sight. Drawn over the 3D view at a
/// constant size, clear of the controls; it takes no
/// touches, so dragging still turns the camera.
final class WalkLabels: UIView {
    /// The controls over the view, in window coordinates, to keep labels clear of.
    var keepClear: [CGRect] = []

    private weak var world: WalkWorld?
    /// How far the line to each peak passed over the terrain when last checked, meters, and
    /// from where, by id.
    private var sightlines: [Int64: (clearance: Double, eye: SIMD3<Double>)] = [:]
    /// The peaks in sight from where the camera is now.
    private var inSight: Set<Int64> = []
    /// A check of which peaks are in sight is under way, and where the last one was made from.
    private var checking = false
    private var checkedEye: SIMD3<Double>?
    private var checkedIDs: [Int64] = []
    /// Labeled last frame, so a label stays put while it still fits (`LabelLayout`).
    private var labeled: Set<Int64> = []
    /// Of those, the ones labeled below their dots, for want of room above.
    private var labeledBelow: Set<Int64> = []
    private var slots: [Int64: Slot] = [:]
    private var images: [ImageKey: CGImage] = [:]
    /// Where each label's text reaches around its dot, measured once a world.
    private var boxes: [ImageKey: TextBox] = [:]

    private struct TextBox {
        var minX, minY, maxX, maxY: Double
    }

    /// The most labels at once, the summit's included.
    static let limit = 6
    /// How many of the best-ranked peaks in view are checked for being in sight each time.
    static let checked = 24
    /// A peak comes into sight only when the line to it passes this far over the terrain in
    /// between, meters; it goes as soon as the terrain is in the way.
    static let enterClearance = 3.0
    static let fade: CFTimeInterval = 0.25

    private struct Slot {
        let layer: CALayer
        let mark: CALayer
        let text: CALayer
        var key: ImageKey?
        var shown = false
        var lastShown: CFTimeInterval = 0
    }

    private struct ImageKey: Hashable {
        var id: Int64
        var summit: Bool
        var below: Bool
        var text: Bool
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Lays the labels out for the camera where it is now (`world.camera`'s model pose, which
    /// is what's drawn this frame): once per screen refresh.
    func update(world: WalkWorld, eye: SIMD3<Double>, now: CFTimeInterval) {
        if self.world !== world {
            // A sharper rebuild of the same ground: what was in sight is checked again.
            for slot in slots.values { slot.layer.removeFromSuperlayer() }
            slots = [:]
            images = [:]
            labeled = []
            labeledBelow = []
            self.world = world
            sightlines = [:]
            inSight = []
            boxes = [:]
            checkedEye = nil
            checkedIDs = []
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard bounds.width > 0, let camera = world.camera.camera else { return hideAll(now: now) }

        let view = simd_inverse(world.camera.simdWorldTransform)
        let focal = Double(bounds.height) / 2 / tan(camera.fieldOfView / 2 * .pi / 180)
        let fog = (start: Double(world.scene.fogStartDistance), end: Double(world.scene.fogEndDistance),
                   exponent: Double(world.scene.fogDensityExponent))
        /// Where a summit is on screen, if in front of the camera, and how deep in the haze, 0 to 1.
        func project(_ p: WalkPeak) -> (point: CGPoint, haze: Double)? {
            let s = WalkWorld.scn(p.top)
            let c = view * SIMD4<Float>(s.x, s.y, s.z, 1)
            let depth = Double(-c.z)
            guard depth > 10 else { return nil }
            let point = CGPoint(x: Double(bounds.midX) + Double(c.x) / depth * focal,
                                y: Double(bounds.midY) - Double(c.y) / depth * focal)
            let d = simd_distance(p.top, eye)
            let haze = pow(min(1, max(0, (d - fog.start) / max(1, fog.end - fog.start))), fog.exponent)
            return (point, haze)
        }

        // Peaks in view, best first, leaving out those lost in the haze.
        let area = bounds.insetBy(dx: -20, dy: -20)
        var inView: [(peak: WalkPeak, point: CGPoint, haze: Double)] = []
        for p in world.labelPeaks {
            guard let q = project(p), q.haze < 0.85, area.contains(q.point) else { continue }
            inView.append((p, q.point, q.haze))
        }
        // A check's answer holds while the camera stays near where it was made: moving the eye
        // d meters moves the line to a summit by at most d over any point in between, up or
        // across, and the ground under it by at most d times the terrain's steepest slope, so a
        // line that cleared the terrain by more than that still does. Past that, a peak counts
        // as hidden until checked again. Looking straight down, nothing was in between: that
        // holds for the first meters only.
        let bound = 1 + world.steepestSlope
        inSight = Set(sightlines.compactMap { id, s in
            let clearance = s.clearance.isFinite ? s.clearance : Self.enterClearance + 1
            let margin = clearance - bound * simd_distance(s.eye, eye)
            // Into sight with a little room to spare; out as soon as terrain may be in the way.
            return margin > (inSight.contains(id) ? 0 : Self.enterClearance) ? id : nil
        })
        let summit = world.summit.flatMap { s in project(s).map { (peak: s, point: $0.point, haze: $0.haze) } }
        check(world: world, eye: eye, peaks: (summit.map { [$0.peak] } ?? []) + inView.prefix(Self.checked).map(\.peak))

        let units = world.units
        var candidates: [LabelLayout.Candidate] = []
        var shown: [Int64: (peak: WalkPeak, point: CGPoint, haze: Double)] = [:]
        if let summit, safeBounds.contains(summit.point), inSight.contains(summit.peak.peak.id) {
            // Its name kept inside the edges, its line still from the summit.
            let text = textBox(summit.peak.peak, units, summit: true)
            let x = Double(summit.point.x), shift = inside(x: x, text)
            let above = LabelBox(minX: min(-10, text.minX + shift), minY: text.minY, maxX: max(10, text.maxX + shift), maxY: 10)
            let below = LabelBox(minX: above.minX, minY: -10, maxX: above.maxX, maxY: -text.minY)
            candidates.append(LabelLayout.Candidate(id: summit.peak.peak.id, x: x, y: Double(summit.point.y), score: .infinity,
                                                    box: above, flippedBox: below, isSelected: true))
            shown[summit.peak.peak.id] = summit
        }
        for v in inView.prefix(Self.checked) where inSight.contains(v.peak.peak.id) {
            let text = textBox(v.peak.peak, units, summit: false)
            let box = LabelBox(minX: min(-10, text.minX), minY: text.minY, maxX: max(10, text.maxX), maxY: 10)
            let below = LabelBox(minX: box.minX, minY: -10, maxX: box.maxX, maxY: -text.minY)
            candidates.append(LabelLayout.Candidate(id: v.peak.peak.id, x: Double(v.point.x), y: Double(v.point.y),
                                                    score: v.peak.score, box: box, flippedBox: below))
            shown[v.peak.peak.id] = v
        }
        // Summits near the top, as in landscape, get their labels below.
        var thresholds = LabelLayout.Thresholds()
        thresholds.flipsOthers = true
        let layout = LabelLayout(bounds: Self.screenRect(safeBounds), keepClear: clearRects.map(Self.screenRect), limit: Self.limit,
                                 thresholds: thresholds)
        let result = layout.place(candidates, previous: labeled, previousBelow: labeledBelow)
        // Every label shown is checked from where the camera is now, exactly: the checks off
        // the main thread only put peaks forward. A peak terrain is in the way of goes at once.
        func certify(_ id: Int64) -> Bool {
            guard let s = sightlines[id], let top = shown[id]?.peak.top else { return false }
            if s.eye == eye { return s.clearance > 0 }
            let clearance = world.clearance(from: eye, to: top)
            sightlines[id] = (clearance, eye)
            return clearance > 0
        }
        let certified = result.labels.filter(certify)
        labeled = Set(certified)
        labeledBelow = result.below.intersection(labeled)

        for id in certified {
            // Only a label still in sight fades; one terrain is in the way of goes at once.
            guard let v = shown[id], certify(id) else { continue }
            let isSummit = id == world.summit?.peak.id
            let below = isSummit ? result.selected == .below : result.below.contains(id)
            var slot = slots[id] ?? makeSlot()
            let key = ImageKey(id: id, summit: isSummit, below: below, text: false)
            if slot.key != key {
                set(slot.mark, image(v.peak.peak, units, key))
                set(slot.text, image(v.peak.peak, units, ImageKey(id: id, summit: isSummit, below: false, text: true)))
                slot.key = key
            }
            slot.layer.position = v.point
            slot.layer.opacity = Float(1 - 0.6 * v.haze)
            // The name above (or below) the line's end, kept inside the edges for the summit.
            let text = textBox(v.peak.peak, units, summit: isSummit)
            let dx = isSummit ? inside(x: Double(v.point.x), text) : 0
            let middle = (text.minY + text.maxY) / 2
            slot.text.position = CGPoint(x: (text.minX + text.maxX) / 2 + dx, y: below ? -middle : middle)
            slot.lastShown = now
            slots[id] = slot
            fade(id, in: true)
        }
        for (id, slot) in slots where !labeled.contains(id) {
            // Only a label still in sight, and in view, fades out (for want of room); one that
            // terrain is in the way of, or out of view, goes at once.
            guard let v = shown[id], certify(id) else {
                slot.layer.removeFromSuperlayer()
                slots[id] = nil
                continue
            }
            slot.layer.position = v.point
            fade(id, in: false)
            if now - slot.lastShown > Self.fade + 0.05 {
                slot.layer.removeFromSuperlayer()
                slots[id] = nil
            }
        }
    }

    /// Checks which of `peaks` are in sight from `eye`, off the main thread, one check at a
    /// time: again as soon as the camera has moved or other peaks have come into view.
    private func check(world: WalkWorld, eye: SIMD3<Double>, peaks: [WalkPeak]) {
        let ids = peaks.map(\.peak.id)
        guard !checking, !peaks.isEmpty else { return }
        if let checkedEye, simd_distance(checkedEye, eye) < 1, ids == checkedIDs { return }
        checking = true
        let targets = peaks.map { (id: $0.peak.id, top: $0.top) }
        Task { @MainActor [weak self] in
            let clearances = await Task.detached(priority: .userInitiated) {
                targets.map { (id: $0.id, clearance: world.clearance(from: eye, to: $0.top)) }
            }.value
            guard let self else { return }
            self.checking = false
            guard self.world === world else { return }
            for (id, clearance) in clearances { self.sightlines[id] = (clearance, eye) }
            self.checkedEye = eye
            self.checkedIDs = ids
        }
    }

    /// How far to move a label's text along the horizon to keep it 8 points inside the edges.
    private func inside(x: Double, _ text: TextBox) -> Double {
        let margin = 8.0
        let area = safeBounds
        var dx = 0.0
        if x + text.maxX > Double(area.maxX) - margin { dx = Double(area.maxX) - margin - (x + text.maxX) }
        if x + text.minX + dx < Double(area.minX) + margin { dx = Double(area.minX) + margin - (x + text.minX) }
        return dx
    }

    private func hideAll(now: CFTimeInterval) {
        labeled = []
        for id in slots.keys { fade(id, in: false) }
    }

    /// Keep text out of every system inset, including the camera cutout in landscape.
    private var safeBounds: CGRect {
        guard let window else { return bounds }
        return bounds.intersection(convert(window.safeAreaLayoutGuide.layoutFrame, from: window))
    }

    /// The status bar and the controls over the view, in this view's coordinates.
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

    // MARK: Drawing

    private func makeSlot() -> Slot {
        let layer = CALayer(), mark = CALayer(), text = CALayer()
        layer.opacity = 1
        for l in [mark, text] {
            l.contentsScale = traitCollection.displayScale
            layer.addSublayer(l)
        }
        // The fade is on the text and the mark together; the haze dims the whole label.
        let slot = Slot(layer: layer, mark: mark, text: text)
        mark.opacity = 0
        text.opacity = 0
        self.layer.addSublayer(layer)
        return slot
    }

    private func set(_ layer: CALayer, _ image: (image: CGImage, size: CGSize, anchor: CGPoint)) {
        layer.contents = image.image
        layer.bounds = CGRect(origin: .zero, size: image.size)
        layer.anchorPoint = CGPoint(x: image.anchor.x / image.size.width, y: image.anchor.y / image.size.height)
    }

    /// Fades a label in or out over a moment, from wherever it is now.
    private func fade(_ id: Int64, in shown: Bool) {
        guard var slot = slots[id], slot.shown != shown else { return }
        slot.shown = shown
        slots[id] = slot
        for l in [slot.mark, slot.text] {
            let from = l.presentation()?.opacity ?? l.opacity
            let to: Float = shown ? 1 : 0
            l.opacity = to
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = to
            animation.duration = Self.fade * CFTimeInterval(abs(to - from))
            l.add(animation, forKey: "fade")
        }
    }

    private static func attributes(size: CGFloat, weight: UIFont.Weight, color: UIColor) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 3
        return [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .shadow: shadow]
    }

    /// As the camera view's labels; the hike's summit in amber, as the camera's selected peak.
    private static let accent = UIColor(red: 1.0, green: 0.84, blue: 0.45, alpha: 1)
    private static let nameAttributes = attributes(size: 15, weight: .semibold, color: .white)
    private static let summitAttributes = attributes(size: 16, weight: .bold, color: accent)
    private static let heightAttributes = attributes(size: 12, weight: .regular, color: UIColor.white.withAlphaComponent(0.8))

    private func strings(_ peak: Peak, _ units: AppSettings.Units, summit: Bool) -> (NSAttributedString, NSAttributedString) {
        (NSAttributedString(string: peak.name, attributes: summit ? Self.summitAttributes : Self.nameAttributes),
         NSAttributedString(string: Format.elevation(of: peak, units), attributes: Self.heightAttributes))
    }

    /// Where the name and elevation reach, above the dot at (0, 0), y down.
    private func textBox(_ peak: Peak, _ units: AppSettings.Units, summit: Bool) -> TextBox {
        if let box = boxes[ImageKey(id: peak.id, summit: summit, below: false, text: true)] { return box }
        let (title, height) = strings(peak, units, summit: summit)
        let t = title.size(), h = height.size()
        let width = Double(max(t.width, h.width))
        let maxY = -36.0, minY = maxY - Double(h.height) - Double(t.height) + 2
        let box = TextBox(minX: -width / 2, minY: minY, maxX: width / 2, maxY: maxY)
        boxes[ImageKey(id: peak.id, summit: summit, below: false, text: true)] = box
        return box
    }

    /// The dot and its line (`text` false), or the name over the elevation (`text` true),
    /// drawn once; the anchor is the dot, or the text's middle.
    private func image(_ peak: Peak, _ units: AppSettings.Units, _ key: ImageKey) -> (image: CGImage, size: CGSize, anchor: CGPoint) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = false
        if key.text {
            let (title, height) = strings(peak, units, summit: key.summit)
            let t = title.size(), h = height.size()
            let size = CGSize(width: ceil(max(t.width, h.width)) + 10, height: ceil(t.height + h.height - 2) + 10)
            let image = cached(key) {
                UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    title.draw(at: CGPoint(x: (size.width - t.width) / 2, y: 5))
                    height.draw(at: CGPoint(x: (size.width - h.width) / 2, y: 5 + t.height - 2))
                }.cgImage!
            }
            return (image, size, CGPoint(x: size.width / 2, y: size.height / 2))
        }
        // The line from the dot up 34 points (or down, for a label below), with room around.
        let size = CGSize(width: 24, height: 48)
        let anchor = CGPoint(x: 12, y: key.below ? 7 : 41)
        let image = cached(key) {
            UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let color = key.summit ? Self.accent : UIColor.white
                let leader = UIBezierPath()
                leader.move(to: CGPoint(x: anchor.x, y: anchor.y + (key.below ? 5 : -5)))
                leader.addLine(to: CGPoint(x: anchor.x, y: anchor.y + (key.below ? 34 : -34)))
                leader.lineWidth = key.summit ? 1.5 : 1
                color.withAlphaComponent(key.summit ? 1 : 0.7).setStroke()
                leader.stroke()
                color.setFill()
                let r: CGFloat = key.summit ? 3.5 : 2.5
                UIBezierPath(ovalIn: CGRect(x: anchor.x - r, y: anchor.y - r, width: 2 * r, height: 2 * r)).fill()
                if key.summit {
                    Self.accent.withAlphaComponent(0.6).setStroke()
                    let ring = UIBezierPath(ovalIn: CGRect(x: anchor.x - 9, y: anchor.y - 9, width: 18, height: 18))
                    ring.lineWidth = 1
                    ring.stroke()
                }
            }.cgImage!
        }
        return (image, size, anchor)
    }

    private func cached(_ key: ImageKey, _ draw: () -> CGImage) -> CGImage {
        if let image = images[key] { return image }
        if images.count > 200 { images = [:] }
        let image = draw()
        images[key] = image
        return image
    }
}

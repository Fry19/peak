import Foundation

/// A phone's back lenses as one zoomable camera, from the wide lens up: the wide at 1× and
/// each telephoto at the zoom where it takes over (2×, 3×, 5×). Zooms are relative to the
/// wide lens's field of view, as the phone's camera app counts them.
///
/// The camera is only ever run at a lens's own zoom, never cropped on the camera: the
/// rest of the zoom is done on screen, the same way for the picture and the lines.
public struct LensSet: Equatable, Sendable {
    /// Each lens's own zoom, ascending; the first is the wide, 1.
    public private(set) var zooms: [Double]
    /// A name for each lens, to keep its corrections under (the camera's device type).
    public private(set) var names: [String]

    public static let wideName = "wide"
    /// Just the wide lens: phones without a telephoto.
    public static let wideOnly = LensSet(telephotos: [])

    /// `telephotos` are the zooms where each telephoto takes over (the camera's switch-over
    /// factors, relative to the wide) and their names.
    public init(telephotos: [(zoom: Double, name: String)]) {
        let teles = telephotos.filter { $0.zoom > 1.2 }.sorted { $0.zoom < $1.zoom }
        zooms = [1] + teles.map(\.zoom)
        names = [Self.wideName] + teles.map(\.name)
    }

    public var hasTelephoto: Bool { zooms.count > 1 }

    /// How far pinching may zoom: about three times the longest lens with a telephoto (10×
    /// over a 3× lens, 15× over a 5×), staying optical plus a modest digital part; 6× on
    /// the wide alone, as before.
    public var maxZoom: Double {
        guard let tele = zooms.last, tele > 1 else { return 6 }
        return max(6, min(15, 2.5 * (tele + 1)))
    }

    /// The lens to use for a total `zoom`, given the one in use now: the longest that doesn't
    /// need zooming out. Moving up waits until the zoom is a little past the lens's own, so a
    /// pinch resting right at it doesn't flip between lenses; moving down can't wait, since
    /// the picture can't be shown smaller than the frame.
    public func lens(for zoom: Double, current: Int) -> Int {
        var best = 0
        for (i, z) in zooms.enumerated() where i > 0 {
            let enter = i > current ? z * Self.switchMargin : z
            if zoom >= enter { best = i }
        }
        return best
    }

    /// How far past a lens's own zoom the pinch goes before switching up to it.
    public static let switchMargin = 1.04

    /// The lens whose own zoom is nearest `zoom` (in ratio).
    public func nearestLens(to zoom: Double) -> Int {
        zooms.indices.min { abs(log(zooms[$0] / zoom)) < abs(log(zooms[$1] / zoom)) } ?? 0
    }

    /// The zoom done on screen for a total `zoom` over a frame whose lens (and any crop on the
    /// camera) already magnifies `optical` times. Never below 1: the picture always fills.
    public static func screenZoom(total zoom: Double, optical: Double) -> Double {
        max(1, zoom / max(optical, 1e-6))
    }
}

/// The lens geometry of one camera frame, from what the camera reports with it.
///
/// A frame may come with an intrinsic matrix. Whether it accounts for a crop on the camera
/// isn't certain, and around a lens switch the zoom read when the frame arrives can be
/// ahead of the frame. So the matrix is checked against each way the frame could have been
/// made (a lens's own frame, or the wide cropped), and the zoom setting is the fallback.
public struct FrameLens: Equatable, Sendable {
    public var intrinsics: CameraIntrinsics
    /// From the frame's own matrix rather than estimated from the zoom.
    public var measured: Bool
    /// How many times the frame magnifies over the wide lens's whole frame.
    public var opticalZoom: Double
    /// Which of the `LensSet`'s lenses took it.
    public var lens: Int

    /// What the camera says about a frame.
    public struct Reading: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// The frame's intrinsic matrix, turned and scaled to the frame, if it had one.
        public var matrix: CameraIntrinsics?
        /// The camera's zoom when the frame arrived, relative to the wide lens.
        public var zoom: Double
        /// The lens the camera says is in use.
        public var activeLens: Int
        /// Since the camera's zoom was last changed, seconds.
        public var sinceZoomChange: Double

        public init(width: Int, height: Int, matrix: CameraIntrinsics?, zoom: Double, activeLens: Int, sinceZoomChange: Double) {
            self.width = width
            self.height = height
            self.matrix = matrix
            self.zoom = zoom
            self.activeLens = activeLens
            self.sinceZoomChange = sinceZoomChange
        }
    }

    /// How far a matrix's focal length may be from one expected for it to count as that.
    public static let tolerance = 0.12
    /// Frames this soon after a zoom change may still be from before it.
    public static let switchSettle = 0.3

    public init(intrinsics: CameraIntrinsics, measured: Bool, opticalZoom: Double, lens: Int) {
        self.intrinsics = intrinsics
        self.measured = measured
        self.opticalZoom = opticalZoom
        self.lens = lens
    }

    /// The lens for a frame. `wideFOV` is the wide lens's field of view along the frame's
    /// long side, degrees.
    public static func resolve(_ r: Reading, lenses: LensSet, wideFOV: Double) -> FrameLens {
        let long = Double(max(r.width, r.height))
        // Focal length in long sides, the measure the zoom scales.
        let wideFocal = 0.5 / tan(wideFOV * .pi / 360)
        func focal(_ k: CameraIntrinsics) -> Double {
            (k.width >= k.height ? k.fx : k.fy) / Double(max(k.width, k.height))
        }
        func near(_ f: Double, _ zoom: Double) -> Bool { abs(f / (wideFocal * zoom) - 1) < tolerance }
        let active = max(0, min(lenses.zooms.count - 1, r.activeLens))

        func result(_ k: CameraIntrinsics, measured: Bool, lens: Int) -> FrameLens {
            var optical = focal(k) / wideFocal
            // The wide's matrix and the format's field of view rarely agree exactly; the
            // wide is 1× all the same, so its picture isn't zoomed on screen for a few percent.
            if lens == 0, abs(optical - 1) < 0.04 { optical = 1 }
            return FrameLens(intrinsics: k, measured: measured, opticalZoom: optical, lens: lens)
        }

        let estimate: CameraIntrinsics = {
            let f = wideFocal * r.zoom * long
            return CameraIntrinsics(width: r.width, height: r.height, fx: f, fy: f,
                                    cx: Double(r.width) / 2, cy: Double(r.height) / 2)
        }()

        guard let m = r.matrix, m.width == r.width, m.height == r.height, m.fx > 0, m.fy > 0,
              abs(m.fx / m.fy - 1) < 0.05, abs(m.cx / Double(r.width) - 0.5) < 0.1,
              abs(m.cy / Double(r.height) - 0.5) < 0.1 else {
            return result(estimate, measured: false, lens: active)
        }
        let f = focal(m)
        let crop = r.zoom / lenses.zooms[active]
        // As the zoom says: a lens's own frame, or the wide cropped with the crop accounted for.
        if near(f, r.zoom) { return result(m, measured: true, lens: crop > 1.01 ? active : lenses.nearestLens(to: r.zoom)) }
        if crop > 1.01, near(f, lenses.zooms[active]) {
            // The lens's own frame where the zoom says it's cropped: just after a change, a
            // frame from before it; later, a crop the matrix doesn't account for.
            if r.sinceZoomChange < switchSettle { return result(m, measured: true, lens: active) }
            return result(m.zoomed(by: crop), measured: true, lens: active)
        }
        // Another lens's own frame: just after a switch, one from before it.
        if let other = lenses.zooms.indices.first(where: { near(f, lenses.zooms[$0]) }) {
            return result(m, measured: true, lens: other)
        }
        return result(estimate, measured: false, lens: active)
    }
}

/// How a lens sits relative to the motion sensors beyond the wide lens: each is mounted a
/// little differently, and at 5× a tenth of a degree shows. Degrees.
public struct LensOffset: Codable, Equatable, Sendable {
    public var heading = 0.0
    public var pitch = 0.0
    public var roll = 0.0

    public init(heading: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.heading = heading
        self.pitch = pitch
        self.roll = roll
    }
}

/// Per-lens offsets on top of the main correction, which is the wide lens's, kept for each
/// lens and way of holding the phone (upright or sideways), as the level is.
///
/// A skyline match through a telephoto measures the main correction and the lens's offset
/// together. Right after the wide lens has been matched the main correction is known, so
/// the difference refines the offset; later the compass may have drifted, so the match
/// (less the stored offset) corrects the main correction instead.
public struct LensOffsets: Codable, Equatable, Sendable {
    private var offsets: [String: LensOffset] = [:]

    /// No lens is mounted further off than this from the wide one; a match that says so is a
    /// bad fit, degrees.
    public static let maxOffset = 1.0
    /// How much of the difference one match moves the offset.
    public static let gain = 0.25
    /// The wide lens's correction counts as current this long after its last match, seconds.
    public static let freshFor = 20.0

    public init() {}

    static func key(_ lens: String, sideways: Bool) -> String { lens + (sideways ? "|sideways" : "|upright") }

    /// The offset for a lens held one way; zero for the wide lens, which the main correction is.
    public func offset(lens: String, sideways: Bool) -> LensOffset {
        lens == LensSet.wideName ? LensOffset() : offsets[Self.key(lens, sideways: sideways)] ?? LensOffset()
    }

    /// What to do with an accepted match through a lens.
    public enum Use: Equatable, Sendable {
        /// Correct the main correction by this much (the match less the lens's offset).
        case main(LensOffset)
        /// The offset was refined; the main correction stays.
        case refinedOffset
        /// Too far off for the lens's mounting: a bad fit, or the main correction moved.
        case ignored
    }

    /// Takes a match through `lens`: `measured` is how far it found the view off from the
    /// corrections in use (the main one plus this lens's offset). `sinceWideMatch` is how
    /// long ago the wide lens was last matched, seconds (nil if never).
    public mutating func take(lens: String, sideways: Bool, measured: LensOffset, sinceWideMatch: Double?) -> Use {
        guard lens != LensSet.wideName, let since = sinceWideMatch, since < Self.freshFor else { return .main(measured) }
        let k = Self.key(lens, sideways: sideways)
        var o = offsets[k] ?? LensOffset()
        guard abs(measured.heading) < Self.maxOffset, abs(measured.pitch) < Self.maxOffset,
              abs(measured.roll) < Self.maxOffset else { return .ignored }
        func bounded(_ v: Double) -> Double { max(-Self.maxOffset, min(Self.maxOffset, v)) }
        o.heading = bounded(o.heading + Self.gain * measured.heading)
        o.pitch = bounded(o.pitch + Self.gain * measured.pitch)
        o.roll = bounded(o.roll + Self.gain * measured.roll)
        offsets[k] = o
        return .refinedOffset
    }

    /// Forgets the offsets for one way of holding the phone, or all of them.
    public mutating func reset(sideways: Bool? = nil) {
        guard let sideways else { return offsets.removeAll() }
        let suffix = sideways ? "|sideways" : "|upright"
        offsets = offsets.filter { !$0.key.hasSuffix(suffix) }
    }
}

extension AlignmentSettings {
    /// Gates for a narrow view. The far skyline must span 4° on a wide lens, to pin the roll
    /// and rule out a lone bump; a telephoto's whole view may be barely twice that, so it
    /// asks for a share of the view instead.
    public mutating func adapt(toHorizontalFOV fov: Double) {
        minFarSpan = min(minFarSpan, 0.35 * fov)
    }
}

extension LabelLayout.Thresholds {
    /// Zoomed in, the hand's shake carries labels further on screen, so it takes more room
    /// to bring one in at the edges or between others; keeping one takes no more than before.
    public func scaled(forZoom zoom: Double) -> LabelLayout.Thresholds {
        var t = self
        let s = 1 + 0.25 * log2(max(1, zoom))
        t.enterGap *= s
        t.enterMargin *= s
        t.enterClear *= s
        return t
    }
}

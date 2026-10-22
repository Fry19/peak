import Foundation

/// A rectangle on screen, in points, y down.
public struct ScreenRect: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Shrunk by `d` on every side (grown when `d` is negative).
    public func inset(by d: Double) -> ScreenRect {
        ScreenRect(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }

    public func contains(_ r: ScreenRect) -> Bool {
        r.minX >= minX && r.maxX <= maxX && r.minY >= minY && r.maxY <= maxY
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }

    public func intersects(_ r: ScreenRect) -> Bool {
        r.minX < maxX && r.maxX > minX && r.minY < maxY && r.maxY > minY
    }

    /// How much of `r` is inside this rectangle, as an area.
    func overlap(_ r: ScreenRect) -> Double {
        max(0, min(maxX, r.maxX) - max(minX, r.minX)) * max(0, min(maxY, r.maxY) - max(minY, r.minY))
    }
}

/// Where a label reaches around its peak's dot, in the label's own upright frame: x along
/// the horizon to the right, y toward the ground, the dot at (0, 0). A label above its dot
/// has negative y.
public struct LabelBox: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

/// Picks which peaks get labels and which only dots, frame after frame, so that labels
/// stay put: a label shown last frame is favored, and it takes more to bring one in than to
/// keep one (closer neighbours, nearer the edge), so sensor noise near a threshold doesn't
/// make labels blink. Labels are tested with their real size, turned to the world's up.
public struct LabelLayout: Sendable {
    /// A peak in view that could be labeled.
    public struct Candidate: Sendable {
        public var id: Int64
        /// Its dot on screen, points.
        public var x: Double
        public var y: Double
        /// Higher is more worth a label; see `PeakRanking`.
        public var score: Double
        /// The label above the dot; nil for a peak that only gets a dot (far down the
        /// ranking, so its label isn't worth drawing).
        public var box: LabelBox?
        /// The same label below the dot, for the selected peak when there's no room above,
        /// and for any other peak when `Thresholds.flipsOthers` is on.
        public var flippedBox: LabelBox?
        /// The peak the user picked: always labeled while its dot is on screen.
        public var isSelected: Bool

        public init(id: Int64, x: Double, y: Double, score: Double, box: LabelBox?, flippedBox: LabelBox? = nil,
                    isSelected: Bool = false) {
            self.id = id
            self.x = x
            self.y = y
            self.score = score
            self.box = box
            self.flippedBox = flippedBox
            self.isSelected = isSelected
        }
    }

    /// Separate thresholds to bring a label in and to keep it, points; the gap between them
    /// is what absorbs jitter.
    public struct Thresholds: Sendable {
        /// Space a new label needs between it and the labels already placed; a shown one
        /// stays until they actually touch (`keepGap`).
        public var enterGap = 12.0
        public var keepGap = 0.0
        /// Space between a label and the screen's edges.
        public var enterMargin = 24.0
        public var keepMargin = 4.0
        /// Space between a label and the controls over the view.
        public var enterClear = 8.0
        public var keepClear = 0.0
        /// The rank a shown label is given on top of its score: a new label bumps it only by
        /// ranking that much higher. Scores only change when the view is rebuilt, so this
        /// needs only to outlast small changes then; the gaps and margins above keep labels
        /// from blinking as the phone moves. A full point (one step that matters, see
        /// `PeakRanking`) let Blanket Mountain hold its label against Kuwohi behind it,
        /// 0.83 higher, as long as both stayed in view.
        public var stickiness = 0.4
        /// A dot this close to a labeled peak's dot is left out.
        public var dotClearance = 10.0
        /// The selected peak's label keeps this far inside the edges.
        public var selectedMargin = 8.0
        /// Other peaks' labels go below their dots, where given, when there's no room above
        /// (as for summits near the top of a wide view). One shown below stays below while it
        /// fits there.
        public var flipsOthers = false

        public init() {}
    }

    public enum Placement: Sendable, Equatable {
        case above, below
    }

    public struct Result: Sendable, Equatable {
        /// Labeled peaks, the selected one first, then by rank.
        public var labels: [Int64]
        /// Those of the other labeled peaks whose labels go below their dots.
        public var below: Set<Int64> = []
        /// Where the selected peak's label goes, or nil if its dot isn't on screen (or it
        /// wasn't a candidate): then it needs an arrow at the edge instead.
        public var selected: Placement?
        /// The other peaks in view, which get only a dot.
        public var dots: [Int64]

        public var labeled: Set<Int64> { Set(labels) }
    }

    /// The view, in points.
    public var bounds: ScreenRect
    /// Controls drawn over the view that labels must keep clear of.
    public var keepClear: [ScreenRect]
    /// The world's up on screen, a unit vector (y down).
    public var upX: Double
    public var upY: Double
    /// The most labels to show, the selected one included.
    public var limit: Int
    public var thresholds = Thresholds()

    public init(bounds: ScreenRect, keepClear: [ScreenRect] = [], upX: Double = 0, upY: Double = -1, limit: Int,
                thresholds: Thresholds = Thresholds()) {
        self.bounds = bounds
        self.keepClear = keepClear.filter { !$0.isEmpty }
        let n = hypot(upX, upY)
        self.upX = n > 0 ? upX / n : 0
        self.upY = n > 0 ? upY / n : -1
        self.limit = limit
        self.thresholds = thresholds
    }

    /// Up to the base number of labels at 1×, half as many again at each doubling of zoom,
    /// one at a time as the pinch goes on, and at most twice the base.
    public static func limit(base: Int, zoom: Double) -> Int {
        let extra = Double(base) * 0.5 * log2(max(1, zoom))
        return min(2 * base, base + Int(extra.rounded(.down)))
    }

    /// Labels the selected peak, then the rest by rank (with those shown last frame,
    /// `previous`, ranked up), each only where it fits and doesn't crowd one placed before.
    public func place(_ candidates: [Candidate], previous: Set<Int64>, previousBelow: Set<Int64> = []) -> Result {
        let t = thresholds
        var placed: [(id: Int64, x: Double, y: Double, box: LabelBox)] = []
        var result = Result(labels: [], selected: nil, dots: [])
        let view = bounds.inset(by: -0.5)

        if let s = candidates.first(where: { $0.isSelected }), view.contains(x: s.x, y: s.y) {
            let area = bounds.inset(by: t.selectedMargin)
            let above = s.box ?? LabelBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
            let options: [(Placement, LabelBox)] = [(.above, above)] + (s.flippedBox.map { [(.below, $0)] } ?? [])
            func room(_ box: LabelBox) -> Double {
                let r = screenRect(box, x: s.x, y: s.y)
                let blocked = keepClear.reduce(0) { $0 + $1.overlap(r) }
                return area.overlap(r) - blocked - r.width * r.height
            }
            // Above if it fits there, else below if it fits there, else wherever more of it shows.
            let fit = options.first { fits($0.1, x: s.x, y: s.y, margin: t.selectedMargin, clear: 0) }
                ?? options.max { room($0.1) < room($1.1) }!
            placed.append((s.id, s.x, s.y, fit.1))
            result.labels.append(s.id)
            result.selected = fit.0
        }

        let others = candidates.filter { !$0.isSelected }
        func rank(_ c: Candidate) -> Double { c.score + (previous.contains(c.id) ? t.stickiness : 0) }
        let order = others.indices.sorted {
            let a = rank(others[$0]), b = rank(others[$1])
            return a != b ? a > b : others[$0].id < others[$1].id
        }
        var unlabeled: [Candidate] = []
        for i in order {
            let c = others[i]
            let shown = previous.contains(c.id)
            let gap = shown ? t.keepGap : t.enterGap
            var options: [(box: LabelBox, below: Bool)] = c.box.map { [($0, false)] } ?? []
            if t.flipsOthers, let flipped = c.flippedBox {
                // Where it was last frame first, so it doesn't hop between the two.
                if previousBelow.contains(c.id) { options.insert((flipped, true), at: 0) } else { options.append((flipped, true)) }
            }
            let fit = placed.count < limit ? options.first(where: { o in
                // Moving to the other side counts as coming in.
                let keep = shown && o.below == previousBelow.contains(c.id)
                return fits(o.box, x: c.x, y: c.y, margin: keep ? t.keepMargin : t.enterMargin, clear: keep ? t.keepClear : t.enterClear)
                    && placed.allSatisfy { !overlaps(o.box, c.x, c.y, $0.box, $0.x, $0.y, gap: keep ? gap : t.enterGap) }
            }) : nil
            if let fit {
                placed.append((c.id, c.x, c.y, fit.box))
                result.labels.append(c.id)
                if fit.below { result.below.insert(c.id) }
            } else {
                unlabeled.append(c)
            }
        }
        result.dots = unlabeled.filter { c in
            placed.allSatisfy { abs($0.x - c.x) > t.dotClearance || abs($0.y - c.y) > t.dotClearance }
        }.map(\.id)
        return result
    }

    /// A label's bounding rectangle on screen, turned to the world's up.
    public func screenRect(_ box: LabelBox, x: Double, y: Double) -> ScreenRect {
        // Screen offsets of the label frame's right and down.
        let rightX = -upY, rightY = upX
        let downX = -upX, downY = -upY
        var r = ScreenRect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for (u, v) in [(box.minX, box.minY), (box.maxX, box.minY), (box.minX, box.maxY), (box.maxX, box.maxY)] {
            let px = x + u * rightX + v * downX, py = y + u * rightY + v * downY
            r = ScreenRect(minX: min(r.minX, px), minY: min(r.minY, py), maxX: max(r.maxX, px), maxY: max(r.maxY, py))
        }
        return r
    }

    private func fits(_ box: LabelBox, x: Double, y: Double, margin: Double, clear: Double) -> Bool {
        let r = screenRect(box, x: x, y: y)
        return bounds.inset(by: margin).contains(r) && !keepClear.contains { $0.inset(by: -clear).intersects(r) }
    }

    /// Whether two labels come within `gap` of each other. Both stand upright in the world,
    /// so this is exact in the labels' own frame.
    private func overlaps(_ a: LabelBox, _ ax: Double, _ ay: Double, _ b: LabelBox, _ bx: Double, _ by: Double,
                          gap: Double) -> Bool {
        let dx = bx - ax, dy = by - ay
        let along = dx * -upY + dy * upX, down = dx * -upX + dy * -upY
        return b.minX + along < a.maxX + gap && b.maxX + along > a.minX - gap
            && b.minY + down < a.maxY + gap && b.maxY + down > a.minY - gap
    }
}

/// How much a peak deserves a label, from what makes a summit stand out rather than just
/// its height: its prominence, how far it rises above the skyline around it from here, how
/// near it is and whether it's notable enough for Wikidata. Sub-summits of a big massif are
/// high but rise little, so they don't crowd out the peaks people look for.
public enum PeakRanking {
    /// How far a peak at (azimuth, elevation) rises above the skyline on either side, in
    /// degrees of view: down to the lower of the two cols, looking `window` degrees each way
    /// or until the skyline climbs higher than the peak. Zero for a peak below the skyline.
    public static func rise(azimuth: Double, elevation: Double, window: Double = 6, step: Double = 0.1,
                            horizon: (Double) -> Double) -> Double {
        let n = max(1, Int((window / step).rounded()))
        func col(_ direction: Double) -> Double {
            var lowest = Double.infinity
            for k in 1...n {
                let e = horizon(azimuth + direction * Double(k) * step)
                lowest = min(lowest, e)
                if e > elevation { break }
            }
            return lowest
        }
        return max(0, elevation - max(col(-1), col(1)))
    }

    /// Higher ranks first. Each term is roughly one point per step that matters to the eye.
    public static func score(_ peak: Peak, rise: Double, distance: Double) -> Double {
        // 100 m of prominence is 1, 1,000 m is 2; when OpenStreetMap doesn't say, a small one.
        let prominence = peak.prominence.map { log10(max($0, 10) / 10) } ?? 0.6
        // 0.25° above the cols is 1, 0.75° is 2, 1.75° is 3.
        let standsOut = log2(1 + rise / 0.25)
        let notable = peak.wikidata != nil ? 0.6 : 0
        // Nearer peaks look bigger and are more often the ones asked about: 10 km costs 0.4.
        let near = -0.4 * log10(max(distance, 1_000) / 1_000)
        return prominence + 0.8 * standsOut + notable + near + peak.elevation / 4_000
    }
}

extension HorizonProfile {
    /// How far a peak at (azimuth, elevation) rises above this skyline around it, degrees.
    public func rise(azimuth: Double, elevation: Double) -> Double {
        PeakRanking.rise(azimuth: azimuth, elevation: elevation, step: max(0.1, azimuthStep)) {
            self.elevation(atAzimuth: $0)
        }
    }
}

/// Notices labels crossing the middle of the screen, for a haptic tick, but only when the
/// phone moved them: a heading correction sliding the overlay across isn't the user turning.
public struct CenterCrossing: Sendable {
    private var sides: [Int64: Bool] = [:]
    /// Only crossings this near the middle count, points along the horizon.
    public var reach = 60.0
    /// Within this of the middle the haptic engine is warmed up, points.
    public var prepareReach = 120.0

    public init() {}

    /// Positions are along the horizon from the middle, points. `correctionShift` is how far
    /// this frame's change in heading correction alone moved everything along the horizon.
    /// Returns true if some label crossed because the phone turned.
    public mutating func update(_ positions: [(id: Int64, x: Double)], correctionShift: Double) -> Bool {
        var next: [Int64: Bool] = [:]
        var crossed = false
        for (id, x) in positions {
            let right = x > 0
            if let before = sides[id], before != right, abs(x) < reach {
                // Where it would be had only the phone moved.
                let moved = x - correctionShift
                if (moved > 0) == right { crossed = true }
            }
            next[id] = right
        }
        sides = next
        return crossed
    }

    /// Whether a label is near enough the middle to get the haptic engine ready.
    public func isNear(_ positions: [(id: Int64, x: Double)]) -> Bool {
        positions.contains { abs($0.x) < prepareReach }
    }
}

import XCTest
@testable import PeakCore

final class LabelTests: XCTestCase {
    /// A typical label: about 90 points wide, rising 70 above its dot.
    let box = LabelBox(minX: -45, minY: -70, maxX: 45, maxY: 6)
    let screen = ScreenRect(x: 0, y: 0, width: 400, height: 800)

    /// Repeatable noise in -1...1.
    struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// Runs `frames` frames, each fed the last one's labels, and counts how often `id`'s
    /// label came or went.
    func toggles(_ layout: LabelLayout, frames: Int = 300, start: Set<Int64>, id: Int64,
                 candidates: (inout Noise) -> [LabelLayout.Candidate]) -> (toggles: Int, shownAtEnd: Bool) {
        var noise = Noise()
        var previous = start
        var count = 0
        for _ in 0..<frames {
            let labeled = layout.place(candidates(&noise), previous: previous).labeled
            if labeled.contains(id) != previous.contains(id) { count += 1 }
            previous = labeled
        }
        return (count, previous.contains(id))
    }

    /// Two close peaks, the second jittering ±3 points with its label 6 points from the
    /// first's: between the gap needed to come in (12) and to stay (0), so whatever it was
    /// it stays.
    func testJitterNearCollisionDoesNotToggle() {
        let layout = LabelLayout(bounds: screen, limit: 10)
        func frame(_ noise: inout Noise) -> [LabelLayout.Candidate] {
            [LabelLayout.Candidate(id: 1, x: 150, y: 400, score: 5, box: box),
             LabelLayout.Candidate(id: 2, x: 150 + 90 + 6 + 3 * noise.next(), y: 400 + 3 * noise.next(), score: 3, box: box)]
        }
        let shown = toggles(layout, start: [1, 2], id: 2, candidates: frame)
        XCTAssertEqual(shown.toggles, 0)
        XCTAssertTrue(shown.shownAtEnd)
        let hidden = toggles(layout, start: [1], id: 2, candidates: frame)
        XCTAssertEqual(hidden.toggles, 0)
        XCTAssertFalse(hidden.shownAtEnd)

        // With one threshold for both, the same noise makes it blink: the test means something.
        var single = LabelLayout.Thresholds()
        single.enterGap = 6
        single.keepGap = 6
        XCTAssertGreaterThan(toggles(LabelLayout(bounds: screen, limit: 10, thresholds: single), start: [1, 2], id: 2,
                                     candidates: frame).toggles, 10)
    }

    /// A label 14 points from the edge, jittering ±3: inside the margin to come in (24) and
    /// outside the one to leave (4).
    func testJitterNearEdgeDoesNotToggle() {
        let layout = LabelLayout(bounds: screen, limit: 10)
        func frame(_ noise: inout Noise) -> [LabelLayout.Candidate] {
            [LabelLayout.Candidate(id: 7, x: 45 + 14 + 3 * noise.next(), y: 400 + 3 * noise.next(), score: 3, box: box)]
        }
        XCTAssertEqual(toggles(layout, start: [7], id: 7, candidates: frame).toggles, 0)
        XCTAssertEqual(toggles(layout, start: [], id: 7, candidates: frame).toggles, 0)
        XCTAssertFalse(toggles(layout, start: [], id: 7, candidates: frame).shownAtEnd)
    }

    /// A shown label gives way only to one that ranks clearly higher.
    func testBumpOnlyForClearlyHigherRank() {
        let layout = LabelLayout(bounds: screen, limit: 10)
        func place(newScore: Double) -> LabelLayout.Result {
            layout.place([LabelLayout.Candidate(id: 1, x: 200, y: 400, score: 3, box: box),
                          LabelLayout.Candidate(id: 2, x: 240, y: 400, score: newScore, box: box)], previous: [1])
        }
        XCTAssertEqual(place(newScore: 3.5).labels, [1])
        XCTAssertEqual(place(newScore: 3.5).dots, [2])
        XCTAssertEqual(place(newScore: 4.5).labels, [2])
        XCTAssertEqual(place(newScore: 4.5).dots, [1])
        // From scratch, the higher one wins.
        XCTAssertEqual(layout.place([LabelLayout.Candidate(id: 1, x: 200, y: 400, score: 3, box: box),
                                     LabelLayout.Candidate(id: 2, x: 240, y: 400, score: 3.5, box: box)], previous: []).labels, [2])
    }

    /// At the limit, shown labels keep their places against new ones a little higher.
    func testLimitFavorsShownLabels() {
        let layout = LabelLayout(bounds: screen, limit: 2)
        func candidates(_ c: Double) -> [LabelLayout.Candidate] {
            [LabelLayout.Candidate(id: 1, x: 100, y: 200, score: 2, box: box),
             LabelLayout.Candidate(id: 2, x: 300, y: 200, score: 2.2, box: box),
             LabelLayout.Candidate(id: 3, x: 200, y: 500, score: c, box: box)]
        }
        XCTAssertEqual(layout.place(candidates(2.5), previous: [1, 2]).labeled, [1, 2])
        XCTAssertEqual(layout.place(candidates(3.5), previous: [1, 2]).labeled, [2, 3])
    }

    /// Labels stand upright in the world: with the phone on its side, two dots one above the
    /// other on screen are side by side along the horizon, and their labels collide.
    func testOverlapIsTestedUprightInTheWorld() {
        let wide = LabelBox(minX: -45, minY: -30, maxX: 45, maxY: 0)
        let candidates = [LabelLayout.Candidate(id: 1, x: 200, y: 350, score: 3, box: wide),
                          LabelLayout.Candidate(id: 2, x: 200, y: 400, score: 2, box: wide)]
        XCTAssertEqual(LabelLayout(bounds: screen, limit: 10).place(candidates, previous: []).labels, [1, 2])
        XCTAssertEqual(LabelLayout(bounds: screen, upX: 1, upY: 0, limit: 10).place(candidates, previous: []).labels, [1])
        // Turned, the label reaches toward the right edge instead of up.
        let turned = LabelLayout(bounds: screen, upX: 1, upY: 0, limit: 10)
        let r = turned.screenRect(box, x: 100, y: 400)
        XCTAssertEqual(r.maxX, 170, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 94, accuracy: 1e-9)
        XCTAssertEqual(r.height, 90, accuracy: 1e-9)
    }

    /// Labels keep clear of the controls over the view.
    func testKeepsClearOfControls() {
        let chips = ScreenRect(x: 0, y: 0, width: 400, height: 100)
        let layout = LabelLayout(bounds: screen, keepClear: [chips], limit: 10)
        XCTAssertEqual(layout.place([LabelLayout.Candidate(id: 1, x: 200, y: 150, score: 3, box: box)], previous: []).dots, [1])
        XCTAssertEqual(layout.place([LabelLayout.Candidate(id: 1, x: 200, y: 200, score: 3, box: box)], previous: []).labels, [1])
    }

    /// The selected peak's label goes below its dot when there's no room above, and needs
    /// an arrow only when the dot is off screen.
    func testSelectedFlipsBelow() {
        let below = LabelBox(minX: -45, minY: -6, maxX: 45, maxY: 70)
        let layout = LabelLayout(bounds: screen, limit: 10)
        func selected(y: Double) -> LabelLayout.Result {
            layout.place([LabelLayout.Candidate(id: 9, x: 200, y: y, score: 0, box: box, flippedBox: below, isSelected: true)],
                         previous: [])
        }
        XCTAssertEqual(selected(y: 400).selected, .above)
        XCTAssertEqual(selected(y: 30).selected, .below)
        XCTAssertEqual(selected(y: 30).labels, [9])
        XCTAssertNil(selected(y: -20).selected)
        XCTAssertEqual(selected(y: -20).labels, [])
    }

    /// With flipping on, a peak near the top gets its label below, keeps it there while it
    /// fits, and only goes back above once there's room to come in; without it, none.
    func testOthersFlipBelowWhenAsked() {
        let below = LabelBox(minX: -45, minY: -6, maxX: 45, maxY: 70)
        var thresholds = LabelLayout.Thresholds()
        thresholds.flipsOthers = true
        let layout = LabelLayout(bounds: screen, limit: 10, thresholds: thresholds)
        func place(y: Double, previous: Set<Int64> = [], below previousBelow: Set<Int64> = []) -> LabelLayout.Result {
            layout.place([LabelLayout.Candidate(id: 3, x: 200, y: y, score: 1, box: box, flippedBox: below)],
                         previous: previous, previousBelow: previousBelow)
        }
        XCTAssertEqual(place(y: 400).below, [])
        XCTAssertEqual(place(y: 40).labels, [3])
        XCTAssertEqual(place(y: 40).below, [3])
        // Above would fit within the keep margin (70 + 4) but not the enter margin (70 + 24).
        XCTAssertEqual(place(y: 80, previous: [3], below: [3]).below, [3], "stays below")
        XCTAssertEqual(place(y: 80, previous: [3]).below, [], "stays above")
        XCTAssertEqual(LabelLayout(bounds: screen, limit: 10).place(
            [LabelLayout.Candidate(id: 3, x: 200, y: 40, score: 1, box: box, flippedBox: below)], previous: []).labels, [],
                       "off by default, as in the camera view")
    }

    /// Pinching in adds labels one at a time, not six at once past 1.5×.
    func testLimitGrowsGraduallyWithZoom() {
        XCTAssertEqual(LabelLayout.limit(base: 10, zoom: 1), 10)
        XCTAssertEqual(LabelLayout.limit(base: 10, zoom: 2), 15)
        XCTAssertEqual(LabelLayout.limit(base: 10, zoom: 16), 20)
        var last = 10
        for z in stride(from: 1.0, through: 8, by: 0.01) {
            let n = LabelLayout.limit(base: 10, zoom: z)
            XCTAssertTrue(n == last || n == last + 1, "at \(z)×")
            last = n
        }
    }

    /// A tick when turning the phone carries a label across the middle, none when only a
    /// heading correction slid it across.
    func testCenterCrossingIgnoresCorrections() {
        var crossing = CenterCrossing()
        XCTAssertFalse(crossing.update([(1, -5)], correctionShift: 0))
        XCTAssertTrue(crossing.update([(1, 5)], correctionShift: 0))
        XCTAssertTrue(crossing.update([(1, -5)], correctionShift: 0))
        // The correction moved it 10 points right; the phone moved it nowhere.
        XCTAssertFalse(crossing.update([(1, 5)], correctionShift: 10))
        XCTAssertTrue(crossing.isNear([(1, 100)]))
        XCTAssertFalse(crossing.isNear([(1, 130)]))
    }

    // MARK: Ranking

    /// The rise is down to the higher of the two cols, stopping at higher ground.
    func testRiseAboveTheSkyline() {
        // A 2° skyline, a peak at 100° to 4°, a col of 3.5° at 101.5° and a higher peak at 103°.
        func horizon(_ az: Double) -> Double {
            if az < 98 || az > 105 { return 2 }
            if az <= 100 { return 2 + (az - 98) }
            if az <= 101.5 { return 4 - (az - 100) / 3 }
            if az <= 103 { return 3.5 + (az - 101.5) }
            return 5 - (az - 103) * 1.5
        }
        XCTAssertEqual(PeakRanking.rise(azimuth: 100, elevation: 4, horizon: horizon), 0.5, accuracy: 0.01)
        XCTAssertEqual(PeakRanking.rise(azimuth: 103, elevation: 5, horizon: horizon), 3, accuracy: 0.01)
        // Below the skyline, nothing rises.
        XCTAssertEqual(PeakRanking.rise(azimuth: 100, elevation: 3, horizon: horizon), 0)
    }

    /// From Gornergrat: Monte Rosa's sub-summits are higher than the Matterhorn but barely
    /// rise above their ridge; ranked by elevation they'd take the first labels.
    func testRankingPrefersProminentPeaks() {
        func peak(_ id: Int64, _ name: String, _ ele: Double, prominence: Double?, wikidata: Bool = true) -> Peak {
            Peak(id: id, name: name, latitude: 46, longitude: 7.8, elevation: ele, prominence: prominence,
                 wikidata: wikidata ? "Q\(id)" : nil)
        }
        let views: [(Peak, rise: Double, distance: Double)] = [
            (peak(1, "Dufourspitze", 4634, prominence: 2165), 1.2, 13_000),
            (peak(2, "Nordend", 4609, prominence: 94), 0.15, 13_500),
            (peak(3, "Zumsteinspitze", 4563, prominence: 110), 0.2, 12_800),
            (peak(4, "Signalkuppe", 4554, prominence: 102), 0.15, 12_500),
            (peak(5, "Parrotspitze", 4432, prominence: nil, wikidata: false), 0.1, 12_000),
            (peak(6, "Matterhorn", 4478, prominence: 1042), 2.5, 17_000),
        ]
        let ranked = views.sorted { PeakRanking.score($0.0, rise: $0.rise, distance: $0.distance)
            > PeakRanking.score($1.0, rise: $1.rise, distance: $1.distance) }.map(\.0.name)
        XCTAssertEqual(Set(ranked.prefix(2)), ["Dufourspitze", "Matterhorn"])
        XCTAssertEqual(ranked.last, "Parrotspitze")
        // By elevation the Matterhorn would come fifth.
        XCTAssertEqual(views.sorted { $0.0.elevation > $1.0.elevation }.firstIndex { $0.0.name == "Matterhorn" }, 4)
    }

    /// All else equal, a peak on Wikidata outranks one that isn't, and a nearer one a farther one.
    func testRankingTieBreaks() {
        let plain = Peak(id: 1, name: "A", latitude: 46, longitude: 7, elevation: 3000)
        var known = plain
        known.wikidata = "Q1"
        XCTAssertGreaterThan(PeakRanking.score(known, rise: 0.5, distance: 10_000),
                             PeakRanking.score(plain, rise: 0.5, distance: 10_000))
        XCTAssertGreaterThan(PeakRanking.score(plain, rise: 0.5, distance: 5_000),
                             PeakRanking.score(plain, rise: 0.5, distance: 50_000))
        XCTAssertGreaterThan(PeakRanking.score(plain, rise: 1.5, distance: 10_000),
                             PeakRanking.score(plain, rise: 0.2, distance: 10_000))
    }
}

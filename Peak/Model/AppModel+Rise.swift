import Foundation
import PeakCore
import UIKit

/// Seeing over the ridges: while the rise button is held, the view is drawn from above where
/// you stand, a step higher every moment (100 m, 300 m, 1 km, or 300, 1,000 and 3,000 ft),
/// over a plain night sky instead of the camera picture, which can't come up too. Letting go
/// brings it back down. The views from above are built one after another on the first press
/// and kept until the live view changes; the live view itself, which skyline matching, the
/// cards and the trails use, stays on the ground throughout.
extension AppModel {
    /// What the rise button shows.
    struct Rise: Equatable {
        /// Held down, or turned on with VoiceOver.
        var holding = false
        /// The height on screen: 0 on the ground, else 1 up to `riseHeights.count`.
        var level = 0
        /// Its height above your eye, meters.
        var height = 0.0
        /// Peaks in sight from up there that are hidden from the ground.
        var revealed = 0
        /// Held, and waiting for a view from above to be built.
        var pending = false
    }

    /// One view from above.
    struct RisenView {
        var scene: TerrainScene
        /// Its peaks hidden behind nearer terrain from the ground. Peaks whose line of sight
        /// coarse terrain can't settle, from either eye, don't count.
        var revealed: Set<Int64>
        var height: Double
        /// How long it took to build, for diagnostics.
        var seconds: Double
    }

    /// The views from above and the work under way.
    struct RiseWork {
        var heights: [Double] = []
        var views: [RisenView?] = []
        /// The views of the live view before last, shown while new ones are built.
        var stale: [RisenView?] = []
        /// The live view (`sceneGeneration`) `views` are seen from.
        var generation = -1
        /// The height to climb to: 1 at first, one more each `dwell` while held.
        var target = 0
        var build: Task<Void, Never>?
        var motion: Task<Void, Never>?
        let haptics = UIImpactFeedbackGenerator(style: .soft)

        /// The view for height `i`, or the stale one while it's built again.
        func view(_ i: Int) -> RisenView? {
            (i < views.count ? views[i] : nil) ?? (i < stale.count ? stale[i] : nil)
        }
    }

    /// Heights above your eye, meters: round numbers in the units you read.
    static func riseHeights(_ units: AppSettings.Units) -> [Double] {
        units == .metric ? [100, 300, 1_000] : [300, 1_000, 3_000].map { $0 * 0.3048 }
    }

    /// How long each height is held before the next, seconds.
    private static let dwell = 0.8

    /// The rise button shows once the view is fully working: the peaks are in, and the pill
    /// has nothing to add (coarse terrain, an approximate location). Short of that there's
    /// little to see from above, and the pill needs the room to say what's missing.
    var offersRise: Bool {
        guard case .ready(.none) = status else { return false }
        return !waitingForPeaks
    }

    /// The live view can go up: it's built, and nothing covers or pauses it.
    var canRise: Bool {
        scene != nil && frozen == nil && !aligning && !showsFromAbove && photo == nil && sheet == nil
    }

    /// The view from above on screen, if risen.
    var risenView: RisenView? {
        rise.level > 0 ? riseWork.view(rise.level - 1) : nil
    }

    /// What the overlay draws: the view from above while risen, else the live view.
    var shownScene: TerrainScene? {
        risenView?.scene ?? scene
    }

    /// The rise button pressed or let go. Held, the view climbs a step at a time; let go, it
    /// comes down a step at a time.
    func setRising(_ holding: Bool) {
        if holding { startRising(climbing: true) } else { stopRising() }
    }

    /// VoiceOver's activation: up one step and staying there, or back down.
    func toggleRising() {
        if rise.holding { stopRising() } else { startRising(climbing: false) }
    }

    /// VoiceOver's adjustable action: one step up or down; below the first, back on the ground.
    func adjustRise(by steps: Int) {
        guard rise.holding else {
            if steps > 0 { startRising(climbing: false) }
            return
        }
        riseWork.target = max(0, min(riseWork.heights.count, riseWork.target + steps))
        if riseWork.target == 0 { stopRising() } else { showRiseLevel() }
    }

    /// Straight back to the ground, for what needs the live view: pausing it, a sheet, a
    /// picture or map over it, lining up, or leaving the app.
    func land() {
        guard rise.holding || rise.level > 0 else { return }
        rise.holding = false
        riseWork.motion?.cancel()
        riseWork.motion = nil
        setRiseLevel(0)
    }

    /// The live view changed: its views from above are out of date. While risen they're built
    /// again, the old ones shown meanwhile; otherwise they're let go.
    func riseSceneChanged() {
        sceneGeneration += 1
        if scene != nil, rise.holding {
            buildRisenViews()
        } else {
            land()
            dropRisenViews()
        }
    }

    /// Lets the views from above go, and any still being built.
    func dropRisenViews() {
        riseWork.build?.cancel()
        riseWork.build = nil
        riseWork.views = []
        riseWork.stale = []
        riseWork.generation = -1
    }

    private func startRising(climbing: Bool) {
        guard canRise, !rise.holding else { return }
        rise.holding = true
        riseWork.target = 0
        buildRisenViews()
        if settings.haptics { riseWork.haptics.prepare() }
        riseWork.motion?.cancel()
        riseWork.motion = Task { @MainActor [weak self] in
            // A tap is too short to go up: it only says to hold.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.rise.holding else { return }
            self.riseWork.target = max(self.riseWork.target, 1)
            self.showRiseLevel()
            // Climbing: a step more each `dwell` once the last one is on screen. Views from
            // above show themselves as they're built.
            while climbing, !Task.isCancelled, self.rise.holding, self.riseWork.target < self.riseWork.heights.count {
                if self.rise.level >= self.riseWork.target {
                    try? await Task.sleep(for: .seconds(Self.dwell))
                    guard !Task.isCancelled, self.rise.holding else { return }
                    self.riseWork.target += 1
                    self.showRiseLevel()
                } else {
                    // Waiting for the next view to be built.
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    private func stopRising() {
        guard rise.holding else { return }
        // Avoid a quick series of depth changes for people who reduce motion.
        if UIAccessibility.isReduceMotionEnabled {
            land()
            return
        }
        rise.holding = false
        setRiseLevel(rise.level)
        riseWork.motion?.cancel()
        // Down through the heights below, quickly.
        riseWork.motion = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, !self.rise.holding, self.rise.level > 0 {
                self.setRiseLevel(self.rise.level - 1)
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    /// Up to the target, or as near as the views built so far allow.
    private func showRiseLevel() {
        var level = 0
        while level < riseWork.target, riseWork.view(level) != nil { level += 1 }
        setRiseLevel(level)
    }

    private func setRiseLevel(_ level: Int) {
        let up = level > rise.level
        var next = Rise(holding: rise.holding, level: level, pending: rise.holding && riseWork.target > level)
        if level > 0, let view = riseWork.view(level - 1) {
            next.height = view.height
            next.revealed = view.revealed.count
        } else {
            next.level = 0
        }
        guard next != rise else { return }
        rise = next
        if up, settings.haptics { riseWork.haptics.impactOccurred(intensity: 0.6) }
        screen?.overlay.setNeedsUpdate()
    }

    /// Builds the views from above that the live view doesn't have yet, lowest first, off the
    /// main thread. Built ones are kept for the next press.
    private func buildRisenViews() {
        guard let scene else { return }
        let heights = Self.riseHeights(settings.units)
        if riseWork.generation != sceneGeneration || riseWork.heights != heights {
            riseWork.build?.cancel()
            riseWork.build = nil
            // Shown until the new ones are in, if they're for the same heights.
            riseWork.stale = riseWork.heights == heights ? riseWork.views.indices.map { riseWork.view($0) } : []
            riseWork.views = Array(repeating: nil, count: heights.count)
            riseWork.heights = heights
            riseWork.generation = sceneGeneration
        }
        guard riseWork.build == nil, riseWork.views.contains(where: { $0 == nil }) else { return }
        let generation = sceneGeneration
        riseWork.build = Task { @MainActor [weak self] in
            for (i, height) in heights.enumerated() {
                guard let self, !Task.isCancelled, self.riseWork.generation == generation else { return }
                if self.riseWork.views[i] != nil { continue }
                let started = Date()
                let view = await Task.detached(priority: .userInitiated) {
                    let up = scene.risen(by: height)
                    let revealed = Set(up.peaks.map(\.id).filter { id in
                        guard !up.uncertain.contains(id), let below = scene.allPeaks[id] else { return false }
                        return !below.isVisible && !below.isUncertain
                    })
                    return RisenView(scene: up, revealed: revealed, height: height, seconds: 0)
                }.value
                guard !Task.isCancelled, self.riseWork.generation == generation else { return }
                var built = view
                built.seconds = Date().timeIntervalSince(started)
                self.riseWork.views[i] = built
                if i < self.riseWork.stale.count { self.riseWork.stale[i] = nil }
                // Not on the way down: that steps on by itself.
                if self.rise.holding { self.showRiseLevel() }
            }
            if let self, self.riseWork.generation == generation {
                self.riseWork.build = nil
                self.riseWork.stale = []
            }
        }
    }

    /// For diagnostics: how long each view from above took.
    var riseDiagnostics: String? {
        let built = riseWork.views.compactMap { $0 }
        guard !built.isEmpty else { return nil }
        return "from above: " + built.map {
            String(format: "%@ %.2f s, %ld more", Format.elevation($0.height, settings.units), $0.seconds, $0.revealed.count)
        }.joined(separator: "; ")
    }
}

import Foundation
import PeakCore
import UIKit

/// Seeing over the ridges: a tap on the rise button draws the view from above where you
/// stand (100 m, 300 m, 1 km or 3 km, or 300, 1,000, 3,000 or 10,000 ft, the one chosen last,
/// at first the second), over a plain night sky instead of the camera picture, which can't
/// come up too, and it stays up until the button is tapped again. The views from above are
/// built one after another, the chosen one first, and kept until the live view changes; the
/// live view itself, which skyline matching, the cards and the trails use, stays on the
/// ground throughout.
extension AppModel {
    /// What the rise button shows.
    struct Rise: Equatable {
        /// Turned on: up, or on the way, until it's turned off.
        var isUp = false
        /// The height chosen, 1 up to `riseHeights.count` (0 on the way down), on screen once
        /// its view is built.
        var target = 0
        /// The height on screen: 0 on the ground, else 1 up to `riseHeights.count`.
        var level = 0
        /// Its height above your eye, meters.
        var height = 0.0
        /// Peaks in sight from up there that are hidden from the ground.
        var revealed = 0

        /// Away from the height chosen: waiting for its view to be built, or stepping to it.
        var pending: Bool { isUp && level != target }
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
        /// The live view (`sceneGeneration`) it's seen from, for its terrain in 3D.
        var generation: Int
    }

    /// The terrain in 3D around a live view, shared by its views from above.
    struct RiseMesh {
        var mesh: PanoramaMesh
        var generation: Int
        var seconds: Double
    }

    /// The views from above and the work under way.
    struct RiseWork {
        var heights: [Double] = []
        var views: [RisenView?] = []
        /// The views of the live view before last, shown while new ones are built.
        var stale: [RisenView?] = []
        /// The terrain in 3D for `views`, and every generation still used by `stale`.
        var mesh: RiseMesh?
        var staleMeshes: [RiseMesh] = []
        /// The live view (`sceneGeneration`) `views` are seen from.
        var generation = -1
        /// The height the next tap goes up to: the one chosen last.
        var chosen = 2
        var build: Task<Void, Never>?
        var motion: Task<Void, Never>?
        let haptics = UIImpactFeedbackGenerator(style: .soft)

        /// The view for height `i`, or the stale one while it's built again.
        func view(_ i: Int) -> RisenView? {
            (i < views.count ? views[i] : nil) ?? (i < stale.count ? stale[i] : nil)
        }

        /// The terrain in 3D seen from the same spot as views of `generation`.
        func mesh(for generation: Int) -> RiseMesh? {
            if let mesh, mesh.generation == generation { return mesh }
            return staleMeshes.first { $0.generation == generation }
        }
    }

    /// Heights above your eye, meters: round numbers in the units you read. The terrain
    /// reaches 80 km, so from the highest it fades into haze about 2.5° below level, where
    /// mountains farther out would stand.
    static func riseHeights(_ units: AppSettings.Units) -> [Double] {
        units == .metric ? [100, 300, 1_000, 3_000] : [300, 1_000, 3_000, 10_000].map { $0 * 0.3048 }
    }

    /// How long the view rests at each height it passes on the way, seconds.
    private static let step = 0.09

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

    /// The terrain in 3D under the view from above on screen, once it's built.
    var risenMesh: RiseMesh? {
        risenView.flatMap { riseWork.mesh(for: $0.generation) }
    }

    /// What the overlay draws: the view from above while risen, else the live view.
    var shownScene: TerrainScene? {
        risenView?.scene ?? scene
    }

    /// The rise button: up to the height chosen last, or back down to the camera.
    func toggleRising() {
        if rise.isUp { comeDown() } else { chooseRiseLevel(riseWork.chosen) }
    }

    /// Up (or down) to height `level`, 1 up to `riseHeights.count`, and staying there.
    func chooseRiseLevel(_ level: Int) {
        let level = max(1, min(Self.riseHeights(settings.units).count, level))
        if !rise.isUp {
            guard canRise else { return }
            rise.isUp = true
            if settings.haptics { riseWork.haptics.prepare() }
        }
        riseWork.chosen = level
        rise.target = level
        buildRisenViews()
        moveToTarget()
    }

    /// VoiceOver's adjustable action: one step up or down; below the first, back on the ground.
    func adjustRise(by steps: Int) {
        guard rise.isUp else {
            if steps > 0 { chooseRiseLevel(1) }
            return
        }
        let target = rise.target + steps
        if target < 1 { comeDown() } else { chooseRiseLevel(target) }
    }

    /// Straight back to the ground, for what needs the live view: pausing it, a sheet, a
    /// picture or map over it, lining up, or leaving the app.
    func land() {
        guard rise.isUp || rise.level > 0 else { return }
        rise.isUp = false
        rise.target = 0
        riseWork.motion?.cancel()
        riseWork.motion = nil
        setRiseLevel(0)
    }

    /// The live view changed: its views from above are out of date. While up they're built
    /// again, the old ones shown meanwhile; otherwise they're let go.
    func riseSceneChanged() {
        sceneGeneration += 1
        if scene != nil, rise.isUp {
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
        riseWork.mesh = nil
        riseWork.staleMeshes = []
        riseWork.generation = -1
    }

    /// Back down to the camera through the heights below, quickly.
    private func comeDown() {
        guard rise.isUp else { return }
        // Avoid a quick series of depth changes for people who reduce motion.
        if UIAccessibility.isReduceMotionEnabled {
            land()
            return
        }
        rise.isUp = false
        rise.target = 0
        moveToTarget()
    }

    /// Steps the view to the height chosen through the heights built in between, a moment
    /// at each, or (with Reduce Motion) straight to it. Short of a view still being built, it
    /// stops as near as it can, and the build moves it on when the view is in.
    private func moveToTarget() {
        riseWork.motion?.cancel()
        riseWork.motion = nil
        guard !UIAccessibility.isReduceMotionEnabled else {
            setRiseLevel((0...rise.target).last { $0 == 0 || riseWork.view($0 - 1) != nil } ?? 0)
            return
        }
        riseWork.motion = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let level = self.rise.level, target = self.rise.target
                let next = target > level
                    ? (level + 1...target).first { self.riseWork.view($0 - 1) != nil }
                    : (target..<level).last { $0 == 0 || self.riseWork.view($0 - 1) != nil }
                guard let next, next != level else { return }
                self.setRiseLevel(next)
                try? await Task.sleep(for: .seconds(Self.step))
            }
        }
    }

    private func setRiseLevel(_ level: Int) {
        let up = level > rise.level
        var next = Rise(isUp: rise.isUp, target: rise.target, level: level)
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

    /// Builds the views from above that the live view doesn't have yet, the height chosen
    /// first and then the lowest, off the main thread. Built ones are kept for the next tap.
    private func buildRisenViews() {
        guard let scene else { return }
        let heights = Self.riseHeights(settings.units)
        if riseWork.generation != sceneGeneration || riseWork.heights != heights {
            riseWork.build?.cancel()
            riseWork.build = nil
            // Shown until the new ones are in, if they're for the same heights.
            riseWork.stale = riseWork.heights == heights ? riseWork.views.indices.map { riseWork.view($0) } : []
            // Rebuilds may overlap: some heights can still be two generations old.
            let generations = Set(riseWork.stale.compactMap { $0?.generation })
            riseWork.staleMeshes = ([riseWork.mesh].compactMap { $0 } + riseWork.staleMeshes)
                .filter { generations.contains($0.generation) }
            riseWork.mesh = nil
            riseWork.views = Array(repeating: nil, count: heights.count)
            riseWork.heights = heights
            riseWork.generation = sceneGeneration
        }
        guard riseWork.build == nil, riseWork.views.contains(where: { $0 == nil }) || riseWork.mesh == nil else { return }
        let generation = sceneGeneration
        riseWork.build = Task { @MainActor [weak self] in
            // The terrain in 3D first: it's quick, and every height uses it.
            if let self, self.riseWork.mesh == nil {
                let started = Date()
                let mesh = await Task.detached(priority: .userInitiated) { scene.panorama() }.value
                guard !Task.isCancelled, self.riseWork.generation == generation else { return }
                self.riseWork.mesh = RiseMesh(mesh: mesh, generation: generation, seconds: Date().timeIntervalSince(started))
                self.screen?.overlay.setNeedsUpdate()
            }
            while let self, !Task.isCancelled, self.riseWork.generation == generation {
                let missing = self.riseWork.views.indices.filter { self.riseWork.views[$0] == nil }
                guard let i = missing.contains(self.rise.target - 1) ? self.rise.target - 1 : missing.first else { break }
                let height = heights[i]
                let started = Date()
                let view = await Task.detached(priority: .userInitiated) {
                    let up = scene.risen(by: height)
                    let revealed = Set(up.peaks.map(\.id).filter { id in
                        guard !up.uncertain.contains(id), let below = scene.allPeaks[id] else { return false }
                        return !below.isVisible && !below.isUncertain
                    })
                    return RisenView(scene: up, revealed: revealed, height: height, seconds: 0, generation: generation)
                }.value
                guard !Task.isCancelled, self.riseWork.generation == generation else { return }
                var built = view
                built.seconds = Date().timeIntervalSince(started)
                self.riseWork.views[i] = built
                if i < self.riseWork.stale.count { self.riseWork.stale[i] = nil }
                // Not on the way down: that steps on by itself.
                if self.rise.pending {
                    self.moveToTarget()
                } else if self.rise.isUp {
                    // The height on screen may have been the old view's: its count with it.
                    self.setRiseLevel(self.rise.level)
                }
            }
            if let self, self.riseWork.generation == generation {
                self.riseWork.build = nil
                self.riseWork.stale = []
                self.riseWork.staleMeshes = []
            }
        }
    }

    /// For diagnostics: how long each view from above took.
    var riseDiagnostics: String? {
        let built = riseWork.views.compactMap { $0 }
        guard !built.isEmpty || riseWork.mesh != nil else { return nil }
        let mesh = riseWork.mesh.map {
            String(format: "3D %.2f s, %ld k triangles; ", $0.seconds, $0.mesh.indices.count / 3_000)
        } ?? ""
        return "from above: " + mesh + built.map {
            String(format: "%@ %.2f s, %ld more", Format.elevation($0.height, settings.units), $0.seconds, $0.revealed.count)
        }.joined(separator: "; ")
    }
}

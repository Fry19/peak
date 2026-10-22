import Foundation
import PeakCore

/// Binoculars: zooming in past a telephoto's own zoom moves the camera to it. Each lens is
/// mounted a little differently relative to the motion sensors, so each keeps a small
/// offset on top of the main correction (the wide lens's), per way of holding the phone.
extension AppModel {
    /// How far a frame is zoomed on screen: the total zoom less what its lens already does.
    func screenZoom(for shown: Shown) -> Double {
        LensSet.screenZoom(total: zoom, optical: shown.lens.opticalZoom)
    }

    /// The offset of the lens that took a frame, for the way the phone is held.
    func lensOffset(_ lens: CameraFeed.Lens?, pose: MotionTracker.Pose?) -> LensOffset {
        guard let lens else { return LensOffset() }
        return lensOffsets.offset(lens: lens.name, sideways: CameraGeometry.isSideways(pose))
    }

    /// The corrections for a frame through `lens`: the main ones plus the lens's offset.
    func viewCorrection(for pose: MotionTracker.Pose?, lens: CameraFeed.Lens?) -> ViewCorrection {
        viewCorrection(for: pose) + lensOffset(lens, pose: pose)
    }

    /// Takes an accepted match. Through a telephoto just after the wide lens was matched,
    /// it refines that lens's offset; otherwise it moves the main correction. Returns
    /// whether anything moved.
    func takeMatch(_ o: SkylineCorrector.Outcome) -> Bool {
        // A frame from before the sensors restarted has no place under the gyroscope's zero.
        guard o.gyro?.epoch == motion.latestGyro?.epoch else { return false }
        let since = lastWideMatch.map { Date().timeIntervalSince($0) }
        let measured = LensOffset(heading: o.delta, pitch: o.pitchDelta, roll: o.rollDelta)
        switch lensOffsets.take(lens: o.lens, sideways: o.sideways, measured: measured, sinceWideMatch: since) {
        case .main:
            let moved = correction.add(o, north: motion.northCorrection, now: motion.latestGyro)
            if moved, o.lens == LensSet.wideName { lastWideMatch = Date() }
            if moved { rememberHeading() }
            return moved
        case .refinedOffset:
            correction.lastMatch = Date()
            correction.lastRMS = o.rms
            return true
        case .ignored:
            return false
        }
    }

    private static let lensOffsetsKey = "lensOffsets"

    func loadLensOffsets() {
        guard let data = UserDefaults.standard.data(forKey: Self.lensOffsetsKey),
              let offsets = try? JSONDecoder().decode(LensOffsets.self, from: data) else { return }
        lensOffsets = offsets
    }

    func saveLensOffsets() {
        if let data = try? JSONEncoder().encode(lensOffsets) { UserDefaults.standard.set(data, forKey: Self.lensOffsetsKey) }
    }

    /// For the diagnostics panel.
    var lensDebugLine: String? {
        guard lenses.hasTelephoto, let lens = screen?.shown?.lens ?? camera.lens else { return nil }
        let o = lensOffset(lens, pose: motion.pose)
        let name = lens.name == LensSet.wideName ? "wide" : "telephoto"
        return String(format: "%@ lens %.2f× of %@; offset heading %+.2f° pitch %+.2f° roll %+.2f°", name, lens.opticalZoom,
                      lenses.zooms.map { Format.zoom($0) }.joined(separator: " "), o.heading, o.pitch, o.roll)
    }
}

func + (c: ViewCorrection, o: LensOffset) -> ViewCorrection {
    ViewCorrection(heading: c.heading + o.heading, pitch: c.pitch + o.pitch, roll: c.roll + o.roll)
}

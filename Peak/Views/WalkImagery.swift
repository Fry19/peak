import SwiftUI
import simd

/// Satellite imagery laid over a world in 3D (`WalkWorld`), the walk's or a summit's: the
/// sharp terrain's before the ring's, then the photos over the hills around, and sharper
/// imagery near what the camera looks at. What loaded is kept for a sharper rebuild of the
/// same ground.
@MainActor @Observable
final class WalkImagery {
    /// The imagery is laid over the sharp terrain of the world shown.
    private(set) var draped = false

    @ObservationIgnored private weak var world: WalkWorld?
    /// Over the sharp terrain and the ring around it.
    @ObservationIgnored private var near: MapImagery?
    @ObservationIgnored private var far: MapImagery?
    /// The sharper imagery near what the camera looks at, and the photos over the hills around.
    @ObservationIgnored private var detail: MapImagery?
    @ObservationIgnored private var mid: MapImagery?

    /// What the tasks laying it are keyed by: tried again for a new world, a change of the
    /// map's style, or when the connection comes back.
    struct DrapeKey: Equatable {
        var world: ObjectIdentifier?
        var satellite: Bool
        var online: Bool

        init(world: WalkWorld?, satellite: Bool, online: Bool) {
            self.world = world.map(ObjectIdentifier.init)
            self.satellite = satellite
            self.online = online
        }
    }

    struct DetailKey: Equatable {
        var world: ObjectIdentifier?
        var draped: Bool
        var online: Bool

        init(world: WalkWorld?, draped: Bool, online: Bool) {
            self.world = world.map(ObjectIdentifier.init)
            self.draped = draped
            self.online = online
        }
    }

    /// A new world to lay the imagery over, in its own colors until it is.
    func show(_ world: WalkWorld?) {
        self.world = world
        draped = false
    }

    /// Loads what imagery is missing, the terrain's before the ring's, and lays each on as
    /// it comes; a part that didn't load is tried again when the connection returns.
    func drape(satellite: Bool) async {
        guard let world, satellite else { return }
        if !world.draped {
            if near.map({ !world.fits($0, ring: false) }) ?? true {
                guard let loaded = await world.loadNearImagery(), !Task.isCancelled, self.world === world else { return }
                near = loaded
            }
            await world.drape(near: near, far: nil)
            guard !Task.isCancelled, self.world === world else { return }
            draped = world.draped
        }
        if !world.ringDraped {
            if far.map({ !world.fits($0, ring: true) }) ?? true {
                guard let loaded = await world.loadFarImagery(), !Task.isCancelled, self.world === world else { return }
                // Coarse enough to be Apple's greener mosaic: in the colors of the photos nearer.
                let near = self.near
                let matched = await Task.detached(priority: .userInitiated) { near.map(loaded.matched) ?? loaded }.value
                guard !Task.isCancelled, self.world === world else { return }
                far = matched
            }
            await world.drape(near: nil, far: far)
        }
        // Then the photos over the hills around, out to where the haze thickens.
        if world.ringDraped, !world.midShown, let rect = world.midRect {
            if mid.map({ $0.rect != rect || $0.center != world.center }) ?? true {
                guard let loaded = await world.loadMidImagery(rect), !Task.isCancelled, self.world === world else { return }
                mid = loaded
            }
            if let mid { world.show(mid: mid) }
        }
    }

    /// Keeps sharper imagery under what the camera looks at, loading it again as the walker
    /// moves on: one download at a time, waiting longer after each one that fails.
    func sharpen(player: WalkPlayer) async {
        guard let world, draped else { return }
        if let detail { world.show(detail: detail) }
        var wait = 2.0
        while !Task.isCancelled {
            let center = world.detailCenter(at: player.shownDistance, walking: player.playing)
            if world.needsDetail(around: center) {
                do {
                    let loaded = try await world.loadDetail(around: center)
                    guard !Task.isCancelled, self.world === world else { return }
                    wait = 2
                    // A slow download may finish after scrubbing back to imagery we already
                    // have. Keep the picture nearest the part of the walk now in view.
                    let wanted = world.detailCenter(at: player.shownDistance, walking: player.playing)
                    if let shown = world.detail, shown.rect.width == loaded.rect.width {
                        let previous = SIMD2<Double>(shown.rect.midX, shown.rect.midY)
                        if simd_distance(previous, wanted) < simd_distance(center, wanted) { continue }
                    }
                    world.show(detail: loaded)
                    detail = loaded
                } catch {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(wait))
                    wait = min(60, wait * 2)
                    continue
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

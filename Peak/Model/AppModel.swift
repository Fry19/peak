import CoreLocation
import Observation
import PeakCore
import SwiftUI

@Observable
final class AppModel {
    enum Phase: Equatable {
        case locating
        case loading(String)
        case ready
        case needsPermission(String)
        case failed(String)
    }

    /// The compass correction from skyline matching, smoothed over frames.
    struct Correction {
        var degrees = 0.0
        var matches = 0
        var lastMatch: Date?
        var lastRMS = 0.0

        /// Matched recently enough to trust over the compass.
        var isAligned: Bool { lastMatch.map { Date().timeIntervalSince($0) < 20 } ?? false }

        mutating func add(_ delta: Double, rms: Double) {
            // Take the first match whole; after that, move halfway each time so a single
            // odd frame can't make the labels jump.
            degrees += matches == 0 ? delta : 0.5 * delta
            matches += 1
            lastMatch = Date()
            lastRMS = rms
        }
    }

    /// A paused view: the phone's pose and the correction when it was paused.
    struct Frozen {
        var pose: MotionTracker.Pose
        var correction: Double
    }

    var phase: Phase = .locating
    var scene: TerrainScene?
    var correction = Correction()
    var frozen: Frozen?

    let camera = CameraFeed()
    let motion = MotionTracker()
    @ObservationIgnored weak var preview: PreviewView?
    private let store = DataStore()
    private let corrector = SkylineCorrector()
    private let locationManager = CLLocationManager()
    private let locationDelegate = LocationDelegate()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var loading = false
    /// The place the scene is built for.
    @ObservationIgnored private var center: CLLocation?
    @ObservationIgnored private var tiles: [DataStore.Key: ElevationTile] = [:]
    @ObservationIgnored private var peaks: [Peak] = []
    @ObservationIgnored private var rebuilding = false
    @ObservationIgnored private var rebuildAgain = false

    func start() {
        guard !started else { return }
        started = true

        locationDelegate.onLocation = { [weak self] in self?.locationChanged($0) }
        locationDelegate.onAuthorization = { [weak self] status in
            if status == .denied || status == .restricted {
                self?.phase = .needsPermission("Peak needs your location to know which mountains you see. Allow it in Settings.")
            }
        }
        locationManager.delegate = locationDelegate
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 100
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()

        // Camera frames arrive on the camera's queue; the corrector takes about one a second.
        camera.onFrame = { [weak self] buffer in
            guard let self, let pose = self.motion.pose else { return }
            self.corrector.offer(buffer, pose: pose, steady: self.motion.isSteady, camera: self.camera)
        }
        corrector.onResult = { [weak self] outcome in
            guard let self, outcome.accepted, self.frozen == nil else { return }
            self.correction.add(outcome.delta, rms: outcome.rms)
            self.corrector.update(horizon: self.scene?.horizon, correction: self.correction.degrees)
        }
        setActive(true)
    }

    /// Runs the camera and motion sensors only while the app is on screen.
    func setActive(_ active: Bool) {
        guard started else { return }
        if active {
            motion.start()
            camera.start { [weak self] running in
                if !running {
                    self?.phase = .needsPermission("Peak needs the camera to label the mountains. Allow it in Settings.")
                }
            }
        } else {
            camera.stop()
            motion.stop()
        }
    }

    // MARK: Freeze frame

    func toggleFreeze() {
        if frozen != nil {
            frozen = nil
            preview?.setFrozen(false)
        } else if let pose = motion.pose {
            frozen = Frozen(pose: pose, correction: correction.degrees)
            preview?.setFrozen(true)
        }
    }

    // MARK: Terrain and peaks

    private func locationChanged(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100, !loading else { return }
        if let center, location.distance(from: center) < 1_000 { return }
        load(location)
    }

    /// Gets what's needed to draw the view from `location`. A quick first pass fetches
    /// every tile at 120 m (60 m for the one you're in), about 2 MB each, all at once, and
    /// shows the view; then nearby tiles are sharpened to 30 m and 60 m in the background.
    private func load(_ location: CLLocation) {
        loading = true
        let lat = location.coordinate.latitude, lon = location.coordinate.longitude
        let keys = DataStore.tiles(latitude: lat, longitude: lon, radius: TerrainScene.radius)
        let here = DataStore.Key(south: Int(lat.rounded(.down)), west: Int(lon.rounded(.down)))
        let store = self.store

        // Peaks come from a different server; don't wait for them to show the terrain.
        Task { @MainActor in
            let found = await store.peaks(latitude: lat, longitude: lon, radius: TerrainScene.radius)
            peaks = found
            if !tiles.isEmpty { await rebuild() }
        }

        Task { @MainActor in
            defer { loading = false }
            if scene == nil { phase = .loading("Getting terrain…") }
            var fetched: [DataStore.Key: ElevationTile] = [:]
            var done = 0
            await withTaskGroup(of: (DataStore.Key, ElevationTile?).self) { group in
                for key in keys {
                    let level = key == here ? 1 : 2
                    group.addTask {
                        var tile: ElevationTile?
                        do {
                            if await store.isSea(key) {
                                tile = Self.seaTile(key)
                            } else {
                                tile = try await store.tile(key, level: level) ?? Self.seaTile(key)
                            }
                        } catch {
                            tile = nil   // retried in the background pass below
                        }
                        return (key, tile)
                    }
                }
                for await (key, tile) in group {
                    done += 1
                    if let tile { fetched[key] = tile }
                    if scene == nil { phase = .loading("Downloading terrain · \(done) of \(keys.count)") }
                }
            }
            guard fetched[here] != nil else {
                if scene == nil { phase = .failed("Couldn't download the terrain here. Check your connection.") }
                return
            }
            // Keep sharper tiles from before, drop ones too far away now.
            for (key, tile) in fetched where tiles[key].map({ $0.rows < tile.rows }) ?? true { tiles[key] = tile }
            for key in tiles.keys where !keys.contains(key) { tiles[key] = nil }
            center = location
            await rebuild()
            phase = .ready

            // Sharper terrain nearby, nearest first: 30 m within 15 km, 60 m within 40 km.
            // Tiles that failed above are tried again here.
            let upgrades = keys
                .map { ($0, DataStore.distance(from: lat, lon, to: $0)) }
                .sorted { $0.1 < $1.1 }
                .compactMap { key, d -> (DataStore.Key, Int)? in
                    let want = d < 15_000 ? 0 : d < 40_000 ? 1 : 2
                    guard let have = tiles[key] else { return (key, want) }
                    return have.rows > 4 && Self.level(of: have) > want ? (key, want) : nil
                }
            for (key, level) in upgrades {
                do {
                    let tile = try await store.tile(key, level: level)
                    tiles[key] = tile ?? Self.seaTile(key)
                    await rebuild()
                } catch {
                    continue   // keep what we have; the next visit tries again
                }
            }
        }
    }

    /// Builds the scene from the tiles and peaks so far, off the main thread. Calls that
    /// arrive while a build runs are folded into one more build afterwards.
    @MainActor private func rebuild() async {
        guard let center else { return }
        if rebuilding {
            rebuildAgain = true
            return
        }
        rebuilding = true
        repeat {
            rebuildAgain = false
            let terrain = Terrain(tiles: Array(tiles.values), missingIsSea: false)
            let peaks = self.peaks
            let lat = center.coordinate.latitude, lon = center.coordinate.longitude
            let built = await Task.detached(priority: .userInitiated) {
                TerrainScene.build(terrain: terrain, latitude: lat, longitude: lon, peaks: peaks)
            }.value
            scene = built
            corrector.update(horizon: built.horizon, correction: correction.degrees)
        } while rebuildAgain
        rebuilding = false
    }

    /// 0 for a full 30 m tile, 1 for 60 m, 2 for 120 m (3600, 1800 or 900 rows below 50°).
    private static func level(of tile: ElevationTile) -> Int {
        let pixel = tile.stepLatitude * 3600
        return pixel < 1.5 ? 0 : pixel < 3 ? 1 : 2
    }

    /// A tile of open sea, where the Copernicus bucket has no data.
    private static func seaTile(_ key: DataStore.Key) -> ElevationTile {
        ElevationTile(south: key.south, west: key.west, size: 2) { _, _ in 0 }
    }
}

/// Location callbacks, forwarded to closures on the main thread.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last { onLocation?(last) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(manager.authorizationStatus)
    }
}

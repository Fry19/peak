import CoreLocation
import Network
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

    /// A paused view: the phone's pose and the heading correction when it was paused.
    struct Frozen {
        var pose: MotionTracker.Pose
        var heading: Double
    }

    var phase: Phase = .locating
    var scene: TerrainScene?
    var correction = Correction()
    var frozen: Frozen?
    var showDebug = false
    /// The last skyline match, for the debug panel.
    var lastOutcome: SkylineCorrector.Outcome?

    let camera = CameraFeed()
    let motion = MotionTracker()
    @ObservationIgnored weak var preview: PreviewView?
    private let store = DataStore()
    private let corrector = SkylineCorrector()
    private let locationManager = CLLocationManager()
    private let locationDelegate = LocationDelegate()
    private let network = NWPathMonitor()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var onWiFi = false
    /// The best location so far, and the one the scene is built for.
    @ObservationIgnored private(set) var location: CLLocation?
    @ObservationIgnored private var center: CLLocation?
    @ObservationIgnored private var tiles: [DataStore.Key: ElevationTile] = [:]
    @ObservationIgnored private var peaks: [Peak] = []
    @ObservationIgnored private var rebuilding = false
    @ObservationIgnored private var rebuildAgain = false
    @ObservationIgnored private(set) var lastBuildSeconds = 0.0
    @ObservationIgnored private(set) var bytesDownloaded = 0

    /// Heading correction to apply to the motion sensors: their north (magnetic or true)
    /// plus what skyline matching found.
    var headingCorrection: Double { motion.northCorrection + correction.degrees }

    func start() {
        guard !started else { return }
        started = true

        locationDelegate.onLocation = { [weak self] in self?.locationChanged($0) }
        locationDelegate.onHeading = { [weak self] heading in
            // True heading minus magnetic heading is the declination here.
            if heading.trueHeading >= 0 {
                var d = heading.trueHeading - heading.magneticHeading
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                self?.motion.setDeclination(d)
            }
        }
        locationDelegate.onAuthorization = { [weak self] status in
            guard let self else { return }
            switch status {
            case .denied, .restricted:
                self.phase = .needsPermission("Peak needs your location to know which mountains you see. Allow it in Settings.")
            case .authorizedWhenInUse, .authorizedAlways:
                // With the location known, the sensors can reference true north.
                if self.active { self.motion.start(trueNorth: true) }
            default:
                break
            }
        }
        locationManager.delegate = locationDelegate
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        locationManager.requestWhenInUseAuthorization()

        network.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && !path.isExpensive
            DispatchQueue.main.async { self?.onWiFi = wifi }
        }
        network.start(queue: DispatchQueue(label: "peak.network"))

        // Camera frames arrive on the camera's queue; the corrector takes about one a second.
        camera.onFrame = { [weak self] buffer in
            guard let self, let pose = self.motion.pose else { return }
            self.corrector.offer(buffer, pose: pose, steady: self.motion.isSteady, camera: self.camera)
        }
        corrector.onResult = { [weak self] outcome in
            guard let self else { return }
            self.lastOutcome = outcome
            guard outcome.accepted, self.frozen == nil else { return }
            self.correction.add(outcome.delta, rms: outcome.rms)
            self.corrector.update(horizon: self.scene?.horizon, correction: self.headingCorrection)
        }
        setActive(true)
    }

    /// Runs the camera and sensors while the app is in use. Permission prompts only make the
    /// app briefly inactive, so only going to the background stops them.
    func setActive(_ active: Bool) {
        guard started, active != self.active else { return }
        self.active = active
        if active {
            let status = locationManager.authorizationStatus
            motion.start(trueNorth: status == .authorizedWhenInUse || status == .authorizedAlways)
            locationManager.startUpdatingLocation()
            locationManager.startUpdatingHeading()
            camera.start { [weak self] running in
                if !running {
                    self?.phase = .needsPermission("Peak needs the camera to label the mountains. Allow it in Settings.")
                }
            }
        } else {
            camera.stop()
            motion.stop()
            locationManager.stopUpdatingHeading()
            locationManager.stopUpdatingLocation()
        }
    }

    // MARK: Freeze frame

    func toggleFreeze() {
        if frozen != nil {
            frozen = nil
            preview?.setFrozen(false)
        } else if let pose = motion.pose, scene != nil {
            frozen = Frozen(pose: pose, heading: headingCorrection)
            preview?.setFrozen(true)
        }
    }

    // MARK: Terrain and peaks

    private func locationChanged(_ new: CLLocation) {
        guard new.horizontalAccuracy >= 0 else { return }
        if let old = location, old.horizontalAccuracy < new.horizontalAccuracy,
           new.distance(from: old) < old.horizontalAccuracy { return }
        location = new
        // Tiles are 1° wide, so a rough first fix is enough to start downloading.
        if !loading, new.horizontalAccuracy < 2_000, center.map({ new.distance(from: $0) > 1_000 }) ?? true {
            load(new)
        } else if let center, scene != nil, new.horizontalAccuracy < 50,
                  new.distance(from: center) > max(50, new.horizontalAccuracy) {
            // A better fix nearby: rebuild for the exact spot (the terrain is already here).
            self.center = new
            Task { @MainActor in await rebuild() }
        }
    }

    /// Gets what's needed to draw the view. A small first download (240 m terrain, about
    /// 0.6 MB a tile, and 120 m within 30 km) shows the view within seconds; then the terrain
    /// nearby is sharpened in the background, to the full 30 m on Wi-Fi.
    private func load(_ start: CLLocation) {
        loading = true
        let lat = start.coordinate.latitude, lon = start.coordinate.longitude
        let keys = DataStore.tiles(latitude: lat, longitude: lon, radius: TerrainScene.radius)
            .sorted { DataStore.distance(from: lat, lon, to: $0) < DataStore.distance(from: lat, lon, to: $1) }
        let here = DataStore.Key(south: Int(lat.rounded(.down)), west: Int(lon.rounded(.down)))
        let store = self.store

        // Peaks come from a different server; don't wait for them to show the terrain.
        Task { @MainActor in
            let found = await store.peaks(latitude: lat, longitude: lon, radius: TerrainScene.radius)
            peaks = found
            if scene != nil { await rebuild() }
        }

        Task { @MainActor in
            defer { loading = false }
            if scene == nil { phase = .loading("Getting terrain…") }
            var done = 0
            await withTaskGroup(of: (DataStore.Key, ElevationTile?).self) { group in
                for key in keys {
                    let level = key == here || DataStore.distance(from: lat, lon, to: key) < 30_000 ? 2 : 3
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
                    if let tile, tiles[key].map({ $0.rows < tile.rows }) ?? true { tiles[key] = tile }
                    bytesDownloaded = await store.bytesDownloaded
                    if scene == nil {
                        let mb = String(format: "%.1f", Double(bytesDownloaded) / 1_000_000)
                        phase = .loading("Downloading terrain · \(done) of \(keys.count) · \(mb) MB")
                    }
                    // Show the view as soon as the terrain around you is in; the rest fills in.
                    if key == here, tile != nil {
                        if center == nil { center = location ?? start }
                        await rebuild()
                        phase = .ready
                    }
                }
            }
            for key in tiles.keys where !keys.contains(key) { tiles[key] = nil }
            if tiles[here] == nil {
                if scene == nil { phase = .failed("Couldn't download the terrain here. Check your connection and reopen Peak.") }
                return
            }
            center = location ?? start
            await rebuild()
            phase = .ready

            // Sharper terrain nearby, nearest first. Tiles that failed above are tried again.
            for key in keys {
                let d = DataStore.distance(from: lat, lon, to: key)
                let want = d < 15_000 ? (onWiFi ? 0 : 1) : d < 40_000 ? (onWiFi ? 1 : 2) : 2
                if let have = tiles[key], have.rows <= 4 || Self.level(of: have) <= want { continue }
                do {
                    let tile = try await store.tile(key, level: want)
                    tiles[key] = tile ?? Self.seaTile(key)
                    bytesDownloaded = await store.bytesDownloaded
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
            let started = Date()
            let built = await Task.detached(priority: .userInitiated) {
                TerrainScene.build(terrain: terrain, latitude: lat, longitude: lon, peaks: peaks)
            }.value
            lastBuildSeconds = Date().timeIntervalSince(started)
            scene = built
            corrector.update(horizon: built.horizon, correction: headingCorrection)
        } while rebuildAgain
        rebuilding = false
    }

    /// 0 for a full 30 m tile, 1 for 60 m, 2 for 120 m, 3 for 240 m.
    static func level(of tile: ElevationTile) -> Int {
        let pixel = tile.stepLatitude * 3600
        return pixel < 1.5 ? 0 : pixel < 3 ? 1 : pixel < 6 ? 2 : 3
    }

    /// A tile of open sea, where the Copernicus bucket has no data.
    private static func seaTile(_ key: DataStore.Key) -> ElevationTile {
        ElevationTile(south: key.south, west: key.west, size: 2) { _, _ in 0 }
    }

    // MARK: Debug

    /// What the app is doing, for the debug panel (long-press the pill).
    var debugLines: [String] {
        var lines: [String] = []
        let s = motion.status
        if let pose = motion.pose {
            let a = CameraGeometry.attitude(pose, correction: headingCorrection)
            lines.append(String(format: "heading %.1f°  pitch %.1f°  roll %.1f°", a.heading, a.pitch, a.roll))
        } else {
            lines.append("no motion data yet")
        }
        lines.append(String(format: "sensors %.0f/s, %@ north, last %.1f s ago", s.updatesPerSecond,
                            s.trueNorth ? "true" : "magnetic", s.secondsSinceUpdate))
        lines.append(String(format: "compass correction %+.2f° (skyline %+.2f°, north %+.2f°), %ld matches",
                            headingCorrection, correction.degrees, motion.northCorrection, correction.matches))
        if let o = lastOutcome {
            lines.append(o.accepted ? String(format: "last match: ok %+.2f°, %.2f° rms, %.0f ms", o.delta, o.rms, o.seconds * 1000)
                                    : "last match: \(o.reason ?? "rejected")")
        }
        if let l = location {
            lines.append(String(format: "GPS ±%.0f m, %.4f, %.4f", l.horizontalAccuracy, l.coordinate.latitude, l.coordinate.longitude))
        }
        let levels = tiles.values.filter { $0.rows > 4 }.map { ["30", "60", "120", "240"][Self.level(of: $0)] }
        lines.append("terrain: \(tiles.count) tiles (\(levels.sorted().joined(separator: " ")) m), " +
                     String(format: "%.1f MB, %@", Double(bytesDownloaded) / 1_000_000, onWiFi ? "Wi-Fi" : "mobile data"))
        if let scene {
            lines.append(String(format: "view: built in %.2f s, %ld peaks, %ld visible, eye at %.0f m", lastBuildSeconds,
                                peaks.count, scene.peaks.count, scene.observer.height))
        }
        lines.append(String(format: "camera: %.1f° field of view, %@ frames", camera.fieldOfView,
                            camera.portraitFrames ? "portrait" : "landscape"))
        return lines
    }
}

/// Location callbacks, forwarded to closures on the main thread.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    var onHeading: ((CLHeading) -> Void)?
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last { onLocation?(last) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        onHeading?(newHeading)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(manager.authorizationStatus)
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}

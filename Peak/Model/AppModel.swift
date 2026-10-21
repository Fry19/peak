import CoreLocation
import Network
import Observation
import PeakCore
import SwiftUI

extension Peak: Identifiable {}

@Observable
final class AppModel {
    enum Phase: Equatable {
        case locating
        case loading(String)
        case ready
        case needsPermission(String)
        case failed(String)
    }

    /// The corrections from skyline matching, smoothed over frames.
    struct Correction {
        var view = ViewCorrection()
        var matches = 0
        var lastMatch: Date?
        var lastRMS = 0.0

        /// Matched recently enough to trust over the compass.
        var isAligned: Bool { lastMatch.map { Date().timeIntervalSince($0) < 20 } ?? false }

        mutating func add(_ o: SkylineCorrector.Outcome) {
            // Take the first match half whole; after that, move part of the way each time so
            // a single odd frame can't make the labels jump. The level is steadier than the
            // compass, so it moves more slowly.
            let first = matches == 0
            view.heading += first ? o.delta : 0.5 * o.delta
            view.pitch = max(-3, min(3, view.pitch + (first ? 0.5 : 0.3) * o.pitchDelta))
            view.roll = max(-3, min(3, view.roll + (first ? 0.5 : 0.3) * o.rollDelta))
            matches += 1
            lastMatch = Date()
            lastRMS = o.rms
        }
    }

    /// A paused view: the frame on screen and how it was drawn.
    struct Frozen {
        var shown: Shown
        var pose: MotionTracker.Pose
        var correction: ViewCorrection
    }

    /// The frame on screen: when it was taken and through which lens.
    struct Shown {
        var time: TimeInterval
        var lens: CameraFeed.Lens
        var portrait: Bool
    }

    enum Sheet: Identifiable, Equatable {
        case peak(Int64)
        case list
        case settings

        var id: String {
            switch self {
            case let .peak(id): return "peak\(id)"
            case .list: return "list"
            case .settings: return "settings"
            }
        }
    }

    /// A trail drawn on the mountain.
    struct ARTrail {
        var trail: Trail
        var peakID: Int64
        /// The stretches in sight, once worked out.
        var runs: [[DrapedPoint]]?
    }

    var phase: Phase = .locating
    var scene: TerrainScene?
    var correction = Correction()
    var frozen: Frozen?
    var settings = AppSettings.load()
    var sheet: Sheet?
    /// The peak highlighted in the view (tapped, or picked from the list).
    var selectedPeakID: Int64?
    var arTrail: ARTrail?
    /// The last skyline match, for diagnostics.
    var lastOutcome: SkylineCorrector.Outcome?
    var offlineStatus: String?
    var storageBytes: Int?

    let camera = CameraFeed()
    let motion = MotionTracker()
    @ObservationIgnored weak var screen: CameraScreenView?
    let store = DataStore()
    private let corrector = SkylineCorrector()
    private let locationManager = CLLocationManager()
    private let locationDelegate = LocationDelegate()
    private let network = NWPathMonitor()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private(set) var onWiFi = false
    /// The best location so far, and the one the scene is built for.
    @ObservationIgnored private(set) var location: CLLocation?
    @ObservationIgnored private var center: CLLocation?
    @ObservationIgnored private var tiles: [DataStore.Key: ElevationTile] = [:]
    /// Sharper patches of tiles near the viewer, by tile and level.
    @ObservationIgnored private var detail: [DataStore.Key: [Int: ElevationTile]] = [:]
    @ObservationIgnored private var peaks: [Peak] = []
    @ObservationIgnored private var rebuilding = false
    @ObservationIgnored private var rebuildAgain = false
    @ObservationIgnored private(set) var lastBuildSeconds = 0.0
    @ObservationIgnored private(set) var bytesDownloaded = 0
    @ObservationIgnored private var details: [Int64: PeakDetails] = [:]

    /// Corrections to apply to the motion sensors: their north (magnetic or true) plus
    /// what skyline matching found.
    var viewCorrection: ViewCorrection {
        var c = correction.view
        c.heading += motion.northCorrection
        return c
    }

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

        // Every frame goes to the screen with the moment it was taken; about one a second
        // also goes to skyline matching, with the phone's pose at that moment.
        camera.onFrame = { [weak self] frame in
            guard let self else { return }
            if let pose = self.motion.pose(at: frame.time) {
                self.corrector.offer(frame, pose: pose, steady: self.motion.isSteady)
            }
            DispatchQueue.main.async { self.screen?.show(frame) }
        }
        corrector.onResult = { [weak self] outcome in
            guard let self else { return }
            self.lastOutcome = outcome
            guard outcome.accepted, self.frozen == nil else { return }
            self.correction.add(outcome)
            self.corrector.update(horizon: self.scene?.horizon, correction: self.viewCorrection)
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
        } else if let shown = screen?.shown, let pose = motion.pose(at: shown.time), scene != nil {
            frozen = Frozen(shown: shown, pose: pose, correction: viewCorrection)
        }
    }

    // MARK: Peaks and trails

    func peak(_ id: Int64) -> Peak? {
        scene?.allPeaks[id]?.peak ?? peaks.first { $0.id == id }
    }

    /// Opens a peak's card and highlights it in the view.
    func select(_ id: Int64) {
        selectedPeakID = id
        sheet = .peak(id)
    }

    /// Facts and hikes for a peak, loading in the background.
    func details(for peak: Peak) -> PeakDetails {
        if let d = details[peak.id] { return d }
        let d = PeakDetails(peak: peak)
        details[peak.id] = d
        d.load(store: store, terrain: { [weak self] in self?.scene?.terrain })
        return d
    }

    /// Draws a trail on the mountain and closes the card so it can be seen.
    func showOnMountain(_ trail: Trail, peakID: Int64) {
        selectedPeakID = peakID
        sheet = nil
        arTrail = ARTrail(trail: trail, peakID: peakID, runs: nil)
        drapeTrail()
    }

    func clearTrail() {
        arTrail = nil
    }

    private func drapeTrail() {
        guard let trail = arTrail?.trail, let scene else { return }
        Task { @MainActor in
            let runs = await Task.detached(priority: .userInitiated) { scene.drape(trail) }.value
            if arTrail?.trail.id == trail.id { arTrail?.runs = runs }
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
    /// 0.6 MB a tile, and 120 m within 30 km) shows the view within seconds. Then the
    /// terrain around you is sharpened block by block: the full 30 m within 10 km, 60 m
    /// within 35 km, and 120 m everywhere; further 30 m terrain on Wi-Fi.
    private func load(_ start: CLLocation, everything: Bool = false) {
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
            defer {
                loading = false
                if everything { offlineStatus = "Saved for offline use" }
            }
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
                            tile = nil   // retried in the passes below
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
            for key in detail.keys where !keys.contains(key) { detail[key] = nil }
            if tiles[here] == nil {
                if scene == nil { phase = .failed("Couldn't download the terrain here. Check your connection and reopen Peak.") }
                return
            }
            center = location ?? start
            await rebuild()
            phase = .ready

            // Sharper terrain, nearest first; each pass shows when it's done.
            let generous = everything || onWiFi || settings.detailOnMobile
            await sharpen(keys, lat, lon, level: 0, radius: 10_000)
            await sharpen(keys, lat, lon, level: 1, radius: 35_000)
            await upgrade(keys, lat, lon, toLevel: 2, within: generous ? TerrainScene.radius + 50_000 : 60_000)
            if generous { await sharpen(keys, lat, lon, level: 0, radius: everything || onWiFi ? 25_000 : 15_000) }
            if everything { await sharpen(keys, lat, lon, level: 1, radius: 60_000) }
        }
    }

    /// Fetches `level` patches for the part of each tile within `radius` of the point.
    @MainActor private func sharpen(_ keys: [DataStore.Key], _ lat: Double, _ lon: Double, level: Int, radius: Double) async {
        var changed = false
        for key in keys where DataStore.distance(from: lat, lon, to: key) < radius {
            if let have = tiles[key], have.rows <= 4 || Self.level(of: have) <= level { continue }
            do {
                if let patch = try await store.patch(key, level: level, latitude: lat, longitude: lon, radius: radius) {
                    // Keep the bigger patch if one from an earlier pass covers more.
                    if let old = detail[key]?[level], old.rows * old.cols > patch.rows * patch.cols { continue }
                    detail[key, default: [:]][level] = patch
                    changed = true
                }
            } catch {
                continue   // keep what we have; the next visit tries again
            }
            bytesDownloaded = await store.bytesDownloaded
        }
        if changed { await rebuild() }
    }

    /// Fetches whole tiles at `level` for tiles within `within` meters that are coarser.
    @MainActor private func upgrade(_ keys: [DataStore.Key], _ lat: Double, _ lon: Double, toLevel level: Int, within: Double) async {
        var changed = false
        for key in keys where DataStore.distance(from: lat, lon, to: key) < within {
            if let have = tiles[key], have.rows <= 4 || Self.level(of: have) <= level { continue }
            if let tile = try? await store.tile(key, level: level) {
                tiles[key] = tile
                changed = true
            } else if tiles[key] == nil, await store.isSea(key) {
                tiles[key] = Self.seaTile(key)
            }
            bytesDownloaded = await store.bytesDownloaded
        }
        if changed { await rebuild() }
    }

    /// Downloads the sharpest terrain for the whole area around you, for use offline.
    func saveAreaForOffline() {
        guard let here = location ?? center else {
            offlineStatus = "Waiting for your position…"
            return
        }
        guard !loading else {
            offlineStatus = "Still loading; try again in a moment"
            return
        }
        offlineStatus = "Downloading…"
        load(here, everything: true)
    }

    func refreshStorage() {
        Task { @MainActor in storageBytes = await store.storageUsed() }
    }

    func clearDownloads() {
        Task { @MainActor in
            await store.clear()
            details.removeAll()
            storageBytes = await store.storageUsed()
            offlineStatus = nil
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
            let terrain = Terrain(tiles: Array(tiles.values), detail: detail.values.flatMap { $0.values }, missingIsSea: false)
            let peaks = self.peaks
            let lat = center.coordinate.latitude, lon = center.coordinate.longitude
            let started = Date()
            let built = await Task.detached(priority: .userInitiated) {
                TerrainScene.build(terrain: terrain, latitude: lat, longitude: lon, peaks: peaks)
            }.value
            lastBuildSeconds = Date().timeIntervalSince(started)
            scene = built
            corrector.update(horizon: built.horizon, correction: viewCorrection)
            if arTrail != nil { drapeTrail() }
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

    // MARK: Diagnostics

    /// What the app is doing, for the diagnostics panel (long-press the pill).
    var debugLines: [String] {
        var lines: [String] = []
        let s = motion.status
        let c = viewCorrection
        if let pose = motion.pose {
            let a = CameraGeometry.attitude(CameraGeometry.axes(pose, orientation: .portrait), correction: c)
            lines.append(String(format: "heading %.1f°  pitch %.1f°  roll %.1f°", a.heading, a.pitch, a.roll))
        } else {
            lines.append("no motion data yet")
        }
        lines.append(String(format: "sensors %.0f/s, %@ north, last %.1f s ago", s.updatesPerSecond,
                            s.trueNorth ? "true" : "magnetic", s.secondsSinceUpdate))
        lines.append(String(format: "correction: heading %+.2f° (skyline %+.2f°, north %+.2f°), pitch %+.2f°, roll %+.2f°",
                            c.heading, correction.view.heading, motion.northCorrection, c.pitch, c.roll))
        lines.append(String(format: "%ld matches", correction.matches))
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
        let patches = detail.values.flatMap { $0 }.map { "\(["30", "60", "120", "240"][$0.key]) m \($0.value.cols)×\($0.value.rows)" }
        if !patches.isEmpty { lines.append("sharper: " + patches.sorted().joined(separator: ", ")) }
        if let scene {
            lines.append(String(format: "view: built in %.2f s, %ld peaks, %ld visible, eye at %.0f m", lastBuildSeconds,
                                peaks.count, scene.peaks.count, scene.observer.height))
        }
        if let lens = camera.lens {
            let k = lens.intrinsics
            lines.append(String(format: "lens: %.1f° (%@), center %+.1f %+.1f px of %ldx%ld", lens.fieldOfView,
                                lens.measured ? "measured" : "estimated", k.cx - Double(k.width) / 2, k.cy - Double(k.height) / 2,
                                k.width, k.height))
        }
        if let shown = screen?.shown, let latest = motion.latestTime {
            lines.append(String(format: "frame drawn with the pose from %.0f ms before the newest", (latest - shown.time) * 1000))
        }
        return lines
    }
}

/// Facts and hikes for one peak, loaded in the background.
@Observable
final class PeakDetails {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// A hike near the peak, with what the terrain says about it.
    struct Hike: Identifiable {
        var trail: Trail
        var profile: TrailProfile?
        /// Comes within 250 m of the summit.
        var reachesSummit: Bool
        var distanceFromPeak: Double
        var id: String { trail.id }
    }

    let peak: Peak
    var facts: PeakFacts?
    var factsState: State = .loading
    var hikes: [Hike] = []
    var hikesState: State = .loading

    init(peak: Peak) {
        self.peak = peak
    }

    func load(store: DataStore, terrain: @escaping () -> Terrain?) {
        let peak = self.peak
        Task { @MainActor in
            do {
                facts = try await store.facts(for: peak)
                factsState = .loaded
            } catch {
                factsState = .failed(error.localizedDescription)
            }
        }
        loadHikes(store: store, terrain: terrain)
    }

    func loadHikes(store: DataStore, terrain: @escaping () -> Terrain?) {
        let peak = self.peak
        hikesState = .loading
        Task { @MainActor in
            do {
                let trails = try await store.trails(near: peak)
                let ground = terrain()
                hikes = await Task.detached(priority: .userInitiated) {
                    trails.map { t in
                        let d = t.distance(to: peak.position)
                        return Hike(trail: t, profile: ground.flatMap { t.profile(on: $0) }, reachesSummit: d < 250, distanceFromPeak: d)
                    }
                    .sorted { ($0.reachesSummit ? 0 : 1, $0.distanceFromPeak) < ($1.reachesSummit ? 0 : 1, $1.distanceFromPeak) }
                }.value
                hikesState = .loaded
            } catch {
                hikesState = .failed("Couldn't load hikes. Check your connection.")
            }
        }
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

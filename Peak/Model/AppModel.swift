import CoreLocation
import Network
import Observation
import PeakCore
import SwiftUI
import UIKit

@Observable
final class AppModel {
    enum Phase: Equatable {
        case locating
        case loading(String)
        case ready
        case needsPermission(String)
        case failed(String)
    }

    /// The corrections from skyline matching (smoothed over frames) and from lining the
    /// view up by hand.
    struct Correction {
        /// Pitch and roll, degrees.
        struct Level: Codable, Equatable {
            var pitch = 0.0
            var roll = 0.0
        }

        /// The compass error, degrees.
        var heading = 0.0
        /// Pitch and roll for the phone held upright and held sideways. A camera mounted a
        /// little askew tilts the view one way upright and another way sideways, so each
        /// keeps its own; they're saved, since they belong to the phone.
        var level = [Level(), Level()]
        var matches = 0
        var lastMatch: Date?
        var lastRMS = 0.0
        /// When the view was last lined up by hand.
        var byHand: Date?

        enum State { case locked, byHand, compass }

        var state: State {
            if let lastMatch, Date().timeIntervalSince(lastMatch) < 20 { return .locked }
            if let byHand, Date().timeIntervalSince(byHand) < 600 { return .byHand }
            return .compass
        }

        func view(sideways: Bool) -> ViewCorrection {
            let l = level[sideways ? 1 : 0]
            return ViewCorrection(heading: heading, pitch: l.pitch, roll: l.roll)
        }

        mutating func add(_ o: SkylineCorrector.Outcome) {
            // Take the first match half whole; after that, move part of the way each time so
            // a single odd frame can't make the labels jump. The level is steadier than the
            // compass, so it moves more slowly.
            let first = matches == 0
            heading += first ? o.delta : 0.5 * o.delta
            let i = o.sideways ? 1 : 0
            level[i].pitch = max(-10, min(10, level[i].pitch + (first ? 0.5 : 0.3) * o.pitchDelta))
            level[i].roll = max(-10, min(10, level[i].roll + (first ? 0.5 : 0.3) * o.rollDelta))
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

    /// Getting the peaks around you: under way, waiting to try again, or done.
    enum PeaksState: Equatable {
        case loading
        /// No connection or the servers were busy, and none were saved; trying again at `at`.
        case retrying(at: Date, reason: String)
        case loaded
    }

    var phase: Phase = .locating
    private(set) var peaksState: PeaksState = .loading
    var scene: TerrainScene?
    var correction = Correction()
    var frozen: Frozen?
    var settings = AppSettings.load()
    var sheet: Sheet?
    /// The peak highlighted in the view (tapped, or picked from the list).
    var selectedPeakID: Int64?
    var arTrail: ARTrail?
    /// Lining the view up by hand: the picture is paused and dragging moves the lines.
    var aligning = false
    /// How far the picture and the lines are zoomed in, 1 to `maxZoom`.
    var zoom: Double = 1
    static let maxZoom = 6.0
    /// The last skyline match, for diagnostics.
    var lastOutcome: SkylineCorrector.Outcome?
    var storageBytes: Int?
    /// Areas saved for offline use, newest first.
    var areas: [OfflineArea] = []
    /// The area downloading now, and how far along it is.
    var areaProgress: AreaProgress?
    /// Why an area's download stopped, by area.
    var areaFailures: [UUID: String] = [:]

    struct AreaProgress: Equatable {
        var id: UUID
        var fraction = 0.0
        var step = "Starting…"
    }

    let camera = CameraFeed()
    let motion = MotionTracker()
    @ObservationIgnored weak var screen: CameraScreenView?
    let store = DataStore()
    private let corrector = SkylineCorrector()
    private let mailbox = FrameMailbox()
    private let locationManager = CLLocationManager()
    private let locationDelegate = LocationDelegate()
    private let network = NWPathMonitor()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var loading = false
    /// Where the terrain and peaks were last loaded around (they're loaded again after
    /// moving `reloadDistance` from it), the load under way, and a count of loads so a
    /// superseded one stops.
    @ObservationIgnored private var loadedAt: CLLocation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    static let reloadDistance = 2_000.0
    /// A load for a place this far behind is dropped for one where you are.
    static let restartDistance = 8_000.0
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

    /// Corrections to apply to the motion sensors for a pose: their north (magnetic or
    /// true) plus what skyline matching or lining up by hand found.
    func viewCorrection(for pose: MotionTracker.Pose?) -> ViewCorrection {
        var c = correction.view(sideways: CameraGeometry.isSideways(pose))
        c.heading += motion.northCorrection
        return c
    }

    private func updateCorrector() {
        let north = motion.northCorrection
        var upright = correction.view(sideways: false), sideways = correction.view(sideways: true)
        upright.heading += north
        sideways.heading += north
        corrector.update(horizon: scene?.horizon, upright: upright, sideways: sideways)
    }

    func start() {
        guard !started else { return }
        started = true

        loadCalibration()
        Task { @MainActor in areas = await store.loadAreas() }
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
            self.mailbox.post(frame) { [weak self] in self?.screen?.show($0) }
        }
        corrector.onResult = { [weak self] outcome in
            guard let self else { return }
            self.lastOutcome = outcome
            guard outcome.accepted, self.frozen == nil else { return }
            self.correction.add(outcome)
            self.updateCorrector()
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
            saveCalibration()
            camera.stop()
            motion.stop()
            locationManager.stopUpdatingHeading()
            locationManager.stopUpdatingLocation()
        }
    }

    // MARK: Freeze frame

    /// Zooms the picture and the lines, 1× to `maxZoom`.
    func setZoom(_ value: Double) {
        zoom = max(1, min(Self.maxZoom, value))
        screen?.zoomChanged()
        // Sharper frames only while zoomed in; the gap between the two keeps it from
        // switching back and forth.
        if zoom >= 2 { camera.setHighResolution(true) } else if zoom <= 1.3 { camera.setHighResolution(false) }
    }

    func toggleFreeze() {
        guard !aligning else { return }
        if frozen != nil {
            frozen = nil
        } else {
            freeze()
        }
    }

    private func freeze() {
        if let shown = screen?.shown, let pose = motion.pose(at: shown.time), scene != nil {
            frozen = Frozen(shown: shown, pose: pose, correction: viewCorrection(for: pose))
        }
    }

    // MARK: Lining up by hand

    /// Pauses the picture so the lines can be dragged onto the mountains.
    func startAligning() {
        sheet = nil
        if frozen == nil { freeze() }
        aligning = true
    }

    func finishAligning() {
        aligning = false
        frozen = nil
        correction.byHand = Date()
        saveCalibration()
        updateCorrector()
    }

    /// Back to the plain compass and level for the way the phone is held.
    func resetAlignment() {
        let sideways = CameraGeometry.isSideways(frozen?.pose ?? motion.pose)
        let before = correction.view(sideways: sideways)
        adjust(heading: -before.heading, pitch: -before.pitch, roll: -before.roll)
        correction.lastMatch = nil
        correction.byHand = nil
    }

    /// Moves the lines: heading, pitch and roll changes in degrees.
    func adjust(heading: Double, pitch: Double, roll: Double) {
        let i = CameraGeometry.isSideways(frozen?.pose ?? motion.pose) ? 1 : 0
        correction.heading += heading
        let level = correction.level[i]
        correction.level[i].pitch = max(-10, min(10, level.pitch + pitch))
        correction.level[i].roll = max(-10, min(10, level.roll + roll))
        if frozen != nil {
            frozen?.correction.heading += heading
            frozen?.correction.pitch += correction.level[i].pitch - level.pitch
            frozen?.correction.roll += correction.level[i].roll - level.roll
        }
    }

    private static let calibrationKey = "levelCalibration"

    private func loadCalibration() {
        guard let data = UserDefaults.standard.data(forKey: Self.calibrationKey),
              let level = try? JSONDecoder().decode([Correction.Level].self, from: data), level.count == 2 else { return }
        correction.level = level
    }

    private func saveCalibration() {
        if let data = try? JSONEncoder().encode(correction.level) { UserDefaults.standard.set(data, forKey: Self.calibrationKey) }
    }

    // MARK: Peaks and trails

    func peak(_ id: Int64) -> Peak? {
        scene?.allPeaks[id]?.peak ?? peaks.first { $0.id == id }
    }

    /// No peaks to show yet because they're still on their way, not because there are none.
    var waitingForPeaks: Bool {
        peaks.isEmpty && peaksState != .loaded
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
            let runs = await Task.detached(priority: .utility) { scene.drape(trail) }.value
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
        guard new.horizontalAccuracy < 2_000 else { return }
        let moved = loadedAt.map { new.distance(from: $0) } ?? .infinity
        if moved > Self.reloadDistance, !loading || moved > Self.restartDistance {
            // Somewhere new: sharp terrain and peaks around it. (A load under way for a spot
            // nearby finishes first, and then loads again around where you are.)
            load(new)
        } else if let center, scene != nil, new.horizontalAccuracy < 50,
                  new.distance(from: center) > max(50, new.horizontalAccuracy) {
            // Moved a little, or a better fix: rebuild for the exact spot (the terrain is here).
            self.center = new
            Task { @MainActor in await rebuild() }
        }
    }

    /// Gets what's needed to draw the view. A small first download (240 m terrain, about
    /// 0.6 MB a tile, and 120 m within 30 km) shows the view within seconds. Then the
    /// terrain around you is sharpened block by block: the full 30 m within 10 km, 60 m
    /// within 35 km, and 120 m everywhere; further 30 m terrain on Wi-Fi or in an area saved
    /// for offline use (where it's all on the phone already).
    private func load(_ start: CLLocation) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        loadedAt = start
        let lat = start.coordinate.latitude, lon = start.coordinate.longitude
        let keys = DataStore.tiles(latitude: lat, longitude: lon, radius: TerrainScene.radius)
            .sorted { DataStore.distance(from: lat, lon, to: $0) < DataStore.distance(from: lat, lon, to: $1) }
        let here = DataStore.Key(south: Int(lat.rounded(.down)), west: Int(lon.rounded(.down)))
        let store = self.store

        // Peaks come from a different server; don't wait for them to show the terrain. With
        // no signal or the servers busy, keep trying until a newer load takes over.
        peaksState = .loading
        Task { @MainActor in
            var wait = 10.0
            while true {
                do {
                    let found = try await store.peaks(latitude: lat, longitude: lon, radius: TerrainScene.radius)
                    // A newer load's peaks win, but these, from a few km away, do until then.
                    let current = generation == loadGeneration
                    guard current || peaks.isEmpty else { return }
                    peaks = found
                    if current { peaksState = .loaded }
                    if scene != nil { await rebuild() }
                    return
                } catch {
                    guard generation == loadGeneration else { return }
                    peaksState = .retrying(at: Date().addingTimeInterval(wait), reason: error.localizedDescription)
                    try? await Task.sleep(for: .seconds(wait))
                    guard generation == loadGeneration else { return }
                    peaksState = .loading
                    wait = min(wait * 2, 60)
                }
            }
        }

        loadTask = Task { @MainActor in
            // A newer load has taken over from this one.
            var superseded: Bool { generation != self.loadGeneration }
            defer {
                if !superseded {
                    loading = false
                    loadTask = nil
                    // Moved on while this ran: load around where you are now.
                    if let location = self.location, location.horizontalAccuracy < 2_000,
                       location.distance(from: start) > Self.reloadDistance { self.load(location) }
                }
            }
            if scene == nil { phase = .loading("Getting terrain…") }
            var done = 0
            await withTaskGroup(of: (DataStore.Key, ElevationTile?).self) { group in
                for key in keys {
                    let level = key == here || DataStore.distance(from: lat, lon, to: key) < 30_000 ? 2 : 3
                    // Already here from a load nearby.
                    if let have = tiles[key], have.rows <= 4 || Self.level(of: have) <= level {
                        done += 1
                        continue
                    }
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
                    if superseded {
                        group.cancelAll()
                        break
                    }
                    done += 1
                    if let tile, tiles[key].map({ $0.rows < tile.rows }) ?? true { tiles[key] = tile }
                    bytesDownloaded = await store.bytesDownloaded
                    if scene == nil {
                        let mb = String(format: "%.1f", Double(bytesDownloaded) / 1_000_000)
                        phase = .loading("Downloading terrain · \(done) of \(keys.count) · \(mb) MB")
                    }
                    // Show the view as soon as the terrain around you is in; the rest fills in.
                    if key == here, tile != nil {
                        center = location ?? start
                        await rebuild()
                        phase = .ready
                    }
                }
            }
            guard !superseded else { return }
            for key in tiles.keys where !keys.contains(key) { tiles[key] = nil }
            // Sharper patches from earlier places that are now too far to matter.
            for (key, patches) in detail {
                let d = DataStore.distance(from: lat, lon, to: key)
                if !keys.contains(key) { detail[key] = nil; continue }
                for level in patches.keys where d > (level == 0 ? 25_000 : 60_000) { detail[key]?[level] = nil }
            }
            if tiles[here] == nil {
                if scene == nil { phase = .failed("Couldn't download the terrain here. Check your connection and reopen Peak.") }
                return
            }
            center = location ?? start
            await rebuild()
            phase = .ready

            // Sharper terrain, nearest first; each pass shows when it's done.
            let saved = areas.contains { $0.complete && $0.contains(LatLon(lat, lon)) }
            let generous = saved || onWiFi || settings.detailOnMobile
            await sharpen(keys, lat, lon, level: 0, radius: 10_000, generation: generation)
            await sharpen(keys, lat, lon, level: 1, radius: 35_000, generation: generation)
            await upgrade(keys, lat, lon, toLevel: 2, within: generous ? TerrainScene.radius + 50_000 : 60_000, generation: generation)
            if generous { await sharpen(keys, lat, lon, level: 0, radius: saved || onWiFi ? 25_000 : 15_000, generation: generation) }
        }
    }

    /// Fetches `level` patches for the part of each tile within `radius` of the point.
    @MainActor private func sharpen(_ keys: [DataStore.Key], _ lat: Double, _ lon: Double, level: Int, radius: Double,
                                    generation: Int) async {
        var changed = false
        for key in keys where DataStore.distance(from: lat, lon, to: key) < radius {
            guard generation == loadGeneration else { return }
            if let have = tiles[key], have.rows <= 4 || Self.level(of: have) <= level { continue }
            do {
                if let patch = try await store.patch(key, level: level, latitude: lat, longitude: lon, radius: radius) {
                    guard generation == loadGeneration else { return }
                    // Keep an earlier patch only if it already covers all of this one (a wider
                    // pass here); one from where you were before gives way.
                    if let old = detail[key]?[level], Self.covers(old, patch) { continue }
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
    @MainActor private func upgrade(_ keys: [DataStore.Key], _ lat: Double, _ lon: Double, toLevel level: Int, within: Double,
                                    generation: Int) async {
        var changed = false
        for key in keys where DataStore.distance(from: lat, lon, to: key) < within {
            guard generation == loadGeneration else { return }
            if let have = tiles[key], have.rows <= 4 || Self.level(of: have) <= level { continue }
            if let tile = try? await store.tile(key, level: level), generation == loadGeneration {
                tiles[key] = tile
                changed = true
            } else if tiles[key] == nil, await store.isSea(key) {
                tiles[key] = Self.seaTile(key)
            }
            bytesDownloaded = await store.bytesDownloaded
        }
        if changed { await rebuild() }
    }

    // MARK: Areas saved for offline use

    /// How far around an area its terrain is saved at 30 m and at 60 m, meters (at 120 m,
    /// everything that can be seen from it). The view uses 30 m within 10 km and 60 m
    /// within 35 km, so this is what it needs anywhere in the area.
    static let areaFullDetail = 10_000.0
    static let areaMediumDetail = 35_000.0

    @ObservationIgnored private var areaTask: Task<Void, Never>?
    @ObservationIgnored private var areaQueue: [UUID] = []

    /// Saves an area: adds it to the list and downloads it (after any download under way).
    func saveArea(name: String, latitude: Double, longitude: Double, radius: Double) {
        let area = OfflineArea(name: name, latitude: latitude, longitude: longitude, radius: radius)
        areas.insert(area, at: 0)
        persistAreas()
        download(area)
    }

    /// Downloads what an area needs that isn't on the phone yet (also to resume one).
    func download(_ area: OfflineArea) {
        areaFailures[area.id] = nil
        guard areaProgress == nil else {
            if !areaQueue.contains(area.id) { areaQueue.append(area.id) }
            return
        }
        areaProgress = AreaProgress(id: area.id)
        areaTask = Task { @MainActor in
            // Keep going for a while if Peak is sent to the background.
            let background = BackgroundTime(name: "Save area")
            defer { background.end() }
            await fetch(area)
            guard !Task.isCancelled else { return }   // deleted; deleting moves the queue on
            areaProgress = nil
            areaTask = nil
            startNextArea()
        }
    }

    private func startNextArea() {
        while areaProgress == nil, !areaQueue.isEmpty {
            let next = areaQueue.removeFirst()
            if let area = areas.first(where: { $0.id == next }) { download(area) }
        }
    }

    @MainActor private func fetch(_ area: OfflineArea) async {
        let store = self.store
        let far = area.tiles
        let medium = DataStore.tiles(latitude: area.latitude, longitude: area.longitude, radius: area.radius + Self.areaMediumDetail)
        let near = DataStore.tiles(latitude: area.latitude, longitude: area.longitude, radius: area.radius + Self.areaFullDetail)
        let steps = Double(far.count + medium.count + near.count + 2)
        var done = 0.0
        var failure: String?
        func report(_ step: String) {
            areaProgress = AreaProgress(id: area.id, fraction: done / steps, step: step)
        }
        func failed(_ error: Error) {
            if !(error is CancellationError) { failure = error.localizedDescription }
        }

        // Peaks and hikes first: small, and from a different server than the terrain.
        report("Peaks")
        do { try await store.downloadAreaPeaks(area) } catch { failed(error) }
        done += 1
        report("Hikes")
        do { try await store.downloadAreaTrails(area) } catch { failed(error) }
        done += 1
        for (i, key) in far.enumerated() where !Task.isCancelled {
            report("Terrain \(i + 1) of \(far.count) · 120 m")
            do { _ = try await store.tile(key, level: 2) } catch { failed(error) }
            done += 1
        }
        for (i, key) in medium.enumerated() where !Task.isCancelled {
            report("Terrain \(i + 1) of \(medium.count) · 60 m")
            do {
                _ = try await store.patch(key, level: 1, latitude: area.latitude, longitude: area.longitude,
                                          radius: area.radius + Self.areaMediumDetail, strict: true)
            } catch { failed(error) }
            done += 1
        }
        for (i, key) in near.enumerated() where !Task.isCancelled {
            report("Terrain \(i + 1) of \(near.count) · 30 m")
            do {
                _ = try await store.patch(key, level: 0, latitude: area.latitude, longitude: area.longitude,
                                          radius: area.radius + Self.areaFullDetail, strict: true)
            } catch { failed(error) }
            done += 1
        }
        bytesDownloaded = await store.bytesDownloaded
        guard !Task.isCancelled, let index = areas.firstIndex(where: { $0.id == area.id }) else { return }
        areas[index].complete = failure == nil
        areas[index].bytes = await store.size(of: area)
        areas[index].saved = Date()
        if let failure { areaFailures[area.id] = failure }
        persistAreas()
        storageBytes = await store.storageUsed()
    }

    /// Deletes an area, with the terrain that no other area (and not where you are) uses.
    func deleteArea(_ area: OfflineArea) {
        if areaProgress?.id == area.id {
            areaTask?.cancel()
            areaTask = nil
            areaProgress = nil
        }
        areaQueue.removeAll { $0 == area.id }
        areas.removeAll { $0.id == area.id }
        areaFailures[area.id] = nil
        persistAreas()
        let others = areas
        let here = (location ?? center).map { LatLon($0.coordinate.latitude, $0.coordinate.longitude) }
        Task { @MainActor in
            await store.deleteArea(area, keeping: others, near: here)
            storageBytes = await store.storageUsed()
        }
        startNextArea()
    }

    func isQueued(_ area: OfflineArea) -> Bool {
        areaQueue.contains(area.id)
    }

    private func persistAreas() {
        store.saveAreas(areas)
    }

    func refreshStorage() {
        Task { @MainActor in storageBytes = await store.storageUsed() }
    }

    func clearDownloads() {
        areaTask?.cancel()
        areaTask = nil
        areaProgress = nil
        areaQueue.removeAll()
        areas.removeAll()
        areaFailures.removeAll()
        Task { @MainActor in
            await store.clear()
            details.removeAll()
            storageBytes = await store.storageUsed()
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
            // Below the interface's priority, so building never makes the screen stutter.
            let built = await Task.detached(priority: .utility) {
                TerrainScene.build(terrain: terrain, latitude: lat, longitude: lon, peaks: peaks)
            }.value
            lastBuildSeconds = Date().timeIntervalSince(started)
            scene = built
            updateCorrector()
            if arTrail != nil { drapeTrail() }
        } while rebuildAgain
        rebuilding = false
    }

    /// 0 for a full 30 m tile, 1 for 60 m, 2 for 120 m, 3 for 240 m.
    /// Whether patch `a` covers all of patch `b` (both of one tile, at one level).
    private static func covers(_ a: ElevationTile, _ b: ElevationTile) -> Bool {
        let ey = a.stepLatitude / 2, ex = a.stepLongitude / 2
        return a.originLatitude + ey >= b.originLatitude &&
            a.originLongitude - ex <= b.originLongitude &&
            a.originLatitude - Double(a.rows - 1) * a.stepLatitude - ey <= b.originLatitude - Double(b.rows - 1) * b.stepLatitude &&
            a.originLongitude + Double(a.cols - 1) * a.stepLongitude + ex >= b.originLongitude + Double(b.cols - 1) * b.stepLongitude
    }

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
        let c = viewCorrection(for: motion.pose)
        if let pose = motion.pose {
            let a = CameraGeometry.attitude(CameraGeometry.axes(pose, orientation: .portrait), correction: c)
            lines.append(String(format: "heading %.1f°  pitch %.1f°  roll %.1f°", a.heading, a.pitch, a.roll))
        } else {
            lines.append("no motion data yet")
        }
        lines.append(String(format: "sensors %.0f/s, %@ north, last %.1f s ago", s.updatesPerSecond,
                            s.trueNorth ? "true" : "magnetic", s.secondsSinceUpdate))
        lines.append(String(format: "correction: heading %+.2f° (skyline %+.2f°, north %+.2f°), pitch %+.2f°, roll %+.2f° (%@)",
                            c.heading, correction.heading, motion.northCorrection, c.pitch, c.roll,
                            CameraGeometry.isSideways(motion.pose) ? "sideways" : "upright"))
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
        switch peaksState {
        case .loading:
            lines.append("peaks: downloading…")
        case let .retrying(at, reason):
            lines.append(String(format: "peaks: trying again in %.0f s (%@)", max(0, at.timeIntervalSinceNow), reason))
        case .loaded:
            break
        }
        if let lens = camera.lens {
            let k = lens.intrinsics
            lines.append(String(format: "lens: %.1f° (%@), center %+.1f %+.1f px of %ldx%ld", lens.fieldOfView,
                                lens.measured ? "measured" : "estimated", k.cx - Double(k.width) / 2, k.cy - Double(k.height) / 2,
                                k.width, k.height))
        }
        if zoom > 1.01 { lines.append(String(format: "zoom %.1f×", zoom)) }
        if let overlay = screen?.overlay {
            lines.append(overlay.drawsWithMetal ? "lines: Metal, \(overlay.segmentCount) segments" : "lines: shape layers")
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
                hikes = await Task.detached(priority: .utility) {
                    trails.map { t in
                        let d = t.distance(to: peak.position)
                        return Hike(trail: t, profile: ground.flatMap { t.profile(on: $0) }, reachesSummit: d < 250, distanceFromPeak: d)
                    }
                    .sorted { ($0.reachesSummit ? 0 : 1, $0.distanceFromPeak) < ($1.reachesSummit ? 0 : 1, $1.distanceFromPeak) }
                }.value
                hikesState = .loaded
            } catch let error as URLError {
                switch error.code {
                case .notConnectedToInternet, .dataNotAllowed, .networkConnectionLost, .internationalRoamingOff:
                    hikesState = .failed("No connection. To have hikes without a signal, save the area beforehand in Settings › Offline areas.")
                case .timedOut:
                    hikesState = .failed("OpenStreetMap's servers are overloaded and didn't answer. Try again in a few minutes.")
                default:
                    hikesState = .failed("Couldn't reach OpenStreetMap (\(error.localizedDescription)).")
                }
            } catch {
                hikesState = .failed(error.localizedDescription)
            }
        }
    }
}

/// Time to finish work after Peak goes to the background (about half a minute), given back
/// when done or when the time is up.
@MainActor private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Hands camera frames to the main thread, keeping only the newest when it falls behind,
/// so frames don't pile up (each holds one of the camera's few buffers).
private final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CameraFeed.Frame?
    private var scheduled = false

    func post(_ frame: CameraFeed.Frame, deliver: @escaping (CameraFeed.Frame) -> Void) {
        lock.lock()
        self.frame = frame
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async {
            self.lock.lock()
            let next = self.frame
            self.frame = nil
            self.scheduled = false
            self.lock.unlock()
            if let next { deliver(next) }
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

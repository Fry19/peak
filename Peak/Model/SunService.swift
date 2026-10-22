import CoreLocation
import Foundation
import Observation
import PeakCore
import UserNotifications

/// When the sun reaches and leaves things, over the real terrain: you, a summit, the top
/// and the start of a hike. Horizons from elsewhere than you cost about 0.4 s each, so
/// they're worked out one at a time off the main thread at utility priority, each once per
/// place and day; asking again while one is on its way just waits for it.
@Observable
final class SunService {
    /// The sun from where you are, today there.
    struct Here {
        var observer: GeoPoint
        var day: SunDay
        /// The peak the sun sets behind, if it sets behind one you can see.
        var setsBehind: String?
    }

    /// Daylight for a hike, walked up to its highest point and back the same way.
    struct Hike {
        /// DIN 33466 walking times, seconds.
        var up: TimeInterval
        var down: TimeInterval
        var top: SunDay
        var start: SunDay
    }

    private(set) var here: Here?
    /// Nil light: the terrain doesn't reach the summit.
    private(set) var summits: [Int64: (day: Date, light: SummitLight?)] = [:]
    private(set) var hikes: [String: (day: Date, hike: Hike)] = [:]
    /// Today's sun path from where you are, for the camera view: apparent elevation every
    /// two minutes, and whether it's above the terrain there.
    @ObservationIgnored private(set) var path: (key: String, points: [PathPoint])?

    struct PathPoint {
        var date: Date
        var azimuth: Double
        var elevation: Double
        var inSight: Bool
        /// The hour, on the hour.
        var hour: Int?
    }

    @ObservationIgnored private var queue: [(key: String, work: () -> Void)] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var working = false
    @ObservationIgnored private var zones: [String: TimeZone] = SunService.loadZones()
    @ObservationIgnored private var geocoding: Set<String> = []
    /// The peak and day reminders were last scheduled for.
    @ObservationIgnored private var scheduled: (id: Int64, day: Date)?
    private(set) var zoneVersion = 0

    // MARK: Time zones

    /// The time zone at a place: from the map once it's been looked up there (and kept for
    /// offline use), the phone's until then.
    func timeZone(latitude: Double, longitude: Double) -> TimeZone {
        let key = Self.zoneKey(latitude, longitude)
        if let zone = zones[key] { return zone }
        lookUpZone(key, latitude, longitude)
        return .current
    }

    private func lookUpZone(_ key: String, _ latitude: Double, _ longitude: Double) {
        guard !geocoding.contains(key) else { return }
        geocoding.insert(key)
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.geocoding.remove(key)
                guard let zone = placemarks?.first?.timeZone else { return }
                self.zones[key] = zone
                Self.saveZones(self.zones)
                // Days start at a different midnight there: work them out again.
                if zone != .current {
                    self.summits.removeAll()
                    self.hikes.removeAll()
                    self.here = nil
                    self.path = nil
                    self.zoneVersion += 1
                }
            }
        }
    }

    /// Time zones change only at borders, so a tenth of a degree is fine enough.
    private static func zoneKey(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.1f,%.1f", latitude, longitude)
    }

    private static let zonesKey = "timeZones"

    private static func loadZones() -> [String: TimeZone] {
        let names = UserDefaults.standard.dictionary(forKey: zonesKey) as? [String: String] ?? [:]
        return names.compactMapValues(TimeZone.init(identifier:))
    }

    private static func saveZones(_ zones: [String: TimeZone]) {
        UserDefaults.standard.set(zones.mapValues(\.identifier), forKey: zonesKey)
    }

    /// Today, midnight to midnight at the place.
    func today(latitude: Double, longitude: Double) -> (zone: TimeZone, day: DateInterval) {
        let zone = timeZone(latitude: latitude, longitude: longitude)
        return (zone, .day(containing: Date(), in: zone))
    }

    // MARK: Work

    /// Runs `work` off the main thread at utility priority, after what's already queued,
    /// unless work with the same key is queued or running.
    private func enqueue(_ key: String, _ work: @escaping () -> Void) {
        guard !queued.contains(key) else { return }
        queued.insert(key)
        queue.append((key, work))
        runNext()
    }

    private func runNext() {
        guard !working, !queue.isEmpty else { return }
        working = true
        let (key, work) = queue.removeFirst()
        Task { @MainActor in
            await Task.detached(priority: .utility) { work() }.value
            self.queued.remove(key)
            self.working = false
            self.runNext()
        }
    }

    // MARK: Here

    /// The sun from the scene's viewpoint today; nil until worked out.
    func here(scene: TerrainScene) -> Here? {
        let observer = scene.observer
        let (_, day) = today(latitude: observer.latitude, longitude: observer.longitude)
        if let here, here.observer == observer, here.day.interval == day { return here }
        let key = "here \(observer.latitude),\(observer.longitude) \(day.start.timeIntervalSince1970)"
        enqueue(key) { [weak self] in
            // When the sun really goes for you: behind the ground near you as it stands, as the
            // hikes' daylight has it at a trailhead, even where the view sees over it.
            let sun = SunDay(horizon: scene.matchingHorizon, interval: day)
            let behind = sun.lastLight.flatMap { Self.peak(behind: $0, in: scene) }
            DispatchQueue.main.async { self?.here = Here(observer: observer, day: sun, setsBehind: behind) }
        }
        return nil
    }

    /// The visible peak standing where the sun crosses the skyline, if there is one.
    private static func peak(behind c: SunDay.Crossing, in scene: TerrainScene) -> String? {
        scene.peaks
            .filter { abs(azimuthDifference($0.azimuth, c.azimuth)) < 1.5 && abs($0.distance - c.distance) < max(1_500, c.distance * 0.25) }
            .min { abs(azimuthDifference($0.azimuth, c.azimuth)) < abs(azimuthDifference($1.azimuth, c.azimuth)) }?
            .peak.name
    }

    /// Today's sun path seen from the scene's viewpoint, worked out once per place and day.
    func path(scene: TerrainScene) -> [PathPoint]? {
        let observer = scene.observer
        let (zone, day) = today(latitude: observer.latitude, longitude: observer.longitude)
        let key = "path \(observer.latitude),\(observer.longitude) \(day.start.timeIntervalSince1970)"
        if let path, path.key == key { return path.points }
        enqueue(key) { [weak self] in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let points = SunDay.path(latitude: observer.latitude, longitude: observer.longitude, height: observer.height,
                                     interval: day, step: 120, k: scene.horizon.settings.refraction)
                .filter { $0.elevation > -3 }
                .map { PathPoint(date: $0.date, azimuth: $0.azimuth, elevation: $0.elevation,
                                 inSight: $0.elevation > scene.horizon.elevation(atAzimuth: $0.azimuth),
                                 hour: calendar.component(.minute, from: $0.date) == 0 ? calendar.component(.hour, from: $0.date) : nil) }
            DispatchQueue.main.async { self?.path = (key, points) }
        }
        return nil
    }

    // MARK: Summits

    /// When the sun reaches and leaves a summit today. `done` is false while it's being
    /// worked out or waiting for terrain; done without a light, the terrain doesn't cover it.
    func summitLight(_ peak: Peak, terrain: Terrain?, ceiling: Double) -> (done: Bool, light: SummitLight?) {
        let (_, day) = today(latitude: peak.latitude, longitude: peak.longitude)
        if let s = summits[peak.id], s.day == day.start { return (true, s.light) }
        guard let terrain else { return (false, nil) }
        enqueue("summit \(peak.id) \(day.start.timeIntervalSince1970)") { [weak self] in
            let light = Self.summitLight(peak, terrain: terrain, ceiling: ceiling, days: [day]).first
            DispatchQueue.main.async { self?.summits[peak.id] = (day.start, light) }
        }
        return (false, nil)
    }

    /// One horizon from the summit, then the sun over it on each day.
    static func summitLight(_ peak: Peak, terrain: Terrain, ceiling: Double, days: [DateInterval]) -> [SummitLight] {
        let renderer = HorizonRenderer(terrain: terrain)
        guard terrain.height(latitude: peak.latitude, longitude: peak.longitude).isFinite else { return [] }
        let horizon = renderer.summitHorizon(latitude: peak.latitude, longitude: peak.longitude, height: peak.elevation)
        return days.map { renderer.summitLight(horizon: horizon, day: $0, ceiling: max(ceiling, peak.elevation)) }
    }

    // MARK: Hikes

    /// Walking times and the sun at the top and the start of a hike today; nil until
    /// worked out, or without a profile.
    func hike(_ trail: Trail, profile: TrailProfile?, terrain: Terrain?) -> Hike? {
        guard let profile, profile.points.count > 2, let start = profile.points.first?.position else { return nil }
        let (_, day) = today(latitude: start.latitude, longitude: start.longitude)
        if let h = hikes[trail.id], h.day == day.start { return h.hike }
        guard let terrain else { return nil }
        enqueue("hike \(trail.id) \(day.start.timeIntervalSince1970)") { [weak self] in
            let renderer = HorizonRenderer(terrain: terrain)
            let top = profile.highestIndex
            func sun(at p: LatLon) -> SunDay {
                let observer = renderer.observer(latitude: p.latitude, longitude: p.longitude)
                return SunDay(horizon: renderer.render(from: observer), interval: day)
            }
            let hike = Hike(up: profile.walkingTime(from: 0, to: top), down: profile.walkingTime(from: top, to: 0),
                            top: sun(at: profile.points[top].position), start: sun(at: start))
            DispatchQueue.main.async { self?.hikes[trail.id] = (day.start, hike) }
        }
        return nil
    }

    // MARK: Alpenglow reminders

    static let reminderLead: TimeInterval = 20 * 60
    private static let reminderPrefix = "alpenglow-"

    /// Asks to send notifications (only the first time), then reminds 20 minutes before
    /// last light on the peak for the next week. False if notifications aren't allowed.
    func remind(_ peak: Peak, terrain: Terrain?, ceiling: Double) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        if let terrain { schedule(peak, terrain: terrain, ceiling: ceiling, again: true) }
        return true
    }

    func cancelReminders() {
        scheduled = nil
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) })
        }
    }

    /// Schedules the week's reminders for the peak, replacing any before. Needs the terrain
    /// around the peak; without it the ones scheduled last time stay.
    func schedule(_ peak: Peak, terrain: Terrain, ceiling: Double, again: Bool = false) {
        let zone = timeZone(latitude: peak.latitude, longitude: peak.longitude)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: Date()) }.map { DateInterval.day(containing: $0, in: zone) }
        // Once a day is enough, unless just turned on.
        guard again || scheduled?.id != peak.id || scheduled?.day != days[0].start else { return }
        scheduled = (peak.id, days[0].start)
        enqueue("remind \(peak.id) \(days[0].start.timeIntervalSince1970)") { [weak self] in
            let lights = Self.summitLight(peak, terrain: terrain, ceiling: ceiling, days: days)
            guard !lights.isEmpty else { return }
            let center = UNUserNotificationCenter.current()
            center.getPendingNotificationRequests { requests in
                center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) })
                let time = DateFormatter()
                time.timeZone = zone
                time.timeStyle = .short
                for (i, light) in lights.enumerated() {
                    guard let last = light.lastLight, last.timeIntervalSinceNow > Self.reminderLead + 60 else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "Alpenglow on \(peak.name) in 20 minutes"
                    content.body = "The sun leaves the summit at \(time.string(from: last))."
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: last.timeIntervalSinceNow - Self.reminderLead, repeats: false)
                    center.add(UNNotificationRequest(identifier: "\(Self.reminderPrefix)\(i)", content: content, trigger: trigger))
                }
            }
            if let today = lights.first {
                DispatchQueue.main.async { self?.summits[peak.id] = (days[0].start, today) }
            }
        }
    }
}

extension SunService {
    /// "19:41", in the place's time zone, with its abbreviation when it isn't the phone's.
    static func time(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.timeStyle = .short
        f.dateStyle = .none
        var text = f.string(from: date)
        if zone.secondsFromGMT(for: date) != TimeZone.current.secondsFromGMT(for: date),
           let abbreviation = zone.abbreviation(for: date) {
            text += " " + abbreviation
        }
        return text
    }

    /// "3 h 40 min", "45 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60 / 5).rounded()) * 5
        if minutes < 60 { return "\(max(5, minutes)) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

extension AppModel {
    /// The highest the terrain beyond what's loaded could plausibly stand: a little above
    /// the highest peak around.
    var terrainCeiling: Double {
        (scene?.allPeaks.values.map(\.peak.elevation).max() ?? 4_000) + 300
    }

    /// Reminders run out after a week; each new scene tops them up when its terrain
    /// covers the chosen peak.
    func refreshAlpenglow() {
        guard let peak = settings.alpenglow, let terrain = scene?.terrain,
              terrain.height(latitude: peak.latitude, longitude: peak.longitude).isFinite else { return }
        sun.schedule(peak, terrain: terrain, ceiling: terrainCeiling)
    }

    /// Turns the alpenglow reminder on for `peak` (asking for notifications the first
    /// time), or off. False if notifications aren't allowed.
    @MainActor func setAlpenglowReminder(_ peak: Peak?) async -> Bool {
        guard let peak else {
            sun.cancelReminders()
            settings.alpenglow = nil
            return true
        }
        guard await sun.remind(peak, terrain: scene?.terrain, ceiling: terrainCeiling) else {
            settings.alpenglow = nil
            return false
        }
        settings.alpenglow = peak
        return true
    }
}

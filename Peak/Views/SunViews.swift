import PeakCore
import SwiftUI

/// A peak card's sun: when the light reaches and leaves the summit today, when the sun
/// leaves you, and a reminder before alpenglow.
struct PeakSunRow: View {
    let model: AppModel
    let peak: Peak
    @State private var notificationsOff = false
    @State private var asking = false

    var body: some View {
        let sun = model.sun
        _ = sun.zoneVersion
        let zone = sun.timeZone(latitude: peak.latitude, longitude: peak.longitude)
        let (done, light) = sun.summitLight(peak, terrain: model.scene?.terrain, ceiling: model.terrainCeiling)
        let here = model.scene.flatMap { sun.here(scene: $0) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sun.horizon")
                    .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.4))
                    .accessibilityHidden(true)
                if let light {
                    Text(summary(light, zone))
                } else if done {
                    Text("Sun: the terrain loaded doesn't reach this summit").foregroundStyle(.secondary)
                } else if model.scene == nil {
                    Text("Sun: waiting for the terrain").foregroundStyle(.secondary)
                } else {
                    Text("Sun: working it out…").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            if let light, light.rangeLimited, let reach = light.reachAtLastLight ?? light.reachAtFirstLight {
                Text("Terrain loaded only to \(Format.distance(reach, model.settings.units)) toward the sun; farther mountains could shorten this.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let here, let text = fromHere(here) {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { model.settings.alpenglow?.id == peak.id }, set: setReminder)) {
                Text("Remind me 20 min before alpenglow")
                    .font(.footnote)
            }
            .disabled(asking)
            .padding(.top, 2)
            if notificationsOff {
                Text("Notifications are off for Peak. Turn them on in Settings to get the reminder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func summary(_ light: SummitLight, _ zone: TimeZone) -> String {
        if light.day.alwaysInSight { return "Sun on the summit all day" }
        if light.day.neverInSight { return "No direct sun on the summit today" }
        var parts: [String] = []
        if let first = light.firstLight { parts.append("first light \(SunService.time(first, in: zone))") }
        if let last = light.lastLight { parts.append("last light \(SunService.time(last, in: zone))") }
        return "Sun: " + parts.joined(separator: " · ")
    }

    private func fromHere(_ here: SunService.Here) -> String? {
        let zone = model.sun.timeZone(latitude: here.observer.latitude, longitude: here.observer.longitude)
        if here.day.neverInSight { return "From here: no direct sun today" }
        guard let set = here.day.lastLight else { return nil }
        let past = set.date < Date()
        let behind = here.setsBehind.map { "behind \($0)" } ?? (set.elevation > 0.5 ? "behind the ridge" : "")
        let verb = past ? "set" : "sets"
        return "From here: the sun \(verb) \(behind.isEmpty ? "" : behind + " ")at \(SunService.time(set.date, in: zone))"
    }

    private func setReminder(_ on: Bool) {
        asking = true
        Task { @MainActor in
            let ok = await model.setAlpenglowReminder(on ? peak : nil)
            notificationsOff = on && !ok
            asking = false
        }
    }
}

/// A hike's daylight: how long it takes and when the sun leaves its top and its start,
/// with a gentle note when it won't fit in what's left of the day.
struct HikeDaylightSection: View {
    let model: AppModel
    let hike: PeakDetails.Hike

    var body: some View {
        if let profile = hike.profile, profile.points.count > 2, let start = profile.trailhead {
            let sun = model.sun
            let _ = sun.zoneVersion
            let zone = sun.timeZone(latitude: start.latitude, longitude: start.longitude)
            let daylight = sun.hike(hike.trail, profile: profile, terrain: model.scene?.terrain)
            Section {
                if let daylight {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(times(daylight, zone))
                            .font(.subheadline)
                        if let note = turnaround(daylight, zone) {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.45))
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.scene == nil ? "Waiting for the terrain" : "Working out the sun on the slope…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Daylight")
            } footer: {
                Text("Walking times by DIN 33466 (4 km/h on the level, 300 m/h up, 500 m/h down), up to the highest point and back the same way, without breaks. Sun times over the terrain model.")
            }
        }
    }

    private func times(_ d: SunService.Hike, _ zone: TimeZone) -> String {
        var text = "About \(SunService.duration(d.up)) up, \(SunService.duration(d.down)) back"
        if let top = d.top.lastLight {
            text += "; sun leaves the top at \(SunService.time(top.date, in: zone))"
        } else if d.top.neverInSight {
            text += "; no direct sun at the top today"
        }
        if let start = d.start.lastLight {
            text += " and the start at \(SunService.time(start.date, in: zone))"
        }
        return text + "."
    }

    /// Only while there's still sun today: if starting now you'd be back after it has left
    /// the start, when to turn around.
    private func turnaround(_ d: SunService.Hike, _ zone: TimeZone) -> String? {
        let now = Date()
        guard let leaves = d.start.lastLight?.date, leaves > now else { return nil }
        guard now.addingTimeInterval(d.up + d.down) > leaves else { return nil }
        let turn = leaves.addingTimeInterval(-d.down)
        if turn.timeIntervalSince(now) < 30 * 60 {
            return "Not enough daylight left today for this hike."
        }
        return "Starting now, you'd be back after the sun has left the start. Turn around by \(SunService.time(turn, in: zone)) to be down in the light."
    }
}

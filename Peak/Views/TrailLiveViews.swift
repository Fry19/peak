import PeakCore
import SwiftUI

/// Words for where you are on a trail you're walking.
enum TrailLive {
    /// "summit" when the trail reaches the peak, else "top".
    static func top(_ trail: Trail, peak: Peak?) -> String {
        guard let peak else { return "top" }
        return trail.distance(to: peak.position) < 250 ? "summit" : "top"
    }

    /// "2.1 km · 480 m up to the summit · about 1 h 50 min" while the top is ahead, else
    /// the same to the end you're walking toward.
    static func summary(_ p: TrailProgress, top: String, units: AppSettings.Units) -> String {
        if p.topAhead, p.toTop > 30 {
            var parts = [Format.distance(p.toTop, units)]
            if p.climbToTop >= 10 { parts.append("\(Format.elevation(p.climbToTop, units)) up to the \(top)") } else { parts.append("to the \(top)") }
            parts.append("about \(SunService.duration(p.timeToTop))")
            return parts.joined(separator: " · ")
        }
        guard p.remaining > 30 else { return "At the end of the trail" }
        var parts = [Format.distance(p.remaining, units)]
        if p.descentToEnd >= 10, p.descentToEnd >= p.climbToEnd {
            parts.append("\(Format.elevation(p.descentToEnd, units)) down to the end")
        } else if p.climbToEnd >= 10 {
            parts.append("\(Format.elevation(p.climbToEnd, units)) up to the end")
        } else {
            parts.append("to the end")
        }
        parts.append("about \(SunService.duration(p.timeToEnd))")
        return parts.joined(separator: " · ")
    }

    /// "About 120 m off the trail".
    static func strayed(_ meters: Double, units: AppSettings.Units) -> String {
        "About \(Format.distance(meters, units)) off the trail"
    }
}

/// On a hike's card, while you're walking it: what's left, and whether it fits in the
/// light that's left.
struct TrailLiveSection: View {
    let model: AppModel
    let hike: PeakDetails.Hike

    var body: some View {
        let tracker = model.tracker
        if tracker.trailID == hike.trail.id, tracker.progress != nil || tracker.strayed != nil {
            let units = model.settings.units
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if let p = tracker.progress {
                        Label {
                            Text(TrailLive.summary(p, top: hike.reachesSummit ? "summit" : "top", units: units))
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "location.fill")
                                .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1))
                        }
                        .font(.subheadline)
                        if let (text, late) = sun(p) {
                            Text(text)
                                .font(.footnote)
                                .foregroundStyle(late ? AnyShapeStyle(Color(red: 1, green: 0.78, blue: 0.45)) : AnyShapeStyle(.secondary))
                        }
                    }
                    if let off = tracker.strayed {
                        Text(TrailLive.strayed(off, units: units))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("On the trail")
            }
            .sheetSection()
        }
    }

    /// When the sun leaves the summit and when you'd get there, or to the start on the
    /// way down; true when you'd arrive after the light has gone.
    private func sun(_ p: TrailProgress) -> (String, Bool)? {
        let sun = model.sun
        _ = sun.zoneVersion
        guard let profile = hike.profile, let start = profile.trailhead,
              let daylight = sun.hike(hike.trail, profile: profile, terrain: model.scene?.terrain) else { return nil }
        let zone = sun.timeZone(latitude: start.latitude, longitude: start.longitude)
        let now = Date()
        let word = hike.reachesSummit ? "summit" : "top"
        if p.topAhead, let leaves = daylight.top.lastLight?.date, leaves > now {
            let arrive = now.addingTimeInterval(p.timeToTop)
            let text = "Sun leaves the \(word) at \(SunService.time(leaves, in: zone)); you'd arrive about \(SunService.time(arrive, in: zone))."
            if arrive > leaves { return (text + " That's after the light has gone up there; think about turning back in time.", true) }
            // Up and back down the same way before the sun leaves the start?
            if let down = daylight.start.lastLight?.date, arrive.addingTimeInterval(daylight.down) > down {
                return (text + " You'd be back down after the sun has left the start.", true)
            }
            return (text, false)
        }
        // On the way down to the start.
        if !p.topAhead, p.direction == .backward, let leaves = daylight.start.lastLight?.date, leaves > now {
            let arrive = now.addingTimeInterval(p.timeToEnd)
            let text = "Sun leaves the start at \(SunService.time(leaves, in: zone)); you'd be down about \(SunService.time(arrive, in: zone))."
            return arrive > leaves ? (text + " That's after the sun has gone; a headlamp helps.", true) : (text, false)
        }
        return nil
    }
}

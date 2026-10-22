import PeakCore
import SwiftUI

/// A spot tapped while lining up by hand, and the peaks it could be, to name it.
struct SummitPick: Identifiable {
    let id = UUID()
    /// Where it was tapped: screen points on the camera, the picture's pixels on a photo.
    var point: CGPoint
    /// Likeliest first (`SummitPins.candidates`).
    var nearby: [VisiblePeak]
    /// Every peak in sight around the view, by name, for one that isn't among them.
    var all: [VisiblePeak]

    init(point: CGPoint, camera: Camera, peaks: [VisiblePeak]) {
        self.point = point
        nearby = SummitPins.candidates(peaks, camera: camera, x: point.x, y: point.y)
        // As far to either side as the compass could be off, beyond the picture's edges.
        let reach = camera.intrinsics.horizontalFOV / 2 + 30
        all = peaks.filter { abs(azimuthDifference($0.azimuth, camera.attitude.heading)) <= reach }
            .sorted { $0.peak.name.localizedStandardCompare($1.peak.name) == .orderedAscending }
    }
}

/// "Which peak is this?": the peaks near a tapped spot, and the rest to search by name.
struct SummitPicker: View {
    let pick: SummitPick
    let units: AppSettings.Units
    let choose: (VisiblePeak) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var found: [VisiblePeak] {
        pick.all.filter { $0.peak.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("Near where you tapped") {
                        if pick.nearby.isEmpty {
                            Text("No peaks in sight near there. Search for it by name.")
                                .foregroundStyle(.secondary)
                                .sheetSection()
                        }
                        rows(pick.nearby)
                    }
                    if !pick.all.isEmpty {
                        Section("All peaks in sight") { rows(pick.all) }
                    }
                } else if found.isEmpty {
                    Text("No peak in sight is called “\(query)”.")
                        .foregroundStyle(.secondary)
                        .sheetSection()
                } else {
                    rows(found)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.sheetBackground)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Peak name")
            .navigationTitle("Which peak is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func rows(_ peaks: [VisiblePeak]) -> some View {
        ForEach(peaks) { v in
            Button {
                choose(v)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.peak.name)
                        .foregroundStyle(.white)
                    Text("\(Format.elevation(of: v.peak, units)) · \(Format.distance(v.distance, units)) · \(Format.bearing(v.azimuth))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .sheetSection()
        }
    }
}

/// While lining up by hand: what to do, and the pinned summits, each one tap from removal.
struct SummitPinsBanner: View {
    let pins: [SummitPins.Pin]
    /// The pins don't fit one view.
    let misfit: Bool
    /// The pins set the tilt, not just the heading.
    let tilt: Bool
    let remove: (Int64) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(instruction)
                .font(.subheadline.weight(.medium))
            if misfit {
                Label("These peaks don't fit one view. One may be the wrong peak: remove it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.amber)
            } else {
                Text(pins.isEmpty ? "Or drag the lines, and turn with two fingers to level them."
                                  : "The pins hold the lines. Remove them to drag the lines freely.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if !pins.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pins) { pin in
                            Button {
                                remove(pin.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "mappin")
                                        .foregroundStyle(Color.amber)
                                    Text(pin.name)
                                        .lineLimit(1)
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.15), in: Capsule())
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel("\(pin.name), pinned")
                            .accessibilityHint("Removes this pin")
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        // Over the picture, it mustn't grow to hide it.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var instruction: String {
        switch pins.count {
        case 0: return "Drag a peak's label onto the real peak, or tap a peak to name it."
        case 1: return "Heading set from \(pins[0].name). Pin a second peak to level the view too."
        default: return tilt ? "Heading and tilt set from \(pins.count) peaks." : "Heading set from \(pins.count) peaks."
        }
    }
}

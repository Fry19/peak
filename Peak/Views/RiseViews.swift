import PeakCore
import SwiftUI

/// Tap to see over the ridges (`AppModel+Rise`): the view goes up to the height chosen last
/// and stays there, the button amber, until it's tapped again. While up, the heights sit
/// beside it, the chosen one amber with its unit, as the Camera app shows its zooms. With
/// VoiceOver, swiping up or down on the button changes the height too.
struct RiseButton: View {
    let model: AppModel

    var body: some View {
        let up = model.rise.isUp
        HStack(spacing: 10) {
            if up {
                RiseHeights(model: model)
                    .transition(.opacity)
            }
            Button { model.toggleRising() } label: {
                Image(systemName: up ? "arrow.down.to.line" : "arrow.up.to.line")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(up ? .black : .white)
                    .frame(width: 44, height: 44)
                    .background {
                        if up { Circle().fill(Color.amber) }
                    }
                    .glassBackground(in: Circle())
                    .environment(\.colorScheme, .dark)
                    .contentShape(Circle())
            }
            .accessibilityLabel(up ? "Back down to the camera" : "See over the ridges")
            .accessibilityValue(value)
            .accessibilityHint("Swipe up or down to change the height.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.adjustRise(by: 1)
                case .decrement: model.adjustRise(by: -1)
                @unknown default: break
                }
            }
        }
        // Taken away while up (the peaks reloading, say): there'd be no way back down.
        .onDisappear { model.land() }
    }

    private var value: String {
        let rise = model.rise
        guard rise.level > 0 else { return rise.pending ? "Rising" : "On the ground" }
        return RiseChip.summary(rise, units: model.settings.units)
    }
}

/// The heights to see from, in a row: the chosen one amber with its unit, the others just
/// their numbers.
private struct RiseHeights: View {
    let model: AppModel

    var body: some View {
        let units = model.settings.units
        HStack(spacing: 0) {
            ForEach(Array(AppModel.riseHeights(units).enumerated()), id: \.offset) { i, height in
                let level = i + 1, chosen = model.rise.target == level
                let text = chosen ? Format.elevation(height, units) : Format.elevationNumber(height, units)
                Button { model.chooseRiseLevel(level) } label: {
                    Text(text)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(chosen ? Color.amber : .white)
                        .padding(.horizontal, 9)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Format.elevation(height, units) + " up")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .glassBackground(in: Capsule())
        .environment(\.colorScheme, .dark)
        .animation(nil, value: model.rise.target)
    }
}

/// Over the top of the view while risen: how high, and how many more peaks are in sight
/// from up there. Before the first view from above is in, that it's on its way.
struct RiseChip: View {
    let model: AppModel

    /// Whether it has anything to say.
    static func isShown(_ model: AppModel) -> Bool {
        model.rise.level > 0 || model.rise.pending
    }

    /// "300 m up · 12 more peaks around you": a count in every direction, not just on screen.
    static func summary(_ rise: AppModel.Rise, units: AppSettings.Units) -> String {
        let up = Format.elevation(rise.height, units) + " up"
        switch rise.revealed {
        case 0: return up
        case 1: return up + " · 1 more peak around you"
        default: return up + " · \(rise.revealed.formatted()) more peaks around you"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .font(.system(size: 13, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .glassBackground(in: Capsule())
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        let rise = model.rise
        if rise.level > 0 {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.amber)
            Text(Self.summary(rise, units: model.settings.units))
                .contentTransition(.numericText())
        } else if rise.pending {
            ProgressView().controlSize(.small).tint(.white)
            Text("Rising…")
        }
    }
}

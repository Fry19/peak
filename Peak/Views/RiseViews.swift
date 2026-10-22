import PeakCore
import SwiftUI

/// Hold to see over the ridges (`AppModel+Rise`): the view climbs while it's held, amber,
/// and comes back down when it's let go. A tap only says to hold. With VoiceOver, it goes up
/// one step and stays; swiping up or down changes the height.
struct RiseButton: View {
    let model: AppModel
    /// Says to hold, at the top of the screen.
    @Binding var hint: Bool
    @State private var pressing = false
    @State private var pressedAt = Date.distantPast
    @State private var hintTask: Task<Void, Never>?

    var body: some View {
        let on = pressing || model.rise.holding
        Image(systemName: "arrow.up.to.line")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(on ? .black : .white)
            .frame(width: 44, height: 44)
            .background {
                if on { Circle().fill(Color.amber) }
            }
            .glassBackground(in: Circle())
            .environment(\.colorScheme, .dark)
            .contentShape(Circle())
            // Never completes: only pressing and letting go (or the touch being taken away) count,
            // and the finger may wander off the button while it's held.
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity) {} onPressingChanged: { pressing in
                self.pressing = pressing
                if pressing {
                    pressedAt = Date()
                    showHint(false)
                    model.setRising(true)
                } else {
                    // Let go before it went up: a tap.
                    let tapped = Date().timeIntervalSince(pressedAt) < 0.35 && model.rise.level == 0
                    model.setRising(false)
                    if tapped { showHint(true) }
                }
            }
            // Taken away while held (the view paused, a sheet): no let-go will come.
            .onDisappear { if pressing || model.rise.holding { model.setRising(false) } }
            .accessibilityElement()
            .accessibilityLabel("See over the ridges")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(value)
            .accessibilityHint(model.rise.holding
                ? "Activate to return to the camera. Swipe up or down to change the height."
                : "Activate to rise and stay above the ridges. Swipe up or down to change the height.")
            .accessibilityAction { model.toggleRising() }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.adjustRise(by: 1)
                case .decrement: model.adjustRise(by: -1)
                @unknown default: break
                }
            }
    }

    private var value: String {
        let rise = model.rise
        guard rise.level > 0 else { return rise.pending ? "Rising" : "On the ground" }
        return RiseChip.summary(rise, units: model.settings.units)
    }

    private func showHint(_ shown: Bool) {
        hintTask?.cancel()
        hint = shown
        guard shown else { return }
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { hint = false }
        }
    }
}

/// Over the top of the view while risen: how high, and how many more peaks are in sight
/// from up there. Before the first view from above is in, that it's on its way; after a
/// tap on the rise button, to hold it.
struct RiseChip: View {
    let model: AppModel
    var hint = false

    /// Whether it has anything to say.
    static func isShown(_ model: AppModel, hint: Bool) -> Bool {
        model.rise.level > 0 || model.rise.pending || hint
    }

    /// "300 m up · 12 more peaks around you": a count in every direction, not just on screen.
    static func summary(_ rise: AppModel.Rise, units: AppSettings.Units) -> String {
        let up = Format.elevation(rise.height, units) + " up"
        switch rise.revealed {
        case 0: return up
        case 1: return up + " · 1 more peak around you"
        default: return up + " · \(rise.revealed) more peaks around you"
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
        } else if hint {
            Text("Hold to see over the ridges")
        }
    }
}

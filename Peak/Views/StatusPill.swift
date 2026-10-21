import PeakCore
import SwiftUI

/// The floating status: what the app is doing, which way you're facing, and whether the
/// labels are locked to the skyline or following the compass. Tap it to pause the view;
/// long-press it for diagnostics.
struct StatusPill: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 8) {
                content
            }
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .lineLimit(2)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .contentShape(Capsule())
            .onTapGesture { model.toggleFreeze() }
            .onLongPressGesture { model.settings.showDiagnostics.toggle() }
        }
    }

    /// Compass heading of the middle of the view, like "236° SW".
    private var heading: String? {
        let pose = model.frozen?.pose ?? model.motion.pose
        guard let pose else { return nil }
        return Format.bearing(CameraGeometry.heading(pose, correction: model.frozen?.correction ?? model.viewCorrection))
    }

    @ViewBuilder private var content: some View {
        if model.frozen != nil {
            Image(systemName: "pause.fill").font(.system(size: 10))
            Text("Paused" + (heading.map { " · \($0)" } ?? ""))
        } else {
            switch model.phase {
            case .locating:
                ProgressView().controlSize(.small).tint(.white)
                Text("Finding your position…")
            case let .loading(text):
                ProgressView().controlSize(.small).tint(.white)
                Text(text)
            case let .needsPermission(text), let .failed(text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(text).multilineTextAlignment(.leading).frame(maxWidth: 260)
            case .ready:
                Circle()
                    .fill(model.correction.isAligned ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text((heading.map { "\($0) · " } ?? "") + (model.correction.isAligned ? "Locked" : "Compass"))
            }
        }
    }
}

/// What the app is doing under the hood, to screenshot when something looks wrong.
struct DebugPanel: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.debugLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        }
        .allowsHitTesting(false)
    }
}

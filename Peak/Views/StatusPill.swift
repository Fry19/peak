import PeakCore
import SwiftUI
import UIKit

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
            .onTapGesture { if !model.aligning { model.toggleFreeze() } }
            .onLongPressGesture { model.settings.showDiagnostics.toggle() }
        }
    }

    /// Compass heading of the middle of the view, like "236° SW".
    private var heading: String? {
        let pose = model.frozen?.pose ?? model.motion.pose
        guard let pose else { return nil }
        return Format.bearing(CameraGeometry.heading(pose, correction: model.frozen?.correction ?? model.viewCorrection(for: pose)))
    }

    @ViewBuilder private var content: some View {
        if model.aligning {
            Image(systemName: "hand.draw.fill").font(.system(size: 11))
            Text("Lining up" + (heading.map { " · \($0)" } ?? ""))
        } else if model.frozen != nil {
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
                let state = model.correction.state
                Circle()
                    .fill(state == .locked ? Color.green : state == .byHand ? Color.cyan : Color.orange)
                    .frame(width: 7, height: 7)
                Text((heading.map { "\($0) · " } ?? "") + (state == .locked ? "Locked" : state == .byHand ? "Lined up" : "Compass")
                     + (model.waitingForPeaks ? " · Getting peaks…" : ""))
            }
        }
    }
}

/// What the app is doing under the hood, to screenshot when something looks wrong, and a
/// button that saves the frame the skyline matcher looks at for testing at a desk.
struct DebugPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.debugLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .allowsHitTesting(false)
            Button(model.savingTestFrame ? "Hold the phone steady…" : "Save frame for testing") {
                model.saveTestFrame { Self.share($0) }
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The share sheet, from whatever is on screen, to AirDrop the files to a Mac.
    private static func share(_ urls: [URL]) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }
}

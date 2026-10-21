import SwiftUI

/// The one floating control: what the app is doing, and whether the labels are locked to
/// the skyline or only following the compass.
struct StatusPill: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 8) {
                content
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private var content: some View {
        if model.frozen != nil {
            Image(systemName: "pause.fill").font(.system(size: 10))
            Text("Paused · tap to go live")
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
                Text(text).multilineTextAlignment(.leading).frame(maxWidth: 280)
            case .ready:
                Circle()
                    .fill(model.correction.isAligned ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.correction.isAligned
                     ? String(format: "Locked to the skyline · compass %+.1f°", -model.correction.degrees)
                     : "Using the compass · point at the mountains")
            }
        }
    }
}

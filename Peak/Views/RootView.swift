import SwiftUI

/// Camera first: the live picture fills the screen, the overlay draws ridgelines and labels,
/// and one floating pill says what's going on (tap it to freeze the view).
struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CameraPreview(model: model)
                .ignoresSafeArea()
            OverlayView(model: model)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 10) {
                if model.showDebug {
                    DebugPanel(model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                Spacer()
                StatusPill(model: model)
                Text("Terrain © Copernicus DEM (DLR, Airbus) · Peaks © OpenStreetMap contributors")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(Color.black)
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            // Permission prompts make the app briefly inactive; only the background stops it.
            if phase == .active { model.setActive(true) } else if phase == .background { model.setActive(false) }
        }
    }
}

/// The live camera picture, filling the view.
struct CameraPreview: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = model.camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        model.preview = view
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

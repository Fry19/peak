import SwiftUI

/// Camera first: the live picture fills the screen, the overlay draws ridgelines and labels,
/// and one floating pill says what's going on. Tap anywhere to freeze the view.
struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CameraPreview(model: model)
                .ignoresSafeArea()
            OverlayView(model: model)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                Spacer()
                StatusPill(model: model)
                Text("Terrain © Copernicus DEM (DLR, Airbus) · Peaks © OpenStreetMap contributors")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.bottom, 12)
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleFreeze() }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
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

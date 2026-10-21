import SwiftUI

/// Camera first: the AR view fills the screen, the overlay draws ridgelines and labels, and
/// one floating pill says what's going on. Tap anywhere to freeze the view.
struct RootView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            ARCameraView(model: model)
                .ignoresSafeArea()
            if let frozen = model.frozen {
                Image(uiImage: frozen.image)
                    .resizable()
                    .ignoresSafeArea()
            }
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
    }
}

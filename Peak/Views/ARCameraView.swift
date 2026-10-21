import ARKit
import SwiftUI

/// The live camera picture, from ARKit.
struct ARCameraView: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = model.session
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        model.arView = view
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}

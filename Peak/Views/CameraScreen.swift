import AVFoundation
import PeakCore
import SwiftUI
import UIKit

/// The camera picture with the ridgelines, labels and trails drawn over it.
struct CameraScreen: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> CameraScreenView {
        let view = CameraScreenView(model: model)
        model.screen = view
        return view
    }

    func updateUIView(_ view: CameraScreenView, context: Context) {}
}

/// Shows camera frames itself, rather than through a preview layer, so it knows exactly
/// which frame is on screen and when it was taken. The overlay is drawn for that moment,
/// so the lines don't run ahead of the picture when the phone turns.
final class CameraScreenView: UIView {
    private let video = AVSampleBufferDisplayLayer()
    let overlay = OverlayCanvas()
    weak var model: AppModel?
    /// The frame on screen.
    private(set) var shown: AppModel.Shown?
    private(set) var lastFrameDate = Date.distantPast

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .black
        video.videoGravity = .resizeAspectFill
        layer.addSublayer(video)
        overlay.screen = self
        overlay.model = model
        addSubview(overlay)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var interfaceOrientation: UIInterfaceOrientation {
        window?.windowScene?.interfaceOrientation ?? .portrait
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        // Turn the picture to match the interface: frames come in portrait (or the sensor's
        // landscape orientation) whichever way the phone is held.
        let portrait = model?.frozen?.shown.portrait ?? shown?.portrait ?? true
        let turns = (CameraGeometry.quarterTurns(interfaceOrientation) - (portrait ? 1 : 0) + 4) % 4
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2))
        video.bounds = CGRect(origin: .zero, size: turns % 2 == 1 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        video.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        overlay.setNeedsDisplay()
    }

    /// Puts a frame on screen, unless the view is paused.
    func show(_ frame: CameraFeed.Frame) {
        guard model?.frozen == nil else { return }
        let renderer = video.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        Self.displayImmediately(frame.sample)
        renderer.enqueue(frame.sample)
        let turned = shown.map { $0.portrait != frame.portrait } ?? true
        shown = AppModel.Shown(time: frame.time, lens: frame.lens, portrait: frame.portrait)
        lastFrameDate = Date()
        if turned { setNeedsLayout() }
        overlay.setNeedsDisplay()
    }

    /// Frames have no playback clock: show each as soon as it arrives.
    private static func displayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let model else { return }
        if let id = overlay.peak(at: gesture.location(in: overlay)) {
            UISelectionFeedbackGenerator().selectionChanged()
            model.select(id)
        } else if model.sheet == nil {
            model.selectedPeakID = nil
        }
    }
}

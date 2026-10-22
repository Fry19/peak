import AVFoundation
import PeakCore
import SwiftUI
import UIKit

/// The camera picture with the ridgelines, labels and trails drawn over it.
struct CameraScreen: UIViewRepresentable {
    let model: AppModel
    /// Controls over the view, in global (window) coordinates, for labels to keep clear of.
    var keepClear: [CGRect] = []

    func makeUIView(context: Context) -> CameraScreenView {
        let view = CameraScreenView(model: model)
        model.screen = view
        return view
    }

    func updateUIView(_ view: CameraScreenView, context: Context) {
        view.overlay.keepClear = keepClear.filter { !$0.isEmpty }
    }
}

/// Shows camera frames itself, rather than through a preview layer, so it knows exactly
/// which frame is on screen and when it was taken. The overlay is drawn for that moment,
/// so the lines don't run ahead of the picture when the phone turns.
final class CameraScreenView: UIView, UIGestureRecognizerDelegate {
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
        clipsToBounds = true   // the zoomed picture reaches past the edges
        video.videoGravity = .resizeAspectFill
        layer.addSublayer(video)
        overlay.screen = self
        overlay.model = model
        overlay.paused = model.showsFromAbove
        addSubview(overlay)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        // Lining up by hand: drag to move the lines, turn with two fingers to level them.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        // Pinch to zoom in on the picture and the lines together.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for g in [pan, rotation, pinch] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    // UIView asks itself this for its own gesture recognizers; dragging and turning only
    // work while lining up.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        gesture is UITapGestureRecognizer || gesture is UIPinchGestureRecognizer || model?.aligning == true
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let model else { return }
        model.setZoom(model.zoom * Double(gesture.scale))
        gesture.scale = 1
    }

    /// A full-screen view covers the camera: the overlay rests until it's gone.
    func setCovered(_ covered: Bool) {
        overlay.paused = covered
    }

    /// Shows the picture at the model's zoom.
    func zoomChanged() {
        layoutVideo()
        overlay.update()
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(gesture is UITapGestureRecognizer) && !(other is UITapGestureRecognizer)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let model, model.aligning, let f = overlay.lastFocal, f > 0 else { return }
        let t = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        // The drag in the world's terms: along the horizon, and down.
        let a = overlay.upAngle
        let along = Double(t.x * cos(a) + t.y * sin(a)), down = Double(-t.x * sin(a) + t.y * cos(a))
        // Lines follow the finger: turning the view left moves them right, tilting it up
        // moves them down.
        model.adjust(heading: -along / f * 180 / .pi, pitch: down / f * 180 / .pi, roll: 0)
        overlay.update()
    }

    @objc private func rotated(_ gesture: UIRotationGestureRecognizer) {
        guard let model, model.aligning else { return }
        let r = Double(gesture.rotation)
        gesture.rotation = 0
        // Turning the camera clockwise turns the picture's contents the other way.
        model.adjust(heading: 0, pitch: 0, roll: -r * 180 / .pi)
        overlay.update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var interfaceOrientation: UIInterfaceOrientation {
        window?.windowScene?.interfaceOrientation ?? .portrait
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        layoutVideo()
        overlay.setNeedsUpdate()
    }

    /// Turns the picture to match the interface (frames come in portrait, or the sensor's
    /// landscape orientation, whichever way the phone is held) and zooms it about the middle.
    private func layoutVideo() {
        let portrait = model?.frozen?.shown.portrait ?? shown?.portrait ?? true
        let turns = (CameraGeometry.quarterTurns(interfaceOrientation) - (portrait ? 1 : 0) + 4) % 4
        let zoom = CGFloat(model?.zoom ?? 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2).scaledBy(x: zoom, y: zoom))
        video.bounds = CGRect(origin: .zero, size: turns % 2 == 1 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        video.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
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
        // Lay the overlay out for this frame now, so both reach the screen together.
        overlay.update()
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
        guard let model, !model.aligning else { return }
        if let id = overlay.peak(at: gesture.location(in: overlay)) {
            UISelectionFeedbackGenerator().selectionChanged()
            model.select(id)
        } else if model.sheet == nil {
            model.selectedPeakID = nil
        }
    }
}

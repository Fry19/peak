import CoreImage
import CoreTransferable
import ImageIO
import Photos
import PeakCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A still picture with the mountains labeled, to look at, line up and share: a paused
/// frame from the camera, or a photo from the library matched to its skyline.
@Observable
final class LabeledPhoto: Identifiable {
    enum Stage: Equatable {
        case loading(String)
        case ready
        case failed(String)
    }

    /// How the lines came to be where they are.
    enum Fit: Equatable {
        /// As the live view had them.
        case live
        /// Matched to the photo's skyline.
        case matched
        /// Needs lining up by hand, and why.
        case byHand(String)
        /// Lined up by hand.
        case linedUp
    }

    let id = UUID()
    let fromCamera: Bool
    var stage: Stage
    var fit = Fit.live
    /// The upright picture at full size.
    private(set) var image: CGImage?
    private(set) var scene: TerrainScene?
    /// The camera for `image`, in its pixels.
    var camera: Camera?
    var variant = PhotoOverlay.Variant.labels
    var selectedID: Int64?
    /// Dragging the lines onto the mountains.
    var adjusting = false
    /// The skyline match running again from where the lines were put by hand.
    private(set) var snapping = false
    /// A note on how the lines were placed, shown once things are ready.
    var note: String?
    /// Summits pinned where they really are while lining up, in the picture's pixels, and
    /// whether they fit one view and set its tilt.
    private(set) var pins = SummitPins()
    private(set) var pinsMisfit = false
    private(set) var pinsTilt = false
    /// A spot tapped while lining up, to name its peak.
    var summitPick: SummitPick?

    /// For matching: the camera from the metadata, and the picture shrunk.
    @ObservationIgnored private var photoCamera: PhotoCamera?
    @ObservationIgnored private var small: RGBImage?
    @ObservationIgnored private var beforeAdjusting: Camera?
    /// Counts the times lining up by hand began, so a match started before the latest one
    /// doesn't move lines put by hand since.
    @ObservationIgnored private var adjustments = 0

    private init(fromCamera: Bool, stage: Stage) {
        self.fromCamera = fromCamera
        self.stage = stage
    }

    // MARK: From the camera

    /// The paused view: the frame on screen, turned upright the way the phone was held,
    /// with the lines where the live view had them.
    @MainActor static func capture(_ frozen: AppModel.Frozen, pixels: CVPixelBuffer, scene: TerrainScene, zoom: Double) -> LabeledPhoto {
        let photo = LabeledPhoto(fromCamera: true, stage: .loading("Preparing the picture…"))
        photo.scene = scene
        let pose = frozen.pose, lens = frozen.shown.lens, portrait = frozen.shown.portrait, correction = frozen.correction
        Task { @MainActor in
            let made = await Task.detached(priority: .userInitiated) {
                Self.upright(pixels, pose: pose, lens: lens, portraitFrame: portrait, correction: correction, zoom: zoom)
            }.value
            guard let made else {
                photo.stage = .failed("Couldn't get the picture from the camera.")
                return
            }
            photo.image = made.image
            photo.camera = made.camera
            photo.stage = .ready
        }
        return photo
    }

    /// The frame turned upright for the way the phone was held (whichever of the four ways
    /// leaves the horizon most level), cut to what was on screen when zoomed, and its camera.
    private static func upright(_ pixels: CVPixelBuffer, pose: MotionTracker.Pose, lens: CameraFeed.Lens, portraitFrame: Bool,
                                correction: ViewCorrection, zoom: Double) -> (image: CGImage, camera: Camera)? {
        let orientations: [UIInterfaceOrientation] = [.portrait, .landscapeRight, .landscapeLeft, .portraitUpsideDown]
        let attitudes = orientations.map { CameraGeometry.attitude(CameraGeometry.axes(pose, orientation: $0), correction: correction) }
        let best = attitudes.indices.min { abs(attitudes[$0].roll) < abs(attitudes[$1].roll) }!
        let turns = (CameraGeometry.quarterTurns(orientations[best]) - (portraitFrame ? 1 : 0) + 4) % 4
        var k = lens.intrinsics
        for _ in 0..<turns { k = k.rotatedClockwise() }
        var picture = CIImage(cvPixelBuffer: pixels)
        picture = picture.oriented([.up, .right, .down, .left][turns])
        picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
        // The picture's size may differ from the lens's by rounding; fit the lens to it.
        let width = Int(picture.extent.width), height = Int(picture.extent.height)
        k = k.scaled(toWidth: width, height: height)
        if zoom > 1.01 {
            // What was on screen: the middle 1/zoom of the frame.
            let w = (Double(width) / zoom).rounded(), h = (Double(height) / zoom).rounded()
            let x0 = ((Double(width) - w) / 2).rounded(), y0 = ((Double(height) - h) / 2).rounded()
            // Core Image counts y up from the bottom.
            picture = picture.cropped(to: CGRect(x: x0, y: Double(height) - y0 - h, width: w, height: h))
            picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
            k = CameraIntrinsics(width: Int(w), height: Int(h), fx: k.fx, fy: k.fy, cx: k.cx - x0, cy: k.cy - y0)
        }
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let image = context.createCGImage(picture, from: picture.extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return (image, Camera(intrinsics: k, attitude: attitudes[best]))
    }

    // MARK: From the library

    /// A photo from the library: read its metadata, get the terrain and peaks where it was
    /// taken, and match its skyline.
    @MainActor static func importing(_ load: @escaping () async throws -> Data?, model: AppModel) -> LabeledPhoto {
        let photo = LabeledPhoto(fromCamera: false, stage: .loading("Reading the photo…"))
        Task { @MainActor in await photo.run(load, model: model) }
        return photo
    }

    @MainActor private func run(_ load: () async throws -> Data?, model: AppModel) async {
        guard let data = try? await load() else {
            stage = .failed("Couldn't read this photo.")
            return
        }
        guard let file = await Task.detached(priority: .userInitiated, operation: { PhotoFile(data) }).value else {
            stage = .failed("Couldn't read this photo.")
            return
        }
        image = file.image
        small = file.small
        let photoCamera: PhotoCamera
        do {
            photoCamera = try PhotoCamera(file.metadata)
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription ?? "This photo has no location.")
            return
        }
        self.photoCamera = photoCamera
        do {
            let place = try await model.scene(latitude: photoCamera.latitude, longitude: photoCamera.longitude,
                                               accuracy: photoCamera.positionError) { [weak self] step in
                self?.stage = .loading(step)
            }
            scene = place.scene
            if !place.hasPeaks { note = "Couldn't get the peaks here, so only the ridgelines are drawn." }
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't get the terrain where this photo was taken.")
            return
        }
        stage = .loading(photoCamera.hasHeading ? "Matching the skyline…" : "No compass heading: looking all the way around…")
        await match()
        stage = .ready
    }

    /// Matches the skyline, from the metadata's heading or, after lining up by hand, from
    /// there; keeps the lines where they were if it doesn't find a clear match.
    @MainActor private func match(near: Attitude? = nil) async {
        guard let image, let small, let photoCamera, let scene else { return }
        let horizon = scene.matchingHorizon
        let started = adjustments
        let m = await Task.detached(priority: .userInitiated) { photoCamera.match(small, horizon: horizon, near: near) }.value
        let a = m.alignment
        // Lined up by hand again meanwhile: that wins.
        if near != nil, adjusting || adjustments != started { return }
        if a.accepted {
            camera = Camera(intrinsics: a.intrinsics.scaled(toWidth: image.width, height: image.height), attitude: a.attitude)
            fit = .matched
            return
        }
        if near != nil { return }   // keep the lines where they were put by hand
        camera = Camera(intrinsics: photoCamera.intrinsics.scaled(toWidth: image.width, height: image.height),
                        attitude: photoCamera.hasHeading ? photoCamera.prior : startingGuess(scene))
        let why = photoCamera.hasHeading ? "The skyline didn't match clearly (clouds, trees, or too little of it in view)."
                                         : "This photo has no compass heading, and its skyline didn't give it away."
        fit = .byHand(why)
        startAdjusting()
    }

    /// Without a heading: facing the most prominent peak in view, horizon a little low.
    private func startingGuess(_ scene: TerrainScene) -> Attitude {
        guard let top = scene.peaks.first else { return Attitude(heading: 0, pitch: 2) }
        return Attitude(heading: top.azimuth, pitch: top.elevation * 0.6)
    }

    // MARK: Lining up by hand

    func startAdjusting() {
        beforeAdjusting = camera
        adjusting = true
        adjustments += 1
        snapping = false
    }

    /// Moves the lines by a drag (in the picture's pixels) or a twist (radians): they follow
    /// the finger.
    func adjust(dx: Double, dy: Double, twist: Double) {
        guard var camera else { return }
        let f = camera.intrinsics.fx
        camera.attitude.heading = normalizedAzimuth(camera.attitude.heading - atan(dx / f) * 180 / .pi)
        camera.attitude.pitch = max(-60, min(60, camera.attitude.pitch + atan(dy / f) * 180 / .pi))
        camera.attitude.roll = max(-45, min(45, camera.attitude.roll - twist * 180 / .pi))
        self.camera = camera
    }

    func cancelAdjusting() {
        if let beforeAdjusting { camera = beforeAdjusting }
        adjusting = false
        clearPins()
    }

    /// Lines the picture up by a peak: its summit belongs at `point` (the picture's pixels).
    /// Pinning starts lining up by hand.
    func pin(_ peakID: Int64, at point: CGPoint) {
        guard let camera, let v = scene?.allPeaks[peakID], v.isVisible else { return }
        if !adjusting { startAdjusting() }
        let k = camera.intrinsics
        pins.pin(SummitPins.Pin(id: peakID, name: v.peak.name, azimuth: v.azimuth, elevation: v.elevation,
                                u: (point.x - k.cx) / k.fx, v: (point.y - k.cy) / k.fy), current: camera.attitude)
        applyPins()
    }

    /// Takes a pin away; with none left, the lines go back to where they were before the first.
    func unpin(_ peakID: Int64) {
        pins.remove(peakID)
        applyPins()
        if pins.isEmpty { clearPins() }
    }

    func clearPins() {
        pins.removeAll()
        pinsMisfit = false
        pinsTilt = false
        summitPick = nil
    }

    /// The peaks that could be at `point` (the picture's pixels), to choose from.
    func pickSummit(at point: CGPoint) {
        guard adjusting, let camera, let scene else { return }
        summitPick = SummitPick(point: point, camera: camera, peaks: scene.peaks)
    }

    private func applyPins() {
        guard let k = camera?.intrinsics, let solved = pins.solve(intrinsics: k) else { return }
        pinsMisfit = solved.misfit
        pinsTilt = solved.tilt
        camera?.attitude = solved.attitude
    }

    /// Done lining up: a photo from the library is matched again from here, which snaps the
    /// lines exactly onto the skyline when it can.
    @MainActor func finishAdjusting() {
        adjusting = false
        clearPins()
        guard camera != beforeAdjusting else { return }
        fit = .linedUp
        guard !fromCamera, let near = camera?.attitude else { return }
        snapping = true
        let started = adjustments
        Task { @MainActor in
            await match(near: near)
            if adjustments == started { snapping = false }
        }
    }

    // MARK: Saving and sharing

    func overlay(units: AppSettings.Units, ridges: Bool, maxLabels: Int, variant: PhotoOverlay.Variant? = nil,
                 selected: Bool = false) -> PhotoOverlay? {
        guard let scene, let camera else { return nil }
        return PhotoOverlay(scene: scene, camera: camera, units: units, variant: variant ?? self.variant, ridges: ridges,
                            maxLabels: maxLabels, selectedID: selected ? selectedID : nil)
    }

    /// The picture with its lines at full size, as JPEG.
    func jpeg(_ overlay: PhotoOverlay) async -> Data? {
        guard let image else { return nil }
        return await Task.detached(priority: .userInitiated) {
            overlay.render(image).jpegData(compressionQuality: 0.92)
        }.value
    }

    enum SaveError: LocalizedError {
        case notAllowed
        case failed

        var errorDescription: String? {
            switch self {
            case .notAllowed: return "Peak isn't allowed to add to your photos. You can allow it in Settings › Privacy › Photos."
            case .failed: return "Couldn't save the picture."
            }
        }
    }

    /// Adds the picture to the photo library; asks only to add, never to see the library.
    func save(_ overlay: PhotoOverlay) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAllowed }
        guard let data = await jpeg(overlay) else { throw SaveError.failed }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

/// The picture to share, rendered when the share sheet asks for it.
struct SharedPhoto: Transferable {
    let photo: LabeledPhoto
    let overlay: PhotoOverlay

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { shared in
            guard let data = await shared.photo.jpeg(shared.overlay) else { throw LabeledPhoto.SaveError.failed }
            return data
        }
        .suggestedFileName("Peak.jpg")
    }
}

/// A photo file read with ImageIO: the upright picture, a small copy for matching the
/// skyline, and what its metadata says (PeakCore turns that into a camera).
struct PhotoFile {
    let image: CGImage
    let small: RGBImage
    let metadata: PhotoMetadata

    /// Width the skyline matcher's copy is made at (it works at 960).
    static let matchingSize = 1280

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let metadata = PhotoMetadata(properties: properties) else { return nil }
        let upright = metadata.uprightSize
        func thumbnail(_ size: Int) -> CGImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image = thumbnail(max(upright.width, upright.height)),
              let shrunk = thumbnail(Self.matchingSize), let small = RGBImage(shrunk) else { return nil }
        self.image = image
        self.small = small
        self.metadata = metadata
    }
}

extension RGBImage {
    /// A CGImage's pixels, drawn into sRGB.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[3 * i] = rgba[4 * i]
            rgb[3 * i + 1] = rgba[4 * i + 1]
            rgb[3 * i + 2] = rgba[4 * i + 2]
        }
        self.init(width: width, height: height, pixels: rgb)
    }
}

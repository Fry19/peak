import Foundation

/// The whole visual heading correction for one frame: shrink the image, find the skyline,
/// and align it with the rendered horizon.
public struct SkylineMatcher: Sendable {
    public var detector = SkylineDetector()
    public var settings = AlignmentSettings()
    /// Width the image is scaled to before detection.
    public var workingWidth = 960
    /// Look for the skyline only where the terrain's skyline can appear (see `searchBand`).
    public var usesSearchBand = true

    public init() {}

    public struct Match: Sendable {
        /// The image at working size.
        public var image: RGBImage
        /// The skyline in the working-size image.
        public var skyline: Skyline
        /// The camera at working size, before correction.
        public var camera: Camera
        public var alignment: AlignmentResult
        public var seconds: Double
    }

    /// `intrinsics` are for the full-size `image`; `prior` is the sensor attitude.
    public func match(_ image: RGBImage, intrinsics: CameraIntrinsics, prior: Attitude, horizon: HorizonProfile) -> Match {
        let start = Date()
        let small = image.width > workingWidth ? image.resized(toWidth: workingWidth) : image
        let k = intrinsics.scaled(toWidth: small.width, height: small.height)
        let camera = Camera(intrinsics: k, attitude: prior)
        let band = usesSearchBand ? Self.searchBand(camera: camera, horizon: horizon, settings: settings) : nil
        let skyline = detector.detect(in: small, band: band)
        let alignment = SkylineAligner.align(skyline, camera: camera, horizon: horizon, settings: settings)
        return Match(image: small, skyline: skyline, camera: camera, alignment: alignment, seconds: Date().timeIntervalSince(start))
    }

    /// For each column of the camera's image, the rows where the terrain's skyline can be:
    /// wherever the rendered horizon lands with the heading anywhere in the aligner's search
    /// and the pitch and roll off by as much as it allows, plus a little. Nothing above that
    /// (eaves, blinds, a porch roof with sky past it) can be the skyline it matches against.
    public static func searchBand(camera: Camera, horizon: HorizonProfile, settings: AlignmentSettings) -> [ClosedRange<Int>] {
        let k = camera.intrinsics
        let projector = camera.projector
        let pitchPixels = tan(settings.pitchRange * .pi / 180) * k.fy
        // The base layer's coarse terrain puts near ridges a degree or two low.
        let coarsePixels = horizon.coarseRays.contains(true) ? tan(2.5 * .pi / 180) * k.fy : 0
        return (0..<k.width).map { x in
            let px = Double(x) + 0.5
            let center = projector.look(x: px, y: k.cy)
            var low = Double.infinity, high = -Double.infinity
            for step in -Int(settings.headingRange * 2)...Int(settings.headingRange * 2) {
                let e = horizon.elevation(atAzimuth: center.azimuth + Double(step) / 2)
                low = min(low, e)
                high = max(high, e)
            }
            guard let top = projector.pixel(azimuth: center.azimuth, elevation: high),
                  let bottom = projector.pixel(azimuth: center.azimuth, elevation: low) else { return 0...k.height }
            let margin = pitchPixels + coarsePixels + abs(px - k.cx) * tan(settings.rollRange * .pi / 180) + Double(k.height) / 60
            let a = max(0, min(k.height, Int((min(top.y, bottom.y) - margin).rounded(.down))))
            let b = max(a, min(k.height, Int((max(top.y, bottom.y) + margin).rounded(.up))))
            return a...b
        }
    }
}

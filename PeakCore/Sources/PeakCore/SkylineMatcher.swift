import Foundation

/// The whole visual heading correction for one frame: shrink the image, find the skyline,
/// and align it with the rendered horizon.
public struct SkylineMatcher: Sendable {
    public var detector = SkylineDetector()
    public var settings = AlignmentSettings()
    /// Width the image is scaled to before detection.
    public var workingWidth = 960

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
        let skyline = detector.detect(in: small)
        let alignment = SkylineAligner.align(skyline, camera: camera, horizon: horizon, settings: settings)
        return Match(image: small, skyline: skyline, camera: camera, alignment: alignment, seconds: Date().timeIntervalSince(start))
    }
}

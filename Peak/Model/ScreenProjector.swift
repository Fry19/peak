import ARKit
import PeakCore

/// Puts true azimuth/elevation directions on the screen, using ARKit's camera and the
/// heading correction from skyline matching.
struct ScreenProjector {
    let size: CGSize
    let correction: Double
    /// True heading of the middle of the view, degrees.
    let heading: Double
    private let viewProjection: simd_float4x4
    private let position: simd_float3

    init(camera: ARCamera, size: CGSize, correction: Double) {
        self.size = size
        self.correction = correction
        viewProjection = camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.1, zFar: 5_000)
            * camera.viewMatrix(for: .portrait)
        let t = camera.transform
        position = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // The camera looks along −z; ARKit's world has x east and z south.
        let forward = -t.columns.2
        heading = normalizedAzimuth(atan2(Double(forward.x), Double(-forward.z)) * 180 / .pi + correction)
    }

    /// Screen point for a direction, or nil if it is behind the camera.
    func point(azimuth: Double, elevation: Double) -> CGPoint? {
        // A peak at true azimuth A sits at A − correction in ARKit's compass-based world.
        let a = (azimuth - correction) * .pi / 180, e = elevation * .pi / 180
        let direction = simd_float3(Float(sin(a) * cos(e)), Float(sin(e)), Float(-cos(a) * cos(e)))
        let clip = viewProjection * simd_float4(position + direction * 1_000, 1)
        guard clip.w > 0.001 else { return nil }
        return CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2) * size.width,
                       y: CGFloat((1 - clip.y / clip.w) / 2) * size.height)
    }
}

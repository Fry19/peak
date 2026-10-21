import XCTest
@testable import PeakCore

final class SkylineTests: XCTestCase {
    /// Sky gradient over textured ground with a known wavy boundary.
    func testDetectsAKnownBoundary() {
        let w = 480, h = 360
        func truth(_ x: Double) -> Double { 150 + 40 * sin(x / 37) + 15 * sin(x / 11) }
        var image = RGBImage(width: w, height: h)
        var rng = SplitMix64(seed: 5)
        for y in 0..<h {
            for x in 0..<w {
                let cy = Double(y) + 0.5
                var c: SIMD3<Double>
                if cy < truth(Double(x) + 0.5) {
                    c = mix(SIMD3(70, 118, 196), SIMD3(205, 218, 232), cy / 200)
                } else {
                    let n = fractalNoise(Double(x) / 6, Double(y) / 6, seed: 9)
                    c = SIMD3(120, 110, 100) + 80 * (n - 0.5)
                }
                c += 3 * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian())
                image.set(x, y, (clampByte(c.x), clampByte(c.y), clampByte(c.z)))
            }
        }
        let skyline = SkylineDetector().detect(in: image)
        XCTAssertGreaterThan(skyline.validFraction, 0.95)
        let errors = (0..<w).compactMap { x -> Double? in
            let r = skyline.rows[x]
            return r.isNaN ? nil : abs(Double(r) - truth(Double(x) + 0.5))
        }.sorted()
        XCTAssertLessThan(errors[errors.count / 2], 0.7, "median error in pixels")
        XCTAssertLessThan(errors[errors.count * 95 / 100], 2.0, "95th percentile error in pixels")
    }

    func testAllTerrainHasNoSkyline() {
        var image = RGBImage(width: 320, height: 240)
        for y in 0..<240 {
            for x in 0..<320 {
                let n = fractalNoise(Double(x) / 5, Double(y) / 5, seed: 2)
                let v = clampByte(110 + 80 * (n - 0.5))
                image.set(x, y, (v, clampByte(Double(v) - 8), clampByte(Double(v) - 16)))
            }
        }
        XCTAssertLessThan(SkylineDetector().detect(in: image).validFraction, 0.25)
    }
}

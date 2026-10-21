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

    /// Looking out past blinds: dark slats cross the sky above the skyline. Told where the
    /// skyline can be, the detector finds it rather than the slats' edges.
    func testBandIgnoresThingsAboveTheSkyline() {
        let w = 480, h = 360
        func truth(_ x: Double) -> Double { 240 + 8 * sin(x / 37) + 3 * sin(x / 11) }
        func slat(_ y: Double) -> Bool { (0..<20).contains(y) || (70..<105).contains(y) || (160..<190).contains(y) }
        var image = RGBImage(width: w, height: h)
        var rng = SplitMix64(seed: 6)
        for y in 0..<h {
            for x in 0..<w {
                let cy = Double(y) + 0.5
                var c: SIMD3<Double>
                if slat(cy) {
                    c = SIMD3(88, 90, 94)
                } else if cy < truth(Double(x) + 0.5) {
                    c = mix(SIMD3(110, 150, 210), SIMD3(215, 225, 235), cy / 240)
                } else {
                    let n = fractalNoise(Double(x) / 6, Double(y) / 6, seed: 9)
                    c = SIMD3(120, 110, 100) + 80 * (n - 0.5)
                }
                c += 3 * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian())
                image.set(x, y, (clampByte(c.x), clampByte(c.y), clampByte(c.z)))
            }
        }
        let band = (0..<w).map { x in Int(truth(Double(x) + 0.5)) - 30...Int(truth(Double(x) + 0.5)) + 30 }
        let skyline = SkylineDetector().detect(in: image, band: band)
        XCTAssertGreaterThan(skyline.validFraction, 0.9)
        let errors = (0..<w).compactMap { x -> Double? in
            let r = skyline.rows[x]
            return r.isNaN ? nil : abs(Double(r) - truth(Double(x) + 0.5))
        }.sorted()
        XCTAssertLessThan(errors[errors.count / 2], 0.7, "median error in pixels")
        XCTAssertLessThan(errors[errors.count * 95 / 100], 2.0, "95th percentile error in pixels")
    }

    /// Low sun turns the sky orange near the horizon; it still counts as sky.
    func testFindsTheSkylineUnderAnOrangeSky() {
        let w = 480, h = 360
        func truth(_ x: Double) -> Double { 200 + 25 * sin(x / 41) }
        var image = RGBImage(width: w, height: h)
        var rng = SplitMix64(seed: 7)
        for y in 0..<h {
            for x in 0..<w {
                let cy = Double(y) + 0.5
                var c: SIMD3<Double>
                if cy < truth(Double(x) + 0.5) {
                    c = mix(SIMD3(150, 185, 225), SIMD3(250, 220, 160), cy / 230)
                } else {
                    let n = fractalNoise(Double(x) / 6, Double(y) / 6, seed: 3)
                    c = SIMD3(90, 80, 70) + 60 * (n - 0.5)
                }
                c += 3 * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian())
                image.set(x, y, (clampByte(c.x), clampByte(c.y), clampByte(c.z)))
            }
        }
        let skyline = SkylineDetector().detect(in: image)
        XCTAssertGreaterThan(skyline.validFraction, 0.9)
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

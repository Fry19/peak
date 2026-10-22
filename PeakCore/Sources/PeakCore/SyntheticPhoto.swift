import Foundation

/// Renders a fake photo of the terrain from a horizon profile, for testing skyline
/// detection and alignment against an exactly known camera.
public struct SyntheticScene: Sendable {
    public var seed: UInt64 = 1
    /// Distance over which the terrain fades into haze (e-folding, meters).
    public var hazeDistance = 45_000.0
    /// Terrain above this height is snow (meters), varied a little by noise. nil: no snow.
    public var snowLine: Double? = 3_100
    public var treeLine = 2_100.0
    /// Fraction of the sky covered by cloud, 0...1.
    public var clouds = 0.0
    /// Fraction of the image width with trees in the foreground, 0...1.
    public var trees = 0.0
    /// Standard deviation of sensor noise, in 0...255 units.
    public var noise = 3.0

    public init() {}
}

/// How a real phone camera departs from a perfect pinhole: what is left of the lens's
/// distortion after the phone corrects it, and rolling shutter (rows read top to bottom
/// while the phone turns).
public struct CameraRealism: Sendable, Equatable {
    /// Radial distortion: a point `r` from the center (in focal lengths) appears at
    /// r·(1 + k1·r²). Positive is pincushion, negative barrel. A few thousandths is typical
    /// of what remains in a phone's corrected picture.
    public var k1 = 0.0
    /// How far the heading turns while the frame is read out, degrees from the top row to
    /// the bottom one (positive turns right). The middle row has the camera's attitude.
    public var rollingShutter = 0.0

    public init(k1: Double = 0, rollingShutter: Double = 0) {
        self.k1 = k1
        self.rollingShutter = rollingShutter
    }

    public var isPinhole: Bool { k1 == 0 && rollingShutter == 0 }

    /// Where a pinhole pixel appears in the distorted picture.
    public func distort(x: Double, y: Double, _ k: CameraIntrinsics) -> (x: Double, y: Double) {
        let u = (x - k.cx) / k.fx, v = (y - k.cy) / k.fy
        let s = 1 + k1 * (u * u + v * v)
        return (k.cx + k.fx * u * s, k.cy + k.fy * v * s)
    }

    /// The pinhole pixel that appears at a pixel of the distorted picture.
    public func undistort(x: Double, y: Double, _ k: CameraIntrinsics) -> (x: Double, y: Double) {
        let ud = (x - k.cx) / k.fx, vd = (y - k.cy) / k.fy
        var u = ud, v = vd
        for _ in 0..<8 {
            let s = 1 + k1 * (u * u + v * v)
            u = ud / s
            v = vd / s
        }
        return (k.cx + k.fx * u, k.cy + k.fy * v)
    }

    /// The camera's heading when row `y` was read, degrees.
    public func heading(row y: Double, _ camera: Camera) -> Double {
        camera.attitude.heading + rollingShutter * (y / Double(camera.intrinsics.height) - 0.5)
    }
}

public enum SyntheticPhoto {
    public static func render(_ horizon: HorizonProfile, camera: Camera, scene: SyntheticScene = SyntheticScene(),
                              realism: CameraRealism = CameraRealism()) -> RGBImage {
        let k = camera.intrinsics
        let w = k.width, h = k.height
        let pinhole = camera.projector
        // With rolling shutter, each row has its own heading.
        let rowProjectors: [Camera.Projector] = realism.rollingShutter == 0 ? [] : (0..<h).map { y in
            var a = camera.attitude
            a.heading = realism.heading(row: Double(y) + 0.5, camera)
            return Camera(intrinsics: k, attitude: a).projector
        }
        var image = RGBImage(width: w, height: h)
        var rng = SplitMix64(seed: scene.seed)
        let noiseSeed = rng.next()
        let observerHeight = horizon.observer.height
        let curvature = (1 - horizon.settings.refraction) / (2 * 6_371_000.0)
        let treeTops = scene.trees > 0 ? treeProfile(width: w, height: h, coverage: scene.trees, rng: &rng) : nil

        for y in 0..<h {
            for x in 0..<w {
                let look: (azimuth: Double, elevation: Double)
                if realism.isPinhole {
                    look = pinhole.look(x: Double(x) + 0.5, y: Double(y) + 0.5)
                } else {
                    let p = realism.undistort(x: Double(x) + 0.5, y: Double(y) + 0.5, k)
                    look = (rowProjectors.isEmpty ? pinhole : rowProjectors[y]).look(x: p.x, y: p.y)
                }
                let skyline = horizon.elevation(atAzimuth: look.azimuth)
                var c: SIMD3<Double>
                if look.elevation > skyline {
                    // Sky: pale near the horizon, deeper blue higher up.
                    let t = max(0, min(1, look.elevation / 35))
                    c = mix(SIMD3(205, 218, 232), SIMD3(70, 118, 196), t)
                    if scene.clouds > 0 {
                        let n = fractalNoise(look.azimuth / 6, look.elevation / 2.5, seed: noiseSeed)
                        let cover = smoothstep(1 - scene.clouds - 0.1, 1 - scene.clouds + 0.15, n)
                        c = mix(c, SIMD3(238, 240, 244) - 40 * fractalNoise(look.azimuth, look.elevation, seed: noiseSeed &+ 7), cover)
                    }
                } else {
                    let d = horizon.distance(atAzimuth: look.azimuth, elevation: look.elevation) ?? 1_000
                    let pointHeight = observerHeight + d * tan(look.elevation * .pi / 180) + d * d * curvature
                    // Texture in ground meters, so far terrain is smoother, as in a photo.
                    let across = look.azimuth * .pi / 180 * d, up = look.elevation * .pi / 180 * d
                    let grain = fractalNoise(across / 40, up / 40, seed: noiseSeed &+ 3)
                    let rock = SIMD3<Double>(112, 102, 92) + 90 * (grain - 0.5)
                    let forest = SIMD3<Double>(56, 74, 50) + 50 * (grain - 0.5)
                    c = pointHeight < scene.treeLine ? forest : rock
                    if let snowLine = scene.snowLine {
                        // Snow lies on gentle slopes: there, a small step up in the image
                        // reaches much farther ground. Steep faces stay rock.
                        let step = 0.05
                        let ahead = horizon.distance(atAzimuth: look.azimuth, elevation: look.elevation + step) ?? d
                        let gentle = (ahead - d) / (d * step * .pi / 180) > 1.2
                        let line = snowLine + 500 * (fractalNoise(across / 400, up / 400, seed: noiseSeed &+ 5) - 0.5)
                        if gentle, pointHeight > line { c = SIMD3(236, 239, 244) - 50 * grain }
                    }
                    // Distance haze.
                    c = mix(c, SIMD3(176, 192, 212), 1 - exp(-d / scene.hazeDistance))
                }
                if let treeTops, Double(y) + 0.5 > treeTops[x] {
                    let n = fractalNoise(Double(x) / 3, Double(y) / 3, seed: noiseSeed &+ 11)
                    c = SIMD3(28, 42, 30) + 30 * (n - 0.5)
                }
                if scene.noise > 0 { c += scene.noise * SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()) }
                image.set(x, y, (clampByte(c.x), clampByte(c.y), clampByte(c.z)))
            }
        }
        return image
    }

    /// Paints buildings over a rendered photo. They stand still in the world as the camera
    /// turns, so frames of one pan see the same roofs, and the skyline only in the gaps.
    public static func occlude(_ image: inout RGBImage, camera: Camera, buildings: [Building],
                               realism: CameraRealism = CameraRealism()) {
        guard !buildings.isEmpty else { return }
        let k = camera.intrinsics
        let pinhole = camera.projector
        for y in 0..<k.height {
            var a = camera.attitude
            a.heading = realism.heading(row: Double(y) + 0.5, camera)
            let projector = realism.rollingShutter == 0 ? pinhole : Camera(intrinsics: k, attitude: a).projector
            for x in 0..<k.width {
                let p = realism.isPinhole ? (x: Double(x) + 0.5, y: Double(y) + 0.5)
                    : realism.undistort(x: Double(x) + 0.5, y: Double(y) + 0.5, k)
                let look = projector.look(x: p.x, y: p.y)
                for b in buildings {
                    let t = azimuthDifference(look.azimuth, b.from) / b.width
                    guard t >= 0, t <= 1, look.elevation < b.roof.left + t * (b.roof.right - b.roof.left) else { continue }
                    // Plain walls with a little texture, darker toward the bottom.
                    let n = fractalNoise(look.azimuth * 4, look.elevation * 4, seed: 23)
                    let v = Double(b.shade) * (0.8 + 0.2 * max(0, min(1, (look.elevation + 20) / 30))) + 20 * (n - 0.5)
                    image.set(x, y, (clampByte(v), clampByte(v * 0.96), clampByte(v * 0.9)))
                    break
                }
            }
        }
    }

    /// A building in front of the view: it hides everything below its roofline.
    public struct Building: Sendable {
        /// Its left edge's azimuth and how far clockwise it reaches, degrees.
        public var from: Double
        public var width: Double
        /// The roofline's elevation at its left and right edges, degrees.
        public var roof: (left: Double, right: Double)
        /// Wall brightness.
        public var shade: UInt8

        public init(from: Double, width: Double, roof: (left: Double, right: Double), shade: UInt8 = 120) {
            self.from = from
            self.width = width
            self.roof = roof
            self.shade = shade
        }
    }

    /// Top edge (y) of a band of conifers along the bottom of the image, per column.
    static func treeProfile(width w: Int, height h: Int, coverage: Double, rng: inout SplitMix64) -> [Double] {
        var tops = [Double](repeating: .infinity, count: w)
        var covered = 0
        while Double(covered) < coverage * Double(w) {
            let center = Double(rng.next() % UInt64(w))
            let halfWidth = Double(w) * (0.01 + 0.02 * rng.uniform())
            let top = Double(h) * (0.25 + 0.6 * rng.uniform())
            for x in max(0, Int(center - halfWidth))..<min(w, Int(center + halfWidth) + 1) {
                // A cone: straight sides up to a point.
                let t = abs(Double(x) - center) / halfWidth
                let y = top + t * (Double(h) - top) * 0.9
                if tops[x] == .infinity { covered += 1 }
                tops[x] = min(tops[x], y)
            }
        }
        return tops
    }
}

func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }

func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}

func clampByte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

/// Smooth value noise in 0...1, four octaves.
func fractalNoise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
    var sum = 0.0, amplitude = 0.5, frequency = 1.0, total = 0.0
    for octave in 0..<4 {
        sum += amplitude * valueNoise(x * frequency, y * frequency, seed: seed &+ UInt64(octave))
        total += amplitude
        amplitude *= 0.5
        frequency *= 2
    }
    return sum / total
}

func valueNoise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
    let xi = x.rounded(.down), yi = y.rounded(.down)
    let fx = x - xi, fy = y - yi
    let ix = Int64(xi), iy = Int64(yi)
    func lattice(_ a: Int64, _ b: Int64) -> Double {
        var z = seed &+ UInt64(bitPattern: a) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: b) &* 0xC2B2_AE3D_27D4_EB4F
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
    let a = lattice(ix, iy), b = lattice(ix + 1, iy), c = lattice(ix, iy + 1), d = lattice(ix + 1, iy + 1)
    return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
}

/// Small deterministic random number generator, so test scenes are reproducible.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Standard normal (Box–Muller).
    public mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

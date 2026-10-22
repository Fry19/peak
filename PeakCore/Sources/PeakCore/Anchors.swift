import Foundation

/// A summit marked by hand in a photo: where it is in the world and where it is in the image.
public struct Anchor: Codable, Sendable {
    public var name: String?
    public var latitude: Double
    public var longitude: Double
    /// Summit elevation from the peak database, meters.
    public var elevation: Double
    /// Pixel position of the summit in the full-size photo.
    public var x: Double
    public var y: Double
    /// False for a proposed position (`AnchorSuggester`) nobody has checked yet; such anchors
    /// must not be used as truth, since they come from the very match being measured. Nil
    /// (marked by hand) and true count as checked.
    public var confirmed: Bool?

    public init(name: String? = nil, latitude: Double, longitude: Double, elevation: Double, x: Double, y: Double,
                confirmed: Bool? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.x = x
        self.y = y
        self.confirmed = confirmed
    }

    /// Checked by a person: marked by hand, or proposed and then confirmed.
    public var isChecked: Bool { confirmed != false }
}

/// Proposes where named summits are in a photo, so marking anchors means confirming or
/// nudging them rather than typing pixels.
public enum AnchorSuggester {
    /// Anchors for the visible peaks with a surveyed elevation that fall inside the picture taken by `camera`, at
    /// least `margin` pixels in from its edges, unconfirmed. Where two would land within
    /// `minSeparation` pixels of each other, only the higher-ranked one is kept. Peaks are
    /// ranked by prominence when known, then by how high they stand in the view; at most
    /// `limit` are returned, left to right.
    public static func suggest(_ peaks: [VisiblePeak], camera: Camera, margin: Double = 8, minSeparation: Double = 30,
                               limit: Int = 12) -> [Anchor] {
        let projector = camera.projector
        let k = camera.intrinsics
        let placed: [(peak: VisiblePeak, x: Double, y: Double)] = peaks.compactMap { v in
            // An elevation taken from the terrain is no good for measuring against.
            guard !v.peak.estimatedElevation, let p = projector.pixel(azimuth: v.azimuth, elevation: v.elevation),
                  p.x >= margin, p.y >= margin, p.x <= Double(k.width) - margin, p.y <= Double(k.height) - margin else { return nil }
            return (v, p.x, p.y)
        }
        let ranked = placed.sorted {
            ($0.peak.peak.prominence ?? 0, $0.peak.elevation) > ($1.peak.peak.prominence ?? 0, $1.peak.elevation)
        }
        var kept: [(peak: VisiblePeak, x: Double, y: Double)] = []
        for p in ranked where kept.count < limit {
            if kept.contains(where: { ($0.x - p.x) * ($0.x - p.x) + ($0.y - p.y) * ($0.y - p.y) < minSeparation * minSeparation }) {
                continue
            }
            kept.append(p)
        }
        return kept.sorted { $0.x < $1.x }.map {
            Anchor(name: $0.peak.peak.name, latitude: $0.peak.peak.latitude, longitude: $0.peak.peak.longitude,
                   elevation: $0.peak.peak.elevation, x: ($0.x * 10).rounded() / 10, y: ($0.y * 10).rounded() / 10,
                   confirmed: false)
        }
    }
}

/// Works out the true camera attitude of a real photo from marked summits, to measure
/// heading error without a survey. One anchor fixes heading and pitch (roll stays as
/// given); two or more fix all three.
public enum AnchorSolver {
    /// A summit's direction (apparent, with refraction, degrees) and the pixel it's marked at.
    public struct Mark: Equatable, Sendable {
        public var azimuth: Double
        public var elevation: Double
        public var x: Double
        public var y: Double

        public init(azimuth: Double, elevation: Double, x: Double, y: Double) {
            self.azimuth = azimuth
            self.elevation = elevation
            self.x = x
            self.y = y
        }
    }

    public static func attitude(anchors: [Anchor], observer: GeoPoint, intrinsics k: CameraIntrinsics,
                                initial: Attitude, refraction: Double = 0.13) -> (attitude: Attitude, rmsPixels: Double)? {
        let frame = LocalFrame(origin: observer)
        let marks = anchors.map {
            let look = frame.look(at: GeoPoint(latitude: $0.latitude, longitude: $0.longitude, height: $0.elevation),
                                  refraction: refraction)
            return Mark(azimuth: look.azimuth, elevation: look.elevation, x: $0.x, y: $0.y)
        }
        return attitude(marks: marks, intrinsics: k, initial: initial)
    }

    /// What a solve may change: the heading alone (pitch and roll as `initial` has them),
    /// heading and pitch, or all three.
    public enum Free: Int, Sendable {
        case heading = 1, headingAndPitch, all
    }

    /// The attitude that puts each summit on its mark, or as near as `free` allows, with
    /// the rest as `initial` has it. `nil` for `free` is the photo anchors' rule: one mark
    /// fixes heading and pitch, two or more all three.
    public static func attitude(marks: [Mark], intrinsics k: CameraIntrinsics, initial: Attitude,
                                free: Free? = nil) -> (attitude: Attitude, rmsPixels: Double)? {
        guard let first = marks.first else { return nil }
        let free = (free ?? (marks.count >= 2 ? .all : .headingAndPitch)).rawValue
        // Start with the first mark straight on its pixel, ignoring roll (and pitch, if it's
        // to stay).
        var q = [
            first.azimuth - atan((first.x - k.cx) / k.fx) * 180 / .pi,
            free >= 2 ? first.elevation + atan((first.y - k.cy) / k.fy) * 180 / .pi : initial.pitch,
            initial.roll,
        ]

        func residuals(_ q: [Double]) -> [Double]? {
            let projector = Camera(intrinsics: k, attitude: Attitude(heading: q[0], pitch: q[1], roll: q[2])).projector
            var r: [Double] = []
            for m in marks {
                guard let p = projector.pixel(azimuth: m.azimuth, elevation: m.elevation) else { return nil }
                r.append(p.x - m.x)
                r.append(p.y - m.y)
            }
            return r
        }

        guard var r = residuals(q) else { return nil }
        for _ in 0..<50 {
            var jac = [[Double]]()
            for j in 0..<free {
                var qp = q, qm = q
                qp[j] += 1e-4
                qm[j] -= 1e-4
                guard let rp = residuals(qp), let rm = residuals(qm) else { return nil }
                jac.append(zip(rp, rm).map { ($0 - $1) / 2e-4 })
            }
            var a = [[Double]](repeating: [Double](repeating: 0, count: free), count: free)
            var g = [Double](repeating: 0, count: free)
            for i in r.indices {
                for j in 0..<free {
                    g[j] -= jac[j][i] * r[i]
                    for l in 0..<free { a[j][l] += jac[j][i] * jac[l][i] }
                }
            }
            for j in 0..<free { a[j][j] *= 1 + 1e-9 }
            guard let step = solve(a, g) else { break }
            for j in 0..<free { q[j] += step[j] }
            guard let next = residuals(q) else { return nil }
            r = next
            if step.map(abs).max()! < 1e-7 { break }
        }
        let rms = (r.reduce(0) { $0 + $1 * $1 } / Double(marks.count)).squareRoot()
        return (Attitude(heading: normalizedAzimuth(q[0]), pitch: q[1], roll: q[2]), rms)
    }
}

/// Summits a person has pinned where they really are in a still view, to fix its heading
/// (and with two, its tilt) by hand. Each pin keeps where it was marked as a direction
/// through the lens (x and y over the focal length, from the principal point), so zooming
/// the view leaves it on the same spot of the picture.
public struct SummitPins: Sendable {
    public struct Pin: Identifiable, Equatable, Sendable {
        /// The peak's id.
        public var id: Int64
        public var name: String
        /// The summit's apparent direction, degrees, as its label is drawn.
        public var azimuth: Double
        public var elevation: Double
        /// Where it was marked: (x − cx) / fx and (y − cy) / fy.
        public var u: Double
        public var v: Double

        public init(id: Int64, name: String, azimuth: Double, elevation: Double, u: Double, v: Double) {
            self.id = id
            self.name = name
            self.azimuth = azimuth
            self.elevation = elevation
            self.u = u
            self.v = v
        }

        /// Pinned at pixel (x, y) of a view with intrinsics `k`.
        public init(_ peak: VisiblePeak, x: Double, y: Double, intrinsics k: CameraIntrinsics) {
            self.init(id: peak.id, name: peak.peak.name, azimuth: peak.azimuth, elevation: peak.elevation,
                      u: (x - k.cx) / k.fx, v: (y - k.cy) / k.fy)
        }

        public func pixel(_ k: CameraIntrinsics) -> (x: Double, y: Double) {
            (k.cx + k.fx * u, k.cy + k.fy * v)
        }
    }

    /// Pinned summits, oldest first.
    public private(set) var pins: [Pin] = []
    /// The attitude before the first pin, to go back to once the last is taken away.
    public private(set) var before: Attitude?

    public init() {}

    public var isEmpty: Bool { pins.isEmpty }

    /// Pins a summit, or moves its pin. `current` is the view's attitude now.
    public mutating func pin(_ pin: Pin, current: Attitude) {
        if pins.isEmpty { before = current }
        if let i = pins.firstIndex(where: { $0.id == pin.id }) { pins[i] = pin } else { pins.append(pin) }
    }

    /// Takes a pin away; the view goes back to `before` once none are left.
    public mutating func remove(_ id: Int64) {
        pins.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        pins = []
        before = nil
    }

    /// Summits closer together than this, degrees, can't tell a tilt from a slip of the
    /// finger: the heading alone fits them.
    public static let tiltSpread = 3.0
    /// The phone's own level is good to a degree or two: a tilt beyond this, degrees, means
    /// the pins don't fit one view.
    public static let maxTilt = 5.0
    /// Pins left this far off their marks, as a share of the focal length (about 0.7°),
    /// don't fit one view either.
    public static let misfit = 0.012

    /// The attitude that puts the pinned summits on their pins in a view with intrinsics `k`,
    /// solved from the attitude before the first pin so the order they were placed in doesn't
    /// matter. One pin moves the heading only; two far enough apart fix the tilt too. With no
    /// pins it's the attitude before the first. `misfit` is true when the pins can't all be met
    /// (likely a wrong pick); the heading then fits them as well as it can and the tilt stays.
    /// `tilt` is whether the pins set the tilt; `allowTilt` false keeps it as it was before
    /// the first pin (where the view can't take the tilt they'd set).
    public func solve(intrinsics k: CameraIntrinsics, allowTilt: Bool = true) -> (attitude: Attitude, misfit: Bool, tilt: Bool)? {
        guard let before else { return nil }
        guard !pins.isEmpty else { return (before, false, false) }
        let marks = pins.map { p -> AnchorSolver.Mark in
            let px = p.pixel(k)
            return AnchorSolver.Mark(azimuth: p.azimuth, elevation: p.elevation, x: px.x, y: px.y)
        }
        let spread = pins.flatMap { a in
            pins.map { b in
                hypot(azimuthDifference(a.azimuth, b.azimuth) * cos((a.elevation + b.elevation) / 2 * .pi / 180),
                      a.elevation - b.elevation)
            }
        }.max() ?? 0
        guard let headingOnly = AnchorSolver.attitude(marks: marks, intrinsics: k, initial: before, free: .heading)?.attitude
        else { return nil }
        // One pin can't disagree with itself: the pitch kept may leave it a little above or
        // below its summit, which says nothing about the pick.
        guard pins.count >= 2 else { return (headingOnly, false, false) }
        let limit = Self.misfit * k.fx
        guard spread >= Self.tiltSpread, allowTilt else {
            // Too close to set the tilt: they still have to agree once the pitch is allowed for.
            let fit = AnchorSolver.attitude(marks: marks, intrinsics: k, initial: before, free: .headingAndPitch)
            return (headingOnly, (fit?.rmsPixels ?? .infinity) > limit, false)
        }
        guard let s = AnchorSolver.attitude(marks: marks, intrinsics: k, initial: before, free: .all),
              s.rmsPixels <= limit, abs(s.attitude.pitch - before.pitch) <= Self.maxTilt,
              abs(s.attitude.roll - before.roll) <= Self.maxTilt else { return (headingOnly, true, false) }
        return (s.attitude, false, true)
    }

    /// Visible peaks that could be the one at pixel (x, y) of `camera`'s view, likeliest
    /// first. The compass may be well off, so a summit can be far to either side of where the
    /// view now draws it, but its elevation (from the phone's level) is close: peaks are
    /// ranked by how far their drawn summit is from (x, y), with sideways distance counting a
    /// quarter as much, within `maxTurn` degrees to either side.
    public static func candidates(_ peaks: [VisiblePeak], camera: Camera, x: Double, y: Double,
                                  maxTurn: Double = 25, limit: Int = 6) -> [VisiblePeak] {
        let projector = camera.projector
        let look = projector.look(x: x, y: y)
        let ranked: [(peak: VisiblePeak, cost: Double)] = peaks.compactMap { v in
            let turn = azimuthDifference(v.azimuth, look.azimuth)
            guard abs(turn) <= maxTurn else { return nil }
            let rise = v.elevation - look.elevation
            // Elevation is off by a few degrees at most (the level, a sloppy tap).
            guard abs(rise) <= 4 else { return nil }
            return (v, hypot(turn / 4, rise))
        }
        return ranked.sorted { ($0.cost, -($0.peak.peak.prominence ?? 0)) < ($1.cost, -($1.peak.peak.prominence ?? 0)) }
            .prefix(limit).map(\.peak)
    }
}

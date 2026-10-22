import Foundation

/// Where the sun is in the sky, without the atmosphere: azimuth and geometric elevation of
/// its center.
public struct SunPosition: Sendable, Equatable {
    /// Degrees clockwise from true north.
    public var azimuth: Double
    /// Geometric elevation of the sun's center, degrees, before refraction.
    public var elevation: Double
    public var declination: Double
    /// Apparent solar time minus mean solar time, minutes.
    public var equationOfTime: Double
    /// Earth–sun distance, astronomical units.
    public var distance: Double

    /// The sun's angular radius, degrees (about 0.267°).
    public var semidiameter: Double { 0.26656 / distance }
}

/// The sun's position by the NOAA solar calculator's algorithm (Meeus, *Astronomical
/// Algorithms*, low-precision series): about 0.01° from 1800 to 2100.
///
/// Refraction is modelled to agree with the horizon renderer. The renderer gives the
/// terrain's *apparent* elevation: the direction a ray grazing it arrives from at the eye,
/// bent along the way with coefficient k (0.13). The sun is hidden when its apparent
/// elevation is below the terrain's along the same azimuth, since then the ray that would
/// carry its light runs into the ground. So the sun's apparent elevation is its geometric
/// one plus the refraction of the whole path through the air (`refraction(apparent:)`),
/// and the two are compared directly. Near and below the observer's level that path dips
/// toward a lowest point before climbing out, and the part between the eye and that point
/// bends by k, as in the renderer.
public enum Sun {
    /// The sun's position seen from (latitude, longitude) at `date`.
    public static func position(at date: Date, latitude: Double, longitude: Double) -> SunPosition {
        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545) / 36_525
        let rad = Double.pi / 180

        let l0 = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(m * rad) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m * rad) * (0.019993 - 0.000101 * t) + sin(3 * m * rad) * 0.000289
        let trueLongitude = l0 + c
        let trueAnomaly = m + c
        let distance = 1.000001018 * (1 - e * e) / (1 + e * cos(trueAnomaly * rad))
        let omega = 125.04 - 1_934.136 * t
        let lambda = trueLongitude - 0.00569 - 0.00478 * sin(omega * rad)
        let seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
        let epsilon = 23 + (26 + seconds / 60) / 60 + 0.00256 * cos(omega * rad)
        let declination = asin(sin(epsilon * rad) * sin(lambda * rad))

        var y = tan(epsilon * rad / 2)
        y *= y
        let l0r = l0 * rad, mr = m * rad
        let eot = 4 / rad * (y * sin(2 * l0r) - 2 * e * sin(mr) + 4 * e * y * sin(mr) * cos(2 * l0r)
            - 0.5 * y * y * sin(4 * l0r) - 1.25 * e * e * sin(2 * mr))

        // True solar time and the hour angle, from UTC.
        let minutes = (jd + 0.5).truncatingRemainder(dividingBy: 1) * 1_440
        let solarTime = minutes + eot + 4 * longitude
        let hourAngle = (solarTime / 4 - 180) * rad
        let phi = latitude * rad
        let sinElevation = sin(phi) * sin(declination) + cos(phi) * cos(declination) * cos(hourAngle)
        let elevation = asin(max(-1, min(1, sinElevation)))
        // Clockwise from north: atan2 of the east and north components of the direction.
        let east = -cos(declination) * sin(hourAngle)
        let north = cos(phi) * sin(declination) - sin(phi) * cos(declination) * cos(hourAngle)
        let azimuth = normalizedAzimuth(atan2(east, north) / rad)
        return SunPosition(azimuth: azimuth, elevation: elevation / rad, declination: declination / rad,
                           equationOfTime: eot, distance: distance)
    }

    /// Air density at `height` meters relative to sea level, in the standard atmosphere.
    static func densityRatio(height: Double) -> Double {
        pow(max(0.05, 1 - 2.25577e-5 * max(0, height)), 4.25588)
    }

    /// Bennett's refraction at apparent elevation `e` ≥ 0 (degrees) at sea level, standard
    /// conditions (1013 hPa, 15 °C).
    static func bennett(_ e: Double) -> Double {
        0.9870 / 60 / tan((e + 7.31 / (e + 4.4)) * .pi / 180)
    }

    /// How much the atmosphere lifts something seen at apparent elevation `apparent`
    /// (degrees) from an eye `height` meters above sea level, degrees.
    ///
    /// At or above the eye's level: Bennett's formula, scaled by the air's density at the
    /// eye. Below it (only from a height), the ray first descends to a lowest point
    /// h − R′δ²/2 below the eye, where R′ = R/(1 − k) and δ is the depression. From there
    /// out it is a horizontal ray at that height, and between it and the eye the path bends
    /// as in the horizon renderer, by k·δ/(1 − k).
    public static func refraction(apparent: Double, height: Double = 0, k: Double = 0.13) -> Double {
        if apparent >= 0 { return bennett(apparent) * densityRatio(height: height) }
        let depression = -apparent * .pi / 180
        let lowest = height - 6_371_000 / (1 - k) * depression * depression / 2
        return bennett(0) * densityRatio(height: lowest) + k * -apparent / (1 - k)
    }

    /// Apparent elevation of something at geometric elevation `elevation` (degrees), seen
    /// from `height` meters above sea level. Far below any horizon (under −10°) it's left as is.
    public static func apparentElevation(_ elevation: Double, height: Double = 0, k: Double = 0.13) -> Double {
        guard elevation > -10 else { return elevation }
        var apparent = elevation + refraction(apparent: max(elevation, -5), height: height, k: k)
        for _ in 0..<8 {
            apparent = elevation + refraction(apparent: apparent, height: height, k: k)
        }
        return apparent
    }
}

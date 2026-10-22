import Foundation

/// How far magnetic north is from true north (east positive), for turning a magnetic
/// compass heading into a true one: heading_true = heading_magnetic + declination.
///
/// The International Geomagnetic Reference Field (IGRF-13, epoch 2020) to degree 8, with
/// its secular variation, on a spherical earth. Good to a few tenths of a degree away from
/// the poles and local anomalies, which is far inside what skyline matching corrects.
public enum MagneticDeclination {
    /// Degrees, east of true north positive.
    public static func degrees(latitude: Double, longitude: Double, date: Date) -> Double {
        let year = 1970 + date.timeIntervalSince1970 / (365.25 * 86_400)
        let t = max(-5, min(10, year - 2020))
        let theta = (90 - max(-89.9, min(89.9, latitude))) * .pi / 180
        let phi = longitude * .pi / 180
        // The field's north and east parts are the potential's slopes: north = ∂V/∂θ,
        // east = −∂V/∂φ / sin θ (with B = −∇V and θ the colatitude, growing southward).
        let h = 1e-6
        let north = (potential(theta + h, phi, t) - potential(theta - h, phi, t)) / (2 * h)
        let east = -(potential(theta, phi + h, t) - potential(theta, phi - h, t)) / (2 * h) / sin(theta)
        return atan2(east, north) * 180 / .pi
    }

    /// The scalar potential on the earth's surface, over the reference radius, nT.
    private static func potential(_ theta: Double, _ phi: Double, _ t: Double) -> Double {
        let x = cos(theta), s = sin(theta)
        var v = 0.0
        for c in coefficients {
            let g = c.g + c.dg * t, hh = c.h + c.dh * t
            v += (g * cos(Double(c.m) * phi) + hh * sin(Double(c.m) * phi)) * schmidt(c.n, c.m, x, s)
        }
        return v
    }

    /// Schmidt semi-normalized associated Legendre function P_n^m(cos θ).
    private static func schmidt(_ n: Int, _ m: Int, _ x: Double, _ s: Double) -> Double {
        // P_m^m = (2m − 1)!! sin^m θ, then up in degree.
        var pmm = 1.0
        for i in stride(from: 1, through: 2 * m - 1, by: 2) { pmm *= Double(i) }
        pmm *= pow(s, Double(m))
        var p: Double
        if n == m {
            p = pmm
        } else {
            var a = pmm, b = x * Double(2 * m + 1) * pmm
            for l in stride(from: m + 2, through: n, by: 1) {
                let c = (Double(2 * l - 1) * x * b - Double(l + m - 1) * a) / Double(l - m)
                a = b
                b = c
            }
            p = b
        }
        guard m > 0 else { return p }
        var ratio = 1.0   // (n − m)! / (n + m)!
        for i in (n - m + 1)...(n + m) { ratio /= Double(i) }
        return p * (2 * ratio).squareRoot()
    }

    private struct Coefficient {
        var n: Int
        var m: Int
        var g: Double
        var h: Double
        var dg: Double
        var dh: Double
    }

    /// IGRF-13 main field for 2020 (nT) and its yearly change, degree 1–8.
    private static let coefficients: [Coefficient] = [
        (1, 0, -29404.8, 0, 5.7, 0), (1, 1, -1450.9, 4652.5, 7.4, -25.9),
        (2, 0, -2499.6, 0, -11.0, 0), (2, 1, 2982.0, -2991.6, -7.0, -30.2), (2, 2, 1677.0, -734.6, -2.1, -22.4),
        (3, 0, 1363.2, 0, 2.2, 0), (3, 1, -2381.2, -82.1, -5.9, 6.0), (3, 2, 1236.2, 241.9, 3.1, -1.1),
        (3, 3, 525.7, -543.4, -12.0, 0.5),
        (4, 0, 903.0, 0, -1.2, 0), (4, 1, 809.5, 281.9, -1.6, -0.1), (4, 2, 86.3, -158.4, -5.9, 6.5),
        (4, 3, -309.4, 199.7, 5.2, 3.6), (4, 4, 48.0, -349.7, -5.1, -5.0),
        (5, 0, -234.3, 0, -0.3, 0), (5, 1, 363.2, 47.7, 0.5, 0.0), (5, 2, 187.8, 208.3, -0.6, 2.5),
        (5, 3, -140.7, -121.2, 0.2, -0.6), (5, 4, -151.2, 32.3, 1.3, 3.0), (5, 5, 13.5, 98.9, 0.9, 0.3),
        (6, 0, 66.0, 0, -0.5, 0), (6, 1, 65.5, -19.1, -0.3, 0.0), (6, 2, 72.9, 25.1, 0.4, -1.6),
        (6, 3, -121.5, 52.8, 1.3, -1.3), (6, 4, -36.2, -64.5, -1.4, 0.8), (6, 5, 13.5, 8.9, 0.0, 0.0),
        (6, 6, -64.7, 68.1, 0.9, 1.0),
        (7, 0, 80.6, 0, -0.1, 0), (7, 1, -76.7, -51.5, -0.2, 0.6), (7, 2, -8.2, -16.9, 0.0, 0.6),
        (7, 3, 56.5, 2.2, 0.7, -0.8), (7, 4, 15.8, 23.5, 0.1, -0.2), (7, 5, 6.4, -2.2, -0.5, -1.1),
        (7, 6, -7.2, -27.2, -0.8, 0.1), (7, 7, 9.8, -1.8, 0.8, 0.3),
        (8, 0, 23.7, 0, 0.0, 0), (8, 1, 9.7, 8.4, 0.1, -0.2), (8, 2, -17.6, -15.3, -0.1, 0.6),
        (8, 3, -0.5, 12.8, 0.4, -0.2), (8, 4, -21.1, -11.7, -0.1, 0.5), (8, 5, 15.3, 14.9, 0.4, -0.3),
        (8, 6, 13.7, 3.6, 0.3, -0.4), (8, 7, -16.5, -6.9, -0.1, 0.5), (8, 8, -0.3, 2.8, 0.4, 0.0),
    ].map { Coefficient(n: $0.0, m: $0.1, g: $0.2, h: $0.3, dg: $0.4, dh: $0.5) }
}

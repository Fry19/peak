import Foundation
@testable import PeakCore

/// Procedural terrain for tests, built from simple shapes whose geometry is known exactly.
enum TestTerrain {
    struct Cone {
        var latitude: Double
        var longitude: Double
        var height: Double
        var radius: Double
    }

    /// Flat ground at `base` meters with cones on it, as a 2×2 block of 1° tiles
    /// (south-west corner at 45°N 7°E) at 6 arc-second spacing.
    static func cones(_ cones: [Cone], base: Double = 500, size: Int = 600) -> Terrain {
        let tiles = [(45, 7), (45, 8), (46, 7), (46, 8)].map { south, west in
            ElevationTile(south: south, west: west, size: size) { lat, lon in
                var h = base
                for c in cones {
                    let dy = (lat - c.latitude) * 111_200
                    let dx = (lon - c.longitude) * 111_200 * cos(c.latitude * .pi / 180)
                    let r = (dx * dx + dy * dy).squareRoot()
                    if r < c.radius { h = max(h, base + c.height * (1 - r / c.radius)) }
                }
                return h
            }
        }
        return Terrain(tiles: tiles)
    }

    /// A mountain range: many cones with varied sizes, seeded so it is reproducible.
    static func range(seed: UInt64 = 7, count: Int = 60) -> Terrain {
        var rng = SplitMix64(seed: seed)
        var list: [Cone] = []
        for _ in 0..<count {
            list.append(Cone(latitude: 45.2 + 1.6 * rng.uniform(), longitude: 7.2 + 1.6 * rng.uniform(),
                             height: 600 + 2_600 * rng.uniform(), radius: 2_500 + 6_000 * rng.uniform()))
        }
        return cones(list)
    }

    static let center = GeoPoint(latitude: 46, longitude: 8)
}

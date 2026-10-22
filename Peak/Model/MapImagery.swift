import MapKit
import PeakCore
import UIKit

/// Satellite imagery for the map from above, from Apple Maps, laid onto the map's own
/// north-up meters so the trail sits exactly where it is on the picture. Needs a connection;
/// the map is drawn from the terrain without it.
struct MapImagery: @unchecked Sendable {
    let image: CGImage
    /// Where the picture's edges lie on the map, meters east and north of `center`.
    let rect: CGRect
    let center: LatLon

    enum Failure: Error {
        case noImage
    }

    /// The imagery for `rect` (map meters around `projection`'s center), `width` pixels across.
    @MainActor static func load(projection: MapProjection, rect: CGRect, width: Int) async throws -> MapImagery {
        let northWest = projection.latLon(SIMD2(rect.minX, rect.maxY))
        let southEast = projection.latLon(SIMD2(rect.maxX, rect.minY))
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: northWest.latitude, longitude: northWest.longitude))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: southEast.latitude, longitude: southEast.longitude))
        let mapRect = MKMapRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)

        let scale = 2.0
        let options = MKMapSnapshotter.Options()
        options.mapRect = mapRect
        options.size = CGSize(width: Double(width) / scale, height: Double(width) / scale * mapRect.height / mapRect.width)
        options.traitCollection = UITraitCollection(displayScale: scale)
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        // A cancelled task stops the download too: the walk asks again as it moves on.
        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await withTaskCancellationHandler {
            // The operation still runs if cancellation preceded the handler's registration.
            try Task.checkCancellation()
            return try await snapshotter.start()
        } onCancel: {
            snapshotter.cancel()
        }
        try Task.checkCancellation()
        guard let source = snapshot.image.cgImage else { throw Failure.noImage }

        // Where the corners and each strip's top and bottom are on the snapshot, in pixels.
        let pixels = Double(source.width) / snapshot.image.size.width
        func onSnapshot(_ p: LatLon) -> CGPoint {
            let s = snapshot.point(for: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
            return CGPoint(x: s.x * pixels, y: s.y * pixels)
        }
        let left = onSnapshot(northWest).x, right = onSnapshot(southEast).x
        let strips = max(1, Int((rect.height / 4_000).rounded(.up)))
        let edges = (0...strips).map { i -> (map: Double, snapshot: Double) in
            let y = rect.maxY - rect.height * Double(i) / Double(strips)
            return (y, onSnapshot(projection.latLon(SIMD2(rect.midX, y))).y)
        }
        let imagery = try await Task.detached(priority: .userInitiated) {
            try reproject(source, rect: rect, center: projection.center, width: width, left: left, right: right, edges: edges)
        }.value
        try Task.checkCancellation()
        return imagery
    }

    /// Apple's imagery is Web Mercator, stretched north–south away from the equator; the map
    /// is spaced evenly by latitude. Drawn in strips a few kilometers high, each stretched to
    /// fit, the two agree to well under a meter.
    private static func reproject(_ source: CGImage, rect: CGRect, center: LatLon, width: Int, left: Double, right: Double,
                                  edges: [(map: Double, snapshot: Double)]) throws -> MapImagery {
        let height = max(1, Int((Double(width) * rect.height / rect.width).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.noImage }
        context.interpolationQuality = .high
        let sx = Double(width) / (right - left)
        let x = -left * sx, w = Double(source.width) * sx
        // From map meters north to the context's y, which counts up from the bottom.
        let py = Double(height) / rect.height
        for (top, bottom) in zip(edges, edges.dropFirst()) {
            let y0 = (top.map - rect.minY) * py, y1 = (bottom.map - rect.minY) * py
            let sy = (y0 - y1) / (bottom.snapshot - top.snapshot)
            context.saveGState()
            // A pixel into the strip above, drawn already, so the row where they meet is
            // covered whole instead of half by each, which would leave a faint line.
            context.clip(to: CGRect(x: 0, y: y1, width: Double(width), height: y0 - y1 + 1))
            // The whole snapshot, placed so this strip's rows land between y1 and y0.
            let imageTop = y0 + top.snapshot * sy
            let h = Double(source.height) * sy
            context.draw(source, in: CGRect(x: x, y: imageTop - h, width: w, height: h))
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw Failure.noImage }
        return MapImagery(image: image, rect: rect, center: center)
    }
}

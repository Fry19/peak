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

    /// The imagery for `rect` (map meters around `projection`'s center), `width` pixels across,
    /// drawn `scale` pixels a point. Apple picks which of its mosaics to draw by how much ground
    /// a point covers (`aerialMetersPerPoint`): at 1, a picture as coarse as its aerial photos
    /// allow still shows them, where at 2 it would be the coarser mosaic.
    @MainActor static func load(projection: MapProjection, rect: CGRect, width: Int, scale: Double = 2) async throws -> MapImagery {
        let northWest = projection.latLon(SIMD2(rect.minX, rect.maxY))
        let southEast = projection.latLon(SIMD2(rect.maxX, rect.minY))
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: northWest.latitude, longitude: northWest.longitude))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: southEast.latitude, longitude: southEast.longitude))
        let mapRect = MKMapRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)

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

    // MARK: Apple's mosaics

    /// The most ground a snapshot's point may cover at `latitude`, meters, for Apple's aerial
    /// photos. Coarser than its zoom level 14 (19.1 m × cos(latitude) at level 13), Apple
    /// serves another mosaic, greener and softer: measured on Kuwohi and around Zermatt, the
    /// photos up to 12 m a point, the other from 16 m. With some room to spare.
    static func aerialMetersPerPoint(at latitude: Double) -> Double {
        0.8 * 19.1 * cos(latitude * .pi / 180)
    }

    /// These colors brought to `reference`'s where the two overlap, channel by channel, to the
    /// same mean and nearly the same spread: coarse imagery is Apple's greener mosaic, and
    /// beside its aerial photos it reads as ground half loaded. The reference is drawn at this
    /// picture's coarseness first, so its finer detail doesn't count as contrast; the spread
    /// changes by at most a third either way. Unchanged without enough overlap or variation.
    func matched(to reference: MapImagery) -> MapImagery {
        guard reference.center == center else { return self }
        let overlap = rect.intersection(reference.rect)
        let perMeter = Double(image.width) / rect.width
        let cols = Int(overlap.width * perMeter), rows = Int(overlap.height * perMeter)
        guard !overlap.isNull, cols >= 16, rows >= 16, var mine = Bitmap(image),
              let theirs = Bitmap(reference.image, width: cols, height: rows, placing: reference.rect, over: overlap) else { return self }
        var a = [[Double]](repeating: [], count: 3), b = [[Double]](repeating: [], count: 3)
        let step = max(1, max(cols, rows) / 64)
        for row in stride(from: 0, to: rows, by: step) {
            for col in stride(from: 0, to: cols, by: step) {
                let p = SIMD2(overlap.minX + (Double(col) + 0.5) / perMeter, overlap.maxY - (Double(row) + 0.5) / perMeter)
                guard let here = mine.pixel(at: p, in: rect),
                      let there = theirs.pixel(col: col, row: row) else { continue }
                for c in 0..<3 {
                    a[c].append(here[c])
                    b[c].append(there[c])
                }
            }
        }
        guard a[0].count >= 100 else { return self }
        var lut = [[UInt8]](repeating: [], count: 3)
        for c in 0..<3 {
            func stats(_ v: [Double]) -> (mean: Double, spread: Double) {
                let mean = v.reduce(0, +) / Double(v.count)
                return (mean, (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)).squareRoot())
            }
            let from = stats(a[c]), to = stats(b[c])
            let gain = from.spread > 2 ? min(1.33, max(0.75, to.spread / from.spread)) : 1
            lut[c] = (0..<256).map { UInt8(max(0, min(255, (Double($0) - from.mean) * gain + to.mean)).rounded()) }
        }
        mine.apply(lut)
        guard let image = mine.image() else { return self }
        return MapImagery(image: image, rect: rect, center: center)
    }

    /// A picture's pixels, RGBA, row 0 at the north edge.
    private struct Bitmap {
        var data: [UInt8]
        let width: Int
        let height: Int

        /// The whole picture, pixel for pixel.
        init?(_ image: CGImage) {
            self.init(image, width: image.width, height: image.height, placing: CGRect(x: 0, y: 0, width: 1, height: 1),
                      over: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        /// `image`, which covers `extent` (map meters), drawn `width` × `height` pixels over
        /// `area`, averaging where it's finer.
        init?(_ image: CGImage, width: Int, height: Int, placing extent: CGRect, over area: CGRect) {
            self.width = width
            self.height = height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let sx = Double(width) / area.width, sy = Double(height) / area.height
            let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                // The context's y counts up from the bottom, as map meters do northward.
                context.draw(image, in: CGRect(x: (extent.minX - area.minX) * sx, y: (extent.minY - area.minY) * sy,
                                               width: extent.width * sx, height: extent.height * sy))
                return true
            }
            guard drawn else { return nil }
            self.data = data
        }

        func pixel(col: Int, row: Int) -> SIMD3<Double>? {
            let i = 4 * (row * width + col)
            // Transparent snapshot/reprojection edges aren't terrain colors.
            guard data[i + 3] == 255 else { return nil }
            return SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
        }

        func pixel(at p: SIMD2<Double>, in rect: CGRect) -> SIMD3<Double>? {
            let col = Int((p.x - rect.minX) / rect.width * Double(width))
            let row = Int((rect.maxY - p.y) / rect.height * Double(height))
            guard col >= 0, row >= 0, col < width, row < height else { return nil }
            return pixel(col: col, row: row)
        }

        mutating func apply(_ lut: [[UInt8]]) {
            data.withUnsafeMutableBufferPointer { p in
                for i in stride(from: 0, to: p.count, by: 4) {
                    let alpha = Int(p[i + 3])
                    if alpha == 255 {
                        p[i] = lut[0][Int(p[i])]
                        p[i + 1] = lut[1][Int(p[i + 1])]
                        p[i + 2] = lut[2][Int(p[i + 2])]
                        continue
                    }
                    guard alpha > 0 else { continue }
                    for c in 0..<3 {
                        // The LUT is for straight RGB; keep the stored RGB premultiplied.
                        let straight = min(255, (Int(p[i + c]) * 255 + alpha / 2) / alpha)
                        p[i + c] = UInt8((Int(lut[c][straight]) * alpha + 127) / 255)
                    }
                }
            }
        }

        func image() -> CGImage? {
            CGDataProvider(data: Data(data) as CFData).flatMap {
                CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
    }
}

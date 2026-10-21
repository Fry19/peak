import Foundation

/// Reads single-band elevation GeoTIFFs such as the Copernicus GLO-30 tiles: little-endian
/// TIFF, tiled or in strips, uncompressed or DEFLATE, with no predictor, horizontal
/// differencing or the floating-point predictor, and 16-bit integer or 32-bit float samples.
///
/// Cloud-optimized GeoTIFFs keep reduced-resolution copies (overviews) of the image, each
/// in one contiguous byte range. Read the `Layout` from the start of the file, then fetch
/// and decode just the level you need.
public enum GeoTIFF {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// One image in the file: the full-resolution one or an overview.
    public struct Image: Sendable {
        public var width: Int
        public var height: Int
        var blockWidth: Int
        var blockHeight: Int
        var tiled: Bool
        var offsets: [Int]
        var counts: [Int]
        var compression: Int
        var predictor: Int
        var bitsPerSample: Int
        var sampleFormat: Int

        /// The bytes of the file holding this image's data.
        public var byteRange: Range<Int> {
            (offsets.min() ?? 0)..<(zip(offsets, counts).map { $0 + $1 }.max() ?? 0)
        }
    }

    public struct Layout: Sendable {
        /// The full-resolution image first, then overviews from largest to smallest.
        public var images: [Image]
        /// Center of the full-resolution image's first pixel, and the pixel spacing, degrees.
        var originLatitude: Double
        var originLongitude: Double
        var stepLatitude: Double
        var stepLongitude: Double
    }

    /// Reads the image directories from the start of a file. Throws if `prefix` is too
    /// short to hold them; 16 KB is plenty for Copernicus tiles.
    public static func layout(_ prefix: [UInt8]) throws -> Layout {
        guard prefix.count > 8, prefix[0] == 0x49, prefix[1] == 0x49, u16(prefix, 2) == 42 else {
            throw Failure("not a little-endian TIFF")
        }
        var images: [Image] = []
        var georef: (Double, Double, Double, Double)?
        var offset = Int(u32(prefix, 4))
        var seen = Set<Int>()
        while offset != 0, !seen.contains(offset) {
            seen.insert(offset)
            let (tags, next) = try readIFD(prefix, at: offset)
            offset = next
            func one(_ tag: Int) -> Int? { tags[tag]?.first.map { Int($0) } }
            // Skip transparency masks (bit 2 of NewSubfileType).
            if let kind = one(254), kind & 4 != 0 { continue }
            images.append(try image(tags))
            if georef == nil { georef = try georeference(tags) }
        }
        guard !images.isEmpty, let (lat, lon, slat, slon) = georef else { throw Failure("no georeferenced image") }
        return Layout(images: images, originLatitude: lat, originLongitude: lon, stepLatitude: slat, stepLongitude: slon)
    }

    /// Decodes image `level` of a file into a 1° tile with heights rounded to whole meters.
    /// `bytes` holds the file from offset `base` on and must cover the level's `byteRange`.
    public static func decode(_ layout: Layout, level: Int, bytes: [UInt8], base: Int) throws -> ElevationTile {
        guard layout.images.indices.contains(level) else { throw Failure("no image at level \(level)") }
        let img = layout.images[level]
        let full = layout.images[0]
        let width = img.width, height = img.height
        let isFloat = img.sampleFormat == 3
        let bytesPerSample = img.bitsPerSample / 8
        let across = (width + img.blockWidth - 1) / img.blockWidth
        let rowBytes = img.blockWidth * bytesPerSample

        var heights = [Int16](repeating: 0, count: width * height)
        for (index, (offset, count)) in zip(img.offsets, img.counts).enumerated() {
            let bx = (index % across) * img.blockWidth, by = (index / across) * img.blockHeight
            // Tiles are always whole; the last strip only has the rows that are left.
            let rows = img.tiled ? img.blockHeight : min(img.blockHeight, height - by)
            let start = offset - base, end = start + count
            guard start >= 0, end <= bytes.count else { throw Failure("block \(index) is outside the data given") }
            var block = Array(bytes[start..<end])
            if img.compression != 1 { block = try Inflate.zlib(block, expectedSize: rows * rowBytes) }
            guard block.count >= rows * rowBytes else { throw Failure("block \(index) is short") }
            for r in 0..<rows {
                let row = r * rowBytes
                switch img.predictor {
                case 2 where !isFloat:
                    // Horizontal differencing on whole samples.
                    for i in stride(from: row + 2, to: row + rowBytes, by: 2) {
                        let v = (UInt16(block[i - 2]) | UInt16(block[i - 1]) << 8) &+ (UInt16(block[i]) | UInt16(block[i + 1]) << 8)
                        block[i] = UInt8(v & 0xFF)
                        block[i + 1] = UInt8(v >> 8)
                    }
                case 3:
                    // Floating-point predictor: bytes are differenced across the row, and the
                    // row holds all the most significant bytes first, then the next ones.
                    for i in (row + 1)..<(row + rowBytes) { block[i] = block[i] &+ block[i - 1] }
                    let planes = Array(block[row..<(row + rowBytes)])
                    for j in 0..<img.blockWidth {
                        for b in 0..<bytesPerSample {
                            block[row + j * bytesPerSample + b] = planes[(bytesPerSample - 1 - b) * img.blockWidth + j]
                        }
                    }
                default: break
                }
            }
            // Copy the part of the block inside the image.
            for r in 0..<min(rows, height - by) {
                for c in 0..<min(img.blockWidth, width - bx) {
                    let i = (r * img.blockWidth + c) * bytesPerSample
                    let value: Double
                    if isFloat {
                        let bits = UInt32(block[i]) | UInt32(block[i + 1]) << 8 | UInt32(block[i + 2]) << 16 | UInt32(block[i + 3]) << 24
                        value = Double(Float(bitPattern: bits))
                    } else {
                        value = Double(Int16(bitPattern: UInt16(block[i]) | UInt16(block[i + 1]) << 8))
                    }
                    heights[(by + r) * width + bx + c] = Int16(max(-32767, min(32767, value.isFinite ? value.rounded(.toNearestOrEven) : 0)))
                }
            }
        }

        // An overview covers the same area with bigger pixels, so its first pixel center
        // sits half of the difference in pixel size further in.
        let stepLat = layout.stepLatitude * Double(full.height) / Double(height)
        let stepLon = layout.stepLongitude * Double(full.width) / Double(width)
        let originLat = layout.originLatitude - (stepLat - layout.stepLatitude) / 2
        let originLon = layout.originLongitude + (stepLon - layout.stepLongitude) / 2
        return ElevationTile(south: Int(layout.originLatitude.rounded(.up)) - 1,
                             west: Int(layout.originLongitude.rounded(.down)),
                             rows: height, cols: width, originLatitude: originLat, originLongitude: originLon,
                             stepLatitude: stepLat, stepLongitude: stepLon, heights: heights)
    }

    /// Decodes image `level` of a whole GeoTIFF file.
    public static func elevationTile(_ data: Data, level: Int = 0) throws -> ElevationTile {
        let bytes = [UInt8](data)
        return try decode(try layout(bytes), level: level, bytes: bytes, base: 0)
    }

    static func image(_ tags: [Int: [Double]]) throws -> Image {
        func one(_ tag: Int) -> Int? { tags[tag]?.first.map { Int($0) } }
        guard let width = one(256), let height = one(257) else { throw Failure("missing image size") }
        let bitsPerSample = one(258) ?? 1
        let compression = one(259) ?? 1
        let sampleFormat = one(339) ?? 1
        guard (one(277) ?? 1) == 1 else { throw Failure("only single-band images are supported") }
        guard [1, 8, 32946].contains(compression) else { throw Failure("compression \(compression) is not supported") }
        guard (sampleFormat == 3 && bitsPerSample == 32) || (sampleFormat != 3 && bitsPerSample == 16) else {
            throw Failure("\(bitsPerSample)-bit samples of format \(sampleFormat) are not supported")
        }
        // Blocks are tiles, or strips as full-width tiles.
        if let tw = one(322), let th = one(323), let o = tags[324], let c = tags[325] {
            return Image(width: width, height: height, blockWidth: tw, blockHeight: th, tiled: true,
                         offsets: o.map { Int($0) }, counts: c.map { Int($0) }, compression: compression,
                         predictor: one(317) ?? 1, bitsPerSample: bitsPerSample, sampleFormat: sampleFormat)
        } else if let o = tags[273], let c = tags[279] {
            return Image(width: width, height: height, blockWidth: width, blockHeight: min(one(278) ?? height, height),
                         tiled: false, offsets: o.map { Int($0) }, counts: c.map { Int($0) }, compression: compression,
                         predictor: one(317) ?? 1, bitsPerSample: bitsPerSample, sampleFormat: sampleFormat)
        }
        throw Failure("no tile or strip offsets")
    }

    /// Pixel spacing and the first pixel's center, from the GeoTIFF tags.
    static func georeference(_ tags: [Int: [Double]]) throws -> (Double, Double, Double, Double)? {
        guard let scale = tags[33550], scale.count >= 2, let tie = tags[33922], tie.count >= 6 else { return nil }
        var originLon = tie[3], originLat = tie[4]
        // GTRasterTypeGeoKey: 1 means the tie point is the first pixel's corner, 2 its center.
        var rasterType = 1
        if let keys = tags[34735], keys.count >= 4 {
            var k = 4
            while k + 3 < keys.count {
                if Int(keys[k]) == 1025 { rasterType = Int(keys[k + 3]) }
                k += 4
            }
        }
        if rasterType == 1 {
            originLon += scale[0] / 2
            originLat -= scale[1] / 2
        }
        return (originLat, originLon, scale[1], scale[0])
    }

    /// Tag values of the image file directory at `offset`, and the offset of the next one.
    static func readIFD(_ b: [UInt8], at offset: Int) throws -> ([Int: [Double]], Int) {
        guard offset + 2 <= b.count else { throw Failure("directory at \(offset) is past the bytes read") }
        let n = Int(u16(b, offset))
        guard offset + 2 + n * 12 + 4 <= b.count else { throw Failure("directory at \(offset) is past the bytes read") }
        var tags: [Int: [Double]] = [:]
        for e in 0..<n {
            let p = offset + 2 + e * 12
            let tag = Int(u16(b, p)), type = Int(u16(b, p + 2)), count = Int(u32(b, p + 4))
            let size: Int
            switch type {
            case 1, 2, 6, 7: size = 1
            case 3, 8: size = 2
            case 4, 9, 11: size = 4
            case 5, 10, 12: size = 8
            default: continue
            }
            let total = size * count
            let base = total <= 4 ? p + 8 : Int(u32(b, p + 8))
            guard base + total <= b.count else { throw Failure("tag \(tag) is past the bytes read") }
            var values: [Double] = []
            values.reserveCapacity(count)
            for i in 0..<count {
                let q = base + i * size
                switch type {
                case 1, 2, 7: values.append(Double(b[q]))
                case 6: values.append(Double(Int8(bitPattern: b[q])))
                case 3: values.append(Double(u16(b, q)))
                case 8: values.append(Double(Int16(bitPattern: u16(b, q))))
                case 4: values.append(Double(u32(b, q)))
                case 9: values.append(Double(Int32(bitPattern: u32(b, q))))
                case 11: values.append(Double(Float(bitPattern: u32(b, q))))
                case 12: values.append(Double(bitPattern: u64(b, q)))
                default: values.append(Double(u32(b, q)) / Double(max(1, u32(b, q + 4))))
                }
            }
            tags[tag] = values
        }
        return (tags, Int(u32(b, offset + 2 + n * 12)))
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i)) | UInt32(u16(b, i + 2)) << 16 }
    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }
}

import Foundation

/// Reads single-band elevation GeoTIFFs such as the Copernicus GLO-30 and USGS 3DEP tiles:
/// little-endian TIFF, tiled or in strips, uncompressed, DEFLATE or LZW, with no predictor,
/// horizontal differencing or the floating-point predictor, and 16-bit integer or 32-bit
/// float samples.
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
        /// The value marking pixels without data (GDAL_NODATA), if the file names one.
        var noData: Double?

        /// The bytes of the file holding this image's data.
        public var byteRange: Range<Int> {
            (offsets.min() ?? 0)..<(zip(offsets, counts).map { $0 + $1 }.max() ?? 0)
        }

        /// The bytes of the file holding one block (a tile or a strip).
        public func byteRange(ofBlock index: Int) -> Range<Int> {
            offsets[index]..<(offsets[index] + counts[index])
        }

        public var blockCount: Int { offsets.count }
        var blocksAcross: Int { (width + blockWidth - 1) / blockWidth }
    }

    public struct Layout: Sendable {
        /// The full-resolution image first, then overviews from largest to smallest.
        public var images: [Image]
        /// Center of the full-resolution image's first pixel, and the pixel spacing, degrees.
        var originLatitude: Double
        var originLongitude: Double
        var stepLatitude: Double
        var stepLongitude: Double

        /// The 1° cell the file covers: the one its middle is in. (USGS 3DEP tiles reach a
        /// few pixels past their cell on every side, so their first pixel is in the next one.)
        public var south: Int { Int((originLatitude - stepLatitude * Double(images[0].height - 1) / 2).rounded(.down)) }
        public var west: Int { Int((originLongitude + stepLongitude * Double(images[0].width - 1) / 2).rounded(.down)) }

        /// First pixel center and pixel size of image `level`, degrees. An overview covers
        /// the same area with bigger pixels, so its first pixel center sits half of the
        /// difference in pixel size further in.
        public func grid(level: Int) -> (originLatitude: Double, originLongitude: Double,
                                         stepLatitude: Double, stepLongitude: Double) {
            let full = images[0], img = images[level]
            let stepLat = stepLatitude * Double(full.height) / Double(img.height)
            let stepLon = stepLongitude * Double(full.width) / Double(img.width)
            return (originLatitude - (stepLat - stepLatitude) / 2, originLongitude + (stepLon - stepLongitude) / 2,
                    stepLat, stepLon)
        }

        /// The blocks of image `level` holding any part of the given area (degrees), with
        /// the pixels needed to interpolate at its edges.
        public func blocks(level: Int, south: Double, north: Double, west: Double, east: Double) -> [Int] {
            guard north > Double(self.south), south < Double(self.south + 1),
                  east > Double(self.west), west < Double(self.west + 1) else { return [] }
            let img = images[level]
            let g = grid(level: level)
            func clampRow(_ v: Double) -> Int { max(0, min(img.height - 1, Int(v.rounded(.down)))) }
            func clampCol(_ v: Double) -> Int { max(0, min(img.width - 1, Int(v.rounded(.down)))) }
            let r0 = clampRow((g.originLatitude - north) / g.stepLatitude), r1 = clampRow((g.originLatitude - south) / g.stepLatitude + 1)
            let c0 = clampCol((west - g.originLongitude) / g.stepLongitude), c1 = clampCol((east - g.originLongitude) / g.stepLongitude + 1)
            var out: [Int] = []
            for by in (r0 / img.blockHeight)...(r1 / img.blockHeight) {
                for bx in (c0 / img.blockWidth)...(c1 / img.blockWidth) { out.append(by * img.blocksAcross + bx) }
            }
            return out
        }
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
        return try decode(layout, level: level, blocks: Array(img.offsets.indices)) { index in
            let start = img.offsets[index] - base, end = start + img.counts[index]
            guard start >= 0, end <= bytes.count else { return nil }
            return bytes[start..<end]
        }
    }

    /// Decodes some blocks of image `level` into a tile covering the rectangle of blocks
    /// around them. Pixels of blocks in that rectangle that weren't asked for hold
    /// `ElevationTile.noData`. `data(block)` returns a block's bytes as stored in the file.
    public static func decode(_ layout: Layout, level: Int, blocks: [Int],
                              data: (Int) throws -> ArraySlice<UInt8>?) throws -> ElevationTile {
        guard layout.images.indices.contains(level) else { throw Failure("no image at level \(level)") }
        let img = layout.images[level]
        guard !blocks.isEmpty, blocks.allSatisfy({ img.offsets.indices.contains($0) }) else { throw Failure("no such blocks") }
        let width = img.width, height = img.height
        let isFloat = img.sampleFormat == 3
        let bytesPerSample = img.bitsPerSample / 8
        let across = img.blocksAcross
        let rowBytes = img.blockWidth * bytesPerSample

        // The window: the rectangle of blocks holding all the requested ones.
        let bxs = blocks.map { $0 % across }, bys = blocks.map { $0 / across }
        let col0 = bxs.min()! * img.blockWidth, row0 = bys.min()! * img.blockHeight
        let cols = min(width, (bxs.max()! + 1) * img.blockWidth) - col0
        let rows = min(height, (bys.max()! + 1) * img.blockHeight) - row0
        let complete = Set(blocks).count == (bxs.max()! - bxs.min()! + 1) * (bys.max()! - bys.min()! + 1)
        var heights = [Int16](repeating: complete ? 0 : ElevationTile.noData, count: rows * cols)

        for index in Set(blocks) {
            let bx = (index % across) * img.blockWidth, by = (index / across) * img.blockHeight
            // Tiles are always whole; the last strip only has the rows that are left.
            let blockRows = img.tiled ? img.blockHeight : min(img.blockHeight, height - by)
            guard let stored = try data(index), stored.count == img.counts[index] else {
                throw Failure("block \(index) is outside the data given")
            }
            var block = Array(stored)
            switch img.compression {
            case 1: break
            case 5: block = try LZW.decode(stored, expectedSize: blockRows * rowBytes)
            default: block = try Inflate.zlib(block, expectedSize: blockRows * rowBytes)
            }
            guard block.count >= blockRows * rowBytes else { throw Failure("block \(index) is short") }
            for r in 0..<blockRows {
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
            for r in 0..<min(blockRows, height - by) {
                for c in 0..<min(img.blockWidth, width - bx) {
                    let i = (r * img.blockWidth + c) * bytesPerSample
                    let value: Double
                    if isFloat {
                        let bits = UInt32(block[i]) | UInt32(block[i + 1]) << 8 | UInt32(block[i + 2]) << 16 | UInt32(block[i + 3]) << 24
                        value = Double(Float(bitPattern: bits))
                    } else {
                        value = Double(Int16(bitPattern: UInt16(block[i]) | UInt16(block[i + 1]) << 8))
                    }
                    // Voids: the file's no-data value, NaN, and the usual fill values
                    // (−32768, −32767, −9999, −999999), which are all far below any land.
                    let void = !value.isFinite || value < -1000 || img.noData.map { Float($0) == Float(value) } == true
                    heights[(by + r - row0) * cols + bx + c - col0] =
                        void ? ElevationTile.noData : Int16(min(32767, value.rounded(.toNearestOrEven)))
                }
            }
        }

        let grid = layout.grid(level: level)
        return ElevationTile(south: layout.south, west: layout.west, rows: rows, cols: cols,
                             originLatitude: grid.originLatitude - Double(row0) * grid.stepLatitude,
                             originLongitude: grid.originLongitude + Double(col0) * grid.stepLongitude,
                             stepLatitude: grid.stepLatitude, stepLongitude: grid.stepLongitude, heights: heights)
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
        guard [1, 5, 8, 32946].contains(compression) else { throw Failure("compression \(compression) is not supported") }
        guard (sampleFormat == 3 && bitsPerSample == 32) || (sampleFormat != 3 && bitsPerSample == 16) else {
            throw Failure("\(bitsPerSample)-bit samples of format \(sampleFormat) are not supported")
        }
        // GDAL_NODATA is ASCII text, such as "-32767".
        let noData = tags[42113].flatMap { chars in
            Double(String(decoding: chars.prefix { $0 != 0 }.map { UInt8(clamping: Int($0)) }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard (1...1 << 20).contains(width), (1...1 << 20).contains(height) else {
            throw Failure("image size \(width)×\(height) is not supported")
        }
        // Blocks are tiles, or strips as full-width tiles.
        let img: Image
        if let tw = one(322), let th = one(323), let o = tags[324], let c = tags[325] {
            img = Image(width: width, height: height, blockWidth: tw, blockHeight: th, tiled: true,
                        offsets: o.map { Int($0) }, counts: c.map { Int($0) }, compression: compression,
                        predictor: one(317) ?? 1, bitsPerSample: bitsPerSample, sampleFormat: sampleFormat, noData: noData)
        } else if let o = tags[273], let c = tags[279] {
            img = Image(width: width, height: height, blockWidth: width, blockHeight: min(one(278) ?? height, height),
                        tiled: false, offsets: o.map { Int($0) }, counts: c.map { Int($0) }, compression: compression,
                        predictor: one(317) ?? 1, bitsPerSample: bitsPerSample, sampleFormat: sampleFormat, noData: noData)
        } else {
            throw Failure("no tile or strip offsets")
        }
        guard (1...1 << 16).contains(img.blockWidth), (1...1 << 20).contains(img.blockHeight) else {
            throw Failure("block size \(img.blockWidth)×\(img.blockHeight) is not supported")
        }
        let blocksDown = (height + img.blockHeight - 1) / img.blockHeight
        guard img.offsets.count == img.blocksAcross * blocksDown, img.counts.count == img.offsets.count else {
            throw Failure("\(img.offsets.count) block offsets and \(img.counts.count) sizes for \(img.blocksAcross * blocksDown) blocks")
        }
        guard img.offsets.allSatisfy({ $0 >= 0 }), img.counts.allSatisfy({ $0 >= 0 }) else { throw Failure("negative block offset or size") }
        return img
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

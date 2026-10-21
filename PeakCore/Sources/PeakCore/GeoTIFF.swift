import Foundation

/// Reads single-band elevation GeoTIFFs such as the Copernicus GLO-30 tiles: little-endian
/// TIFF, tiled or in strips, uncompressed or DEFLATE, with no predictor, horizontal
/// differencing or the floating-point predictor, and 16-bit integer or 32-bit float samples.
public enum GeoTIFF {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// Decodes a GeoTIFF into a 1° tile with heights rounded to whole meters.
    public static func elevationTile(_ data: Data) throws -> ElevationTile {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0] == 0x49, bytes[1] == 0x49, u16(bytes, 2) == 42 else {
            throw Failure("not a little-endian TIFF")
        }
        let tags = try readIFD(bytes, at: Int(u32(bytes, 4)))
        func one(_ tag: Int) -> Int? { tags[tag]?.first.map { Int($0) } }

        guard let width = one(256), let height = one(257) else { throw Failure("missing image size") }
        let bitsPerSample = one(258) ?? 1
        let compression = one(259) ?? 1
        let predictor = one(317) ?? 1
        let sampleFormat = one(339) ?? 1
        guard (one(277) ?? 1) == 1 else { throw Failure("only single-band images are supported") }
        guard [1, 8, 32946].contains(compression) else { throw Failure("compression \(compression) is not supported") }
        let isFloat = sampleFormat == 3 && bitsPerSample == 32
        let isInt16 = sampleFormat != 3 && bitsPerSample == 16
        guard isFloat || isInt16 else { throw Failure("\(bitsPerSample)-bit samples of format \(sampleFormat) are not supported") }
        let bytesPerSample = bitsPerSample / 8

        // Blocks are tiles, or strips as full-width tiles.
        let blockWidth: Int, blockHeight: Int, offsets: [Double], counts: [Double], tiled: Bool
        if let tw = one(322), let th = one(323), let o = tags[324], let c = tags[325] {
            (blockWidth, blockHeight, offsets, counts, tiled) = (tw, th, o, c, true)
        } else if let o = tags[273], let c = tags[279] {
            (blockWidth, blockHeight, offsets, counts, tiled) = (width, min(one(278) ?? height, height), o, c, false)
        } else {
            throw Failure("no tile or strip offsets")
        }
        let across = (width + blockWidth - 1) / blockWidth

        var heights = [Int16](repeating: 0, count: width * height)
        let rowBytes = blockWidth * bytesPerSample
        for (index, (offset, count)) in zip(offsets, counts).enumerated() {
            let bx = (index % across) * blockWidth, by = (index / across) * blockHeight
            // Tiles are always whole; the last strip only has the rows that are left.
            let rows = tiled ? blockHeight : min(blockHeight, height - by)
            let start = Int(offset), end = start + Int(count)
            guard start >= 0, end <= bytes.count else { throw Failure("block \(index) is outside the file") }
            var block = Array(bytes[start..<end])
            if compression != 1 { block = try Inflate.zlib(block, expectedSize: rows * rowBytes) }
            guard block.count >= rows * rowBytes else { throw Failure("block \(index) is short") }
            for r in 0..<rows {
                let row = r * rowBytes
                switch predictor {
                case 2 where isInt16:
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
                    for j in 0..<blockWidth {
                        for b in 0..<bytesPerSample {
                            block[row + j * bytesPerSample + b] = planes[(bytesPerSample - 1 - b) * blockWidth + j]
                        }
                    }
                default: break
                }
            }
            // Copy the part of the block inside the image.
            for r in 0..<min(rows, height - by) {
                for c in 0..<min(blockWidth, width - bx) {
                    let i = (r * blockWidth + c) * bytesPerSample
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

        // Georeferencing: pixel spacing, the tie point, and whether it marks the corner or
        // the center of the first pixel.
        guard let scale = tags[33550], scale.count >= 2, let tie = tags[33922], tie.count >= 6 else {
            throw Failure("missing georeferencing")
        }
        var originLon = tie[3], originLat = tie[4]
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
        return ElevationTile(south: Int(originLat.rounded(.up)) - 1, west: Int(originLon.rounded(.down)),
                             rows: height, cols: width, originLatitude: originLat, originLongitude: originLon,
                             stepLatitude: scale[1], stepLongitude: scale[0], heights: heights)
    }

    /// Tag values of the first image file directory, as numbers.
    static func readIFD(_ b: [UInt8], at offset: Int) throws -> [Int: [Double]] {
        guard offset + 2 <= b.count else { throw Failure("bad directory offset") }
        let n = Int(u16(b, offset))
        var tags: [Int: [Double]] = [:]
        for e in 0..<n {
            let p = offset + 2 + e * 12
            guard p + 12 <= b.count else { throw Failure("truncated directory") }
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
            guard base + total <= b.count else { throw Failure("tag \(tag) is outside the file") }
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
        return tags
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i)) | UInt32(u16(b, i + 2)) << 16 }
    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }
}

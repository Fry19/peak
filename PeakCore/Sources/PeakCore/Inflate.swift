import Foundation
#if canImport(Compression)
import Compression
#endif

/// A DEFLATE decoder (RFC 1951, with the zlib wrapper of RFC 1950), so GeoTIFF tiles can
/// be read the same way on every platform without a system library.
public enum Inflate {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// Decompresses a zlib stream. The Adler-32 checksum is not verified.
    public static func zlib(_ data: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
        guard data.count >= 2 else { throw Failure("zlib stream too short") }
        let cmf = Int(data[0]), flg = Int(data[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0 else { throw Failure("not a zlib stream") }
        guard flg & 0x20 == 0 else { throw Failure("zlib preset dictionaries are not supported") }
        #if canImport(Compression)
        // Apple's decoder is several times faster; use it when the output size is known.
        if expectedSize > 0, let out = system(data, from: 2, expectedSize: expectedSize) { return out }
        #endif
        return try raw(data, from: 2, expectedSize: expectedSize)
    }

    #if canImport(Compression)
    /// Raw DEFLATE through the Compression framework, or nil if the output isn't exactly
    /// `expectedSize` bytes (then the portable decoder takes over).
    static func system(_ data: [UInt8], from start: Int, expectedSize: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: expectedSize + 1)
        let written = data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress! + start, src.count - start,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        out.removeLast()
        return out
    }
    #endif

    /// Decompresses raw DEFLATE data starting at byte `start`.
    public static func raw(_ data: [UInt8], from start: Int = 0, expectedSize: Int = 0) throws -> [UInt8] {
        try data.withUnsafeBufferPointer { input in
            var decoder = Decoder(input: input, position: start, capacity: max(expectedSize, input.count * 4))
            try decoder.run()
            return Array(decoder.output[0..<decoder.count])
        }
    }

    // Lengths and distances for codes 257...285 and 0...29.
    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                     3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                      257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                      8193, 12289, 16385, 24577]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                       7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let fixedLiterals: Huffman = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return try! Huffman(lengths: lengths)
    }()
    static let fixedDistances = try! Huffman(lengths: [UInt8](repeating: 5, count: 30))

    /// Canonical Huffman code as a lookup table indexed by the next `maxBits` input bits.
    struct Huffman {
        /// symbol << 4 | code length; 0 marks bit patterns no code uses.
        var table: [UInt32]
        var maxBits: Int

        init(lengths: [UInt8]) throws {
            maxBits = max(1, Int(lengths.max() ?? 1))
            guard maxBits <= 15 else { throw Failure("Huffman code longer than 15 bits") }
            var counts = [Int](repeating: 0, count: 16)
            for l in lengths where l > 0 { counts[Int(l)] += 1 }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for bits in 1...15 {
                code = (code + counts[bits - 1]) << 1
                next[bits] = code
            }
            table = [UInt32](repeating: 0, count: 1 << maxBits)
            for (symbol, l) in lengths.enumerated() where l > 0 {
                let len = Int(l)
                let c = next[len]
                next[len] += 1
                // Codes are stored most significant bit first; the bit reader gives the
                // first bit in the lowest position, so index by the reversed code.
                var reversed = 0
                for b in 0..<len where c & (1 << b) != 0 { reversed |= 1 << (len - 1 - b) }
                guard reversed < table.count else { throw Failure("over-subscribed Huffman code") }
                let entry = UInt32(symbol) << 4 | UInt32(len)
                for i in stride(from: reversed, to: table.count, by: 1 << len) { table[i] = entry }
            }
        }
    }

    struct Decoder {
        let input: UnsafeBufferPointer<UInt8>
        var position: Int
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var output: [UInt8]
        var count = 0

        init(input: UnsafeBufferPointer<UInt8>, position: Int, capacity: Int) {
            self.input = input
            self.position = position
            output = [UInt8](repeating: 0, count: max(capacity, 1024))
        }

        @inline(__always)
        mutating func refill() throws {
            while bitCount <= 56 {
                if position < input.count {
                    bitBuffer |= UInt64(input[position]) << UInt64(bitCount)
                } else if position > input.count + 8 {
                    throw Failure("unexpected end of compressed data")
                }
                position += 1
                bitCount += 8
            }
        }

        @inline(__always)
        mutating func bits(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            if bitCount < n { try refill() }
            let v = Int(bitBuffer & ((1 << UInt64(n)) - 1))
            bitBuffer >>= UInt64(n)
            bitCount -= n
            return v
        }

        @inline(__always)
        mutating func decode(_ h: Huffman) throws -> Int {
            if bitCount < h.maxBits { try refill() }
            let entry = h.table[Int(bitBuffer & ((1 << UInt64(h.maxBits)) - 1))]
            let len = Int(entry & 15)
            guard len > 0 else { throw Failure("invalid Huffman code") }
            bitBuffer >>= UInt64(len)
            bitCount -= len
            return Int(entry >> 4)
        }

        @inline(__always)
        mutating func reserve(_ n: Int) {
            if count + n > output.count {
                output.append(contentsOf: repeatElement(0, count: max(output.count, n)))
            }
        }

        mutating func run() throws {
            var final = false
            while !final {
                final = try bits(1) == 1
                switch try bits(2) {
                case 0: try stored()
                case 1: try block(Inflate.fixedLiterals, Inflate.fixedDistances)
                case 2:
                    let (lit, dist) = try dynamicTables()
                    try block(lit, dist)
                default: throw Failure("invalid block type")
                }
            }
        }

        mutating func stored() throws {
            // Skip to a byte boundary; whole bytes still in the bit buffer come first.
            _ = try bits(bitCount % 8)
            let len = try bits(16), nlen = try bits(16)
            guard len == ~nlen & 0xFFFF else { throw Failure("stored block length mismatch") }
            reserve(len)
            for _ in 0..<len {
                output[count] = UInt8(try bits(8))
                count += 1
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let hlit = try bits(5) + 257, hdist = try bits(5) + 1, hclen = try bits(4) + 4
            var codeLengths = [UInt8](repeating: 0, count: 19)
            for i in 0..<hclen { codeLengths[Inflate.codeLengthOrder[i]] = UInt8(try bits(3)) }
            let lengthCode = try Huffman(lengths: codeLengths)
            var lengths = [UInt8]()
            lengths.reserveCapacity(hlit + hdist)
            while lengths.count < hlit + hdist {
                let symbol = try decode(lengthCode)
                switch symbol {
                case 0...15: lengths.append(UInt8(symbol))
                case 16:
                    guard let last = lengths.last else { throw Failure("repeat with no previous length") }
                    lengths.append(contentsOf: repeatElement(last, count: 3 + (try bits(2))))
                case 17: lengths.append(contentsOf: repeatElement(0, count: 3 + (try bits(3))))
                default: lengths.append(contentsOf: repeatElement(0, count: 11 + (try bits(7))))
                }
            }
            guard lengths.count == hlit + hdist else { throw Failure("code lengths overflow") }
            return (try Huffman(lengths: Array(lengths[0..<hlit])), try Huffman(lengths: Array(lengths[hlit...])))
        }

        mutating func block(_ literals: Huffman, _ distances: Huffman) throws {
            while true {
                let symbol = try decode(literals)
                if symbol < 256 {
                    reserve(1)
                    output[count] = UInt8(symbol)
                    count += 1
                } else if symbol == 256 {
                    return
                } else {
                    let li = symbol - 257
                    guard li < 29 else { throw Failure("invalid length code") }
                    let length = Inflate.lengthBase[li] + (try bits(Inflate.lengthExtra[li]))
                    let di = try decode(distances)
                    guard di < 30 else { throw Failure("invalid distance code") }
                    let distance = Inflate.distanceBase[di] + (try bits(Inflate.distanceExtra[di]))
                    guard distance <= count else { throw Failure("distance before start of output") }
                    reserve(length)
                    // Byte by byte: the source may overlap what is being written.
                    var from = count - distance
                    for _ in 0..<length {
                        output[count] = output[from]
                        count += 1
                        from += 1
                    }
                }
            }
        }
    }
}

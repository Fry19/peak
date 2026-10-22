import Foundation

/// A decoder for TIFF's LZW compression (TIFF 6.0, section 13), which USGS 3DEP and
/// swissALTI3D tiles use: codes most significant bit first, 9 to 12 bits wide, widening one
/// code early, with 256 clearing the table and 257 ending the data.
public enum LZW {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    static let clear = 256
    static let end = 257

    /// Decompresses one strip or tile. Data that stops without an end code ends there.
    public static func decode(_ data: ArraySlice<UInt8>, expectedSize: Int = 0) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)
        // Each code is a string: the string of `prefix` followed by `suffix`, `length` long.
        var prefix = [Int32](repeating: -1, count: 4096)
        var suffix = [UInt8](repeating: 0, count: 4096)
        var length = [Int32](repeating: 1, count: 4096)
        var first = [UInt8](repeating: 0, count: 4096)
        for i in 0..<256 {
            suffix[i] = UInt8(i)
            first[i] = UInt8(i)
        }
        var next = 258, width = 9
        var old = -1
        var buffer: UInt64 = 0, bits = 0
        var i = data.startIndex

        /// Appends the string of `code`.
        func emit(_ code: Int) {
            let n = Int(length[code])
            let start = out.count
            out.append(contentsOf: repeatElement(0, count: n))
            var c = code, k = start + n - 1
            while k >= start {
                out[k] = suffix[c]
                c = Int(prefix[c])
                k -= 1
            }
        }

        while true {
            while bits < width, i < data.endIndex {
                buffer = buffer << 8 | UInt64(data[i])
                bits += 8
                i += 1
            }
            guard bits >= width else { break }
            let code = Int((buffer >> UInt64(bits - width)) & UInt64((1 << width) - 1))
            bits -= width
            if code == end { break }
            if code == clear {
                next = 258
                width = 9
                old = -1
                continue
            }
            if old < 0 {
                guard code < 256 else { throw Failure("code \(code) right after a clear") }
                emit(code)
                old = code
                continue
            }
            guard code <= next else { throw Failure("code \(code) before it was defined (next is \(next))") }
            // A code not in the table yet is the previous string and its own first byte.
            let head = code < next ? first[code] : first[old]
            if next < 4096 {
                prefix[next] = Int32(old)
                suffix[next] = head
                length[next] = length[old] + 1
                first[next] = first[old]
            }
            emit(code)
            if next < 4096 {
                next += 1
                // One code early: the encoder widens as it hands out the last code of a width.
                if next >= (1 << width) - 1, width < 12 { width += 1 }
            }
            old = code
        }
        return out
    }
}

import Foundation

/// An 8-bit RGB image, rows top to bottom.
public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 3)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8) = (0, 0, 0)) {
        self.width = width
        self.height = height
        var p = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            p[3 * i] = fill.0
            p[3 * i + 1] = fill.1
            p[3 * i + 2] = fill.2
        }
        pixels = p
    }

    @inline(__always)
    public func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = 3 * (y * width + x)
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    @inline(__always)
    public mutating func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = 3 * (y * width + x)
        pixels[i] = c.0
        pixels[i + 1] = c.1
        pixels[i + 2] = c.2
    }

    /// Area-averaged downscale (or nearest-neighbor upscale) to the given width,
    /// keeping the aspect ratio.
    public func resized(toWidth newWidth: Int) -> RGBImage {
        guard newWidth != width else { return self }
        let newHeight = max(1, Int((Double(height) * Double(newWidth) / Double(width)).rounded()))
        var out = [UInt8](repeating: 0, count: newWidth * newHeight * 3)
        let sx = Double(width) / Double(newWidth), sy = Double(height) / Double(newHeight)
        for y in 0..<newHeight {
            let y0 = Int(Double(y) * sy), y1 = max(y0 + 1, min(height, Int(Double(y + 1) * sy)))
            for x in 0..<newWidth {
                let x0 = Int(Double(x) * sx), x1 = max(x0 + 1, min(width, Int(Double(x + 1) * sx)))
                var r = 0, g = 0, b = 0
                for yy in y0..<y1 {
                    var i = 3 * (yy * width + x0)
                    for _ in x0..<x1 {
                        r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
                        i += 3
                    }
                }
                let n = (y1 - y0) * (x1 - x0)
                let o = 3 * (y * newWidth + x)
                out[o] = UInt8(r / n); out[o + 1] = UInt8(g / n); out[o + 2] = UInt8(b / n)
            }
        }
        return RGBImage(width: newWidth, height: newHeight, pixels: out)
    }

    /// Draws a polyline, skipping NaN points and jumps longer than `maxGap` pixels.
    public mutating func drawPolyline(_ points: [(Double, Double)], color: (UInt8, UInt8, UInt8),
                                      thickness: Int = 1, maxGap: Double = .infinity) {
        guard points.count > 1 else { return }
        for i in 1..<points.count {
            let (x0, y0) = points[i - 1], (x1, y1) = points[i]
            guard !x0.isNaN, !y0.isNaN, !x1.isNaN, !y1.isNaN else { continue }
            guard hypot(x1 - x0, y1 - y0) <= maxGap else { continue }
            drawLine(x0, y0, x1, y1, color: color, thickness: thickness)
        }
    }

    public mutating func drawLine(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                                  color: (UInt8, UInt8, UInt8), thickness: Int = 1) {
        let steps = max(1, Int(max(abs(x1 - x0), abs(y1 - y0)).rounded(.up)))
        let half = thickness / 2
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            let x = Int((x0 + (x1 - x0) * t).rounded()), y = Int((y0 + (y1 - y0) * t).rounded())
            for dy in -half...(thickness - 1 - half) {
                for dx in -half...(thickness - 1 - half) { set(x + dx, y + dy, color) }
            }
        }
    }

    public mutating func drawDot(_ x: Double, _ y: Double, radius: Int, color: (UInt8, UInt8, UInt8)) {
        let cx = Int(x.rounded()), cy = Int(y.rounded())
        for dy in -radius...radius {
            for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                set(cx + dx, cy + dy, color)
            }
        }
    }
}

// MARK: - PPM files

public enum ImageError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .unreadable(path): return "can't read image \(path)"
        case let .unsupported(why): return why
        }
    }
}

extension RGBImage {
    /// Reads a binary PPM (P6, 8-bit) file.
    public init(ppm data: Data) throws {
        var index = data.startIndex
        func token() -> String {
            var s = ""
            while index < data.endIndex {
                let c = data[index]
                if c == UInt8(ascii: "#") {
                    while index < data.endIndex, data[index] != UInt8(ascii: "\n") { index += 1 }
                } else if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 {
                    if !s.isEmpty { index += 1; break }
                } else {
                    s.append(Character(UnicodeScalar(c)))
                }
                index += 1
            }
            return s
        }
        guard token() == "P6", let w = Int(token()), let h = Int(token()), let maxValue = Int(token()),
              maxValue == 255 else { throw ImageError.unsupported("only 8-bit binary PPM (P6) is supported") }
        // Exactly one whitespace byte follows the header, and `token` consumed it.
        let start = index
        guard data.endIndex - start >= w * h * 3 else { throw ImageError.unsupported("PPM is truncated") }
        self.init(width: w, height: h, pixels: [UInt8](data[start..<(start + w * h * 3)]))
    }

    public func ppmData() -> Data {
        var d = Data("P6\n\(width) \(height)\n255\n".utf8)
        d.append(contentsOf: pixels)
        return d
    }
}

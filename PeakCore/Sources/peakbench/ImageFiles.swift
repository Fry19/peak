import Foundation
import PeakCore

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let defaultImageExtension = "png"

/// Loads PPM directly, and anything ImageIO reads (JPEG, HEIC, PNG) with its EXIF
/// orientation applied, so portrait photos come out upright.
func loadImage(_ path: String) throws -> RGBImage {
    if path.lowercased().hasSuffix(".ppm") { return try RGBImage(ppm: Data(contentsOf: URL(fileURLWithPath: path))) }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
    else { throw ImageError.unreadable(path) }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(w, h),
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw ImageError.unreadable(path)
    }
    let width = cg.width, height = cg.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
        guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { throw ImageError.unreadable(path) }
    var rgb = [UInt8](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) {
        rgb[3 * i] = rgba[4 * i]
        rgb[3 * i + 1] = rgba[4 * i + 1]
        rgb[3 * i + 2] = rgba[4 * i + 2]
    }
    return RGBImage(width: width, height: height, pixels: rgb)
}

func saveImage(_ image: RGBImage, to path: String) throws {
    if path.lowercased().hasSuffix(".ppm") {
        try image.ppmData().write(to: URL(fileURLWithPath: path))
        return
    }
    var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
    for i in 0..<(image.width * image.height) {
        rgba[4 * i] = image.pixels[3 * i]
        rgba[4 * i + 1] = image.pixels[3 * i + 1]
        rgba[4 * i + 2] = image.pixels[3 * i + 2]
    }
    let type = path.lowercased().hasSuffix(".jpg") ? UTType.jpeg : UTType.png
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil)
    else { throw ImageError.unsupported("can't write \(path)") }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { throw ImageError.unsupported("can't write \(path)") }
}

/// Builds a case file from a photo's EXIF: GPS position, the compass heading the iPhone
/// stores with each photo (GPSImgDirection), and the field of view from the 35 mm
/// equivalent focal length.
func caseCommand(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw HarnessError("which photo?") }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { throw ImageError.unreadable(path) }
    let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    guard var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double else {
        throw HarnessError("\(path) has no GPS position")
    }
    if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
    if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
    guard let heading = gps[kCGImagePropertyGPSImgDirection] as? Double else {
        throw HarnessError("\(path) has no compass heading (GPSImgDirection)")
    }
    if (gps[kCGImagePropertyGPSImgDirectionRef] as? String) == "M" {
        log("warning: the heading is magnetic, not true north; add the local declination by hand")
    }
    guard let f35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double, f35 > 0 else {
        throw HarnessError("\(path) has no 35 mm equivalent focal length")
    }
    var w = Double(props[kCGImagePropertyPixelWidth] as? Int ?? 4032)
    var h = Double(props[kCGImagePropertyPixelHeight] as? Int ?? 3024)
    // EXIF orientations 5–8 are rotated by 90°: the upright image is portrait.
    if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
    // The 35 mm equivalent matches the diagonal of a 36×24 mm frame (43.27 mm).
    let sensorWidth = 43.27 * w / (w * w + h * h).squareRoot()
    let fov = 2 * atan(sensorWidth / (2 * f35)) * 180 / .pi

    let photo = PhotoCase(image: URL(fileURLWithPath: path).lastPathComponent, latitude: lat, longitude: lon,
                          altitude: nil, heading: heading, pitch: nil, roll: nil, horizontalFOV: fov, truth: nil,
                          anchors: nil, dem: nil, note: "From EXIF. Add anchors (marked summits) to measure the error.")
    let out = args.string("out") ?? URL(fileURLWithPath: path).deletingPathExtension().path + ".json"
    try writeCase(photo, to: out)
    print("Wrote \(out): \(String(format: "%.5f, %.5f", lat, lon)), heading \(String(format: "%.1f", heading))°, " +
          "horizontal field of view \(String(format: "%.1f", fov))°")
}

#else

let defaultImageExtension = "ppm"

func loadImage(_ path: String) throws -> RGBImage {
    guard path.lowercased().hasSuffix(".ppm") else {
        throw ImageError.unsupported("only .ppm images can be read on this platform (convert with: convert in.jpg out.ppm)")
    }
    return try RGBImage(ppm: Data(contentsOf: URL(fileURLWithPath: path)))
}

func saveImage(_ image: RGBImage, to path: String) throws {
    let url = path.lowercased().hasSuffix(".ppm") ? URL(fileURLWithPath: path)
        : URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("ppm")
    try image.ppmData().write(to: url)
}

func caseCommand(_ args: Arguments) throws {
    throw HarnessError("reading photo metadata needs ImageIO (macOS)")
}

#endif

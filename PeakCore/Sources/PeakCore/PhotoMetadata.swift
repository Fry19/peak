import Foundation

/// What a photo's metadata says about where it was taken and through which lens: the
/// fields of ImageIO's property dictionary that matter for labeling it. Reading the file is
/// left to the caller (ImageIO isn't on every platform); this only interprets the values.
public struct PhotoMetadata: Sendable, Equatable {
    /// Pixel size as stored, before the orientation is applied.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// EXIF orientation, 1–8. 5–8 are turned a quarter turn: the upright picture is the
    /// stored one with width and height swapped.
    public var orientation = 1
    public var latitude: Double?
    public var longitude: Double?
    /// GPS altitude, meters. Not used for the eye height (the terrain gives that), only shown.
    public var altitude: Double?
    /// GPS horizontal error, meters, when the camera wrote it.
    public var positionError: Double?
    /// Which way the lens pointed (GPSImgDirection), degrees clockwise from north.
    public var heading: Double?
    /// The heading is from magnetic north (GPSImgDirectionRef "M") rather than true north.
    public var headingIsMagnetic = false
    /// 35 mm equivalent focal length, millimeters.
    public var focalLength35mm: Double?
    /// When the photo was taken, if known.
    public var date: Date?

    public init(pixelWidth: Int, pixelHeight: Int, orientation: Int = 1, latitude: Double? = nil, longitude: Double? = nil,
                altitude: Double? = nil, positionError: Double? = nil, heading: Double? = nil, headingIsMagnetic: Bool = false,
                focalLength35mm: Double? = nil, date: Date? = nil) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.positionError = positionError
        self.heading = heading
        self.headingIsMagnetic = headingIsMagnetic
        self.focalLength35mm = focalLength35mm
        self.date = date
    }

    /// From ImageIO's properties for the image (`CGImageSourceCopyPropertiesAtIndex`), whose
    /// keys are these strings ("{GPS}", "ImgDirection", …). Nil without a pixel size.
    public init?(properties: [String: Any]) {
        func number(_ value: Any?) -> Double? {
            switch value {
            case let n as NSNumber: return n.doubleValue
            case let d as Double: return d
            case let i as Int: return Double(i)
            case let s as String: return Double(s)
            default: return nil
            }
        }
        let gps = properties["{GPS}"] as? [String: Any] ?? [:]
        let exif = properties["{Exif}"] as? [String: Any] ?? [:]
        let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
        guard let w = number(properties["PixelWidth"] ?? exif["PixelXDimension"]),
              let h = number(properties["PixelHeight"] ?? exif["PixelYDimension"]), w > 0, h > 0 else { return nil }
        self.init(pixelWidth: Int(w), pixelHeight: Int(h))
        if let o = number(properties["Orientation"] ?? tiff["Orientation"]), (1...8).contains(Int(o)) { orientation = Int(o) }
        if var lat = number(gps["Latitude"]), var lon = number(gps["Longitude"]), lat.isFinite, lon.isFinite {
            if (gps["LatitudeRef"] as? String)?.uppercased() == "S" { lat = -abs(lat) }
            if (gps["LongitudeRef"] as? String)?.uppercased() == "W" { lon = -abs(lon) }
            // Some apps write 0, 0 for "unknown".
            if abs(lat) <= 90, abs(lon) <= 180, lat != 0 || lon != 0 {
                latitude = lat
                longitude = lon
            }
        }
        if var alt = number(gps["Altitude"]) {
            if number(gps["AltitudeRef"]) == 1 { alt = -alt }
            altitude = alt
        }
        positionError = number(gps["HPositioningError"])
        if let d = number(gps["ImgDirection"]), d.isFinite, d >= 0, d <= 360 {
            heading = normalizedAzimuth(d)
            headingIsMagnetic = (gps["ImgDirectionRef"] as? String)?.uppercased() == "M"
        }
        if let f = number(exif["FocalLenIn35mmFilm"]), f > 0 { focalLength35mm = f }
        date = Self.date(gps: gps, exif: exif)
    }

    /// The GPS time (UTC) if there is one, else the camera clock with its offset (or as UTC).
    private static func date(gps: [String: Any], exif: [String: Any]) -> Date? {
        func parse(_ text: String, _ format: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            return f.date(from: text)
        }
        if let day = gps["DateStamp"] as? String, let time = gps["TimeStamp"] as? String,
           let d = parse(day + " " + time.prefix(8), "yyyy:MM:dd HH:mm:ss") {
            return d
        }
        guard let text = exif["DateTimeOriginal"] as? String, var d = parse(text, "yyyy:MM:dd HH:mm:ss") else { return nil }
        // "+02:00": the camera clock was that far ahead of UTC.
        if let offset = exif["OffsetTimeOriginal"] as? String, offset.count == 6,
           let hours = Int(offset.dropFirst().prefix(2)), let minutes = Int(offset.suffix(2)) {
            let seconds = Double(hours * 3600 + minutes * 60)
            d.addTimeInterval(offset.hasPrefix("-") ? seconds : -seconds)
        }
        return d
    }

    /// The upright picture's size: the stored one, turned for orientations 5–8.
    public var uprightSize: (width: Int, height: Int) {
        orientation >= 5 ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight)
    }
}

/// The camera a photo was taken with, worked out from its metadata: where it stood, the
/// lens for the upright picture, and which way it looked as far as the metadata knows.
public struct PhotoCamera: Sendable, Equatable {
    public enum Problem: Error, Equatable, LocalizedError {
        case noLocation

        public var errorDescription: String? {
            switch self {
            case .noLocation: return "This photo has no location, so there's no telling which mountains are in it."
            }
        }
    }

    /// The 35 mm equivalent assumed when the photo doesn't say: an iPhone's main camera.
    public static let defaultFocalLength35mm = 26.0
    public static let typicalPositionError = 10.0

    public var latitude: Double
    public var longitude: Double
    /// How far off the position may be, meters: the GPS error the camera wrote, or a
    /// typical phone fix's when it didn't.
    public var positionError: Double
    /// For the upright picture at full size.
    public var intrinsics: CameraIntrinsics
    /// Heading from true north (0 when unknown, see `hasHeading`); pitch and roll 0: the
    /// metadata has no level, so the photo is taken as held level.
    public var prior: Attitude
    /// The metadata had a heading.
    public var hasHeading: Bool
    /// Magnetic declination added to a magnetic heading, degrees (nil for a true heading).
    public var declination: Double?
    /// The focal length wasn't in the metadata, and is a guess.
    public var focalLengthIsGuessed: Bool
    public var date: Date?

    public init(_ metadata: PhotoMetadata) throws {
        guard let lat = metadata.latitude, let lon = metadata.longitude else { throw Problem.noLocation }
        latitude = lat
        longitude = lon
        positionError = metadata.positionError.flatMap { $0 > 0 ? $0 : nil } ?? Self.typicalPositionError
        date = metadata.date
        let (w, h) = metadata.uprightSize
        let f35 = metadata.focalLength35mm ?? Self.defaultFocalLength35mm
        focalLengthIsGuessed = metadata.focalLength35mm == nil
        intrinsics = CameraIntrinsics(width: w, height: h, horizontalFOV: Self.horizontalFOV(focalLength35mm: f35, width: w, height: h))
        if var heading = metadata.heading {
            if metadata.headingIsMagnetic {
                let d = MagneticDeclination.degrees(latitude: lat, longitude: lon, date: metadata.date ?? Date())
                declination = d
                heading += d
            }
            prior = Attitude(heading: normalizedAzimuth(heading))
            hasHeading = true
        } else {
            prior = Attitude(heading: 0)
            hasHeading = false
        }
    }

    /// Horizontal field of view of a `width` × `height` picture from its 35 mm equivalent
    /// focal length, which matches the picture's diagonal to a 36 × 24 mm frame's (43.27 mm).
    public static func horizontalFOV(focalLength35mm f: Double, width: Int, height: Int) -> Double {
        let w = Double(width), h = Double(height)
        let sensorWidth = 43.27 * w / (w * w + h * h).squareRoot()
        return 2 * atan(sensorWidth / (2 * f)) * 180 / .pi
    }

    /// How to match the skyline: the photo settings (no pitch or roll known), also solving
    /// for the lens when it's a guess, and a little wider for a magnetic heading.
    public var alignmentSettings: AlignmentSettings {
        var s = AlignmentSettings.photo
        s.positionUncertainty = LocationQuality.positionUncertainty(accuracy: positionError, moved: 0)
        if focalLengthIsGuessed {
            s.refineFieldOfView = true
            s.fieldOfViewSigma = 0.1
        }
        if !hasHeading {
            s.headingRange = 180
        } else if declination != nil {
            // A magnetic compass near metal, or a declination a little off: some more room.
            s.headingRange = 25
        }
        return s
    }

    /// Finds the photo's skyline and lines it up with the terrain's. `image` is the upright
    /// picture at any size (the intrinsics are scaled to it). `near` replaces the metadata's
    /// heading, as when the photo was lined up roughly by hand; it's searched ±20°.
    ///
    /// Without a heading the search goes all the way around: first coarsely, with the roll
    /// held near level, to find which way the photo looks, then as with a compass from there.
    /// The match only counts if no other direction fits about as well.
    public func match(_ image: RGBImage, horizon: HorizonProfile, near: Attitude? = nil) -> SkylineMatcher.Match {
        let k = intrinsics.scaled(toWidth: image.width, height: image.height)
        var matcher = SkylineMatcher()
        matcher.settings = alignmentSettings
        if let near {
            matcher.settings.headingRange = 20
            return matcher.match(image, intrinsics: k, prior: near, horizon: horizon)
        }
        guard !hasHeading else { return matcher.match(image, intrinsics: k, prior: prior, horizon: horizon) }

        var around = matcher
        around.usesSearchBand = false   // every column can hold the skyline
        around.settings.headingStep = 0.5
        around.settings.rollRange = 1
        around.settings.refineFieldOfView = false
        around.settings.rivalLimits = (matcher.settings.pitchRange, matcher.settings.rollRange)
        let found = around.match(image, intrinsics: k, prior: prior, horizon: horizon)
        var prior = self.prior
        prior.heading = found.alignment.attitude.heading
        prior.pitch = found.alignment.attitude.pitch
        matcher.settings.headingRange = 5
        var m = matcher.match(image, intrinsics: k, prior: prior, horizon: horizon)
        m.alignment.headingCorrection = azimuthDifference(m.alignment.attitude.heading, self.prior.heading)
        m.alignment.ambiguity = max(m.alignment.ambiguity, found.alignment.ambiguity)
        m.seconds += found.seconds
        if m.alignment.accepted, found.alignment.ambiguity > matcher.settings.maxAmbiguity {
            m.alignment.accepted = false
            m.alignment.rejectionReason = String(format: "ambiguous: another direction fits almost as well (%.2f)",
                                                 found.alignment.ambiguity)
        }
        return m
    }
}

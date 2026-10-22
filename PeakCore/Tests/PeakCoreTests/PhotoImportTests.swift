import XCTest
@testable import PeakCore

/// Imported photos: from the metadata ImageIO reads to the camera, and on to a match.
final class PhotoImportTests: XCTestCase {
    static let date = Date(timeIntervalSince1970: 1_750_000_000)   // June 2025

    /// ImageIO's properties for an iPhone photo, as `CGImageSourceCopyPropertiesAtIndex` gives them.
    func properties(width: Int = 4032, height: Int = 3024, orientation: Int = 1, heading: Double? = 123.4,
                    ref: String = "T", focal35: Double? = 26) -> [String: Any] {
        var gps: [String: Any] = ["Latitude": 46.0207, "LatitudeRef": "N", "Longitude": 7.7491, "LongitudeRef": "E",
                                  "Altitude": 1620.5, "AltitudeRef": 0, "HPositioningError": 4.8,
                                  "DateStamp": "2025:06:15", "TimeStamp": "14:03:22.00"]
        if let heading {
            gps["ImgDirection"] = NSNumber(value: heading)
            gps["ImgDirectionRef"] = ref
        }
        var exif: [String: Any] = ["DateTimeOriginal": "2025:06:15 16:03:22", "OffsetTimeOriginal": "+02:00",
                                   "PixelXDimension": width, "PixelYDimension": height]
        if let focal35 { exif["FocalLenIn35mmFilm"] = focal35 }
        return ["PixelWidth": width, "PixelHeight": height, "Orientation": orientation, "{GPS}": gps, "{Exif}": exif,
                "{TIFF}": ["Orientation": orientation, "Model": "iPhone 15 Pro"]]
    }

    func testReadsAnIPhonePhoto() throws {
        let m = try XCTUnwrap(PhotoMetadata(properties: properties()))
        XCTAssertEqual(m.pixelWidth, 4032)
        XCTAssertEqual(m.latitude ?? 0, 46.0207, accuracy: 1e-9)
        XCTAssertEqual(m.longitude ?? 0, 7.7491, accuracy: 1e-9)
        XCTAssertEqual(m.altitude ?? 0, 1620.5, accuracy: 1e-9)
        XCTAssertEqual(m.heading ?? 0, 123.4, accuracy: 1e-9)
        XCTAssertFalse(m.headingIsMagnetic)
        XCTAssertEqual(m.focalLength35mm, 26)
        // GPS time is UTC, and matches the camera clock less its offset.
        XCTAssertEqual(m.date?.timeIntervalSince1970 ?? 0, 1_749_996_202, accuracy: 0.5)
        var noGPSTime = properties()
        var gps = noGPSTime["{GPS}"] as! [String: Any]
        gps["DateStamp"] = nil
        noGPSTime["{GPS}"] = gps
        XCTAssertEqual(PhotoMetadata(properties: noGPSTime)?.date, m.date)

        let camera = try PhotoCamera(m)
        XCTAssertTrue(camera.hasHeading)
        XCTAssertNil(camera.declination)
        XCTAssertFalse(camera.focalLengthIsGuessed)
        XCTAssertEqual(camera.prior.heading, 123.4, accuracy: 1e-9)
        XCTAssertEqual(camera.prior.pitch, 0)
        XCTAssertEqual(camera.prior.roll, 0)
        XCTAssertEqual(camera.intrinsics.width, 4032)
        XCTAssertEqual(camera.intrinsics.height, 3024)
        // 26 mm equivalent on a 4:3 picture: about 67° across.
        XCTAssertEqual(camera.intrinsics.horizontalFOV, 67.3, accuracy: 0.2)
        XCTAssertEqual(camera.intrinsics.fx, camera.intrinsics.fy)
        XCTAssertEqual(camera.intrinsics.cx, 2016)
        XCTAssertEqual(camera.positionError, 4.8)
        XCTAssertEqual(camera.alignmentSettings.positionUncertainty, 5)   // never under the floor
    }

    func testSouthAndWestAreNegative() throws {
        var p = properties()
        var gps = p["{GPS}"] as! [String: Any]
        gps["LatitudeRef"] = "S"
        gps["LongitudeRef"] = "W"
        gps["AltitudeRef"] = 1
        p["{GPS}"] = gps
        let m = try XCTUnwrap(PhotoMetadata(properties: p))
        XCTAssertEqual(m.latitude ?? 0, -46.0207, accuracy: 1e-9)
        XCTAssertEqual(m.longitude ?? 0, -7.7491, accuracy: 1e-9)
        XCTAssertEqual(m.altitude ?? 0, -1620.5, accuracy: 1e-9)
    }

    func testMagneticHeadingGetsTheDeclination() throws {
        let m = try XCTUnwrap(PhotoMetadata(properties: properties(heading: 123.4, ref: "M")))
        XCTAssertTrue(m.headingIsMagnetic)
        let camera = try PhotoCamera(m)
        let d = try XCTUnwrap(camera.declination)
        // Zermatt: a little east of north (about +3.3° in 2025).
        XCTAssertEqual(d, 3.3, accuracy: 0.7)
        XCTAssertEqual(camera.prior.heading, 123.4 + d, accuracy: 1e-9)
        XCTAssertEqual(camera.alignmentSettings.headingRange, 25)

        // A magnetic heading near north that the declination carries past 0.
        var p = properties(heading: 359, ref: "M")
        var gps = p["{GPS}"] as! [String: Any]
        gps["Latitude"] = 47.6
        gps["Longitude"] = 122.33
        gps["LongitudeRef"] = "W"   // Seattle, about 15° east
        p["{GPS}"] = gps
        let seattle = try PhotoCamera(XCTUnwrap(PhotoMetadata(properties: p)))
        XCTAssertEqual(seattle.prior.heading, 14, accuracy: 1)
    }

    /// Against the declinations NOAA's calculator gives for mid-2025.
    func testDeclinationAroundTheWorld() {
        let places: [(String, Double, Double, Double)] = [
            ("Zermatt", 46.02, 7.75, 3.3), ("New York", 40.71, -74.01, -12.8), ("Seattle", 47.61, -122.33, 15.0),
            ("Denver", 39.74, -104.99, 7.6), ("Wellington", -41.29, 174.78, 22.8), ("Cape Town", -33.92, 18.42, -25.6),
            ("Kathmandu", 27.71, 85.32, -0.5), ("Anchorage", 61.22, -149.9, 14.0),
        ]
        for (name, lat, lon, expected) in places {
            let d = MagneticDeclination.degrees(latitude: lat, longitude: lon, date: Self.date)
            XCTAssertEqual(d, expected, accuracy: 1.2, name)
        }
    }

    func testPortraitPhotoIsTurned() throws {
        // Stored landscape, shown turned a quarter (orientation 6, the iPhone held upright).
        let m = try XCTUnwrap(PhotoMetadata(properties: properties(orientation: 6)))
        XCTAssertEqual(m.orientation, 6)
        XCTAssertEqual(m.uprightSize.width, 3024)
        XCTAssertEqual(m.uprightSize.height, 4032)
        let portrait = try PhotoCamera(m)
        let landscape = try PhotoCamera(XCTUnwrap(PhotoMetadata(properties: properties(orientation: 1))))
        XCTAssertEqual(portrait.intrinsics.width, 3024)
        XCTAssertEqual(portrait.intrinsics.height, 4032)
        // The same lens: the narrow side of the portrait picture spans the landscape's vertical view.
        XCTAssertEqual(portrait.intrinsics.horizontalFOV, landscape.intrinsics.verticalFOV, accuracy: 0.01)
        XCTAssertEqual(portrait.intrinsics.verticalFOV, landscape.intrinsics.horizontalFOV, accuracy: 0.01)
        XCTAssertEqual(portrait.prior, landscape.prior)
        // Orientations 2–4 are flips and half turns: the size stays.
        XCTAssertEqual(PhotoMetadata(properties: properties(orientation: 3))?.uprightSize.width, 4032)
    }

    func testMissingFields() throws {
        // No heading: the camera searches all the way around.
        let noHeading = try PhotoCamera(XCTUnwrap(PhotoMetadata(properties: properties(heading: nil))))
        XCTAssertFalse(noHeading.hasHeading)
        XCTAssertEqual(noHeading.alignmentSettings.headingRange, 180)

        // No focal length: an iPhone's main camera, refined by the match.
        let noLens = try PhotoCamera(XCTUnwrap(PhotoMetadata(properties: properties(focal35: nil))))
        XCTAssertTrue(noLens.focalLengthIsGuessed)
        XCTAssertTrue(noLens.alignmentSettings.refineFieldOfView)
        XCTAssertEqual(noLens.intrinsics.horizontalFOV, 67.3, accuracy: 0.2)

        // No position: nothing to label.
        var p = properties()
        p["{GPS}"] = nil
        let m = try XCTUnwrap(PhotoMetadata(properties: p))
        XCTAssertNil(m.latitude)
        XCTAssertNil(m.heading)
        XCTAssertNil(m.positionError)
        XCTAssertThrowsError(try PhotoCamera(m)) { XCTAssertEqual($0 as? PhotoCamera.Problem, .noLocation) }

        // 0, 0 is how some apps say "unknown".
        var zero = properties()
        zero["{GPS}"] = ["Latitude": 0.0, "Longitude": 0.0]
        XCTAssertNil(PhotoMetadata(properties: zero)?.latitude)

        // No size at all: not an image.
        XCTAssertNil(PhotoMetadata(properties: ["{GPS}": properties()["{GPS}"]!]))
        // Size only in the EXIF block, and nothing else.
        let bare = try XCTUnwrap(PhotoMetadata(properties: ["{Exif}": ["PixelXDimension": 800, "PixelYDimension": 600]]))
        XCTAssertEqual(bare.uprightSize.width, 800)
        XCTAssertNil(bare.date)
        XCTAssertNil(bare.focalLength35mm)
    }

    // MARK: Through to a match

    static let terrain = TestTerrain.range()

    func horizon(from observer: GeoPoint, step: Double) -> HorizonProfile {
        var s = HorizonSettings()
        s.azimuthStep = step
        s.maxDistance = 80_000
        return HorizonRenderer(terrain: Self.terrain).render(from: observer, settings: s)
    }

    /// A synthetic photo with metadata that says what an iPhone would: a compass heading
    /// some degrees off, and the phone not quite level.
    func syntheticImport(heading: Double?, orientation: Int = 1, awayFromNorth: Bool = false) throws -> (PhotoCamera, RGBImage, HorizonProfile, Attitude) {
        let renderer = HorizonRenderer(terrain: Self.terrain)
        let lat = 46.05, lon = 7.95
        let observer = renderer.observer(latitude: lat, longitude: lon)
        let world = horizon(from: observer, step: 0.05)
        let truth = Attitude(heading: awayFromNorth ? Self.farHeading(world, within: 90...270) : AlignmentTests().farHeading(world),
                             pitch: 1.8, roll: -0.9)
        let (w, h) = orientation >= 5 ? (3024, 4032) : (4032, 3024)
        var p = properties(width: orientation >= 5 ? h : w, height: orientation >= 5 ? w : h, orientation: orientation,
                           heading: heading.map { normalizedAzimuth(truth.heading + $0) }, focal35: 26)
        var gps = p["{GPS}"] as! [String: Any]
        gps["Latitude"] = lat
        gps["Longitude"] = lon
        p["{GPS}"] = gps
        let camera = try PhotoCamera(XCTUnwrap(PhotoMetadata(properties: p)))
        // The photo as the app hands it over: upright, shrunk.
        let k = camera.intrinsics.scaled(toWidth: w / 5, height: h / 5)
        var scene = SyntheticScene()
        scene.hazeDistance = 200_000
        let image = SyntheticPhoto.render(world, camera: Camera(intrinsics: k, attitude: truth), scene: scene)
        return (camera, image, horizon(from: observer, step: 0.1), truth)
    }

    /// The heading in `range` with the most skyline over 8 km away in a 50° view.
    static func farHeading(_ profile: HorizonProfile, within range: ClosedRange<Double>) -> Double {
        let half = Int(25 / profile.azimuthStep)
        func farCount(_ c: Int) -> Int {
            (-half...half).filter { profile.distances[(c + $0 + profile.count) % profile.count] > 8_000 }.count
        }
        let rays = stride(from: 0, to: profile.count, by: 10).filter { range.contains(profile.azimuth(ofRay: $0)) }
        return profile.azimuth(ofRay: rays.max { farCount($0) < farCount($1) }!)
    }

    func testSyntheticPhotoAligns() throws {
        for (error, orientation) in [(9.0, 1), (-12.0, 6)] {
            let (camera, image, horizon, truth) = try syntheticImport(heading: error, orientation: orientation)
            let m = camera.match(image, horizon: horizon)
            XCTAssertTrue(m.alignment.accepted, m.alignment.rejectionReason ?? "")
            XCTAssertEqual(azimuthDifference(m.alignment.attitude.heading, truth.heading), 0, accuracy: 0.1)
            XCTAssertEqual(m.alignment.attitude.pitch, truth.pitch, accuracy: 0.15)
            XCTAssertEqual(m.alignment.attitude.roll, truth.roll, accuracy: 0.3)
        }
    }

    func testSyntheticPhotoWithoutHeadingAligns() throws {
        // Looking well away from north, where the search starts.
        let (camera, image, horizon, truth) = try syntheticImport(heading: nil, awayFromNorth: true)
        XCTAssertFalse(camera.hasHeading)
        XCTAssertEqual(camera.prior.heading, 0)
        let m = camera.match(image, horizon: horizon)
        XCTAssertTrue(m.alignment.accepted, m.alignment.rejectionReason ?? "")
        XCTAssertEqual(azimuthDifference(m.alignment.attitude.heading, truth.heading), 0, accuracy: 0.1)
    }
}

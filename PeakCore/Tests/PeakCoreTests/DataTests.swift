import XCTest
@testable import PeakCore

final class InflateTests: XCTestCase {
    func testStoredBlocks() throws {
        let out = try Inflate.zlib([UInt8](Fixtures.stored))
        XCTAssertEqual(out.count, 2060)
        XCTAssertEqual(String(decoding: out.prefix(44), as: UTF8.self), "the quick brown fox jumps over the lazy dog ")
    }

    func testFixedHuffman() throws {
        let out = try Inflate.zlib([UInt8](Fixtures.fixed))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abcabcabcabcabc hello hello")
    }

    func testDynamicHuffman() throws {
        let out = try Inflate.zlib([UInt8](Fixtures.dynamic))
        let words = String(decoding: out, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        XCTAssertEqual(words.count, 1500)
        XCTAssertTrue(words.allSatisfy { Fixtures.dynamicWords.contains(String($0)) })
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try Inflate.zlib([0x12, 0x34, 0x56]))
        XCTAssertThrowsError(try Inflate.zlib([0x78, 0x9C, 0xFF, 0xFF, 0xFF]))
    }
}

final class GeoTIFFTests: XCTestCase {
    func testFloatTilesWithFloatingPointPredictor() throws {
        let tile = try GeoTIFF.elevationTile(Fixtures.floatTIFF)
        XCTAssertEqual(tile.rows, 20)
        XCTAssertEqual(tile.cols, 24)
        XCTAssertEqual(tile.originLatitude, 47)
        XCTAssertEqual(tile.originLongitude, 8)
        XCTAssertEqual(tile.stepLatitude, 1.0 / 3600, accuracy: 1e-15)
        XCTAssertEqual(tile.south, 46)
        XCTAssertEqual(tile.west, 8)
        let h = tile.heightValues
        for r in 0..<20 {
            for c in 0..<24 {
                let v = Float(1000 + 13.25 * Double(r) - 7.5 * Double(c) + 0.5 * sin(Double(c)))
                XCTAssertEqual(h[r * 24 + c], Int16(Double(v).rounded(.toNearestOrEven)), "row \(r) col \(c)")
            }
        }
    }

    func testInt16StripsWithHorizontalDifferencing() throws {
        let tile = try GeoTIFF.elevationTile(Fixtures.int16TIFF)
        let h = tile.heightValues
        for r in 0..<20 {
            for c in 0..<24 { XCTAssertEqual(h[r * 24 + c], Int16(500 + 3 * r + 2 * c)) }
        }
    }

    func testRejectsNonTIFF() {
        XCTAssertThrowsError(try GeoTIFF.elevationTile(Data("hello".utf8)))
    }
}

final class PeakDataTests: XCTestCase {
    func testElevationFormats() {
        XCTAssertEqual(Overpass.parseElevation("4478"), 4478)
        XCTAssertEqual(Overpass.parseElevation("4478.5"), 4478.5)
        XCTAssertEqual(Overpass.parseElevation("4,478"), 4478)
        XCTAssertEqual(Overpass.parseElevation("4478,5"), 4478.5)
        XCTAssertEqual(Overpass.parseElevation("4478 m"), 4478)
        XCTAssertEqual(Overpass.parseElevation("14505 ft")!, 4421.1, accuracy: 0.1)
        XCTAssertNil(Overpass.parseElevation("high"))
        XCTAssertNil(Overpass.parseElevation(""))
        XCTAssertNil(Overpass.parseElevation("44780"))
    }

    func testOverpassResponse() throws {
        let json = """
        {"version":0.6,"elements":[
          {"type":"node","id":1,"lat":45.9763,"lon":7.6586,"tags":{"natural":"peak","name":"Matterhorn","ele":"4478"}},
          {"type":"node","id":2,"lat":45.9,"lon":7.8,"tags":{"natural":"peak","name":"No height"}},
          {"type":"node","id":3,"lat":46.1,"lon":7.7,"tags":{"natural":"peak","ele":"3000"}}
        ]}
        """
        let peaks = try Overpass.peaks(fromJSON: Data(json.utf8))
        XCTAssertEqual(peaks, [Peak(id: 1, name: "Matterhorn", latitude: 45.9763, longitude: 7.6586, elevation: 4478)])
        XCTAssertTrue(Overpass.peaksQuery(south: 45, west: 7, north: 46, east: 8).contains("(45.0000,7.0000,46.0000,8.0000)"))
    }
}

final class UprightFrameTests: XCTestCase {
    func testRotateClockwise() {
        var image = RGBImage(width: 3, height: 2)
        image.set(0, 0, (1, 0, 0))   // top left
        image.set(2, 1, (2, 0, 0))   // bottom right
        let r = image.rotatedClockwise()
        XCTAssertEqual(r.width, 2)
        XCTAssertEqual(r.height, 3)
        XCTAssertEqual(r.pixel(1, 0).0, 1)   // top left goes to top right
        XCTAssertEqual(r.pixel(0, 2).0, 2)   // bottom right goes to bottom left
    }

    func testAttitudeFromAxesRoundTrips() {
        for a in [Attitude(heading: 37, pitch: 4, roll: -6), Attitude(heading: 300, pitch: -10, roll: 88),
                  Attitude(heading: 180, pitch: 20, roll: -91)] {
            let axes = a.axes
            let b = Attitude(right: axes.right, down: axes.down, forward: axes.forward)
            XCTAssertEqual(azimuthDifference(b.heading, a.heading), 0, accuracy: 1e-9)
            XCTAssertEqual(b.pitch, a.pitch, accuracy: 1e-9)
            XCTAssertEqual(b.roll, a.roll, accuracy: 1e-9)
        }
    }

    /// A phone held upright delivers landscape frames with the sky on one side. Turned
    /// upright, every pixel must still look in the same direction as before.
    func testSidewaysFrameTurnsUpright() {
        let k = CameraIntrinsics(width: 64, height: 48, fx: 50, fy: 51, cx: 31, cy: 25)
        // The sensor's x axis points down in the world: roll of +90° from level.
        let sensor = Attitude(heading: 120, pitch: 3, roll: 90)
        let axes = sensor.axes
        var image = RGBImage(width: 64, height: 48)
        image.set(10, 5, (255, 0, 0))
        let frame = UprightFrame(image: image, intrinsics: k, right: axes.right, down: axes.down, forward: axes.forward)
        XCTAssertEqual(frame.image.width, 48)
        XCTAssertEqual(frame.image.height, 64)
        XCTAssertEqual(frame.camera.attitude.roll, 0, accuracy: 1e-9)
        XCTAssertEqual(frame.camera.attitude.heading, 120, accuracy: 1e-9)

        // Find the marked pixel and compare the directions it looks in.
        var marked = (0, 0)
        for y in 0..<frame.image.height {
            for x in 0..<frame.image.width where frame.image.pixel(x, y).0 == 255 { marked = (x, y) }
        }
        let before = Camera(intrinsics: k, attitude: sensor).projector.look(x: 10.5, y: 5.5)
        let after = frame.camera.projector.look(x: Double(marked.0) + 0.5, y: Double(marked.1) + 0.5)
        XCTAssertEqual(azimuthDifference(after.azimuth, before.azimuth), 0, accuracy: 1e-9)
        XCTAssertEqual(after.elevation, before.elevation, accuracy: 1e-9)
    }
}

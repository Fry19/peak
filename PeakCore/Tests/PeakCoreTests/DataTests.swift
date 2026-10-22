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

    func testOverviewLevelsFromRangedReads() throws {
        let bytes = [UInt8](Fixtures.pyramidTIFF)
        // tifffile writes the overview's directory after the first image's data, unlike a
        // cloud-optimized file, so a short prefix doesn't hold it.
        XCTAssertThrowsError(try GeoTIFF.layout(Array(bytes.prefix(1024))))
        let layout = try GeoTIFF.layout(bytes)
        XCTAssertEqual(layout.images.map(\.width), [32, 16])
        // Decode the overview from just its own bytes, as the app does with a range request.
        let range = layout.images[1].byteRange
        let overview = try GeoTIFF.decode(layout, level: 1, bytes: Array(bytes[range]), base: range.lowerBound)
        XCTAssertEqual(overview.rows, 16)
        XCTAssertEqual(overview.south, 45)
        XCTAssertEqual(overview.west, 9)
        let h = overview.heightValues
        for r in 0..<16 {
            for c in 0..<16 { XCTAssertEqual(h[r * 16 + c], Int16(2007 + 20 * r + 8 * c)) }
        }
        // Both levels describe the same plane, so they must agree everywhere in between:
        // this checks the overview's pixel positions.
        let full = Terrain(tiles: [try GeoTIFF.elevationTile(Fixtures.pyramidTIFF, level: 0)])
        let coarse = Terrain(tiles: [overview])
        var rng = SplitMix64(seed: 4)
        for _ in 0..<200 {
            let lat = 46 - (1 + 29 * rng.uniform()) / 3600, lon = 9 + (1 + 29 * rng.uniform()) / 3600
            XCTAssertEqual(coarse.height(latitude: lat, longitude: lon), full.height(latitude: lat, longitude: lon), accuracy: 0.01)
        }
    }

    /// The app fetches just the blocks around the viewer at full resolution. Decoded on
    /// their own or a few at a time, they must match the whole image pixel for pixel.
    func testBlocksDecodeOnTheirOwn() throws {
        let bytes = [UInt8](Fixtures.floatTIFF)
        let layout = try GeoTIFF.layout(bytes)
        let full = try GeoTIFF.decode(layout, level: 0, bytes: bytes, base: 0)
        XCTAssertEqual(layout.images[0].blockCount, 4)   // 24×20 in 16×16 tiles
        func data(_ index: Int) -> ArraySlice<UInt8> { bytes[layout.images[0].byteRange(ofBlock: index)] }

        // The bottom-right block alone: 8 columns by 4 rows, starting at pixel (16, 16).
        let corner = try GeoTIFF.decode(layout, level: 0, blocks: [3], data: data)
        XCTAssertEqual(corner.rows, 4)
        XCTAssertEqual(corner.cols, 8)
        XCTAssertEqual(corner.originLatitude, full.originLatitude - 16 * full.stepLatitude, accuracy: 1e-12)
        XCTAssertEqual(corner.originLongitude, full.originLongitude + 16 * full.stepLongitude, accuracy: 1e-12)
        let f = full.heightValues, h = corner.heightValues
        for r in 0..<4 {
            for c in 0..<8 { XCTAssertEqual(h[r * 8 + c], f[(16 + r) * 24 + 16 + c]) }
        }

        // Two diagonal blocks: the rectangle around them, with no data in the other two.
        let diagonal = try GeoTIFF.decode(layout, level: 0, blocks: [0, 3], data: data).heightValues
        XCTAssertEqual(diagonal[0], f[0])
        XCTAssertEqual(diagonal[19 * 24 + 23], f[19 * 24 + 23])
        XCTAssertEqual(diagonal[0 * 24 + 20], ElevationTile.noData)
        XCTAssertEqual(diagonal[18 * 24 + 2], ElevationTile.noData)

        // Blocks decoded one at a time and merged give back the whole image.
        let parts = try (0..<4).map { try GeoTIFF.decode(layout, level: 0, blocks: [$0], data: data) }
        let merged = try XCTUnwrap(ElevationTile(merging: parts.reversed()))
        XCTAssertEqual(merged.rows, 20)
        XCTAssertEqual(merged.cols, 24)
        XCTAssertEqual(merged.originLatitude, full.originLatitude, accuracy: 1e-12)
        XCTAssertEqual(merged.originLongitude, full.originLongitude, accuracy: 1e-12)
        XCTAssertEqual(merged.heightValues, f)
    }

    func testBlocksCoveringAnArea() throws {
        let layout = try GeoTIFF.layout([UInt8](Fixtures.floatTIFF))
        let step = 1.0 / 3600
        // Pixel centers start at 47°N 8°E; blocks are 16 pixels square, two across.
        XCTAssertEqual(layout.blocks(level: 0, south: 47 - 5 * step, north: 47, west: 8, east: 8 + 5 * step), [0])
        XCTAssertEqual(layout.blocks(level: 0, south: 47 - 5 * step, north: 47, west: 8 + 15.5 * step, east: 8 + 17 * step), [0, 1])
        XCTAssertEqual(layout.blocks(level: 0, south: 47 - 18 * step, north: 47 - 17 * step, west: 8 + 18 * step, east: 8 + 19 * step), [3])
        XCTAssertEqual(layout.blocks(level: 0, south: 40, north: 41, west: 8, east: 9), [])
    }

    func testRejectsNonTIFF() {
        XCTAssertThrowsError(try GeoTIFF.elevationTile(Data("hello".utf8)))
    }

    /// A USGS 3DEP-like tile: LZW with the floating-point predictor, reaching past its 1°
    /// cell on every side. It belongs to the cell its middle is in, not its first pixel's.
    func testLZWTileReachingPastItsCell() throws {
        let bytes = [UInt8](Fixtures.lzwTIFF)
        let layout = try GeoTIFF.layout(bytes)
        XCTAssertEqual(layout.south, 35)
        XCTAssertEqual(layout.west, -84)
        let tile = try GeoTIFF.decode(layout, level: 0, bytes: bytes, base: 0)
        XCTAssertEqual(tile.south, 35)
        XCTAssertEqual(tile.west, -84)
        let step = 1.0 / 36
        XCTAssertEqual(tile.stepLatitude, step, accuracy: 1e-12)
        // The tie point is the first pixel's corner, two pixels past the cell.
        XCTAssertEqual(tile.originLatitude, 36 + 1.5 * step, accuracy: 1e-12)
        XCTAssertEqual(tile.originLongitude, -84 - 1.5 * step, accuracy: 1e-12)
        let h = tile.heightValues
        for r in 0..<40 {
            for c in 0..<40 {
                let expected = r == 5 && c == 7 ? ElevationTile.noData : Int16((1000 + 3 * Double(r) - 2 * Double(c) + 0.25).rounded(.toNearestOrEven))
                XCTAssertEqual(h[r * 40 + c], expected, "row \(r) col \(c)")
            }
        }
        // The overview, from its own bytes.
        let range = layout.images[1].byteRange
        let overview = try GeoTIFF.decode(layout, level: 1, bytes: Array(bytes[range]), base: range.lowerBound)
        XCTAssertEqual(overview.rows, 20)
        XCTAssertEqual(overview.south, 35)
        XCTAssertEqual(overview.heightValues[3 * 20 + 4], 1000 + 6 * 3 - 4 * 4)
        // Blocks are found for an area of the cell, and one block decodes on its own.
        let blocks = layout.blocks(level: 0, south: 35.0, north: 35.12, west: -83.12, east: -83.0)
        XCTAssertEqual(blocks, [8])
        let one = try GeoTIFF.decode(layout, level: 0, blocks: blocks) { bytes[layout.images[0].byteRange(ofBlock: $0)] }
        XCTAssertEqual(one.heightValues[0], h[32 * 40 + 32])
    }

    func testLZWStripsWithoutPredictor() throws {
        let tile = try GeoTIFF.elevationTile(Fixtures.lzwStripTIFF)
        XCTAssertEqual(tile.rows, 10)
        XCTAssertEqual(tile.cols, 12)
        let h = tile.heightValues
        for r in 0..<10 {
            for c in 0..<12 { XCTAssertEqual(h[r * 12 + c], Int16(2500 + 10 * r + c)) }
        }
    }
}

final class LZWTests: XCTestCase {
    /// A stream long enough to widen codes to 12 bits and clear the table, from Python's
    /// imagecodecs (libtiff's encoder).
    func testDecodesAcrossWidthsAndClears() throws {
        var state: UInt32 = 12345
        var expected = [UInt8]()
        for _ in 0..<48_000 {
            state = (state &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            expected.append(65 + UInt8((state >> 16) % 2))
        }
        let packed = [UInt8](Fixtures.lzwStream)
        XCTAssertGreaterThan(packed.count * 8 / 12, 4096, "the stream should need a clear")
        XCTAssertEqual(try LZW.decode(packed[...], expectedSize: expected.count), expected)
    }

    func testSmallStreams() throws {
        // Clear, "A", "B", "AB" (code 258, defined from the first two), end; 9-bit codes.
        func pack(_ codes: [Int]) -> [UInt8] {
            var bits = [Bool]()
            for c in codes { for k in (0..<9).reversed() { bits.append(c >> k & 1 == 1) } }
            while bits.count % 8 != 0 { bits.append(false) }
            return stride(from: 0, to: bits.count, by: 8).map { i in
                bits[i..<(i + 8)].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
            }
        }
        XCTAssertEqual(try LZW.decode(pack([256, 65, 66, 258, 257])[...]), Array("ABAB".utf8))
        // A code used in the same step that defines it: "A", then 258 = "A" + "A".
        XCTAssertEqual(try LZW.decode(pack([256, 65, 258, 257])[...]), Array("AAA".utf8))
        // A code from beyond the table is an error, not garbage.
        XCTAssertThrowsError(try LZW.decode(pack([256, 65, 300, 257])[...]))
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
        XCTAssertEqual(peaks.map(\.id), [1, 2], "unnamed peaks are left out")
        XCTAssertEqual(peaks[0], Peak(id: 1, name: "Matterhorn", latitude: 45.9763, longitude: 7.6586, elevation: 4478))
        // No elevation in OpenStreetMap: kept, for the terrain to fill in.
        XCTAssertTrue(peaks[1].estimatedElevation)
        XCTAssertFalse(peaks[0].estimatedElevation)
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

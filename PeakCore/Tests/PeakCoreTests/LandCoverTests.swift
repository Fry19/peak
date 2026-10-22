import XCTest
@testable import PeakCore

final class LandCoverTests: XCTestCase {
    private let center = LatLon(46, 7.8)

    /// A flat grid of 11 by 11 points 100 m apart around `center`: points from −500 to 500 m.
    private func grid() -> ReliefMap {
        ReliefMap(center: center, cellSize: 100, rows: 11, cols: 11, heights: [Float](repeating: 2_000, count: 121))
    }

    /// A closed ring through map points (meters east and north of `center`).
    private func ring(_ points: [(Double, Double)]) -> [LatLon] {
        let projection = MapProjection(center: center)
        let ring = points.map { projection.latLon(SIMD2($0.0, $0.1)) }
        return ring + [ring[0]]
    }

    private func square(_ half: Double) -> [LatLon] {
        ring([(-half, -half), (half, -half), (half, half), (-half, half)])
    }

    /// The value at the grid point `x`, `y` meters east and north of the center.
    private func at(_ values: [Float], _ x: Double, _ y: Double) -> Float {
        values[Int(5 - y / 100) * 11 + Int(5 + x / 100)]
    }

    func testSquareCoversItsCells() {
        let cover = grid().landCover([LandCoverArea(id: 1, cover: .glacier, rings: [square(200)])])
        XCTAssertEqual(at(cover.glacier, 0, 0), 1)
        XCTAssertEqual(at(cover.glacier, 100, -100), 1)
        // The edge runs through the middle of these points' squares.
        XCTAssertEqual(at(cover.glacier, 200, 0), 0.5, accuracy: 1e-5)
        XCTAssertEqual(at(cover.glacier, 0, -200), 0.5, accuracy: 1e-5)
        XCTAssertEqual(at(cover.glacier, 200, 200), 0.25, accuracy: 1e-5)
        XCTAssertEqual(at(cover.glacier, 300, 0), 0)
        XCTAssertEqual(at(cover.glacier, -500, 500), 0)
        // All of it, and nothing more: 400 m by 400 m is 16 squares of 100 m.
        XCTAssertEqual(cover.glacier.reduce(0, +), 16, accuracy: 1e-3)
        XCTAssertEqual(cover.rock.reduce(0, +), 0)
        XCTAssertEqual(cover.water.reduce(0, +), 0)
        XCTAssertFalse(cover.isEmpty)
        XCTAssertTrue(grid().landCover([]).isEmpty)
    }

    func testInnerRingsAreHoles() {
        // A lake with an island, the shore in two ways joined at their ends.
        let cover = grid().landCover([LandCoverArea(id: -7, cover: .water, rings: [square(400), square(100)])])
        XCTAssertEqual(at(cover.water, 0, 0), 0, "the island")
        XCTAssertEqual(at(cover.water, 300, 0), 1)
        XCTAssertEqual(at(cover.water, -200, 300), 1)
        XCTAssertEqual(cover.water.reduce(0, +), 64 - 4, accuracy: 1e-3)
    }

    /// Slanted edges cut squares partly; what's covered adds up to the area all the same.
    func testSlantedEdgesCoverTheirShare() {
        let triangle = ring([(-450, -450), (450, -450), (-450, 450)])
        let cover = grid().landCover([LandCoverArea(id: 1, cover: .rock, rings: [triangle])])
        let area = Double(cover.rock.reduce(0, +)) * 100 * 100
        let half: Double = 900 * 900 / 2
        XCTAssertEqual(area, half, accuracy: half * 0.01)
        XCTAssertEqual(at(cover.rock, -300, -300), 1)
        XCTAssertEqual(at(cover.rock, 300, 300), 0)
        // On the diagonal: about half.
        XCTAssertEqual(at(cover.rock, 0, 0), 0.5, accuracy: 0.1)
    }

    func testCoversAreKeptApartAndDontAddUpPastAll() {
        let cover = grid().landCover([
            LandCoverArea(id: 1, cover: .glacier, rings: [square(300)]),
            LandCoverArea(id: 2, cover: .glacier, rings: [square(200)]),   // mapped twice
            LandCoverArea(id: 3, cover: .water, rings: [square(100)]),
        ])
        XCTAssertEqual(at(cover.glacier, 0, 0), 1)
        XCTAssertEqual(at(cover.water, 0, 0), 1)
        XCTAssertEqual(at(cover.water, 200, 0), 0)
        XCTAssertEqual(cover[.glacier], cover.glacier)
    }

    /// An area reaching past the grid fills it to the edge and no further.
    func testAreasLargerThanTheGrid() {
        let cover = grid().landCover([LandCoverArea(id: 1, cover: .glacier, rings: [square(5_000)])])
        XCTAssertEqual(cover.glacier.reduce(0, +), 121, accuracy: 1e-3)
        let away = ring([(2_000, 2_000), (3_000, 2_000), (3_000, 3_000)])
        XCTAssertTrue(grid().landCover([LandCoverArea(id: 2, cover: .water, rings: [away])]).isEmpty)
    }

    /// Past the edge of what was fetched there's no cover, and it fades in inside it.
    func testFadesInFromTheEdgeOfWhatWasFetched() {
        let fetched = GeoBox(MapExtent(center: MapProjection(center: center).latLon(SIMD2(-100, 0)), width: 800, height: 2_000))
        // Fetched from 500 m west to 300 m east.
        let cover = grid().landCover([LandCoverArea(id: 1, cover: .glacier, rings: [square(5_000)])], within: fetched, fade: 200)
        XCTAssertEqual(at(cover.glacier, 400, 0), 0)
        XCTAssertEqual(at(cover.glacier, 300, 0), 0, accuracy: 1e-4, "on the edge")
        XCTAssertEqual(at(cover.glacier, 200, 0), 0.5, accuracy: 1e-3, "halfway in")
        XCTAssertEqual(at(cover.glacier, 100, 0), 1, accuracy: 1e-4)
        XCTAssertEqual(at(cover.glacier, -200, 0), 1, accuracy: 1e-4)
        XCTAssertEqual(at(cover.glacier, -400, 0), 0.5, accuracy: 1e-3)
        // A hard edge without a fade.
        let hard = grid().landCover([LandCoverArea(id: 1, cover: .glacier, rings: [square(5_000)])], within: fetched)
        XCTAssertEqual(at(hard.glacier, 200, 0), 1, accuracy: 1e-4)
        XCTAssertEqual(at(hard.glacier, 400, 0), 0)
    }

    func testOverpassAreas() throws {
        let json = """
        {"elements":[
          {"type":"way","id":1,"tags":{"natural":"glacier","name":"Gornergletscher"},
           "geometry":[{"lat":45.9,"lon":7.8},{"lat":45.9,"lon":7.81},{"lat":45.91,"lon":7.81},{"lat":45.9,"lon":7.8}]},
          {"type":"way","id":2,"tags":{"natural":"scree"},
           "geometry":[{"lat":45.9,"lon":7.8},{"lat":45.9,"lon":7.81},{"lat":45.91,"lon":7.81}]},
          {"type":"way","id":3,"tags":{"natural":"wood"},
           "geometry":[{"lat":45.9,"lon":7.8},{"lat":45.9,"lon":7.81},{"lat":45.91,"lon":7.81},{"lat":45.9,"lon":7.8}]},
          {"type":"way","id":4,"tags":{"waterway":"riverbank"},
           "geometry":[{"lat":46.0,"lon":7.8},{"lat":46.0,"lon":7.81},{"lat":46.01,"lon":7.81},{"lat":46.0,"lon":7.8}]},
          {"type":"way","id":5,"tags":{"natural":"bare_rock"},
           "geometry":[{"lat":46.1,"lon":7.8},{"lat":46.1,"lon":7.81},{"lat":46.11,"lon":7.81},{"lat":46.1,"lon":7.8}]},
          {"type":"relation","id":10,"tags":{"type":"multipolygon","natural":"water"},
           "members":[
             {"type":"way","ref":20,"role":"outer","geometry":[{"lat":46.0,"lon":7.0},{"lat":46.0,"lon":7.1},{"lat":46.1,"lon":7.1}]},
             {"type":"way","ref":21,"role":"outer","geometry":[{"lat":46.0,"lon":7.0},{"lat":46.1,"lon":7.0},{"lat":46.1,"lon":7.1}]},
             {"type":"way","ref":22,"role":"inner","geometry":[{"lat":46.04,"lon":7.04},{"lat":46.04,"lon":7.06},{"lat":46.06,"lon":7.06},{"lat":46.04,"lon":7.04}]}
           ]},
          {"type":"relation","id":11,"tags":{"type":"multipolygon","natural":"glacier"},
           "members":[
             {"type":"way","ref":30,"role":"outer","geometry":[{"lat":46.2,"lon":7.0},{"lat":46.2,"lon":7.1},{"lat":46.3,"lon":7.1}]},
             {"type":"way","ref":31,"role":"outer"}
           ]}
        ]}
        """
        let areas = try Overpass.landCover(fromJSON: Data(json.utf8))
        XCTAssertEqual(areas.map(\.id), [1, 4, 5, -10], "open rings, other covers and incomplete relations are left out")
        XCTAssertEqual(areas.map(\.cover), [.glacier, .water, .rock, .water])
        let lake = areas[3]
        XCTAssertEqual(lake.rings.count, 2, "the shore joined into one ring, and the island")
        for ring in lake.rings { XCTAssertEqual(ring.first, ring.last) }
        XCTAssertEqual(lake.rings.map(\.count).sorted(), [4, 5])
        XCTAssertEqual(lake.bounds, GeoBox(south: 46.0, west: 7.0, north: 46.1, east: 7.1))
        XCTAssertEqual(LandCover(tags: ["natural": "scree"]), .rock)
        XCTAssertNil(LandCover(tags: ["landuse": "meadow"]))

        let query = Overpass.landCoverQuery(south: 45.9, west: 7.7, north: 46.0, east: 7.8)
        XCTAssertTrue(query.contains("(45.90000,7.70000,46.00000,7.80000)"))
        XCTAssertTrue(query.contains("out geom;"), "relations with their members' points")
        XCTAssertFalse(query.contains("geom("), "not clipped, so rings stay closed")
    }

    func testKeptCompactly() throws {
        let areas = [
            LandCoverArea(id: -14_779_748, cover: .glacier, rings: [square(300), square(100)]),
            LandCoverArea(id: 25_385_199, cover: .rock, rings: [ring([(0, 0), (10, 0), (10, 10)])]),
        ]
        let data = LandCoverArea.encode(areas)
        XCTAssertLessThan(data.count, 20 + 2 * 17 + 3 * 4 + (5 + 5 + 4) * 8 + 1)
        let back = try LandCoverArea.decode(data)
        XCTAssertEqual(back.map(\.id), areas.map(\.id))
        XCTAssertEqual(back.map(\.cover), areas.map(\.cover))
        for (a, b) in zip(back.flatMap(\.rings).flatMap { $0 }, areas.flatMap(\.rings).flatMap { $0 }) {
            XCTAssertEqual(a.latitude, b.latitude, accuracy: 1e-7)
            XCTAssertEqual(a.longitude, b.longitude, accuracy: 1e-7)
        }
        XCTAssertEqual(back[0].rings[0].first, back[0].rings[0].last, "rings stay closed")
        XCTAssertEqual(try LandCoverArea.decode(LandCoverArea.encode([])), [])
        XCTAssertThrowsError(try LandCoverArea.decode(data.dropLast(3)))
        XCTAssertThrowsError(try LandCoverArea.decode(Data("{\"elements\":[]}".utf8)))
    }

    func testCells() {
        let box = GeoBox(south: 45.95, west: 7.71, north: 46.12, east: 7.88)
        let cells = LandCoverCell.covering(box)
        XCTAssertEqual(cells.count, 6)
        XCTAssertEqual(cells.first, LandCoverCell(south: 459, west: 77))
        XCTAssertEqual(cells.last, LandCoverCell(south: 461, west: 78))
        XCTAssertEqual(cells.first?.fileName, "459_77.pklc")
        XCTAssertEqual(LandCoverCell(LatLon(-0.05, -0.05)), LandCoverCell(south: -1, west: -1))
        XCTAssertEqual(LandCoverCell(south: 459, west: 77).box, GeoBox(south: 45.9, west: 7.7, north: 46.0, east: 7.8))
        for cell in cells { XCTAssertTrue(cell.box.intersects(box)) }

        // Fetched in blocks of up to 3 by 3, each cell once.
        let wide = LandCoverCell.covering(GeoBox(south: 45.0, west: 7.0, north: 45.55, east: 7.55))
        XCTAssertEqual(wide.count, 36)
        let batches = LandCoverCell.batches(wide)
        XCTAssertEqual(batches.count, 4)
        XCTAssertEqual(batches.map(\.count), [9, 9, 9, 9])
        XCTAssertEqual(Set(batches.flatMap { $0 }), Set(wide))
        XCTAssertEqual(LandCoverCell.box(batches[0]), GeoBox(south: 45.0, west: 7.0, north: 45.3, east: 7.3))
        XCTAssertNil(LandCoverCell.box([]))
    }

    func testBoxes() {
        let extent = MapExtent(center: center, width: 2_000, height: 1_000)
        let box = GeoBox(extent, margin: 500)
        let projection = MapProjection(center: center)
        XCTAssertEqual(projection.point(LatLon(box.north, box.east)).x, 1_500, accuracy: 1e-6)
        XCTAssertEqual(projection.point(LatLon(box.north, box.east)).y, 1_000, accuracy: 1e-6)
        XCTAssertEqual(projection.point(LatLon(box.south, box.west)).y, -1_000, accuracy: 1e-6)
        let other = GeoBox(south: box.south - 1, west: box.west + 0.001, north: box.north - 0.001, east: box.east + 1)
        XCTAssertEqual(box.intersection(other), GeoBox(south: box.south, west: box.west + 0.001, north: box.north - 0.001, east: box.east))
        XCTAssertNil(box.intersection(GeoBox(south: box.north + 0.1, west: box.west, north: box.north + 0.2, east: box.east)))
        let relief = grid().box
        XCTAssertEqual(projection.point(LatLon(relief.south, relief.west)).x, -500, accuracy: 1e-6)
    }
}

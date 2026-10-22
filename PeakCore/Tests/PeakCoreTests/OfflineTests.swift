import XCTest
@testable import PeakCore

final class OfflineTests: XCTestCase {
    func testPeakCellKeys() {
        // Just west of Greenwich and just south of the equator round to the same cell as
        // just east and north of them, with one file name.
        let a = PeakCell(latitude: -0.05, longitude: -0.1, radius: 80_000)
        let b = PeakCell(latitude: 0.05, longitude: 0.1, radius: 80_000)
        XCTAssertEqual(a.fileName, "0.00_0.00_80_v2.json")
        XCTAssertEqual(a, b)
        XCTAssertEqual(PeakCell(latitude: 45.98, longitude: 7.66, radius: 80_000).fileName, "46.00_7.75_80_v2.json")
        XCTAssertEqual(PeakCell(fileName: "-0.00_7.75_80_v2.json"), PeakCell(latitude: 0, longitude: 7.75, radius: 80_000))
        XCTAssertEqual(PeakCell(fileName: "46.00_-121.75_80_v2.json")?.longitude, -121.75)
        XCTAssertNil(PeakCell(fileName: "46.00_7.75_80.json"), "before volcanoes")
        XCTAssertNil(PeakCell(fileName: "areas.json"))
    }

    /// Hiked into the next cell with no signal: the first cell's file still covers you.
    func testNearestCoveringCell() {
        let trailhead = PeakCell(latitude: 46.0, longitude: 7.75, radius: 80_000)
        let far = PeakCell(latitude: 47.5, longitude: 7.75, radius: 80_000)
        let otherRadius = PeakCell(latitude: 46.25, longitude: 7.75, radius: 40_000)
        let here = LatLon(46.2, 7.8)   // in the 46.25 cell
        XCTAssertNotEqual(PeakCell(latitude: here.latitude, longitude: here.longitude, radius: 80_000), trailhead)
        XCTAssertEqual(PeakCell.nearestCovering(here, radius: 80_000, among: [far, otherRadius, trailhead]), trailhead)
        XCTAssertNil(PeakCell.nearestCovering(LatLon(48.5, 7.8), radius: 80_000, among: [trailhead]))
    }

    func testSplitBoxes() {
        let box = GeoBox(around: LatLon(46, 7.7), radius: 58_000)
        let parts = box.split(side: 30_000)
        XCTAssertEqual(parts.count, 16)
        XCTAssertEqual(parts.first?.south, box.south)
        XCTAssertEqual(parts.last?.east, box.east)
        // Every point of the box is in one of them.
        for p in [LatLon(46, 7.7), LatLon(box.south, box.west), LatLon(box.north, box.east), LatLon(45.7, 8.2)] {
            XCTAssertTrue(parts.contains { $0.contains(p) }, "\(p)")
        }
        XCTAssertEqual(GeoBox(around: LatLon(46, 7.7), radius: 5_000).split(side: 30_000).count, 1)
    }

    /// A path crossing the edge between two boxes comes back clipped from each; merged, it's
    /// whole again, as is a route.
    func testMergeClippedResponses() throws {
        let west = """
        {"elements":[
          {"type":"relation","id":10,"tags":{"route":"hiking","name":"Tour"},
           "members":[{"type":"way","ref":1,"geometry":[{"lat":46.0,"lon":7.0},{"lat":46.0,"lon":7.01},null]}]},
          {"type":"way","id":5,"tags":{"highway":"path","name":"Ridge Path"},
           "geometry":[{"lat":46.1,"lon":7.0},{"lat":46.1,"lon":7.01},null]}
        ]}
        """
        let east = """
        {"elements":[
          {"type":"relation","id":10,"tags":{"route":"hiking","name":"Tour"},
           "members":[{"type":"way","ref":1,"geometry":[null,{"lat":46.0,"lon":7.01},{"lat":46.0,"lon":7.02}]}]},
          {"type":"way","id":5,"tags":{"highway":"path","name":"Ridge Path"},
           "geometry":[null,{"lat":46.1,"lon":7.01},{"lat":46.1,"lon":7.02}]},
          {"type":"way","id":6,"tags":{"highway":"path","name":"Other"},
           "geometry":[{"lat":46.2,"lon":7.0},{"lat":46.2,"lon":7.01}]}
        ]}
        """
        let merged = try Overpass.merge([Data(west.utf8), Data(east.utf8)])
        let trails = try Overpass.trails(fromJSON: merged, minLength: 0).sorted { $0.id < $1.id }
        XCTAssertEqual(trails.map(\.id), ["p:Other", "p:Ridge Path", "r10"])
        for t in trails where t.id != "p:Other" {
            XCTAssertFalse(t.isPartial, t.id)
            XCTAssertEqual(t.lines.map(\.count), [3], t.id)
        }
    }

    /// Ways of one name 40 km apart are two hikes; a small gap in one doesn't split it.
    func testNamedPathsGroupByNearness() throws {
        let json = """
        {"elements":[
          {"type":"way","id":1,"tags":{"highway":"path","name":"Spur Trail","sac_scale":"hiking"},
           "geometry":[{"lat":46.00,"lon":7.00},{"lat":46.01,"lon":7.00}]},
          {"type":"way","id":2,"tags":{"highway":"path","name":"Spur Trail"},
           "geometry":[{"lat":46.0105,"lon":7.00},{"lat":46.02,"lon":7.00}]},
          {"type":"way","id":3,"tags":{"highway":"path","name":"Spur Trail","sac_scale":"alpine_hiking"},
           "geometry":[{"lat":46.36,"lon":7.00},{"lat":46.37,"lon":7.00}]}
        ]}
        """
        let trails = try Overpass.trails(fromJSON: Data(json.utf8)).sorted { $0.id < $1.id }
        XCTAssertEqual(trails.map(\.id), ["p:Spur Trail#1", "p:Spur Trail#3"])
        XCTAssertEqual(trails[0].lines.count, 2, "55 m apart: one hike")
        XCTAssertEqual(trails[0].mappedLength, 2_169, accuracy: 5)
        XCTAssertEqual(trails[0].difficulty, .hiking)
        XCTAssertEqual(trails[1].mappedLength, 1_112, accuracy: 3)
        XCTAssertEqual(trails[1].difficulty, .alpineHiking)

        XCTAssertEqual(Trail.groups([[LatLon(0, 0), LatLon(0, 0.01)], [LatLon(1, 0), LatLon(1, 0.01)],
                                     [LatLon(0.001, 0.005), LatLon(0.01, 0.005)]], within: 250), [[0, 2], [1]],
                       "an end near the middle of another line joins it")
    }

    func testAreaQueryAsksForPathsNearEverySummit() {
        let q = Overpass.trailsQuery(south: 46, west: 7, north: 46.2, east: 7.3, everySummit: true)
        XCTAssertTrue(q.contains("->.summits;"), q)
        XCTAssertTrue(q.contains("[!\"name\"](around.summits:400)(46.00000,7.00000,46.20000,7.30000);"), q)
    }
}

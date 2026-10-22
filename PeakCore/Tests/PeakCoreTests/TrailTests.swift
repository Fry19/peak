import XCTest
@testable import PeakCore

final class TrailTests: XCTestCase {
    func testSacScale() {
        XCTAssertEqual(Difficulty(sacScale: "mountain_hiking"), .mountainHiking)
        XCTAssertEqual(Difficulty(sacScale: "T5"), .demandingAlpineHiking)
        XCTAssertNil(Difficulty(sacScale: "yes"))
        XCTAssertEqual(Difficulty.alpineHiking.grade, "T4")
        XCTAssertTrue(Difficulty.hiking < .difficultAlpineHiking)
    }

    /// Ways of a route come in any order and direction; joined, they make one line, and a
    /// branch that doesn't continue it stays separate.
    func testChainJoinsWaysAtSharedEnds() {
        let a = LatLon(46.00, 7.00), b = LatLon(46.01, 7.00), c = LatLon(46.02, 7.00), d = LatLon(46.03, 7.00)
        let mid = LatLon(46.015, 7.001)
        let lines = Trail.chain([[c, d], [b, a], [b, mid, c], [LatLon(46.1, 7.1), LatLon(46.1, 7.11)]])
        XCTAssertEqual(lines.count, 2)
        let main = lines[0]
        XCTAssertEqual(main.count, 5)
        XCTAssertTrue(main == [a, b, mid, c, d] || main == [d, c, mid, b, a], "\(main)")
        XCTAssertEqual(Trail.chain([[a]]), [])
    }

    func testLengthAndClosestApproach() {
        // 0.01° of latitude is about 1112 m.
        let trail = Trail(id: "t", name: "T", kind: .path, lines: [[LatLon(46.00, 7.00), LatLon(46.01, 7.00), LatLon(46.02, 7.00)]])
        XCTAssertEqual(trail.length, 2_224, accuracy: 3)
        XCTAssertEqual(trail.distance(to: LatLon(46.005, 7.01)), 773, accuracy: 3)   // beside the middle
        XCTAssertEqual(trail.distance(to: LatLon(46.03, 7.00)), 1_112, accuracy: 3)  // past the end
        let dense = trail.densified(spacing: 100)[0]
        XCTAssertEqual(dense.count, 25)
        XCTAssertTrue(zip(dense, dense.dropFirst()).allSatisfy { $0.distance(to: $1) <= 100 })
    }

    func testOverpassTrails() throws {
        let json = """
        {"elements":[
          {"type":"relation","id":10,"tags":{"type":"route","route":"hiking","name":"Hörnli Trail","network":"lwn","distance":"12 km"},
           "members":[
             {"type":"way","ref":1,"role":"","geometry":[{"lat":46.00,"lon":7.00},{"lat":46.01,"lon":7.00}]},
             {"type":"way","ref":2,"role":"","geometry":[{"lat":46.02,"lon":7.00},{"lat":46.01,"lon":7.00}]},
             {"type":"way","ref":3,"role":""},
             {"type":"node","ref":99,"role":"guidepost","lat":46.0,"lon":7.0}]},
          {"type":"relation","id":11,"tags":{"type":"superroute","route":"hiking","name":"Big Tour"},
           "members":[{"type":"relation","ref":10,"role":""}]},
          {"type":"way","id":2,"tags":{"highway":"path","sac_scale":"alpine_hiking"}},
          {"type":"way","id":1,"tags":{"highway":"path","name":"Hörnli Trail","sac_scale":"mountain_hiking"},
           "geometry":[{"lat":46.00,"lon":7.00},{"lat":46.01,"lon":7.00}]},
          {"type":"way","id":20,"tags":{"highway":"path","name":"Lake Path","sac_scale":"hiking"},
           "geometry":[{"lat":46.10,"lon":7.10},{"lat":46.104,"lon":7.10}]},
          {"type":"way","id":21,"tags":{"highway":"path","name":"Lake Path"},
           "geometry":[{"lat":46.108,"lon":7.10},{"lat":46.104,"lon":7.10},null,{"lat":46.2,"lon":7.2}]},
          {"type":"way","id":30,"tags":{"highway":"path","name":"Short Cut"},
           "geometry":[{"lat":46.30,"lon":7.30},{"lat":46.301,"lon":7.30}]},
          {"type":"way","id":41,"tags":{"highway":"path","sac_scale":"demanding_alpine_hiking"},
           "geometry":[{"lat":46.40,"lon":7.40},{"lat":46.403,"lon":7.40}]},
          {"type":"way","id":40,"tags":{"highway":"path","sac_scale":"alpine_hiking"},
           "geometry":[{"lat":46.403,"lon":7.40},{"lat":46.406,"lon":7.40}]}
        ]}
        """
        let trails = try Overpass.trails(fromJSON: Data(json.utf8)).sorted { $0.name < $1.name }
        XCTAssertEqual(trails.map(\.name), ["Hörnli Trail", "Lake Path", "Unnamed path (T5)"])

        // Two unnamed graded ways that meet make one path, as hard as its hardest part.
        let unnamed = trails[2]
        XCTAssertEqual(unnamed.id, "u40")
        XCTAssertEqual(unnamed.lines.count, 1)
        XCTAssertEqual(unnamed.lines[0].count, 3)
        XCTAssertEqual(unnamed.difficulty, .demandingAlpineHiking)

        let route = trails[0]
        XCTAssertEqual(route.id, "r10")
        XCTAssertEqual(route.kind, .route)
        XCTAssertEqual(route.lines.count, 1)
        XCTAssertEqual(route.mappedLength, 2_224, accuracy: 3)
        XCTAssertEqual(route.difficulty, .alpineHiking, "hardest member way")
        XCTAssertTrue(route.isPartial, "way 3 had no geometry")
        XCTAssertEqual(route.length, 12_000, "partial routes use their distance tag")
        XCTAssertEqual(route.network, "lwn")

        let path = trails[1]
        XCTAssertEqual(path.kind, .path)
        XCTAssertEqual(path.lines.count, 1, "the clipped point splits off a single point, which is dropped")
        XCTAssertEqual(path.lines[0].count, 3)
        XCTAssertEqual(path.difficulty, .hiking)
        XCTAssertTrue(path.isPartial)

        let query = Overpass.trailsQuery(latitude: 45.9763, longitude: 7.6586, radius: 5_000)
        XCTAssertTrue(query.contains("(45.93125,7.59378,46.02135,7.72342)"), query)
        XCTAssertTrue(query.contains("out tags geom("))
        XCTAssertTrue(query.contains("[!\"name\"](around:400,45.976300,7.658600)"))
        let area = Overpass.trailsQuery(south: 35.5, west: -83.6, north: 35.8, east: -83.2)
        XCTAssertTrue(area.contains("(35.50000,-83.60000,35.80000,-83.20000)"))
        XCTAssertFalse(area.contains("!\"name\""), "no summit, no unnamed paths")
    }

    func testOverpassFailures() {
        let timedOut = Data(#"{"version":0.6,"remark":"runtime error: Query timed out in \"query\" at line 3 after 26 seconds.","elements":[]}"#.utf8)
        XCTAssertNotNil(Overpass.failure(inJSON: timedOut))
        XCTAssertNil(Overpass.failure(inJSON: Data(#"{"elements":[]}"#.utf8)))
        XCTAssertNil(Overpass.failure(inJSON: Data("not json".utf8)))
    }

    /// A trail straight up a cone climbs the cone's height and starts at its foot.
    func testProfileUpACone() throws {
        let cone = TestTerrain.Cone(latitude: 46.2, longitude: 8.2, height: 1_500, radius: 4_000)
        let terrain = TestTerrain.cones([cone])
        // From the summit due south to 3 km away, drawn top down.
        let foot = destination(from: GeoPoint(latitude: 46.2, longitude: 8.2), azimuth: 180, distance: 3_000)
        let trail = Trail(id: "t", name: "Cone", kind: .path,
                          lines: [[LatLon(46.2, 8.2), LatLon(foot.latitude, foot.longitude)]])
        let profile = try XCTUnwrap(trail.profile(on: terrain))
        XCTAssertEqual(profile.gain, 1_125, accuracy: 30)   // from 1 − 3/4 to the top
        XCTAssertEqual(profile.loss, 0, accuracy: 5)
        XCTAssertEqual(profile.highest, 2_000, accuracy: 25)
        XCTAssertEqual(profile.points.first!.elevation, 875, accuracy: 25)
        XCTAssertEqual(profile.trailhead!.latitude, foot.latitude, accuracy: 1e-6)
        XCTAssertEqual(profile.points.last!.distance, 3_000, accuracy: 10)
        XCTAssertTrue(zip(profile.points, profile.points.dropFirst()).allSatisfy { $0.distance < $1.distance })
    }

    /// From the south, a trail on a cone's south face is in sight and one on its north
    /// face is hidden behind the summit.
    func testDrapeHidesTheFarSide() throws {
        let cone = TestTerrain.Cone(latitude: 46.2, longitude: 8.0, height: 1_500, radius: 4_000)
        let terrain = TestTerrain.cones([cone])
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: 46.05, longitude: 8.0)
        var settings = HorizonSettings()
        settings.maxDistance = 40_000
        let horizon = renderer.render(from: observer, settings: settings)
        func line(_ fromKm: Double, _ toKm: Double, azimuth: Double) -> [LatLon] {
            [fromKm, toKm].map {
                let p = destination(from: GeoPoint(latitude: 46.2, longitude: 8.0), azimuth: azimuth, distance: $0 * 1_000)
                return LatLon(p.latitude, p.longitude)
            }
        }
        let south = renderer.drape([line(0.5, 3.5, azimuth: 175)], from: observer, horizon: horizon)
        // From 100 m past the summit: everything there is behind it.
        let north = renderer.drape([line(0.1, 3.5, azimuth: 5)], from: observer, horizon: horizon)
        XCTAssertEqual(south.count, 1)
        XCTAssertGreaterThan(south[0].count, 150)
        XCTAssertTrue(north.isEmpty, "\(north.map(\.count))")
        // Points sit on the terrain: their angles match the depth map at their distance.
        for p in south[0] {
            XCTAssertEqual(azimuthDifference(Double(p.azimuth), 0), 0, accuracy: 3)
            XCTAssertGreaterThan(p.elevation, 0)
        }

        // Seeing through the cone: the north face comes back, marked hidden, and a trail over
        // the top is one line, in sight up to the summit and hidden beyond it.
        let throughNorth = renderer.drape([line(0.1, 3.5, azimuth: 5)], from: observer, horizon: horizon, includeHidden: true)
        XCTAssertEqual(throughNorth.count, 1)
        XCTAssertGreaterThan(throughNorth[0].count, 150)
        XCTAssertTrue(throughNorth[0].allSatisfy { !$0.isInSight })
        let throughSouth = renderer.drape([line(0.5, 3.5, azimuth: 175)], from: observer, horizon: horizon, includeHidden: true)
        XCTAssertEqual(throughSouth.map(\.count), south.map(\.count))
        XCTAssertTrue(throughSouth[0].allSatisfy(\.isInSight))
        let over = renderer.drape([line(3, 0, azimuth: 180) + line(0, 3, azimuth: 0).dropFirst()], from: observer,
                                  horizon: horizon, includeHidden: true)
        XCTAssertEqual(over.count, 1)
        let firstHidden = try XCTUnwrap(over[0].firstIndex { !$0.isInSight })
        XCTAssertTrue(over[0][..<firstHidden].allSatisfy(\.isInSight))
        XCTAssertTrue(over[0][firstHidden...].allSatisfy { !$0.isInSight })
        // The switch is at the summit, give or take a pixel of the terrain model.
        let summit = LatLon(46.05, 8.0).distance(to: LatLon(46.2, 8.0))
        XCTAssertEqual(Double(over[0][firstHidden].distance), summit, accuracy: 100)
    }

    /// Bare ground under a forested surface (a gentle hill in open country, its surface 30 m
    /// of trees above the ground, as Copernicus has much of a forest's height): a trail's
    /// climb follows the ground. Its line on the mountain stays on the surface, as the
    /// skylines and the eye are: one consistent view, until the eye can stand on the ground.
    func testTrailClimbsFollowTheGroundUnderTrees() throws {
        let top = (latitude: 46.5, longitude: 8.5)
        func distance(_ lat: Double, _ lon: Double) -> Double {
            let dy = (lat - top.latitude) * 111_200, dx = (lon - top.longitude) * 111_200 * cos(top.latitude * .pi / 180)
            return (dx * dx + dy * dy).squareRoot()
        }
        func bare(_ lat: Double, _ lon: Double) -> Double { 500 + 600 * max(0, 1 - distance(lat, lon) / 4_000) }
        let surface = [(45, 7), (45, 8), (46, 7), (46, 8)].map { south, west in
            ElevationTile(south: south, west: west, size: 600) { bare($0, $1) + (distance($0, $1) < 4_000 ? 30 : 0) }
        }
        // The ground at 1 arc-second, around the hill, in its 1° cell.
        let step = 1.0 / 3600, rows = 361, cols = 481
        var heights = [Int16](repeating: 0, count: rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                heights[r * cols + c] = Int16(bare(46.55 - Double(r) * step, 8.43 + Double(c) * step).rounded())
            }
        }
        let patch = ElevationTile(south: 46, west: 8, rows: rows, cols: cols, originLatitude: 46.55, originLongitude: 8.43,
                                  stepLatitude: step, stepLongitude: step, heights: heights)
        let forest = Terrain(tiles: surface)
        let terrain = Terrain(tiles: surface, ground: [patch])

        // Straight up the south face, drawn top down.
        func line(_ fromKm: Double, _ toKm: Double, azimuth: Double) -> [LatLon] {
            [fromKm, toKm].map {
                let p = destination(from: GeoPoint(latitude: top.latitude, longitude: top.longitude), azimuth: azimuth, distance: $0 * 1_000)
                return LatLon(p.latitude, p.longitude)
            }
        }
        let trail = Trail(id: "t", name: "Hill", kind: .path, lines: [line(0, 3, azimuth: 180)])
        let profile = try XCTUnwrap(trail.profile(on: terrain))
        XCTAssertEqual(profile.highest, 1_100, accuracy: 8)
        XCTAssertEqual(profile.points.first!.elevation, bare(profile.trailhead!.latitude, profile.trailhead!.longitude), accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(trail.profile(on: forest)).highest, 1_130, accuracy: 8)
        XCTAssertTrue(terrain.hasGround(under: trail))
        XCTAssertFalse(forest.hasGround(under: trail))

        // On the mountain, as on the surface alone.
        let renderer = HorizonRenderer(terrain: terrain)
        let observer = renderer.observer(latitude: 46.35, longitude: 8.5)
        var settings = HorizonSettings()
        settings.maxDistance = 40_000
        let horizon = renderer.render(from: observer, settings: settings)
        let draped = renderer.drape([line(0.5, 3.5, azimuth: 175)], from: observer, horizon: horizon)
        let onTrees = HorizonRenderer(terrain: forest).drape([line(0.5, 3.5, azimuth: 175)], from: observer, horizon: horizon)
        XCTAssertGreaterThan(draped.first?.count ?? 0, 150)
        XCTAssertEqual(draped.map { $0.map(\.elevation) }, onTrees.map { $0.map(\.elevation) })
    }
}

final class PeakFactsTests: XCTestCase {
    func testWikidataFacts() throws {
        let json = """
        {"entities":{"Q1374":{"type":"item","id":"Q1374",
          "descriptions":{"en":{"language":"en","value":"mountain in the Pennine Alps"}},
          "claims":{
            "P2660":[{"mainsnak":{"snaktype":"value","datavalue":{"type":"quantity","value":{"amount":"+1031","unit":"http://www.wikidata.org/entity/Q11573"}}},"rank":"normal"}],
            "P2659":[{"mainsnak":{"snaktype":"value","datavalue":{"type":"quantity","value":{"amount":"+13.8","unit":"http://www.wikidata.org/entity/Q828224"}}},"rank":"normal"}],
            "P4552":[{"mainsnak":{"snaktype":"value","datavalue":{"type":"wikibase-entityid","value":{"entity-type":"item","numeric-id":1286,"id":"Q1286"}}},"rank":"normal"}],
            "P17":[{"mainsnak":{"snaktype":"value","datavalue":{"type":"wikibase-entityid","value":{"id":"Q39"}}},"rank":"normal"},
                   {"mainsnak":{"snaktype":"value","datavalue":{"type":"wikibase-entityid","value":{"id":"Q38"}}},"rank":"normal"}],
            "P18":[{"mainsnak":{"snaktype":"value","datavalue":{"type":"string","value":"Matterhorn from Domhütte - 2.jpg"}},"rank":"normal"}],
            "P793":[{"mainsnak":{"snaktype":"value","datavalue":{"type":"wikibase-entityid","value":{"id":"Q1194369"}}},"rank":"normal",
                     "qualifiers":{"P585":[{"snaktype":"value","datavalue":{"type":"time","value":{"time":"+1865-07-14T00:00:00Z","precision":11}}}]}}],
            "P2044":[{"mainsnak":{"snaktype":"somevalue"},"rank":"normal"}]
          },
          "sitelinks":{"enwiki":{"site":"enwiki","title":"Matterhorn"},"dewiki":{"site":"dewiki","title":"Matterhorn"},
                       "commonswiki":{"site":"commonswiki","title":"Category:Matterhorn"},"enwikivoyage":{"site":"enwikivoyage","title":"Zermatt"}}
        }}}
        """
        let facts = try Wikidata.facts(fromJSON: Data(json.utf8), id: "Q1374")
        XCTAssertEqual(facts.description, "mountain in the Pennine Alps")
        XCTAssertEqual(facts.prominence, 1_031)
        XCTAssertEqual(facts.isolation!, 13_800, accuracy: 1e-6)
        XCTAssertEqual(facts.rangeID, "Q1286")
        XCTAssertEqual(facts.countryIDs, ["Q39", "Q38"])
        XCTAssertEqual(facts.firstAscentYear, 1865)
        XCTAssertEqual(facts.image, "Matterhorn from Domhütte - 2.jpg")
        XCTAssertEqual(facts.articles, ["en": "Matterhorn", "de": "Matterhorn"])
        XCTAssertEqual(facts.linkedIDs, ["Q1286", "Q39", "Q38"])
        XCTAssertEqual(facts.pictureURL?.absoluteString,
                       "https://commons.wikimedia.org/wiki/Special:FilePath/Matterhorn_from_Domh%C3%BCtte_-_2.jpg?width=800")

        let labels = try Wikidata.labels(fromJSON: Data("""
            {"entities":{"Q1286":{"labels":{"en":{"value":"Pennine Alps"}}},"Q39":{"labels":{"en":{"value":"Switzerland"}}},"Q38":{"labels":{}}}}
            """.utf8))
        XCTAssertEqual(labels, ["Q1286": "Pennine Alps", "Q39": "Switzerland"])
        XCTAssertEqual(Wikidata.labelsURL(["Q1", "Q2"]).absoluteString.contains("ids=Q1%7CQ2"), true)
    }

    /// Prominence for many items in one query: only real item ids go in, values come back in
    /// meters, a preferred statement beats normal ones, and what makes no sense is left out.
    func testWikidataProminenceInBulk() throws {
        let query = Wikidata.prominenceQuery(["Q685166", "Q1374", "Q685166", "Q1} . ?x ?y ?z . {", "q12", "Q", "Q12a", ""])
        XCTAssertTrue(query.contains("VALUES ?item { wd:Q1374 wd:Q685166 }"))
        XCTAssertFalse(query.contains("?x ?y ?z"))
        XCTAssertTrue(query.contains("psn:P2660"))
        XCTAssertTrue(Wikidata.isItemID("Q31663127"))
        XCTAssertFalse(Wikidata.isItemID("Q１２"))  // full-width digits
        XCTAssertFalse(Wikidata.isItemID("Q1234567890123"))

        func row(_ id: String, _ rank: String, _ amount: String) -> String {
            """
            {"item":{"type":"uri","value":"http://www.wikidata.org/entity/\(id)"},
             "rank":{"type":"uri","value":"http://wikiba.se/ontology#\(rank)"},
             "amount":{"datatype":"http://www.w3.org/2001/XMLSchema#decimal","type":"literal","value":"\(amount)"}}
            """
        }
        let rows = [
            row("Q685166", "NormalRank", "1372.5171018"),       // from 4,503 ft
            row("Q1374", "NormalRank", "1031"),
            row("Q1374", "PreferredRank", "1040"),
            row("Q1374", "NormalRank", "1100"),
            row("Q7799150", "NormalRank", "331.3"),
            row("Q7799150", "NormalRank", "331.3"),             // the same statement twice
            row("Q6921794", "NormalRank", "414.5"),
            row("Q6921794", "NormalRank", "420"),
            row("Q2", "DeprecatedRank", "500"),
            row("Q3", "NormalRank", "-12"),
            row("Q4", "NormalRank", "NaN"),
            row("Q5", "NormalRank", "12000"),
            row("Q6", "NormalRank", "about 300"),
            row("Q7} injected", "NormalRank", "300"),
        ]
        let json = #"{"head":{"vars":["item","rank","amount"]},"results":{"bindings":["# + rows.joined(separator: ",") + "]}}"
        let table = try Wikidata.prominence(fromSPARQLJSON: Data(json.utf8))
        XCTAssertEqual(table, ["Q685166": 1372.5171018, "Q1374": 1040, "Q7799150": 331.3, "Q6921794": 420])
        XCTAssertEqual(try Wikidata.prominence(fromSPARQLJSON: Data(#"{"results":{"bindings":[]}}"#.utf8)), [:])
        XCTAssertThrowsError(try Wikidata.prominence(fromSPARQLJSON: Data("<!DOCTYPE html><title>Error</title>".utf8)))

        // A peak's card picks the same one: the preferred statement, in meters, over a normal one in feet.
        func statement(_ amount: String, _ unit: String, _ rank: String) -> String {
            #"{"mainsnak":{"datavalue":{"type":"quantity","value":{"amount":"\#(amount)","unit":"http://www.wikidata.org/entity/\#(unit)"}}},"rank":"\#(rank)"}"#
        }
        let entity = #"{"entities":{"Q1374":{"claims":{"P2660":["# + [
            statement("+3609", "Q3710", "normal"), statement("+1040", "Q11573", "preferred"),
            statement("+1100", "Q11573", "deprecated"), statement("+99999", "Q11573", "preferred"),
        ].joined(separator: ",") + "]}}}}"
        XCTAssertEqual(try Wikidata.facts(fromJSON: Data(entity.utf8), id: "Q1374").prominence, 1_040)
    }

    func testWikipediaSummary() throws {
        var facts = PeakFacts()
        facts.articles = ["de": "Matterhorn"]
        XCTAssertEqual(Wikipedia.article(facts: facts, osmTag: "fr:Cervin")?.language, "fr")
        facts.articles["en"] = "Matterhorn"
        XCTAssertEqual(Wikipedia.article(facts: facts, osmTag: "fr:Cervin")?.language, "en")
        XCTAssertNil(Wikipedia.article(facts: nil, osmTag: "Cervin"))
        XCTAssertEqual(Wikipedia.summaryURL(language: "en", title: "Mount St. Helens")?.absoluteString,
                       "https://en.wikipedia.org/api/rest_v1/page/summary/Mount_St._Helens")

        try Wikipedia.addSummary(fromJSON: Data("""
            {"type":"standard","title":"Matterhorn","extract":"The Matterhorn is a mountain of the Alps. ",
             "thumbnail":{"source":"https://upload.wikimedia.org/x.jpg","width":320,"height":240},
             "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Matterhorn"},"mobile":{"page":"https://en.m.wikipedia.org/wiki/Matterhorn"}}}
            """.utf8), to: &facts)
        XCTAssertEqual(facts.summary, "The Matterhorn is a mountain of the Alps.")
        XCTAssertEqual(facts.thumbnailURL?.absoluteString, "https://upload.wikimedia.org/x.jpg")
        XCTAssertEqual(facts.articleURL?.absoluteString, "https://en.m.wikipedia.org/wiki/Matterhorn")
    }

    func testPeakTags() throws {
        let json = """
        {"elements":[{"type":"node","id":1,"lat":45.9763,"lon":7.6586,
          "tags":{"natural":"peak","name":"Matterhorn","ele":"4478","prominence":"1031","wikidata":"Q1374","wikipedia":"de:Matterhorn"}}]}
        """
        let peak = try XCTUnwrap(Overpass.peaks(fromJSON: Data(json.utf8)).first)
        XCTAssertEqual(peak.prominence, 1_031)
        XCTAssertEqual(peak.wikidata, "Q1374")
        XCTAssertEqual(peak.wikipedia, "de:Matterhorn")
    }
}

import Foundation

/// A few facts about a peak from Wikidata and Wikipedia.
public struct PeakFacts: Codable, Sendable, Equatable {
    /// Wikidata's one-line description, like "mountain in the Pennine Alps".
    public var description: String?
    public var prominence: Double?
    /// Distance to the nearest higher ground, meters.
    public var isolation: Double?
    public var firstAscentYear: Int?
    public var rangeID: String?
    public var range: String?
    public var countryIDs: [String] = []
    public var countries: [String] = []
    public var parentID: String?
    public var parent: String?
    /// Wikimedia Commons file name of the main picture.
    public var image: String?
    /// Article titles by language code, from the item's site links.
    public var articles: [String: String] = [:]

    /// The article's first paragraph, from Wikipedia.
    public var summary: String?
    public var thumbnailURL: URL?
    public var articleURL: URL?

    public init() {}

    /// Items whose names are needed: the range, countries and parent peak.
    public var linkedIDs: [String] { ([rangeID, parentID].compactMap { $0 } + countryIDs) }

    /// A picture of the peak: the Wikipedia thumbnail, or the Commons image.
    public var pictureURL: URL? {
        if let thumbnailURL { return thumbnailURL }
        guard let image, let name = image.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(name)?width=800")
    }
}

public enum Wikidata {
    /// Claims, labels, descriptions and site links of an item, in English.
    public static func entityURL(_ id: String) -> URL {
        URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&ids=\(id)" +
            "&props=claims%7Cdescriptions%7Csitelinks&languages=en")!
    }

    /// English labels of several items.
    public static func labelsURL(_ ids: [String]) -> URL {
        URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&ids=" +
            ids.joined(separator: "%7C") + "&props=labels&languages=en")!
    }

    private struct Response: Decodable {
        var entities: [String: Entity]
    }

    private struct Entity: Decodable {
        struct Text: Decodable { var value: String }
        struct Link: Decodable { var title: String }
        var labels: [String: Text]?
        var descriptions: [String: Text]?
        var claims: [String: [Statement]]?
        var sitelinks: [String: Link]?
    }

    private struct Statement: Decodable {
        var mainsnak: Snak
        var rank: String?
        var qualifiers: [String: [Snak]]?
    }

    private struct Snak: Decodable {
        var datavalue: DataValue?
    }

    /// The parts of Wikidata values used here: item ids, quantities, times and strings.
    private enum DataValue: Decodable {
        case item(String)
        case quantity(Double, unit: String)
        case time(String)
        case string(String)
        case other

        enum CodingKeys: String, CodingKey { case type, value }
        struct ItemValue: Decodable { var id: String }
        struct QuantityValue: Decodable { var amount: String; var unit: String }
        struct TimeValue: Decodable { var time: String }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "wikibase-entityid":
                self = .item(try c.decode(ItemValue.self, forKey: .value).id)
            case "quantity":
                let q = try c.decode(QuantityValue.self, forKey: .value)
                self = Double(q.amount).map { .quantity($0, unit: q.unit) } ?? .other
            case "time":
                self = .time(try c.decode(TimeValue.self, forKey: .value).time)
            case "string":
                self = .string(try c.decode(String.self, forKey: .value))
            default:
                self = .other
            }
        }
    }

    /// Facts about item `id` from a `entityURL` response.
    public static func facts(fromJSON data: Data, id: String) throws -> PeakFacts {
        var facts = PeakFacts()
        guard let entity = try JSONDecoder().decode(Response.self, from: data).entities[id] else { return facts }
        facts.description = entity.descriptions?["en"]?.value
        let claims = entity.claims ?? [:]
        // Preferred statements first, deprecated ones never.
        func statements(_ p: String) -> [Statement] {
            (claims[p] ?? []).filter { $0.rank != "deprecated" }.sorted { ($0.rank == "preferred" ? 0 : 1) < ($1.rank == "preferred" ? 0 : 1) }
        }
        func meters(_ p: String) -> Double? {
            for s in statements(p) {
                guard case let .quantity(v, unit)? = s.mainsnak.datavalue else { continue }
                switch unit.split(separator: "/").last {
                case "Q11573": return v            // metre
                case "Q828224": return v * 1_000    // kilometre
                case "Q3710": return v * 0.3048     // foot
                case "Q253276": return v * 1_609.344 // mile
                default: continue
                }
            }
            return nil
        }
        func items(_ p: String) -> [String] {
            statements(p).compactMap { if case let .item(id)? = $0.mainsnak.datavalue { return id } else { return nil } }
        }
        facts.prominence = meters("P2660")
        facts.isolation = meters("P2659")
        facts.rangeID = items("P4552").first
        facts.parentID = items("P3137").first
        facts.countryIDs = Array(items("P17").prefix(3))
        facts.image = statements("P18").lazy.compactMap { if case let .string(s)? = $0.mainsnak.datavalue { return s } else { return nil } }.first
        // First ascent: a "significant event" (P793) of "first ascent" (Q1194369), dated by P585.
        for s in statements("P793") {
            guard case .item("Q1194369")? = s.mainsnak.datavalue else { continue }
            for q in s.qualifiers?["P585"] ?? [] {
                if case let .time(t)? = q.datavalue, let year = Int(t.dropFirst().prefix { $0 != "-" }) {
                    facts.firstAscentYear = (t.hasPrefix("-") ? -1 : 1) * year
                }
            }
        }
        for (site, link) in entity.sitelinks ?? [:] where site.hasSuffix("wiki") && !site.contains("_") {
            let language = String(site.dropLast(4))
            if ["commons", "species", "meta", "simple"].contains(language) { continue }
            facts.articles[language] = link.title
        }
        return facts
    }

    /// English labels by item id from a `labelsURL` response.
    public static func labels(fromJSON data: Data) throws -> [String: String] {
        let entities = try JSONDecoder().decode(Response.self, from: data).entities
        return entities.compactMapValues { $0.labels?["en"]?.value }
    }
}

public enum Wikipedia {
    /// The article to show: English if there is one, else the one OpenStreetMap names
    /// (its `wikipedia` tag looks like "de:Matterhorn"), else any.
    public static func article(facts: PeakFacts?, osmTag: String?) -> (language: String, title: String)? {
        if let title = facts?.articles["en"] { return ("en", title) }
        if let tag = osmTag, let colon = tag.firstIndex(of: ":"), colon != tag.startIndex {
            let title = tag[tag.index(after: colon)...]
            if !title.isEmpty { return (String(tag[..<colon]), String(title)) }
        }
        if let any = facts?.articles.sorted(by: { $0.key < $1.key }).first { return (any.key, any.value) }
        return nil
    }

    public static func summaryURL(language: String, title: String) -> URL? {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-.()'")))
        guard let path, language.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        return URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(path)")
    }

    /// Adds the summary, thumbnail and article link from a `summaryURL` response.
    public static func addSummary(fromJSON data: Data, to facts: inout PeakFacts) throws {
        struct Summary: Decodable {
            struct Image: Decodable { var source: String }
            struct Page: Decodable { var page: String }
            struct URLs: Decodable { var mobile: Page? }
            var type: String?
            var extract: String?
            var thumbnail: Image?
            var content_urls: URLs?
        }
        let s = try JSONDecoder().decode(Summary.self, from: data)
        guard s.type != "disambiguation" else { return }
        if let extract = s.extract?.trimmingCharacters(in: .whitespacesAndNewlines), !extract.isEmpty { facts.summary = extract }
        if let source = s.thumbnail?.source { facts.thumbnailURL = URL(string: source) }
        if let page = s.content_urls?.mobile?.page { facts.articleURL = URL(string: page) }
    }
}

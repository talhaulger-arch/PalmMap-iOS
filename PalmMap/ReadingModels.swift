import Foundation

enum PalmLanguage: String, CaseIterable, Codable, Identifiable {
    case en, tr

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: self == .tr ? "tr_TR" : "en_US") }
    func text(_ tr: String, _ en: String) -> String { self == .tr ? tr : en }
    func select(_ pair: [String]) -> String {
        pair.indices.contains(self == .tr ? 0 : 1) ? pair[self == .tr ? 0 : 1] : ""
    }
}

enum PalmSide: String, CaseIterable, Codable, Identifiable {
    case left = "LEFT", right = "RIGHT"

    var id: String { rawValue }
    func title(_ language: PalmLanguage) -> String {
        self == .left ? language.text("Sol avuç içi", "Left palm") : language.text("Sağ avuç içi", "Right palm")
    }
}

struct PalmPoint: Codable {
    let x: Double
    let y: Double
}

enum PalmLineKind: String, Codable, CaseIterable, Identifiable {
    case heart, head, life
    var id: String { rawValue }

    func title(_ language: PalmLanguage) -> String {
        switch self {
        case .heart: return language.text("Kalp çizgisi", "Heart line")
        case .head: return language.text("Akıl çizgisi", "Head line")
        case .life: return language.text("Hayat çizgisi", "Life line")
        }
    }
}

struct PalmTrace: Codable, Identifiable {
    let kind: PalmLineKind
    let points: [PalmPoint]
    var id: String { kind.id }
}

struct RuleEvidence: Codable {
    let id: String
    let side: PalmSide
    let confidence: Double
}

struct HandReading: Codable, Identifiable {
    let side: PalmSide
    let traces: [PalmTrace]
    let evidence: [RuleEvidence]
    var id: String { side.id }
}

enum ScanError: Error {
    case image, hand, pose, light, lines, resource, repeated, noSharedEvidence

    func message(_ l: PalmLanguage) -> String {
        switch self {
        case .image: return l.text("Fotoğraf açılamadı. Yeniden seç veya çek.", "The photo couldn’t be opened. Take or choose another.")
        case .hand: return l.text("Tek bir avuç içi görünmeli. Bileğini ve parmaklarını kadraja al.", "Show one palm, with your wrist and fingertips in the frame.")
        case .pose: return l.text("Parmakların yukarı baksın. Avucunu kameraya düz çevir.", "Point your fingers up and face your open palm toward the camera.")
        case .light: return l.text("Avucunu aydınlık bir yerde, gölge veya parlama olmadan çek.", "Photograph your palm in even light, without shadows or glare.")
        case .lines: return l.text("Avuç çizgileri yeterince net değil. Avucunu biraz yaklaştırıp tekrar çek.", "The palm lines aren’t clear enough. Move your palm closer and try again.")
        case .resource: return l.text("Analiz dosyası açılamadı. Uygulamayı yeniden başlat.", "The analysis model couldn’t be loaded. Restart the app.")
        case .repeated: return l.text("Bu fotoğraf zaten kullanıldı. Diğer avucun yeni bir fotoğrafını seç.", "This photo was already used. Choose a new photo of the other palm.")
        case .noSharedEvidence: return l.text("Ortak ilişki okuması için iki kişiden yeterli bulgu çıkmadı. Daha net fotoğraflarla tekrar dene.", "There aren’t enough shared findings for a relationship reading. Try again with clearer photos.")
        }
    }
}

struct PalmProfile {
    var displayName = ""
    var birthDate: Date?
    var married = false
    var marriageDate: Date?

    var canAnalyze: Bool {
        let words = displayName.split(whereSeparator: \.isWhitespace)
        guard words.filter({ $0.contains(where: \.isLetter) }).count >= 2,
              displayName.count <= 90, let birthDate,
              (1...110).contains(ProfileEngine.age(birthDate)),
              ProfileEngine.supports(displayName) else { return false }
        if married {
            guard let marriageDate else { return false }
            return marriageDate >= birthDate && marriageDate <= Date()
        }
        return true
    }
}

struct LocalRule: Decodable {
    let module: String
    let meaning: [String]
    let polarity: String
    let evidenceGroup: String
    let threshold: Double
}

enum PalmResources {
    static func load<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { throw ScanError.resource }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static let rules = (try? load([String: LocalRule].self, named: "SupportedRules")) ?? [:]
}

struct ContextSection: Codable, Identifiable {
    let key: String
    let title: String
    let meaning: String
    let use: String
    let watch: String
    var id: String { key }
}

struct ContextHighlight: Codable, Identifiable {
    let key: String
    let title: String
    let meaning: String
    let side: String
    let polarity: String
    var id: String { key }
}

struct ContextSignal: Codable {
    let key: String
    let title: String
    let meaning: String
    let use: String
    let watch: String
    let domains: [String]
}

struct ContextPeriod: Codable {
    let key: String
    let year: Int
    let kind: String
    let meaning: String
    let domains: [String]
}

struct FutureFactor: Codable, Identifiable {
    let key: String
    let category: String
    let title: String
    let value: String
    let meaning: String
    let positive: String
    let caution: String
    let year: Int?
    let domains: [String]
    var id: String { key }
}

struct PersonalContext: Codable {
    let schemaVersion: Int
    let language: PalmLanguage
    let previewAnchor: String
    let age: Int
    let leftRightSource: String
    let sections: [ContextSection]
    let highlights: [ContextHighlight]
    let personalSignals: [ContextSignal]
    let awarenessPeriods: [ContextPeriod]
    let futureFactors: [FutureFactor]
}

struct RelationshipSection: Codable, Identifiable {
    let code: String
    let narrative: String
    let opportunity: String
    let attention: String
    let practice: String
    var id: String { code }
}

struct RelationshipContext: Codable {
    let claimId: String
    let language: PalmLanguage
    let sections: [RelationshipSection]
}

struct NearTermReading: Codable {
    let months: Int
    let paragraphs: [String]
}

struct AISection: Codable, Identifiable {
    let key: String
    let narrative: String
    let use: String?
    let watch: String?
    var id: String { key }
}

struct AIProjection: Codable, Identifiable {
    let domain: String
    let title: String
    let outlook: String
    let positive: String
    let caution: String?
    var id: String { domain }
}

struct PersonalReading: Codable {
    let impactLine: String?
    let overview: String?
    let leftRight: String?
    let sections: [AISection]?
    let highlights: [AISection]?
    let crosses: [AISection]?
    let themes: [AISection]?
    let futureProjections: [AIProjection]?
    let nearTermOutlook: NearTermReading?
    let closing: String?

    enum CodingKeys: String, CodingKey {
        case impactLine, overview, leftRight, sections, highlights, crosses, themes, futureProjections, nearTermOutlook, closing
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        impactLine = try fields.decodeIfPresent(String.self, forKey: .impactLine)
        overview = try fields.decodeIfPresent(String.self, forKey: .overview)
        leftRight = try fields.decodeIfPresent(String.self, forKey: .leftRight)
        sections = try fields.decodeIfPresent([AISection].self, forKey: .sections)
        highlights = try fields.decodeIfPresent([AISection].self, forKey: .highlights)
        crosses = try fields.decodeIfPresent([AISection].self, forKey: .crosses)
        themes = try fields.decodeIfPresent([AISection].self, forKey: .themes)
        futureProjections = try fields.decodeIfPresent([AIProjection].self, forKey: .futureProjections)
        if let outlook = try? fields.decode(NearTermReading.self, forKey: .nearTermOutlook) {
            nearTermOutlook = outlook
        } else if let scenes = try? fields.decode([LegacyOutlook].self, forKey: .nearTermOutlook) {
            nearTermOutlook = NearTermReading(months: 3, paragraphs: scenes.map(\.outlook))
        } else {
            nearTermOutlook = nil
        }
    }

    private struct LegacyOutlook: Decodable { let outlook: String }
}

struct RelationshipReading: Codable {
    let overview: String
    let sections: [RelationshipSection]
    let nearTermOutlook: NearTermReading?
}

struct PersonalResult: Decodable {
    let reportId: String
    let reading: PersonalReading
}

struct RelationshipResult: Decodable {
    let reportId: String
    let reading: RelationshipReading
}

struct OwnedReading: Codable, Identifiable, Hashable {
    let id: String
    let language: PalmLanguage
    let names: [String]
    let savedAt: Date
    let personal: PersonalReading?
    let relationship: RelationshipReading?
    let titles: [String: String]
    let years: [String: Int]
    let hands: [HandReading]

    var isRelationship: Bool { relationship != nil }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

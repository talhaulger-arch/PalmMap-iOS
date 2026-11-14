import Foundation

enum ReadingEngine {
    private struct Cue: Decodable {
        let code: String
        let domain: String
        let family: String
        let ids: [String]
        let text: [String]
    }

    private struct Topic: Decodable {
        struct Contrast: Decodable {
            let first: String
            let second: String
            let reading: [String]
            let opportunity: [String]
            let attention: [String]
            let practice: [String]
        }

        let code: String
        let title: [String]
        let context: [String]
        let opportunity: [String]
        let attention: [String]
        let practice: [String]
        let contrasts: [Contrast]
    }

    private struct RelationshipTables: Decodable {
        let cues: [Cue]
        let topics: [Topic]
    }

    private static let tables = try? PalmResources.load(RelationshipTables.self, named: "RelationshipTables")

    static func personal(hands: [HandReading], profile: PalmProfile, language l: PalmLanguage) throws -> PersonalContext {
        let analysis = try ProfileEngine.analyze(profile, l)
        let rules = PalmResources.rules
        let findings = hands.flatMap(\.evidence)
            .filter { hit in rules[hit.id].map { hit.confidence >= $0.threshold } ?? false }
        let grouped = Dictionary(grouping: findings, by: \.id)
        let highlights = grouped.keys.sorted().compactMap { key -> ContextHighlight? in
            guard let rule = rules[key], let hits = grouped[key] else { return nil }
            let sides = Set(hits.map(\.side))
            return ContextHighlight(key: key, title: title(rule.module, l), meaning: l.select(rule.meaning),
                side: sides.count == 2 ? "BOTH" : (hits.first?.side.rawValue ?? "BOTH"), polarity: rule.polarity)
        }
        guard !highlights.isEmpty else { throw ScanError.lines }
        let sections = Dictionary(grouping: highlights) { rules[$0.key]?.module ?? "" }.sorted { $0.key < $1.key }.map { module, items in
            ContextSection(key: module, title: title(module, l),
                           meaning: items.map(\.meaning).joined(separator: " "),
                           use: l.text("Bu eğilimin günlük hayatta nerede karşılık bulduğunu düşün.", "Notice where this tendency appears in everyday life."),
                           watch: l.text("Yorumu kişisel düşünme alanı olarak kullan.", "Use the interpretation as a prompt for reflection."))
        }
        return PersonalContext(
            schemaVersion: 3, language: l, previewAnchor: sections.first?.meaning ?? "",
            age: profile.birthDate.map { ProfileEngine.age($0) } ?? 0,
            leftRightSource: l.text("İki avuç içi birlikte değerlendirildi. Her bulgu gözlemlendiği elle eşleştirildi.",
                                   "The two palms were read together. Each finding is linked to the hand where it was observed."),
            sections: sections, highlights: highlights, personalSignals: analysis.signals,
            awarenessPeriods: analysis.periods, futureFactors: analysis.forecasts)
    }

    static func relationship(first: [HandReading], second: [HandReading], language l: PalmLanguage) throws -> RelationshipContext {
        guard let tables else { throw ScanError.resource }
        let a = cues(from: first, tables.cues)
        let b = cues(from: second, tables.cues)
        let sections = tables.topics.compactMap { topic -> RelationshipSection? in
            let left = a.filter { $0.domain == topic.code }
            let right = b.filter { $0.domain == topic.code }
            guard !left.isEmpty, !right.isEmpty else { return nil }
            let leftIDs = Set(left.map(\.code))
            let rightIDs = Set(right.map(\.code))
            let contrast = topic.contrasts.first { item in
                (leftIDs.contains(item.first) && rightIDs.contains(item.second) && !leftIDs.contains(item.second) && !rightIDs.contains(item.first))
                    || (leftIDs.contains(item.second) && rightIDs.contains(item.first) && !leftIDs.contains(item.first) && !rightIDs.contains(item.second))
            }
            let shared = left.filter { rightIDs.contains($0.code) }
            let opening: String
            if let contrast {
                opening = l.select(contrast.reading)
            } else if !shared.isEmpty {
                let common = phrase(shared, l)
                opening = l.text("İkinizin okumasında \(common) ortak bir vurgu oluşturuyor.",
                                 "Both readings emphasize \(common).")
            } else {
                let first = phrase(left, l), second = phrase(right, l)
                opening = l.text("Birlikte değerlendirmede \(first) ile \(second) bir araya geliyor.",
                                 "Together, the readings bring \(first) into contact with \(second).")
            }
            return RelationshipSection(code: topic.code, narrative: opening + " " + l.select(topic.context),
                opportunity: l.select(contrast?.opportunity ?? topic.opportunity),
                attention: l.select(contrast?.attention ?? topic.attention),
                practice: l.select(contrast?.practice ?? topic.practice))
        }
        guard !sections.isEmpty else { throw ScanError.noSharedEvidence }
        return RelationshipContext(claimId: UUID().uuidString.lowercased(), language: l, sections: sections)
    }

    static func relationshipTitles(_ l: PalmLanguage) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (tables?.topics ?? []).map { ($0.code, l.select($0.title)) })
    }

    private static func cues(from hands: [HandReading], _ cues: [Cue]) -> [Cue] {
        let hits = hands.flatMap(\.evidence)
        let scored = cues.compactMap { cue -> (Cue, Double)? in
            let confidence = hits.filter { cue.ids.contains($0.id) && $0.confidence >= 0.72 }.map(\.confidence).max()
            return confidence.map { (cue, $0) }
        }
        let families = Dictionary(grouping: scored, by: { $0.0.family })
        return scored.filter { families[$0.0.family]?.count == 1 }
            .sorted { $0.1 == $1.1 ? $0.0.code < $1.0.code : $0.1 > $1.1 }
            .map { $0.0 }
    }

    private static func phrase(_ items: [Cue], _ l: PalmLanguage) -> String {
        items.prefix(2).map { l.select($0.text) }.joined(separator: l.text(" ve ", " and "))
    }

    private static func title(_ module: String, _ l: PalmLanguage) -> String {
        switch module {
        case "head_line": return PalmLineKind.head.title(l)
        case "heart_line": return PalmLineKind.heart.title(l)
        case "life_line": return PalmLineKind.life.title(l)
        default: return l.text("Başparmak yapısı", "Thumb shape")
        }
    }
}

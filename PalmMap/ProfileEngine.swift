import Foundation

enum ProfileEngine {
    private struct Tables: Decodable {
        let character: [String: [String]]
        let balance: [String: [String]]
        let labels: [String: [String]]
        let months: [String: [String: [String]]]
        let special: [String: [String]]
        let luck: [[String]]
    }

    struct Analysis {
        let signals: [ContextSignal]
        let periods: [ContextPeriod]
        let forecasts: [FutureFactor]
    }

    private static let tables = try? PalmResources.load(Tables.self, named: "ProfileTables")
    private static let letters: [Character: Int] = Dictionary(uniqueKeysWithValues:
        ["AHÖY", "BIPZ", "CİR", "ÇJS", "DKQŞ", "ELT", "FMU", "GNÜ", "ĞOVWX"]
            .enumerated().flatMap { index, group in group.map { ($0, index + 1) } }
    )
    private static let calendar = Calendar(identifier: .gregorian)

    static func age(_ birth: Date, today: Date = Date()) -> Int {
        calendar.dateComponents([.year], from: calendar.startOfDay(for: birth), to: calendar.startOfDay(for: today)).year ?? 0
    }

    static func supports(_ name: String) -> Bool { letterValues(name).count >= 2 }

    static func analyze(_ profile: PalmProfile, _ l: PalmLanguage, today: Date = Date()) throws -> Analysis {
        guard let tables, let birthDate = profile.birthDate, birthDate <= today, supports(profile.displayName) else {
            throw ScanError.resource
        }
        let birth = calendar.dateComponents([.day, .month, .year], from: birthDate)
        guard let year = birth.year, let month = birth.month, let day = birth.day else { throw ScanError.resource }
        let character = reduce(letterValues(profile.displayName).reduce(0, +))
        let base = digits(year)
        let birthNumber = reduce(digits(day) + digits(month) + base).number
        let balanceCode = birthNumber == 11 ? "AMPLIFIED" : birthNumber > character.number ? "EXPANSIVE" : birthNumber == character.number ? "ALIGNED" : "DELIBERATE"
        guard let characterCopy = tables.character[String(character.number)], let balanceCopy = tables.balance[balanceCode] else {
            throw ScanError.resource
        }
        let characterSignal = signal("CHARACTER_PROFILE", characterCopy, l, ["work", "love", "money"])
        let balance = signal("BALANCE_\(balanceCode)", balanceCopy, l, ["work", "money", "love"])
        let group = String(character.number)
        let meaning: String
        if let special = tables.special[group] {
            meaning = l.select(special)
        } else {
            guard let traits = tables.months[group]?[String(month)] else { throw ScanError.resource }
            let phrase = traits.compactMap { tables.labels[$0].map(l.select) }.joined(separator: ", ")
            meaning = l.text("İsim ve doğum ayı birlikte okunduğunda \(phrase) temaları aynı profilde buluşuyor.",
                             "Read together, the name and birth month bring \(phrase) into the same profile.")
        }
        let combined = ContextSignal(
            key: tables.special[group] == nil ? "NAME_BIRTH_PROFILE" : "NAME_PROFILE_MONTH_INDEPENDENT",
            title: l.text("İsim ve doğum ayı profili", "Name and birth-month profile"), meaning: meaning,
            use: l.text("Bu birleşimin güçlü tarafını somut bir hedefte kullan.", "Apply the strongest side of this combination to a concrete goal."),
            watch: l.text("Temalardan birini değişmez kader veya kesin sonuç gibi görme.", "Treat these themes as ideas for reflection."), domains: ["work", "love", "money"]
        )
        let luckIndex = birthNumber == 11 ? 0 : birthNumber >= 8 ? 1 : birthNumber >= 5 ? 2 : birthNumber >= 3 ? 3 : 4
        let luck = ContextSignal(
            key: "BIRTH_LUCK_PROFILE", title: l.text("Doğal şans eğilimi", "Natural luck tendency"),
            meaning: l.select(tables.luck[luckIndex]),
            use: l.text("Fırsatı hazırlık, beceri ve doğru zamanlamayla birleştir.", "Combine opportunity with preparation, skill, and sound timing."),
            watch: l.text("Fırsatları koşullarıyla birlikte değerlendir.", "Consider the conditions that shape an opportunity."),
            domains: ["work", "money", "love"]
        )
        var signals = [characterSignal, combined, luck, balance]
        if character.marker {
            signals.append(ContextSignal(key: "NAME_STRUCTURE_MARKER",
                title: l.text("Büyük fikri yapıya dönüştürme", "Turning a large idea into structure"),
                meaning: l.text("Büyük ölçekli fikirleri uygulanabilir bir düzene çevirme eğilimi.", "A tendency to turn large ideas into workable structures."),
                use: l.text("Vizyonu küçük teslimlere ve açık sorumluluklara böl.", "Break the vision into small deliveries and clear ownership."),
                watch: l.text("Başlangıç adımını küçük tut.", "Keep the first step small."), domains: ["work", "money"]))
        }
        if base == 20 {
            signals.append(ContextSignal(key: "FREQUENT_REVIEW_MARKER",
                title: l.text("Sık kontrol isteyen dönem ritmi", "A rhythm needing regular review"),
                meaning: l.text("Büyük kararları küçük aşamalara bölmek ve her aşamada şartları yeniden kontrol etmek öne çıkar.", "Breaking major decisions into smaller stages makes room to revisit conditions as you go."),
                use: l.text("Her aşamada şartları gözden geçir.", "Review the conditions at each stage."),
                watch: l.text("Plan için yeniden değerlendirme zamanı ayır.", "Leave time to revisit the plan."), domains: ["work", "money", "love"]))
        }

        let currentYear = calendar.component(.year, from: today)
        let marriageYear = profile.married ? profile.marriageDate.flatMap { $0 <= today ? calendar.component(.year, from: $0) : nil } : nil
        var periods = cycles(origin: year, base: base, current: currentYear, married: false, l)
        if let marriageYear {
            periods += cycles(origin: marriageYear, base: base, current: currentYear, married: true, l)
        }
        if (1...9).contains(birthNumber) {
            let next = nextCycle(origin: year, step: base, current: currentYear)
            let difference = (birthNumber - next % 10 + 9) % 10 + 1
            let supportive = next + difference
            periods.append(ContextPeriod(key: "SUPPORTIVE_\(supportive)", year: supportive, kind: "supportive",
                meaning: l.text("Hazırlığı tamamlanmış bir hedefi görünür adıma çevirmek için destekleyici kabul edilen bir zaman işareti.",
                                "A symbolic time marker for turning a prepared goal into a visible step."),
                domains: ["work", "money"]))
        }
        periods.sort { $0.year < $1.year }
        var forecasts = [
            factor("FORECAST_NAME_BIRTH", "name_birth", l.text("Karakter eğilimi", "Character tendency"),
                   combined.meaning + " " + characterSignal.meaning, combined.use, combined.watch, nil, combined.domains),
            factor("FORECAST_LUCK_BALANCE", "luck", luck.title, luck.meaning + " " + balance.meaning,
                   balance.use, balance.watch, nil, luck.domains)
        ]
        let preferred = [
            periods.first { $0.kind == "critical" } ?? periods.first { $0.kind == "attention" },
            periods.first { $0.kind == "supportive" },
            periods.first { $0.kind == "relationship_critical" } ?? periods.first { $0.kind == "relationship_attention" }
        ].compactMap { $0 }
        for period in preferred {
            switch period.kind {
            case "supportive":
                forecasts.append(factor("FORECAST_SUPPORTIVE_\(period.year)", "supportive", l.text("Şansın desteklediği yıl", "A year supported by luck"),
                    period.meaning, l.text("Hazırladığın hedefi görünür bir adıma dönüştür.", "Turn a prepared goal into a visible step."),
                    l.text("Koşulları ve kaynakları gözden geçir.", "Review the conditions and resources."), period.year, period.domains))
            case "relationship_critical", "relationship_attention":
                forecasts.append(factor("FORECAST_MARRIAGE_\(period.year)", "marriage", l.text("Evlilikte dikkat edilmesi gereken yıl", "A marriage year requiring extra care"),
                    period.meaning, l.text("Beklentileri ve günlük sorumlulukları açıkça konuş.", "Discuss expectations and everyday responsibilities openly."),
                    l.text("Önemli ortak kararlar için düşünme payı bırak.", "Leave room to reflect before major shared decisions."), period.year, period.domains))
            default:
                forecasts.append(factor("FORECAST_PERSONAL_\(period.year)", "timing", l.text("Dikkat edilmesi gereken yıl", "A year requiring extra care"),
                    period.meaning, l.text("Önemli kararlar için ikinci bir kontrol noktası koy.", "Add a second checkpoint for major decisions."),
                    l.text("Geri dönüşü zor kararları aceleye getirme.", "Allow time for decisions that are difficult to reverse."), period.year, period.domains))
            }
        }
        let selectedYears = Set(forecasts.compactMap(\.year))
        return Analysis(signals: signals, periods: periods.filter { selectedYears.contains($0.year) }, forecasts: forecasts)
    }

    private static func signal(_ key: String, _ values: [String], _ l: PalmLanguage, _ domains: [String]) -> ContextSignal {
        let offset = l == .tr ? 0 : 4
        return ContextSignal(key: key, title: values[offset], meaning: values[offset + 1],
                             use: values[offset + 2], watch: values[offset + 3], domains: domains)
    }

    private static func factor(_ key: String, _ category: String, _ title: String, _ meaning: String, _ positive: String,
                               _ caution: String, _ year: Int?, _ domains: [String]) -> FutureFactor {
        FutureFactor(key: key, category: category, title: title, value: year.map { String($0) } ?? "",
                     meaning: meaning, positive: positive, caution: caution, year: year, domains: domains)
    }

    private static func letterValues(_ name: String) -> [Int] {
        name.uppercased(with: Locale(identifier: "tr_TR")).compactMap { character in
            if let known = letters[character] { return known }
            let folded = String(character).folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            return folded.first.flatMap { letters[$0] }
        }
    }

    private static func digits(_ value: Int) -> Int {
        String(value).compactMap(\.wholeNumberValue).reduce(0, +)
    }

    private static func reduce(_ number: Int) -> (number: Int, marker: Bool) {
        var number = number
        var marker = false
        while number > 9 && number != 11 {
            marker = marker || number == 22
            number = digits(number)
        }
        return (number, marker)
    }

    private static func nextCycle(origin: Int, step: Int, current: Int) -> Int {
        let first = origin + step
        return first + (max(0, current - first) + step - 1) / step * step
    }

    private static func cycles(origin: Int, base: Int, current: Int, married: Bool, _ l: PalmLanguage) -> [ContextPeriod] {
        let smallestDivisor = (2...max(2, Int(Double(base).squareRoot()))).first { $0 < base && base % $0 == 0 }
        let step = base == 20 ? 2 : smallestDivisor.map { base / $0 } ?? base
        let first = nextCycle(origin: origin, step: step, current: current)
        return (0..<3).map { first + $0 * step }.filter { $0 <= current + 40 }.map { year in
            let critical = base == 20 || (year - origin) % base == 0
            let kind = (married ? "relationship_" : "") + (critical ? "critical" : "attention")
            let meaning: String
            if married {
                meaning = critical
                    ? l.text("Ortak kararlar ve birikmiş konulara daha fazla dikkat ayırmak için sembolik bir dönem.", "A symbolic period for giving extra care to shared decisions and unresolved issues.")
                    : l.text("Beklentileri konuşmak ve günlük sorumluluk dengesini gözden geçirmek için bir ara dönem.", "An interim period for discussing expectations and reviewing everyday responsibilities.")
            } else {
                meaning = critical
                    ? l.text("Yeni başlangıçlar ve önemli kararlar için şartları yeniden değerlendirmeyi hatırlatan sembolik bir yıl.", "A symbolic year for reassessing conditions around major choices and new starts.")
                    : l.text("Büyük kararlar öncesi koşulları ikinci kez kontrol etmek için bir ara dönem.", "An interim period for giving the conditions a second look before major choices.")
            }
            return ContextPeriod(key: "\(married ? "RELATIONSHIP" : "PERSONAL")_ATTENTION_\(year)",
                                 year: year, kind: kind, meaning: meaning, domains: married ? ["love"] : ["work", "money", "love"])
        }
    }
}

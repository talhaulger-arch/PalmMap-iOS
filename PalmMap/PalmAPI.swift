import CryptoKit
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation

struct PalmAPIError: Error {
    let code: String

    func message(_ l: PalmLanguage) -> String {
        switch code {
        case "sign_in_required", "account_changed":
            return l.text("Devam etmek için hesabına giriş yap.", "Sign in to your account to continue.")
        case "premium_entitlement_required", "partner_entitlement_required", "reward_credit_required":
            return l.text("Bu rapor için bir analiz hakkı gerekiyor.", "You need a reading credit to open this report.")
        case "plus_monthly_limit_reached":
            return l.text("Bu dönemin Plus hakları kullanıldı.", "You’ve used your Plus credits for this period.")
        case "report_generation_in_progress", "partner_ai_in_progress":
            return l.text("Rapor hazırlanıyor. Biraz sonra tekrar aç.", "Your reading is being prepared. Open it again in a moment.")
        case "ios_store_not_configured", "not_found":
            return l.text("iOS mağaza bağlantısı henüz hazır değil.", "The iOS store connection isn’t ready yet.")
        case "reward_device_verification_required":
            return l.text("Reklam ödülü için cihaz doğrulanamadı.", "This device couldn’t be verified for ad rewards.")
        case "rewards_not_configured", "ad_unavailable":
            return l.text("Şu anda izlenebilir ödüllü reklam yok.", "There’s no rewarded ad available right now.")
        case "reward_daily_limit":
            return l.text("Bugünkü reklam sınırına ulaştın.", "You’ve reached today’s ad limit.")
        case "apple_transaction_account_mismatch", "purchase_token_already_claimed":
            return l.text("Bu satın alma farklı bir PalmMap hesabına bağlı.", "This purchase belongs to another PalmMap account.")
        case "sign_in_failed", "google_sign_in_not_configured":
            return l.text("Giriş tamamlanamadı. Tekrar dene.", "Sign-in couldn’t be completed. Try again.")
        case "purchase_pending":
            return l.text("Satın alma Apple onayını bekliyor.", "The purchase is awaiting Apple’s approval.")
        case "pending_report_exists":
            return l.text("Önce Raporlarım bölümünden bekleyen raporu aç.", "Open your pending reading from My reports first.")
        case "local_storage_failed":
            return l.text("Rapor arşivi cihazda açılamadı.", "The report archive couldn’t be opened on this device.")
        default:
            return l.text("İşlem tamamlanamadı. Bağlantını kontrol edip tekrar dene.", "The request couldn’t be completed. Check your connection and try again.")
        }
    }
}

struct Entitlement: Codable {
    var subscriptionActive = false
    var subscriptionExpiry: String?
    var plusCreditsRemaining = 0
    var plusCreditsLimit = 30
    var reportCredits = 0
    var partnerCredits = 0
    var rewardCredits = 0
}

struct EntitlementReply: Decodable { let entitlement: Entitlement }

struct LatestReportReply: Decodable {
    struct Report: Decodable {
        struct Context: Decodable {
            let sections: [ContextSection]?
            let futureFactors: [FutureFactor]?
        }

        let reportId: String
        let language: PalmLanguage
        let reading: PersonalReading
        let context: Context?
    }

    let report: Report?
}

struct RewardWallet: Codable {
    let enabled: Bool
    let gold: Int
    let analysisGold: Int
    let rewardCredits: Int
    let rewardGrantsTotal: Int
    let entitlement: Entitlement
}

struct RewardSession: Decodable {
    let sessionId: String
    let customData: String
    let ssvUser: String
    let adUnitId: String
    let maxGold: Int
}

struct RewardRevenue: Codable {
    let sessionId: String
    let valueMicros: Int
    let currency: String
    let precision: Int
}

@MainActor
enum PalmAPI {
    static func request<T: Decodable>(
        _ path: String, method: String = "GET", body: (any Encodable)? = nil,
        uid: String, attested: Bool = false, timeout: TimeInterval = 35
    ) async throws -> T {
        guard let gateway = PalmConfiguration.gateway,
              let url = URL(string: gateway.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path),
              FirebaseApp.app() != nil, let user = Auth.auth().currentUser, user.uid == uid else {
            throw PalmAPIError(code: "sign_in_required")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(try await user.getIDToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("3.8.9-ios", forHTTPHeaderField: "X-PalmMap-Client")
        if attested {
            let token = try await AppCheck.appCheck().token(forcingRefresh: false)
            request.setValue(token.token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        guard Auth.auth().currentUser?.uid == uid else { throw PalmAPIError(code: "account_changed") }
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard Auth.auth().currentUser?.uid == uid else { throw PalmAPIError(code: "account_changed") }
        guard let http = response as? HTTPURLResponse else { throw PalmAPIError(code: "network") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? decoder.decode(Failure.self, from: data)
            throw PalmAPIError(code: failure?.error ?? "http_\(http.statusCode)")
        }
        return try decoder.decode(T.self, from: data)
    }

    static func message(_ error: Error, _ l: PalmLanguage) -> String {
        if let error = error as? PalmAPIError { return error.message(l) }
        if let error = error as? ScanError { return error.message(l) }
        return PalmAPIError(code: "network").message(l)
    }

    private struct Failure: Decodable { let error: String }
}

struct PendingReport: Codable {
    let id: UUID
    let personal: PersonalContext?
    let relationship: RelationshipContext?
    let names: [String]
    let hands: [HandReading]
    let rewardOnly: Bool

    var language: PalmLanguage { personal?.language ?? relationship?.language ?? .en }
}

@MainActor
enum PalmArchive {
    private struct Contents: Codable {
        var reports: [OwnedReading] = []
        var pending: PendingReport?
        var adRevenue: [RewardRevenue] = []
    }

    static func reports(_ uid: String) throws -> [OwnedReading] { try load(uid).reports }
    static func pending(_ uid: String) throws -> PendingReport? { try load(uid).pending }
    static func revenues(_ uid: String) throws -> [RewardRevenue] { try load(uid).adRevenue }

    static func setPending(_ value: PendingReport?, uid: String) throws {
        var data = try load(uid)
        data.pending = value
        try save(data, uid)
    }

    static func saveReport(_ value: OwnedReading, uid: String, completesPending: Bool = false) throws {
        var data = try load(uid)
        data.reports.removeAll { $0.id == value.id }
        data.reports.insert(value, at: 0)
        if completesPending { data.pending = nil }
        try save(data, uid)
    }

    static func queue(_ value: RewardRevenue, uid: String) throws {
        var data = try load(uid)
        data.adRevenue.removeAll { $0.sessionId == value.sessionId }
        data.adRevenue.append(value)
        try save(data, uid)
    }

    static func removeRevenue(_ session: String, uid: String) throws {
        var data = try load(uid)
        data.adRevenue.removeAll { $0.sessionId == session }
        try save(data, uid)
    }

    static func erase(_ uid: String) throws {
        let file = try url(uid)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private static func load(_ uid: String) throws -> Contents {
        do {
            let file = try url(uid)
            guard FileManager.default.fileExists(atPath: file.path) else { return Contents() }
            return try JSONDecoder().decode(Contents.self, from: Data(contentsOf: file))
        } catch { throw PalmAPIError(code: "local_storage_failed") }
    }

    private static func save(_ contents: Contents, _ uid: String) throws {
        do {
            try JSONEncoder().encode(contents).write(to: url(uid), options: [.atomic, .completeFileProtection])
        } catch { throw PalmAPIError(code: "local_storage_failed") }
    }

    private static func url(_ uid: String) throws -> URL {
        var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("PalmMap", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var settings = URLResourceValues()
        settings.isExcludedFromBackup = true
        try root.setResourceValues(settings)
        let hash = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash + ".json")
    }
}

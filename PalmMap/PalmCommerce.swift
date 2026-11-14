import Foundation
import StoreKit
import SwiftUI

enum PalmProduct: String, CaseIterable, Identifiable {
    case personal = "elharitasi_deep_report"
    case relationship = "elharitasi_partner_analysis"
    case plus = "elharitasi_plus"

    var id: String { rawValue }

    func title(_ l: PalmLanguage) -> String {
        switch self {
        case .personal: return l.text("Tek kişisel okuma", "Single personal reading")
        case .relationship: return l.text("Tek ilişki analizi", "Single relationship reading")
        case .plus: return "PalmMap Plus"
        }
    }

    func description(_ l: PalmLanguage) -> String {
        switch self {
        case .personal: return l.text("Bir tam kişisel rapor", "One complete personal reading")
        case .relationship: return l.text("İki avuç haritasından bir ortak rapor", "One shared reading from two palm maps")
        case .plus: return l.text("Ayda 30 kişisel veya ilişki analizi hakkı. Otomatik yenilenir.",
                                  "30 personal or relationship readings per month. Renews automatically.")
        }
    }
}

@MainActor
final class PalmCommerce: ObservableObject {
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var entitlement = Entitlement()
    @Published private(set) var buying = false
    @Published private(set) var storeReady = false

    private var user: String?
    private var observer: Task<Void, Never>?
    private var inDelivery: Set<UInt64> = []

    func setUser(_ uid: String?) {
        guard user != uid else { return }
        observer?.cancel()
        observer = nil
        user = uid
        entitlement = Entitlement()
        storeReady = false
        guard let uid else { return }
        observer = Task { [weak self] in
            guard let self else { return }
            for await transaction in Transaction.updates {
                guard !Task.isCancelled, self.user == uid else { break }
                try? await self.deliver(transaction, uid: uid)
            }
        }
    }

    func loadProducts() async throws {
        let found = try await Product.products(for: PalmProduct.allCases.map(\.rawValue))
        products = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
    }

    func refresh(_ uid: String) async throws {
        let response: EntitlementReply = try await PalmAPI.request("/v1/entitlements", uid: uid)
        guard user == uid else { return }
        entitlement = response.entitlement
        storeReady = (try? await storeConfiguration(uid).enabled) ?? false
    }

    func update(_ value: Entitlement, for uid: String) {
        guard user == uid else { return }
        entitlement = value
    }

    func retryPending(_ uid: String, restoreSubscriptions: Bool = false) async {
        for await transaction in Transaction.unfinished {
            guard user == uid, !Task.isCancelled else { return }
            try? await deliver(transaction, uid: uid)
        }
        if restoreSubscriptions {
            for await transaction in Transaction.currentEntitlements {
                guard user == uid, !Task.isCancelled else { return }
                try? await deliver(transaction, uid: uid)
            }
        }
    }

    func buy(_ item: PalmProduct, uid: String) async throws {
        guard !buying else { return }
        guard let product = products[item.rawValue], user == uid else {
            throw PalmAPIError(code: "ios_store_not_configured")
        }
        buying = true
        defer { buying = false }
        let config = try await storeConfiguration(uid)
        guard config.enabled else { throw PalmAPIError(code: "ios_store_not_configured") }
        switch try await product.purchase(options: [.appAccountToken(config.appAccountToken)]) {
        case .success(let transaction): try await deliver(transaction, uid: uid)
        case .pending: throw PalmAPIError(code: "purchase_pending")
        case .userCancelled: return
        @unknown default: throw PalmAPIError(code: "purchase_failed")
        }
    }

    func restore(_ uid: String) async throws {
        guard !buying else { return }
        buying = true
        defer { buying = false }
        try await AppStore.sync()
        await retryPending(uid, restoreSubscriptions: true)
        try await refresh(uid)
    }

    private func deliver(_ result: VerificationResult<Transaction>, uid: String) async throws {
        guard case .verified(let transaction) = result, PalmProduct(rawValue: transaction.productID) != nil else {
            throw PalmAPIError(code: "purchase_failed")
        }
        guard user == uid else { throw PalmAPIError(code: "account_changed") }
        guard inDelivery.insert(transaction.id).inserted else { return }
        defer { inDelivery.remove(transaction.id) }
        let config = try await storeConfiguration(uid)
        guard config.enabled, transaction.appAccountToken == config.appAccountToken else {
            throw PalmAPIError(code: "apple_transaction_account_mismatch")
        }
        let response: VerifiedPurchase = try await PalmAPI.request(
            "/v1/ios/purchases/verify", method: "POST", body: Purchase(signedTransaction: result.jwsRepresentation), uid: uid
        )
        guard response.verified, user == uid else { throw PalmAPIError(code: "purchase_failed") }
        entitlement = response.entitlement
        await transaction.finish()
    }

    private func storeConfiguration(_ uid: String) async throws -> Configuration {
        try await PalmAPI.request("/v1/ios/store", uid: uid)
    }

    private struct Configuration: Decodable { let enabled: Bool; let appAccountToken: UUID }
    private struct Purchase: Encodable { let signedTransaction: String }
    private struct VerifiedPurchase: Decodable { let verified: Bool; let entitlement: Entitlement }
}

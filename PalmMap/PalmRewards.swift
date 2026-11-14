import Foundation
import GoogleMobileAds
import StoreKit
import SwiftUI
import UIKit
import UserMessagingPlatform

@MainActor
final class PalmRewards: NSObject, ObservableObject, FullScreenContentDelegate {
    @Published private(set) var wallet: RewardWallet?
    @Published private(set) var showing = false
    @Published private(set) var loading = false
    @Published private(set) var pending = false
    @Published private(set) var needsPrivacyOptions = false
    @Published private(set) var eligibleRegion = false
    @Published var notice: PalmAPIError?

    private var activeAd: RewardedAd?
    private var settlement: Task<Void, Never>?
    private var user: String?
    private var consentLoaded = false
    private var sdkStarted = false
    private var earnedBeforeDismissal = false

    var available: Bool { eligibleRegion && PalmConfiguration.rewardedUnit != nil && wallet?.enabled == true }

    func setUser(_ uid: String?) {
        guard user != uid else { return }
        settlement?.cancel()
        settlement = nil
        user = uid
        wallet = nil
        pending = false
    }

    func refresh(_ uid: String) async throws {
        let storefront = await Storefront.current
        eligibleRegion = storefront.map { $0.countryCode != "TUR" } ?? false
        guard user == uid else { return }
        try? await flush(uid)
        let value: RewardWallet = try await PalmAPI.request("/v1/rewards/wallet", uid: uid)
        if user == uid { wallet = value }
    }

    func watch(_ uid: String) async throws {
        guard user == uid, available, let unit = PalmConfiguration.rewardedUnit,
              let presenter = Presentation.controller, loading == false, showing == false else {
            throw PalmAPIError(code: "ad_unavailable")
        }
        loading = true
        defer { loading = false }
        try await requestConsent(from: presenter)
        guard user == uid, ConsentInformation.shared.canRequestAds else {
            throw PalmAPIError(code: "ad_unavailable")
        }
        if !sdkStarted {
            sdkStarted = true
            MobileAds.shared.requestConfiguration.setPublisherFirstPartyIDEnabled(false)
            MobileAds.shared.start(completionHandler: nil)
        }
        let request = Request()
        let options = Extras()
        options.additionalParameters = ["npa": "1"]
        request.register(options)
        let ad = try await RewardedAd.load(with: unit, request: request)
        guard user == uid, let presenter = Presentation.controller else { throw PalmAPIError(code: "account_changed") }
        let session: RewardSession = try await PalmAPI.request(
            "/v1/ios/rewards/session", method: "POST", body: EmptyBody(), uid: uid, attested: true
        )
        guard session.adUnitId == unit, user == uid else { throw PalmAPIError(code: "rewards_not_configured") }
        let verification = ServerSideVerificationOptions()
        verification.userIdentifier = session.ssvUser
        verification.customRewardText = session.customData
        ad.serverSideVerificationOptions = verification
        ad.fullScreenContentDelegate = self
        ad.paidEventHandler = { [weak self] value in
            let micros = value.value.multiplying(byPowerOf10: 6).doubleValue
            let currency = value.currencyCode.uppercased()
            let precision = value.precision.rawValue
            guard micros.isFinite, micros >= 0, currency == "USD", precision == 1 || precision == 3 else { return }
            let capped = Int(min(micros.rounded(), Double(session.maxGold)))
            let item = RewardRevenue(sessionId: session.sessionId, valueMicros: capped, currency: currency, precision: precision)
            Task { @MainActor in await self?.queue(item, uid: uid) }
        }
        earnedBeforeDismissal = false
        activeAd = ad
        showing = true
        ad.present(from: presenter) { [weak self] in
            Task { @MainActor in
                guard let self, self.user == uid else { return }
                self.earnedBeforeDismissal = true
                self.poll(uid)
            }
        }
    }

    func privacyOptions() async throws {
        guard let presenter = Presentation.controller else { return }
        try await ConsentForm.presentPrivacyOptionsForm(from: presenter)
        needsPrivacyOptions = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        showing = false
        activeAd = nil
        if !earnedBeforeDismissal, let user { Task { try? await refresh(user) } }
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        showing = false
        activeAd = nil
        notice = PalmAPIError(code: "ad_unavailable")
    }

    private func requestConsent(from presenter: UIViewController) async throws {
        guard !consentLoaded else { return }
        let parameters = RequestParameters()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        try await ConsentForm.loadAndPresentIfRequired(from: presenter)
        needsPrivacyOptions = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        consentLoaded = true
    }

    private func queue(_ revenue: RewardRevenue, uid: String) async {
        guard user == uid else { return }
        do {
            try PalmArchive.queue(revenue, uid: uid)
            try await flush(uid)
        } catch {
            if user == uid { notice = error as? PalmAPIError }
        }
    }

    private func flush(_ uid: String) async throws {
        for item in try PalmArchive.revenues(uid) {
            guard user == uid else { return }
            do {
                let response: RevenueReply = try await PalmAPI.request(
                    "/v1/rewards/revenue", method: "POST", body: item, uid: uid, attested: true
                )
                try PalmArchive.removeRevenue(item.sessionId, uid: uid)
                if user == uid { wallet = response.wallet }
            } catch let error as PalmAPIError {
                let settledCodes = ["reward_session_not_found", "reward_session_expired", "reward_value_already_recorded"]
                guard settledCodes.contains(error.code) else { throw error }
                try PalmArchive.removeRevenue(item.sessionId, uid: uid)
            }
        }
    }

    private func poll(_ uid: String) {
        let old = wallet
        settlement?.cancel()
        pending = true
        settlement = Task {
            for seconds in [2, 3, 5, 10, 20, 35] {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard user == uid else { return }
                try? await refresh(uid)
                if wallet?.gold != old?.gold || wallet?.rewardGrantsTotal != old?.rewardGrantsTotal { break }
            }
            if user == uid { pending = false }
        }
    }

    private struct EmptyBody: Encodable {}
    private struct RevenueReply: Decodable { let wallet: RewardWallet }
}

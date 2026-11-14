import SwiftUI

@MainActor
final class PalmReadings: ObservableObject {
    @Published private(set) var reports: [OwnedReading] = []
    @Published private(set) var pending: PendingReport?
    @Published private(set) var working = false

    private var user: String?

    func setUser(_ uid: String?) {
        guard user != uid else { return }
        user = uid
        reports = []
        pending = nil
        if let uid { try? reload(uid) }
    }

    func reload(_ uid: String) throws {
        guard user == uid else { return }
        reports = try PalmArchive.reports(uid)
        pending = try PalmArchive.pending(uid)
    }

    func finish(_ draft: PendingReport, uid: String) async throws -> OwnedReading {
        guard !working, user == uid else { throw PalmAPIError(code: "report_generation_in_progress") }
        if let pending, pending.id != draft.id {
            throw PalmAPIError(code: "pending_report_exists")
        }
        working = true
        defer { working = false }
        try PalmArchive.setPending(draft, uid: uid)
        try reload(uid)
        let saved: OwnedReading
        do {
            if let context = draft.personal {
                let path = draft.rewardOnly ? "/v1/interpretation/reward" : "/v1/interpretation"
                let result: PersonalResult = try await PalmAPI.request(path, method: "POST", body: context, uid: uid, timeout: 90)
                let titles = Dictionary(uniqueKeysWithValues: context.sections.map { ($0.key, $0.title) })
                let years = Dictionary(uniqueKeysWithValues: context.futureFactors.compactMap { value in value.year.map { (value.category, $0) } })
                saved = OwnedReading(id: result.reportId, language: context.language, names: draft.names, savedAt: Date(),
                                    personal: result.reading, relationship: nil, titles: titles, years: years, hands: draft.hands)
            } else if let context = draft.relationship {
                let path = draft.rewardOnly ? "/v1/partner-analyses/claim-reward" : "/v1/partner-analyses/claim"
                let claim: Claim = try await PalmAPI.request(path, method: "POST", body: ClaimBody(claimId: context.claimId), uid: uid)
                guard claim.allowed else { throw PalmAPIError(code: "partner_entitlement_required") }
                let result: RelationshipResult = try await PalmAPI.request("/v1/partner-analyses/interpretation",
                    method: "POST", body: context, uid: uid, timeout: 95)
                saved = OwnedReading(id: result.reportId, language: context.language, names: draft.names, savedAt: Date(),
                    personal: nil, relationship: result.reading, titles: ReadingEngine.relationshipTitles(context.language),
                    years: [:], hands: draft.hands)
            } else {
                throw ScanError.resource
            }
        } catch let error as PalmAPIError where
            ["premium_entitlement_required", "partner_entitlement_required", "reward_credit_required", "plus_monthly_limit_reached"].contains(error.code) {
            if user == uid {
                try PalmArchive.setPending(nil, uid: uid)
                try reload(uid)
            }
            throw error
        }
        guard user == uid else { throw PalmAPIError(code: "account_changed") }
        try PalmArchive.saveReport(saved, uid: uid, completesPending: true)
        try reload(uid)
        return saved
    }

    func restoreLatest(_ uid: String) async throws -> OwnedReading? {
        let response: LatestReportReply = try await PalmAPI.request("/v1/reports/latest", uid: uid)
        guard user == uid, let report = response.report else { return nil }
        if let local = reports.first(where: { $0.id == report.reportId }) { return local }
        var titles: [String: String] = [:]
        var years: [String: Int] = [:]
        for section in report.context?.sections ?? [] { titles[section.key] = section.title }
        for factor in report.context?.futureFactors ?? [] where years[factor.category] == nil {
            years[factor.category] = factor.year
        }
        let restored = OwnedReading(id: report.reportId, language: report.language, names: [], savedAt: Date(),
            personal: report.reading, relationship: nil, titles: titles, years: years, hands: [])
        try PalmArchive.saveReport(restored, uid: uid)
        try reload(uid)
        return restored
    }

    func flag(_ report: OwnedReading, reason: String, uid: String) async throws {
        let result: FlagResult = try await PalmAPI.request("/v1/content-reports", method: "POST",
            body: Flag(reportId: report.id, reason: reason), uid: uid)
        guard result.reported else { throw PalmAPIError(code: "content_report_not_confirmed") }
    }

    func feedback(_ report: OwnedReading, rating: String?, suggestion: String, uid: String) async throws {
        let result: FeedbackResult = try await PalmAPI.request("/v1/reading-feedback", method: "POST",
            body: Feedback(reportId: report.id, rating: rating, suggestion: suggestion, language: report.language), uid: uid)
        guard result.saved else { throw PalmAPIError(code: "feedback_not_saved") }
    }

    private struct Claim: Decodable { let allowed: Bool }
    private struct ClaimBody: Encodable { let claimId: String }
    private struct Flag: Encodable { let reportId: String; let reason: String }
    private struct FlagResult: Decodable { let reported: Bool }
    private struct Feedback: Encodable { let reportId: String; let rating: String?; let suggestion: String; let language: PalmLanguage }
    private struct FeedbackResult: Decodable { let saved: Bool }
}

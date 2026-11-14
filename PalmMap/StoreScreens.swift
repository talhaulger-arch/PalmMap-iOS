import AuthenticationServices
import StoreKit
import SwiftUI

struct ShopScreen: View {
    let language: PalmLanguage
    @EnvironmentObject private var account: PalmAccount
    @EnvironmentObject private var commerce: PalmCommerce
    @EnvironmentObject private var rewards: PalmRewards
    @State private var showAccount = false
    @State private var message = ""

    var body: some View {
        PalmScreen {
            PalmTitle(title: language.text("Ücretler ve paketler", "Pricing and plans"), subtitle: "")
            if account.uid != nil {
                PalmCard {
                    Text(language.text("Mevcut haklarım", "My reading credits")).font(.headline)
                    rights(language.text("Kişisel okuma", "Personal"), commerce.entitlement.reportCredits)
                    rights(language.text("İlişki analizi", "Relationship"), commerce.entitlement.partnerCredits)
                    rights("Plus", commerce.entitlement.plusCreditsRemaining)
                    rights(language.text("Reklamdan kazanılan", "Ad-earned"), commerce.entitlement.rewardCredits)
                }
            }
            ForEach(PalmProduct.allCases) { item in
                PalmCard {
                    Text(item.title(language)).font(.system(.title2, design: .serif, weight: .semibold))
                    Text(item.description(language)).font(.subheadline).foregroundStyle(PalmStyle.muted)
                    if let product = commerce.products[item.rawValue] {
                        let price = item == .plus ? language.text("\(product.displayPrice) / ay", "\(product.displayPrice) / month") : product.displayPrice
                        Button(price) { buy(item) }.buttonStyle(PalmActionStyle())
                            .accessibilityLabel("\(item.title(language)), \(price)")
                            .disabled(commerce.buying || (account.uid != nil && !commerce.storeReady)
                                      || (item == .plus && commerce.entitlement.subscriptionActive))
                    } else {
                        Text(language.text("Fiyat henüz alınamadı", "Price unavailable")).font(.footnote).foregroundStyle(PalmStyle.muted)
                    }
                }
            }
            if account.uid == nil {
                Button(language.text("Hesaba giriş yap", "Sign in")) { showAccount = true }.buttonStyle(.bordered)
            } else if !commerce.storeReady {
                Text(language.text("App Store satın alma bağlantısı şu anda kullanılamıyor.", "The App Store purchase connection is currently unavailable."))
                    .font(.footnote).foregroundStyle(PalmStyle.muted)
            }
            Button(language.text("Satın alımları geri yükle", "Restore purchases")) {
                guard let uid = account.uid else { showAccount = true; return }
                Task {
                    await run {
                        try await commerce.restore(uid)
                        message = language.text("Hesabındaki satın alımlar güncellendi.", "Purchases on your account have been refreshed.")
                    }
                }
            }.buttonStyle(.bordered).disabled(commerce.buying)
            if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                Link(language.text("Apple aboneliklerini yönet", "Manage Apple subscriptions"), destination: url)
            }
            if rewards.available || (PalmConfiguration.rewardedUnit != nil && account.uid == nil) {
                RewardCard(language: language) { showAccount = true }
            }
            if commerce.buying { ProgressView() }
            if !message.isEmpty { PalmMessage(value: message) }
            LegalLinks(language: language)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAccount) { AccountSheet(language: language) }
        .task {
            await run {
                try await commerce.loadProducts()
                if let uid = account.uid { try await commerce.refresh(uid) }
            }
        }
    }

    private func rights(_ title: String, _ count: Int) -> some View {
        HStack { Text(title); Spacer(); Text(String(count)).monospacedDigit().foregroundStyle(PalmStyle.gold) }
            .font(.subheadline)
    }

    private func buy(_ item: PalmProduct) {
        guard let uid = account.uid else { showAccount = true; return }
        Task { await run { try await commerce.buy(item, uid: uid) } }
    }

    private func run(_ work: () async throws -> Void) async {
        message = ""
        do { try await work() } catch { message = PalmAPI.message(error, language) }
    }
}

private struct RewardCard: View {
    let language: PalmLanguage
    let requestAccount: () -> Void
    @EnvironmentObject private var account: PalmAccount
    @EnvironmentObject private var commerce: PalmCommerce
    @EnvironmentObject private var rewards: PalmRewards

    var body: some View {
        PalmCard {
            Label(language.text("Analiz hakkı kazan", "Earn a reading credit"), systemImage: "sparkles")
                .font(.headline).foregroundStyle(PalmStyle.gold)
            Text(language.text("Ödüllü reklam izle, altın biriktir ve bir rapor aç.",
                               "Watch rewarded ads, collect gold and unlock a reading."))
                .font(.subheadline)
            if let wallet = rewards.wallet {
                let target = max(1, wallet.analysisGold)
                let balance = max(0, min(wallet.gold, target))
                let displayed = Int((Double(balance) / Double(target) * 50).rounded(.down))
                ProgressView(value: Double(balance), total: Double(target)).tint(PalmStyle.gold)
                Text(language.text("\(displayed) / 50 altın", "\(displayed) / 50 gold"))
                    .font(.caption.monospacedDigit()).foregroundStyle(PalmStyle.muted)
            }
            Button(language.text("Ödüllü reklam izle", "Watch rewarded ad")) {
                guard let uid = account.uid else { requestAccount(); return }
                Task {
                    rewards.notice = nil
                    do { try await rewards.watch(uid) }
                    catch { rewards.notice = error as? PalmAPIError ?? PalmAPIError(code: "ad_unavailable") }
                }
            }.buttonStyle(.bordered).disabled(rewards.loading || rewards.showing)
            if rewards.loading || rewards.pending {
                ProgressView(rewards.pending ? language.text("Ödül doğrulanıyor…", "Verifying reward…") : language.text("Reklam hazırlanıyor…", "Loading ad…"))
                    .font(.caption)
            }
            if let notice = rewards.notice { PalmMessage(value: notice.message(language)) }
        }
        .onChange(of: rewards.wallet?.rewardCredits) { _, _ in
            if let uid = account.uid, let entitlement = rewards.wallet?.entitlement {
                commerce.update(entitlement, for: uid)
            }
        }
    }
}

struct SettingsScreen: View {
    let language: PalmLanguage
    @AppStorage("palmmap.language") private var selected = ""
    @EnvironmentObject private var account: PalmAccount
    @EnvironmentObject private var rewards: PalmRewards
    @State private var showAccount = false
    @State private var confirmDelete = false
    @State private var appleDelete = false
    @State private var working = false
    @State private var message = ""

    var body: some View {
        PalmScreen {
            PalmTitle(title: language.text("Ayarlar", "Settings"), subtitle: "")
            PalmCard {
                Picker(language.text("Dil", "Language"), selection: $selected) {
                    Text("English").tag("en")
                    Text("Türkçe").tag("tr")
                }.pickerStyle(.segmented)
            }
            PalmCard {
                Text(language.text("Hesap", "Account")).font(.headline)
                if account.uid != nil {
                    if let email = account.email { Text(email).font(.subheadline).textSelection(.enabled) }
                    Button(language.text("Çıkış yap", "Sign out")) {
                        do { try account.signOut() } catch { message = PalmAPI.message(error, language) }
                    }.buttonStyle(.bordered)
                    Button(language.text("Hesabı sil", "Delete account"), role: .destructive) {
                        confirmDelete = true
                    }.disabled(working)
                } else {
                    Button(language.text("Giriş yap", "Sign in")) { showAccount = true }.buttonStyle(.bordered)
                }
            }
            if rewards.needsPrivacyOptions {
                Button(language.text("Reklam gizlilik seçenekleri", "Ad privacy options")) {
                    Task { await run { try await rewards.privacyOptions() } }
                }.buttonStyle(.bordered)
            }
            LegalLinks(language: language)
            if working { ProgressView() }
            if !message.isEmpty { PalmMessage(value: message) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAccount) { AccountSheet(language: language) }
        .sheet(isPresented: $appleDelete) {
            PalmScreen {
                PalmTitle(title: language.text("Hesap silmeyi doğrula", "Confirm account deletion"),
                          subtitle: language.text("Apple hesabını doğruladıktan sonra PalmMap verilerin silinecek.",
                                                  "Confirm your Apple account to delete your PalmMap data."))
                SignInWithAppleButton(.continue, onRequest: { account.prepareApple($0, deleting: true) }, onCompletion: { result in
                    Task {
                        await run {
                            try await account.completeApple(result, deleting: true)
                            appleDelete = false
                            message = language.text("PalmMap hesabın silindi.", "Your PalmMap account was deleted.")
                        }
                    }
                }).signInWithAppleButtonStyle(.white).frame(height: 48).disabled(working)
                Button(language.text("Vazgeç", "Cancel")) { appleDelete = false }.disabled(working)
                if !message.isEmpty { PalmMessage(value: message) }
            }
        }
        .confirmationDialog(language.text("PalmMap hesabın silinsin mi?", "Delete your PalmMap account?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(language.text("Hesabı sil", "Delete account"), role: .destructive) {
                guard let uid = account.uid else { return }
                if account.usesApple {
                    message = ""
                    appleDelete = true
                } else {
                    Task {
                        await run {
                            try await account.delete(uid: uid)
                            message = language.text("PalmMap hesabın silindi.", "Your PalmMap account was deleted.")
                        }
                    }
                }
            }
        } message: {
            Text(language.text("Raporların ve hesap hakların silinir. Aktif Apple aboneliğini App Store’dan yönetebilirsin.",
                               "Your reports and account credits are deleted. You can manage an active Apple subscription in the App Store."))
        }
    }

    private func run(_ work: () async throws -> Void) async {
        working = true
        message = ""
        defer { working = false }
        do { try await work() } catch { message = PalmAPI.message(error, language) }
    }
}

struct LegalLinks: View {
    let language: PalmLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let privacy = PalmConfiguration.gateway?.appendingPathComponent("privacy") {
                Link(language.text("Gizlilik politikası", "Privacy policy"), destination: privacy)
            }
            if let eula = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                Link(language.text("Kullanım koşulları", "Terms of use"), destination: eula)
            }
        }.font(.footnote)
    }
}

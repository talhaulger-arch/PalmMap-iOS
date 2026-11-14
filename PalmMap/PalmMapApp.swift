import AuthenticationServices
import GoogleSignIn
import SwiftUI

@main
@MainActor
struct PalmMapApp: App {
    @StateObject private var account: PalmAccount
    @StateObject private var commerce = PalmCommerce()
    @StateObject private var rewards = PalmRewards()
    @StateObject private var readings = PalmReadings()
    @AppStorage("palmmap.language") private var language = ""

    init() {
        PalmConfiguration.configureFirebase()
        _account = StateObject(wrappedValue: PalmAccount())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let l = PalmLanguage(rawValue: language) {
                    HomeScreen(language: l)
                        .environment(\.locale, l.locale)
                } else {
                    LanguageScreen { language = $0.rawValue }
                }
            }
            .environmentObject(account)
            .environmentObject(commerce)
            .environmentObject(rewards)
            .environmentObject(readings)
            .preferredColorScheme(.dark)
            .tint(PalmStyle.gold)
            .onOpenURL { _ = GIDSignIn.sharedInstance.handle($0) }
            .task(id: account.uid) {
                let uid = account.uid
                commerce.setUser(uid)
                rewards.setUser(uid)
                readings.setUser(uid)
                if let uid {
                    await commerce.retryPending(uid, restoreSubscriptions: true)
                    try? await commerce.refresh(uid)
                    try? await rewards.refresh(uid)
                }
            }
        }
    }
}

enum PalmStyle {
    static let night = Color(red: 0.025, green: 0.105, blue: 0.100)
    static let emerald = Color(red: 0.054, green: 0.235, blue: 0.215)
    static let gold = Color(red: 0.94, green: 0.78, blue: 0.50)
    static let paper = Color(red: 0.97, green: 0.92, blue: 0.82)
    static let muted = Color(red: 0.74, green: 0.81, blue: 0.76)
    static let stroke = gold.opacity(0.25)

    static var background: some View {
        LinearGradient(colors: [emerald, night, night], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

struct PalmScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .frame(maxWidth: 620)
                .padding(.horizontal, 22)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
        }
        .background(PalmStyle.background)
        .foregroundStyle(PalmStyle.paper)
        .scrollDismissesKeyboard(.interactively)
    }
}

struct PalmCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(17)
            .background(PalmStyle.emerald.opacity(0.72), in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(PalmStyle.stroke, lineWidth: 1))
    }
}

struct PalmTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.largeTitle, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(PalmStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PalmActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 12)
            .foregroundStyle(PalmStyle.night)
            .background(PalmStyle.gold, in: RoundedRectangle(cornerRadius: 13))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.48)
    }
}

struct PalmMessage: View {
    let value: String

    var body: some View {
        Text(value).font(.subheadline).foregroundStyle(PalmStyle.gold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct LanguageScreen: View {
    let choose: (PalmLanguage) -> Void

    var body: some View {
        PalmScreen {
            VStack(spacing: 16) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 54, weight: .ultraLight)).foregroundStyle(PalmStyle.gold)
                    .accessibilityHidden(true)
                Text("PalmMap").font(.system(size: 49, weight: .regular, design: .serif))
                Button("English") { choose(.en) }.buttonStyle(PalmActionStyle())
                Button("Türkçe") { choose(.tr) }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        }
    }
}

struct HomeScreen: View {
    let language: PalmLanguage

    var body: some View {
        NavigationStack {
            PalmScreen {
                VStack(alignment: .leading, spacing: 7) {
                    Text("PalmMap").font(.system(size: 47, weight: .regular, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    Text(language.text("Avuçlarındaki hikâyeyi keşfet.", "Discover the story in your palms."))
                        .font(.subheadline).foregroundStyle(PalmStyle.muted)
                }
                NavigationLink {
                    CaptureFlow(language: language, relationship: false)
                } label: {
                    feature("PersonalArt", language.text("El haritamı oluştur", "Create my palm map"),
                            language.text("Kişisel okuma", "Personal reading"))
                }.buttonStyle(.plain)
                NavigationLink {
                    CaptureFlow(language: language, relationship: true)
                } label: {
                    feature("RelationshipArt", language.text("İlişki analizi", "Relationship reading"),
                            language.text("İki el haritası, bir ortak rapor", "Two palm maps, one shared report"))
                }.buttonStyle(.plain)
                NavigationLink {
                    ArchiveScreen(language: language)
                } label: {
                    Label(language.text("Raporlarım", "My reports"), systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                }.buttonStyle(.bordered)
                NavigationLink {
                    ShopScreen(language: language)
                } label: {
                    Label(language.text("Ücretler ve paketler", "Pricing and plans"), systemImage: "sparkle")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                }.buttonStyle(.bordered)
                Text(language.text("Geleneksel el yorumuna dayalı bir eğlence deneyimi.", "An entertainment experience inspired by traditional palm reading."))
                    .font(.footnote).foregroundStyle(PalmStyle.muted)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen(language: language)
                    } label: {
                        Label(language.text("Ayarlar", "Settings"), systemImage: "gearshape").labelStyle(.iconOnly)
                    }
                }
            }
        }
    }

    private func feature(_ image: String, _ title: String, _ detail: String) -> some View {
        PalmCard {
            HStack(spacing: 14) {
                Image(image)
                    .resizable().scaledToFill().frame(width: 86, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(.title3, design: .serif, weight: .semibold)).foregroundStyle(PalmStyle.paper)
                    Text(detail).font(.subheadline).foregroundStyle(PalmStyle.muted)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.forward").font(.caption.weight(.bold)).foregroundStyle(PalmStyle.gold)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 92)
        }
    }
}

struct AccountSheet: View {
    let language: PalmLanguage
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: PalmAccount
    @State private var message = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            PalmScreen {
                PalmTitle(title: language.text("PalmMap hesabın", "Your PalmMap account"),
                          subtitle: language.text("Raporlarını ve analiz haklarını hesabında tut.", "Keep your reports and reading credits with your account."))
                if account.isConfigured {
                    SignInWithAppleButton(.continue, onRequest: { account.prepareApple($0) }, onCompletion: { result in
                        Task { await run { try await account.completeApple(result) } }
                    })
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 48)
                    .disabled(working)
                    Button(language.text("Google ile devam et", "Continue with Google")) {
                        Task { await run { try await account.googleSignIn() } }
                    }
                    .buttonStyle(.bordered)
                    .disabled(working)
                } else {
                    PalmMessage(value: language.text("Hesap bağlantısı henüz yapılandırılmadı.", "Account sign-in has yet to be configured."))
                }
                if working { ProgressView() }
                if !message.isEmpty { PalmMessage(value: message) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("Kapat", "Close")) { dismiss() }
                }
            }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await work()
            dismiss()
        } catch {
            if (error as? ASAuthorizationError)?.code != .canceled { message = PalmAPI.message(error, language) }
        }
    }
}

import AuthenticationServices
import CryptoKit
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import SwiftUI
import UIKit

enum PalmConfiguration {
    static var gateway: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PalmMapGatewayURL") as? String,
              let url = URL(string: raw), url.scheme == "https", let host = url.host,
              host.hasSuffix(".run.app"), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static var rewardedUnit: String? {
        guard let appId = Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String,
              !appId.contains("3940256099942544"),
              let value = Bundle.main.object(forInfoDictionaryKey: "PalmMapRewardedAdUnit") as? String,
              value.range(of: #"^ca-app-pub-[0-9]+/[0-9]+$"#, options: .regularExpression) != nil,
              !value.contains("3940256099942544") else { return nil }
        return value
    }

    static func configureFirebase() {
        guard FirebaseApp.app() == nil,
              let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let values = NSDictionary(contentsOfFile: path),
              values["PALMMAP_PLACEHOLDER"] as? Bool != true,
              let options = FirebaseOptions(contentsOfFile: path) else { return }
        AppCheck.setAppCheckProviderFactory(PalmAttestation())
        FirebaseApp.configure(options: options)
    }
}

private final class PalmAttestation: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator) && DEBUG
        return AppCheckDebugProvider(app: app)
        #else
        return AppAttestProvider(app: app)
        #endif
    }
}

@MainActor
enum Presentation {
    static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }

    static var controller: UIViewController? {
        var current = window?.rootViewController
        while let next = current?.presentedViewController, !next.isBeingDismissed { current = next }
        return current
    }
}

@MainActor
final class PalmAccount: ObservableObject {
    @Published private(set) var uid: String?
    @Published private(set) var email: String?
    @Published private(set) var usesApple = false

    private var handle: AuthStateDidChangeListenerHandle?
    private var nonce: String?

    var isConfigured: Bool { FirebaseApp.app() != nil }

    init() {
        guard isConfigured else { return }
        update(Auth.auth().currentUser)
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.update(user) }
        }
    }

    private func update(_ user: FirebaseAuth.User?) {
        uid = user?.uid
        email = user?.email
        usesApple = user?.providerData.contains { $0.providerID == "apple.com" } ?? false
    }

    func googleSignIn() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID, let presenter = Presentation.controller,
              let schemes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            throw PalmAPIError(code: "google_sign_in_not_configured")
        }
        let expectedScheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        guard
              schemes.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(expectedScheme) == true }) else {
            throw PalmAPIError(code: "google_sign_in_not_configured")
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let response = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = response.user.idToken?.tokenString else { throw PalmAPIError(code: "sign_in_failed") }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: response.user.accessToken.tokenString)
        update(try await Auth.auth().signIn(with: credential).user)
    }

    func prepareApple(_ request: ASAuthorizationAppleIDRequest, deleting: Bool = false) {
        let nonce = UUID().uuidString + UUID().uuidString
        self.nonce = nonce
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        if !deleting { request.requestedScopes = [.fullName, .email] }
    }

    func completeApple(_ result: Result<ASAuthorization, Error>, deleting: Bool = false) async throws {
        guard isConfigured, let nonce else { throw PalmAPIError(code: "sign_in_failed") }
        self.nonce = nil
        let response = try result.get()
        guard let apple = response.credential as? ASAuthorizationAppleIDCredential,
              let token = apple.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw PalmAPIError(code: "sign_in_failed")
        }
        let credential = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: apple.fullName)
        if deleting {
            guard let user = Auth.auth().currentUser,
                  let code = apple.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw PalmAPIError(code: "sign_in_failed")
            }
            _ = try await user.reauthenticate(with: credential)
            guard Auth.auth().currentUser?.uid == user.uid else { throw PalmAPIError(code: "account_changed") }
            try await Auth.auth().revokeToken(withAuthorizationCode: code)
            try await delete(uid: user.uid)
        } else {
            update(try await Auth.auth().signIn(with: credential).user)
        }
    }

    func signOut() throws {
        guard isConfigured else { return }
        try Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        update(nil)
    }

    func delete(uid: String) async throws {
        let reply: DeletedAccount = try await PalmAPI.request("/v1/account", method: "DELETE", uid: uid)
        guard reply.deleted else { throw PalmAPIError(code: "account_delete_failed") }
        try PalmArchive.erase(uid)
        try signOut()
    }

    private struct DeletedAccount: Decodable { let deleted: Bool }
}

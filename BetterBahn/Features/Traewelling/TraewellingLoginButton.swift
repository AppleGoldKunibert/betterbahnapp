import AuthenticationServices
import BetterBahnKit
import SwiftUI

struct TraewellingLoginButton: View {
    var onSuccess: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isRunning = false
    @State private var error: Error?

    var body: some View {
        VStack(spacing: 10) {
            Button(action: login) {
                Group {
                    if isRunning {
                        ProgressView()
                    } else {
                        Label("Mit Träwelling anmelden", systemImage: "person.badge.key.fill")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.brand)
            .controlSize(.large)
            .disabled(isRunning)

            if let error {
                ErrorBanner(error: error)
            }
        }
    }

    private func login() {
        let config = model.traewelling.config
        guard !config.clientID.isEmpty else {
            error = OAuthError.missingClientID
            return
        }
        guard config.callbackHost != nil, config.callbackPath != nil else {
            error = OAuthError.invalidRedirectURI
            return
        }
        isRunning = true
        let pkce = PKCE()
        Task {
            defer { isRunning = false }
            do {
                let callback = try await webAuthenticationSession.authenticate(
                    using: config.authorizeURL(pkce: pkce),
                    callback: .customScheme(config.callbackScheme),
                    preferredBrowserSession: .ephemeral,
                    additionalHeaderFields: [:]
                )
                try await model.traewelling.completeLogin(callbackURL: callback, pkce: pkce)
                error = nil
                onSuccess()
            } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            } catch {
                self.error = error
            }
        }
    }
}

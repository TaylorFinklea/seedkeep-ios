import SwiftUI
import AuthenticationServices
import SeedkeepKit

/// Entry-point screen. Phase 1 only supports Sign in with Apple.
/// The actual id-token-for-bearer-token exchange goes through
/// `AuthController.adoptBearerToken(_:)`.
struct SignInView: View {
    @Environment(AuthController.self) private var auth
    @Environment(AppEnvironment.self) private var appEnv
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            VellumBackground()

            VStack(spacing: 28) {
                Spacer()

                Image("BrandMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 140, height: 140)

                VStack(spacing: 10) {
                    Text("the herbarium")
                        .font(HerbFont.smallCaps(size: 11))
                        .tracking(3.0)
                        .textCase(.uppercase)
                        .foregroundStyle(HerbColor.sepia)

                    Text("Seedkeep")
                        .font(HerbFont.display(size: 48))
                        .foregroundStyle(HerbColor.ink)

                    Text("Your seed library, pressed between the pages.")
                        .font(HerbFont.bodyItalic(size: 14))
                        .foregroundStyle(HerbColor.inkSoft)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                ScholarRule(verticalMargin: 4)
                    .padding(.horizontal, 48)

                Spacer()

                VStack(spacing: 12) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handle(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .padding(.horizontal)

                    Text("Sign in to begin your library.")
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.inkFaint)
                        .multilineTextAlignment(.center)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.rose)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer().frame(height: 32)
            }
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                errorMessage = "Apple did not return a credential we could use."
                return
            }
            Task {
                await exchangeAppleToken(idToken: idToken, credential: credential)
            }
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }

    /// Hands the Apple identity token to the better-auth social endpoint.
    /// On success we get back a Bearer token that the AuthController
    /// stores and uses for every subsequent request.
    private func exchangeAppleToken(idToken: String, credential: ASAuthorizationAppleIDCredential) async {
        struct Body: Encodable {
            let provider: String
            let idToken: IDTokenPayload
            let user: AppleUser?
        }
        // better-auth's native sign-in expects idToken as an object,
        // not a raw string. Sending a string triggers the OAuth
        // redirect path, which returns {redirect: true, url: ...} and
        // omits the Bearer token from the response body.
        struct IDTokenPayload: Encodable {
            let token: String
        }
        struct AppleUser: Encodable {
            let firstName: String?
            let lastName: String?
            let email: String?
        }
        struct Response: Decodable {
            let token: String?
        }

        let baseURL = await appEnv.client.configuration.baseURL
        var url = baseURL
        url.append(path: "/api/auth/sign-in/social")

        let user: AppleUser? = {
            guard credential.fullName != nil || credential.email != nil else { return nil }
            return AppleUser(
                firstName: credential.fullName?.givenName,
                lastName: credential.fullName?.familyName,
                email: credential.email
            )
        }()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(
            Body(provider: "apple", idToken: IDTokenPayload(token: idToken), user: user)
        )

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            // better-auth's response shape varies slightly across versions.
            // We accept either a top-level `token` or a nested `session.token`.
            let token = extractToken(from: data)
            guard let token else {
                errorMessage = "Sign-in didn't complete. Try again."
                return
            }
            await auth.adoptBearerToken(token)
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func extractToken(from data: Data) -> String? {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dict = any as? [String: Any] else { return nil }
        if let token = dict["token"] as? String { return token }
        if let session = dict["session"] as? [String: Any], let token = session["token"] as? String {
            return token
        }
        if let data = dict["data"] as? [String: Any] {
            if let token = data["token"] as? String { return token }
            if let session = data["session"] as? [String: Any], let token = session["token"] as? String {
                return token
            }
        }
        return nil
    }
}

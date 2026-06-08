import SwiftUI
import SeedkeepKit

/// Sheet that's auto-presented when a `seedkeep://invite/<code>` URL or
/// the `applinks:seedkeep.app` universal link is opened. Calls
/// `POST /api/invites/:code/accept` and refreshes the household state.
struct InviteAcceptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AuthController.self) private var auth

    let code: String

    enum Phase: Equatable {
        case confirming
        case accepting
        case success(HouseholdDTO)
        case failure(String)
    }

    @State private var phase: Phase = .confirming

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                content
                Spacer()
            }
            .padding(.horizontal, 24)
            .navigationTitle("Household invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .accepting ? "" : "Close") { dismiss() }
                        .disabled(phase == .accepting)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .confirming:
            confirmingView
        case .accepting:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).herbProgressStyle()
                Text("Joining household…").foregroundStyle(.secondary)
            }
        case .success(let household):
            successView(household: household)
        case .failure(let message):
            failureView(message: message)
        }
    }

    @ViewBuilder
    private var confirmingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.open")
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundStyle(.tint)
            Text("Join a household")
                .font(.title2.weight(.semibold))
            Text("You've been invited to share a seed library. Joining replaces your current household.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.title3.monospaced())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.secondary.opacity(0.12), in: .capsule)
                .padding(.top, 4)
            Button {
                Task { await accept() }
            } label: {
                Text("Accept invite")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func successView(household: HouseholdDTO) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundStyle(HerbColor.sage)
            Text("Joined \(household.name)")
                .font(.title2.weight(.semibold))
            Text("Pulling shared inventory…")
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func failureView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundStyle(HerbColor.ochre)
            Text("Couldn't join")
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Try again") {
                    phase = .confirming
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    private func accept() async {
        phase = .accepting
        do {
            let res = try await appEnv.client.acceptInvite(code: code)
            phase = .success(res.household)
            // Refresh identity so the rest of the app sees the new household.
            await auth.restoreSession()
            // Pull the shared inventory so the Library reflects it.
            await appEnv.syncIfPossible()
        } catch let err as SeedkeepError {
            phase = .failure(err.message)
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }
}

/// Routes `seedkeep://invite/<code>` and `https://seedkeep.app/invite/<code>`
/// to an invite code, or returns `nil` for anything else.
enum InviteURLRouter {
    static func invitationCode(from url: URL) -> String? {
        // Custom scheme: seedkeep://invite/<code> or seedkeep://invite?code=<code>
        if url.scheme == "seedkeep", url.host == "invite" {
            if let code = url.pathComponents.dropFirst().first, !code.isEmpty {
                return code
            }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "code" })?
                .value
        }
        // Universal link: https://seedkeep.app/invite/<code>
        if url.scheme == "https", url.host == "seedkeep.app",
           url.pathComponents.count >= 3, url.pathComponents[1] == "invite" {
            return url.pathComponents[2]
        }
        return nil
    }
}

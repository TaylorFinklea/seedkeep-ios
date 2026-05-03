import SwiftUI
import SwiftData
import SeedkeepKit

/// Pulls a random `active` seed from the server (linear-by-age policy)
/// and renders it as a big card. The actual weighting lives on the API
/// side — we just call `/api/seeds/random`.
struct RandomPickView: View {
    @Environment(AppEnvironment.self) private var appEnv

    enum LoadState: Equatable {
        case idle
        case loading
        case picked(SeedDTO)
        case empty
        case error(String)
    }

    @State private var state: LoadState = .idle

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                content
                Spacer()
                Button {
                    Task { await pick() }
                } label: {
                    Label(state == .idle ? "Pick a seed" : "Pick another", systemImage: "shuffle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state == .loading)
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Random")
            .task(id: state) {
                if state == .idle {
                    await pick()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
        case .picked(let seed):
            SeedCard(seed: seed)
        case .empty:
            ContentUnavailableView(
                "No active seeds yet",
                systemImage: "leaf",
                description: Text("Add some packets to your library, then come back.")
            )
        case .error(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
    }

    private func pick() async {
        state = .loading
        do {
            if let seed = try await appEnv.client.randomSeed() {
                state = .picked(seed)
            } else {
                state = .empty
            }
        } catch let err as SeedkeepError {
            state = .error("\(err.code): \(err.message)")
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

private struct SeedCard: View {
    let seed: SeedDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(displayName)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.leading)
            if let company = seed.custom_company, !company.isEmpty {
                Text(company)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if seed.packet_count > 0 {
                    Tag(text: "×\(seed.packet_count) packet\(seed.packet_count == 1 ? "" : "s")")
                }
                if let year = seed.year_packed {
                    Tag(text: "packed \(String(year))")
                }
            }
            if let notes = seed.notes, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .padding(.horizontal)
    }

    private var displayName: String {
        if let n = seed.custom_name, !n.isEmpty {
            return n
        }
        return seed.custom_variety ?? "Untitled seed"
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.tint.opacity(0.18), in: .capsule)
            .foregroundStyle(.tint)
    }
}

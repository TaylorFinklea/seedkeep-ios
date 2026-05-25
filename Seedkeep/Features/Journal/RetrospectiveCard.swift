import SwiftUI
import SeedkeepKit

/// Top-of-feed card that surfaces journal entries from the same MM-DD in
/// prior years. Hidden when the user has no prior-year data near today.
///
/// The server filters out the current year, so a first-year gardener sees
/// nothing here until they have history. The card simply hides itself
/// (returns an empty body) when `years` is empty.
struct RetrospectiveCard: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var response: RetrospectiveResponseDTO?
    @State private var didLoad = false

    private static var todayAnchor: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: Date())
    }

    var body: some View {
        Group {
            if let response, !response.years.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.tint)
                        Text("Today in your garden")
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(response.years, id: \.year) { yearBlock in
                        DisclosureGroup {
                            ForEach(yearBlock.entries, id: \.id) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.occurredOn)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(entry.body)
                                        .font(.body)
                                        .lineLimit(3)
                                }
                                .padding(.vertical, 2)
                            }
                        } label: {
                            Text("\(String(yearBlock.year)) · \(yearBlock.entries.count) \(yearBlock.entries.count == 1 ? "entry" : "entries")")
                                .font(.footnote)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
    }

    private func load() async {
        do {
            response = try await appEnv.journal.retrospective(on: Self.todayAnchor)
        } catch {
            response = nil
        }
    }
}

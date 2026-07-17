import SwiftUI
import SwiftData
import SeedkeepKit

/// R1 27d.18 — the one-time review inbox for ambiguous participant journal rows quarantined by
/// `ParticipantRowRecovery`. Mirrors `PendingWritesView`'s list idiom. Presented as a sheet from
/// Settings ▸ the CloudKit section's participant branch.
struct JournalRecoveryReviewView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<LocalJournalRecoveryItem> { $0.status == "pending" },
           sort: \LocalJournalRecoveryItem.detectedAt, order: .forward)
    private var allPending: [LocalJournalRecoveryItem]

    @State private var busyItemID: String?

    private var items: [LocalJournalRecoveryItem] {
        guard let scopeKey = appEnv.participantRecoveryScopeKey else { return [] }
        return allPending.filter { $0.scopeKey == scopeKey }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing to review",
                    systemImage: "checkmark.seal",
                    description: Text("Every recovered journal entry has been reviewed.")
                )
            } else {
                List {
                    ForEach(items) { item in
                        rowView(item)
                    }
                }
            }
        }
        .navigationTitle("Journal items need review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Keep all private") {
                        for item in items { appEnv.keepJournalRecoveryItemPrivate(item) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ item: LocalJournalRecoveryItem) -> some View {
        let snapshot = ParticipantRowRecovery.decodeSnapshot(item.snapshotJSON)
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot?.occurredOn ?? "Unknown date")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HerbColor.ink)
            if let body = snapshot?.body {
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(HerbColor.inkSoft)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Share to garden") {
                    Task {
                        busyItemID = item.id
                        await appEnv.shareJournalRecoveryItem(item)
                        busyItemID = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(busyItemID == item.id)
                Button("Keep private", role: .destructive) {
                    appEnv.keepJournalRecoveryItemPrivate(item)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(busyItemID == item.id)
            }
        }
        .padding(.vertical, 2)
    }
}

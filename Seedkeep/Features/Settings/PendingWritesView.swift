import SwiftUI
import SwiftData
import SeedkeepKit

/// Diagnostics view for the offline write queue. Lists every
/// `LocalPendingWrite` row, surfaces last error + attempt count, and lets
/// the user retry or forget rows that are stuck.
///
/// Only meaningful in dev (when the user is actively offline) and in
/// rare incident cases. Surfaces from Settings → Pending writes.
struct PendingWritesView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Query(sort: \LocalPendingWrite.createdAt, order: .forward)
    private var rows: [LocalPendingWrite]

    @State private var rowPendingForget: LocalPendingWrite?

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing pending",
                    systemImage: "checkmark.seal",
                    description: Text("Every local change has synced.")
                )
            } else {
                List {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .navigationTitle("Pending writes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { try? await appEnv.sync.flushPending() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Retry all")
            }
        }
        .confirmationDialog(
            "Forget this write?",
            isPresented: Binding(
                get: { rowPendingForget != nil },
                set: { if !$0 { rowPendingForget = nil } }
            ),
            titleVisibility: .visible,
            presenting: rowPendingForget
        ) { row in
            Button("Forget", role: .destructive) {
                appEnv.sync.forgetPendingWrite(id: row.id)
                rowPendingForget = nil
            }
            Button("Cancel", role: .cancel) {
                rowPendingForget = nil
            }
        } message: { _ in
            Text("The change won't be sent to the server. It's gone for good.")
        }
    }

    @ViewBuilder
    private func rowView(_ row: LocalPendingWrite) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(row.entityType).\(row.operation)")
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(HerbColor.ink)
                Spacer()
                if row.isDeadLettered {
                    Text("dead-letter")
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HerbColor.rose.opacity(0.18), in: .capsule)
                        .foregroundStyle(HerbColor.rose)
                } else if row.attemptCount > 0 {
                    Text("retry × \(row.attemptCount)")
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HerbColor.ochre.opacity(0.18), in: .capsule)
                        .foregroundStyle(HerbColor.ochre)
                }
            }
            Text(row.entityID)
                .font(.caption.monospaced())
                .foregroundStyle(HerbColor.inkSoft)
                .lineLimit(1)
                .truncationMode(.middle)
            if let err = row.lastError {
                Text(err)
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.rose)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if row.isDeadLettered {
                    Button("Retry") {
                        appEnv.sync.retryPendingWrite(id: row.id)
                        Task { try? await appEnv.sync.flushPending() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Button("Forget", role: .destructive) {
                    rowPendingForget = row
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }
}

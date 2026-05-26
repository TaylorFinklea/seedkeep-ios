import SwiftUI
import SeedkeepKit

/// Phase 4 D — let the user flag a correction on a catalog entry's
/// growing-info section. Submits to /api/catalog/:id/feedback. The
/// server queues the report for out-of-band review; no in-app
/// moderation UI for the queue yet.
struct CatalogFeedbackSheet: View {
    let catalogID: String
    let catalogName: String?

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    @State private var feedbackText: String = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    var canSubmit: Bool {
        !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitting
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Suggest a correction")
                                .font(HerbFont.display(size: 28))
                                .foregroundStyle(HerbColor.ink)
                            if let name = catalogName {
                                Text("for \(name)")
                                    .font(HerbFont.bodyItalic(size: 13))
                                    .foregroundStyle(HerbColor.inkSoft)
                            }
                            Text("Your note goes to the catalog reviewers. They'll fold accurate fixes back into the shared growing info so other households see them too.")
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.inkSoft)
                                .padding(.top, 6)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        TextField(
                            "e.g. \"Days to maturity is 75–85, not 60. Confirmed at my farm last year.\"",
                            text: $feedbackText,
                            axis: .vertical
                        )
                        .font(HerbFont.body(size: 14))
                        .lineLimit(5...12)
                    } header: {
                        Rubric(text: "what should be fixed")
                    }

                    if didSubmit {
                        Section {
                            HStack(spacing: 8) {
                                Text("✓")
                                    .foregroundStyle(HerbColor.verdictNow)
                                Text("Thanks — your note was filed.")
                                    .font(HerbFont.bodyItalic(size: 13))
                                    .foregroundStyle(HerbColor.ink)
                            }
                        }
                    } else if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(HerbFont.bodyItalic(size: 12))
                                .foregroundStyle(HerbColor.rose)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !didSubmit {
                        Button("Submit") { Task { await submit() } }
                            .disabled(!canSubmit)
                    }
                }
            }
        }
    }

    private func submit() async {
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        do {
            _ = try await appEnv.client.submitCatalogFeedback(
                catalogID: catalogID,
                body: feedbackText.trimmingCharacters(in: .whitespacesAndNewlines))
            didSubmit = true
        } catch let err as SeedkeepError {
            errorMessage = "\(err.code): \(err.message)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

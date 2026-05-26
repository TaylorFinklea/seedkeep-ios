import SwiftUI
import SeedkeepKit

/// Identity tab — restyled as "House". Who I am, who is my household,
/// sign out. Locations, tags, and household-invite flow live in Settings.
struct YouView: View {
    @Environment(AuthController.self) private var auth

    var body: some View {
        NavigationStack {
            ZStack {
                VellumBackground()
                Form {
                    Section {
                        heading
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                    if case .signedIn(let user, let household) = auth.state {
                        Section {
                            LabeledContent("Email") { Text(user.email ?? "—").font(HerbFont.bodyItalic(size: 12)) }
                            LabeledContent("Name") { Text(user.name ?? "—").font(HerbFont.bodyItalic(size: 12)) }
                        } header: {
                            Rubric(text: "steward", number: 1)
                        }
                        Section {
                            LabeledContent("Name") { Text(household.name).font(HerbFont.bodyItalic(size: 12)) }
                        } header: {
                            Rubric(text: "house", number: 2)
                        }
                    }
                    Section {
                        Button("Sign out", role: .destructive) {
                            Task { await auth.signOut() }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            FolioStrip(section: "House", folio: 1)
                .padding(.horizontal, -16)
            Text("House")
                .font(HerbFont.display(size: 38))
                .foregroundStyle(HerbColor.ink)
            Text(subtitle)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
            ScholarRule(verticalMargin: 8)
        }
    }

    private var subtitle: String {
        if case .signedIn(let user, let household) = auth.state {
            let stewardName = user.name?.split(separator: " ").first.map(String.init) ?? "Steward"
            return "House of \(household.name) · \(stewardName) is at the table"
        }
        return "House awaiting steward"
    }
}

import SwiftUI

/// The "What's New" sheet: opens on `initialRelease`; a History toolbar button
/// pushes the full release list. Styled with Herbarium tokens (light-mode only).
struct WhatsNewSheet: View {
    let initialRelease: ChangelogRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReleaseDetailView(release: initialRelease)
                .navigationTitle("What's New")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            ChangelogHistoryView()
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
        }
    }
}

/// One release rendered: header (version · date · headline) then its changes
/// grouped by category in New → Improved → Fixed order.
struct ReleaseDetailView: View {
    let release: ChangelogRelease

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                ForEach(ChangelogCategory.allCases, id: \.self) { category in
                    let items = release.changes.filter { $0.category == category }
                    if !items.isEmpty {
                        categorySection(category, items)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VellumBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(release.version) (\(release.build))")
                .font(HerbFont.display(size: 30))
                .foregroundStyle(HerbColor.ink)
            if let date = release.date {
                Text(date)
                    .font(HerbFont.smallCaps(size: 10))
                    .tracking(1.5)
                    .foregroundStyle(HerbColor.inkFaint)
            }
            if let headline = release.headline {
                Text(headline)
                    .font(HerbFont.bodyItalic(size: 14))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            ScholarRule(verticalMargin: 8)
        }
    }

    private func categorySection(_ category: ChangelogCategory, _ items: [ChangelogChange]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: category.symbolName)
                Text(category.title.uppercased())
                    .font(HerbFont.smallCaps(size: 11))
                    .tracking(2.0)
            }
            .foregroundStyle(category.tint)

            ForEach(Array(items.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(category.tint)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(change.text)
                        .font(HerbFont.body(size: 15))
                        .foregroundStyle(HerbColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Scrollable list of every release, newest-first; each row pushes its detail.
struct ChangelogHistoryView: View {
    var body: some View {
        List(ChangelogData.releases) { release in
            NavigationLink {
                ReleaseDetailView(release: release)
                    .navigationTitle("What's New")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.version) (\(release.build))")
                        .font(HerbFont.bodyEmph(size: 15))
                        .foregroundStyle(HerbColor.ink)
                    if let date = release.date {
                        Text(date)
                            .font(HerbFont.bodyItalic(size: 12))
                            .foregroundStyle(HerbColor.inkSoft)
                    }
                }
            }
        }
        .navigationTitle("Version History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

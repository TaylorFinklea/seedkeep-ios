import SwiftUI

/// The "What's New" sheet: opens on `initialRelease`; a History toolbar button
/// pushes the full release list. Styled with Workbench tokens.
struct WhatsNewSheet: View {
    let initialRelease: ChangelogRelease
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReleaseDetailView(release: initialRelease)
                .navigationTitle("What's New")
                .accessibilityIdentifier("screen.whatsNew")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
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
                        .accessibilityLabel("Version history")
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
        .background(WBScreenBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(release.version) (\(release.build))")
                .font(.wbLargeTitle)
                .foregroundStyle(WBColor.ink)
                .accessibilityAddTraits(.isHeader)
            if let date = release.date {
                Text(date)
                    .font(.wbCaption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(WBColor.muted)
            }
            if let headline = release.headline {
                Text(headline)
                    .font(.wbBody)
                    .foregroundStyle(WBColor.muted)
            }
            Rectangle().fill(WBColor.line).frame(height: 1).padding(.vertical, 8)
        }
    }

    private func categorySection(_ category: ChangelogCategory, _ items: [ChangelogChange]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // The category colour marks the icon only; the title is text, so it stays `ink`.
                Image(systemName: category.symbolName)
                    .foregroundStyle(category.tint)
                WBSectionHeader(category.title)
            }

            ForEach(Array(items.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(category.tint)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(change.text)
                        .font(.wbBody)
                        .foregroundStyle(WBColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Colour for each change category in this sheet. It replaces the Herbarium tints that
/// `ChangelogCategory` used to carry in Core.
private extension ChangelogCategory {
    var tint: Color {
        switch self {
        case .new:      WBColor.accent
        case .improved: WBColor.verdict("plant_soon")
        case .fixed:    WBColor.warn
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
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(release.version) (\(release.build))")
                        .font(.wbCallout.weight(.semibold))
                        .foregroundStyle(WBColor.ink)
                    if let date = release.date {
                        Text(date)
                            .font(.wbFootnote)
                            .foregroundStyle(WBColor.muted)
                    }
                }
            }
        }
        .wbForm()
        .navigationTitle("Version History")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

import SwiftUI

struct SeasonalCareTemplatePicker: View {
    let templates: [SeasonalCareTemplate]
    let onAdd: (SeasonalCareTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No reviewed templates",
                        systemImage: "leaf",
                        description: Text("Add a manual care task instead. Seedkeep does not guess crop timing.")
                    )
                } else {
                    List(templates) { template in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(template.title)
                                    .font(.headline)
                                Spacer()
                                Button("Add") {
                                    onAdd(template)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel("Add \(template.title)")
                            }
                            Text(template.instructions)
                                .font(.subheadline)
                                .foregroundStyle(HerbColor.inkSoft)
                            Text(windowLabel(template))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(HerbColor.sepia)
                            Text(template.applicabilityLabel ?? regionLabel(template))
                                .font(.footnote)
                                .foregroundStyle(HerbColor.inkSoft)
                            Link("Source: \(template.authorityName)", destination: template.sourceURL)
                                .font(.footnote)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(template.title), \(windowLabel(template)), \(template.authorityName)")
                    }
                }
            }
            .navigationTitle("Care templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func windowLabel(_ template: SeasonalCareTemplate) -> String {
        "Annual window: \(monthDay(template.startMonth, template.startDay))–\(monthDay(template.endMonth, template.endDay))"
    }

    private func monthDay(_ month: Int, _ day: Int) -> String {
        let names = Calendar.current.monthSymbols
        let monthName = names.indices.contains(month - 1) ? names[month - 1] : "Month \(month)"
        return "\(monthName) \(day)"
    }

    private func regionLabel(_ template: SeasonalCareTemplate) -> String {
        let regions = template.regionCodes.joined(separator: ", ")
        return regions == "all" ? "Broad authoritative guidance" : "Applies to \(regions); confirm local conditions."
    }
}

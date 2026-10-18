import SwiftUI

struct WorkbenchSidebar: View {
    @Bindable var model: WorkbenchModel
    let seedCount: Int

    var body: some View {
        List(selection: Binding(
            get: { Optional(model.route) },
            set: { if let route = $0 { model.route = route } }
        )) {
            ForEach(WorkbenchRoute.allCases) { route in
                NavigationLink(value: route) {
                    Label {
                        HStack {
                            Text(route.title)
                            Spacer()
                            if route == .seeds {
                                Text("\(seedCount)")
                                    .font(.wbMonoCaption)
                                    .foregroundStyle(WBColor.muted)
                                    .accessibilityLabel("\(seedCount) seeds")
                            }
                        }
                        .font(.wbBody)
                        .foregroundStyle(WBColor.ink)
                    } icon: {
                        Image(systemName: route.symbol).foregroundStyle(WBColor.accent)
                    }
                    .padding(.vertical, 4)
                    .frame(minHeight: WBMetrics.touchTarget)
                }
                .tag(route)
            }
        }
        .scrollContentBackground(.hidden)
        .background(WBColor.panel)
        .navigationTitle("Seedkeep")
        .accessibilityLabel("Workbench navigation")
    }
}

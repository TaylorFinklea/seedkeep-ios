import SwiftUI

struct WorkbenchSidebar: View {
    @Bindable var model: WorkbenchModel
    let seedCount: Int

    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsShortcutHints = false
    #endif

    var body: some View {
        List(selection: Binding(
            get: { Optional(model.route) },
            set: { if let route = $0 { model.route = route } }
        )) {
            ForEach(WorkbenchNavigation.routes(isMac: WorkbenchNavigation.isMacPlatform)) { route in
                NavigationLink(value: route) {
                    Label {
                        HStack {
                            Text(route.title)
                            Spacer()
                            if route == .seeds {
                                Text("\(seedCount)")
                                    .font(.wbMonoCaption)
                                    .accessibilityLabel("\(seedCount) seeds")
                            }
                            #if os(macOS)
                            if showsShortcutHints, let key = WorkbenchGoShortcut.key(for: route) {
                                Text(String(key))
                                    .font(.wbMonoCaption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                    .accessibilityHidden(true)
                            }
                            #endif
                        }
                        .font(.wbBody)
                    } icon: {
                        Image(systemName: route.symbol)
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
        #if os(macOS)
        .onModifierKeysChanged(mask: .command) { _, modifiers in
            showsShortcutHints = appearsActive && scenePhase == .active && modifiers.contains(.command)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                showsShortcutHints = false
            }
        }
        .onChange(of: appearsActive) { _, isActive in
            if !isActive {
                showsShortcutHints = false
            }
        }
        .onDisappear {
            showsShortcutHints = false
        }
        #endif
    }
}

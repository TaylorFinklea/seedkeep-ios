import SwiftUI

/// View modifier that publishes the current page's context to the
/// AIAssistantCoordinator on appear (and clears on disappear). The
/// TopBarSparkleButton reads from this to pre-attach context when launching
/// a new thread, so the user doesn't have to re-state where they were.
///
/// Usage on a SeedDetailView:
///   .publishesAssistantContext(pageType: "seed", entityID: seed.id, label: seed.customName)
struct PageContextPublisher: ViewModifier {
    @Environment(AppEnvironment.self) private var appEnv
    let context: AIAssistantCoordinator.AIPageContext

    func body(content: Content) -> some View {
        content
            .onAppear {
                appEnv.assistant.setPageContext(context)
            }
            .onDisappear {
                // Clear if we still own the context. Avoids races when a child
                // view publishes its own context and then the parent
                // re-publishes on its return.
                if appEnv.assistant.pageContext == context {
                    appEnv.assistant.clearPageContext()
                }
            }
    }
}

extension View {
    /// Publishes the current page's context to Sprout. Call on appear of any
    /// view that has a meaningful "entity in focus" (a specific seed, bed,
    /// planting event, journal entry, etc.).
    func publishesAssistantContext(
        pageType: String,
        entityID: String? = nil,
        label: String? = nil
    ) -> some View {
        modifier(PageContextPublisher(
            context: AIAssistantCoordinator.AIPageContext(
                pageType: pageType, entityID: entityID, label: label)
        ))
    }
}

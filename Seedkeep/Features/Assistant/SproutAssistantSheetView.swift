import SwiftUI
import SwiftData

/// Popup-sheet host for Sprout. Mounted by `SproutAssistantOverlay` at the
/// root and presented when `AIAssistantCoordinator.isSheetPresented` flips
/// true (triggered by the bottom-right `SproutFAB`).
///
/// The user's current page context is already attached to the thread (the
/// FAB sets it via `presentSheet`). The sheet shows the live conversation
/// with the standard composer + tool-call cards.
///
/// Pattern mirrors SimmerSmith's `AIAssistantSheetView` — three detents,
/// drag indicator, background interaction enabled at the small detent so
/// the user can keep tapping around their app while Sprout is open.
struct SproutAssistantSheetView: View {
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        NavigationStack {
            Group {
                if let threadID = appEnv.assistant.currentThreadID {
                    AssistantThreadView(threadID: threadID)
                } else {
                    ContentUnavailableView(
                        "Sprout's offline",
                        systemImage: "sparkles",
                        description: Text("Couldn't open a conversation. Try again from the Sprout tab.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { appEnv.assistant.dismissSheet() }
                }
            }
        }
        .presentationDetents([.fraction(1.0 / 3.0), .medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(1.0 / 3.0)))
        .presentationDragIndicator(.visible)
    }
}

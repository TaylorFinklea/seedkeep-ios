# Phase 4 (Sprout) — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the iOS client side of Sprout — Seedkeep's BYOK AI assistant. New top-level Assistant tab, multi-thread chat, server-side streaming via SSE, inline tool-call cards with proposed-change confirmations, global TopBarSparkleButton + page-context coordinator, BYOK key Settings.

**Architecture:** Four new SwiftData models mirror the server tables. `AIAssistantCoordinator` (@MainActor @Observable) owns the live conversation state, the page-context bus, and the streaming state machine. SeedkeepKit gains a `streamAssistantResponse` method that uses `URLSession.AsyncBytes` to parse SSE. UI is modeled on SimmerSmith's pattern (`~/git/simmersmith/SimmerSmith/SimmerSmith/Features/Assistant/`) — read those files; don't reinvent.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, URLSession.AsyncBytes. XcodeGen (`project.yml`).

**Spec:** `~/git/seedkeep/.docs/ai/specs/2026-05-25-phase-4-sprout-assistant-design.md`.

**Build phases covered:** spec phases 5-8 (iOS data layer, Assistant tab + thread list, compose + streaming + tool-call cards, sparkle button + page context + key settings).

**Prerequisite**: server side (`seedkeep-server/.docs/ai/plans/2026-05-25-phase-4-sprout-server.md`) deployed to Fly v16 — migration 0012 applied, all assistant routes live. Tasks 1-9 can be built against a local dev server with `ASSISTANT_ANTHROPIC_MOCK=1`; Task 10 (TestFlight + device verify) needs prod.

---

## Pattern references (read these before writing code)

The lesson from the Phase 3 plans: do **not** prescribe code blocks for codebase-derived patterns; read the existing reference and mirror it.

| Need | Reference file | What to mirror |
|---|---|---|
| Reference assistant impl | `~/git/simmersmith/SimmerSmith/SimmerSmith/Features/Assistant/AssistantView.swift` (542 lines) | Thread list, NavigationStack structure, message rendering, compose box, empty-state starter prompts, streaming typewriter rendering. |
| Tool-call card UI | `~/git/simmersmith/SimmerSmith/SimmerSmith/Features/Assistant/AssistantToolCallCard.swift` (268 lines) | Status pill, expand-for-details, ProposedChangeCard variant with Confirm/Cancel buttons. |
| Sparkle button | `~/git/simmersmith/SimmerSmith/SimmerSmith/DesignSystem/Components/TopBarSparkleButton.swift` | TopBar toolbar item, reads from a shared coordinator's `pageContext`, taps create a new thread + open the assistant tab. |
| Page-context bus | `~/git/simmersmith/SimmerSmith/SimmerSmith/App/AppState+Assistant.swift` (464 lines) | Coordinator pattern, `AssistantLaunchContext`, thread management, `consumeAssistantLaunchContext`. |
| Stream client | `~/git/simmersmith/SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift` `streamAssistantResponse` | URLSession.AsyncBytes-based SSE parser; AsyncThrowingStream wrapper. |
| SwiftData model pattern (Seedkeep) | `Seedkeep/Core/Models/LocalJournalEntry.swift` (Phase 3) | `@Model final class`, `@Attribute(.unique) var id`, init param matches field list. |
| DTO/mapping pattern | `Seedkeep/Core/Models/Mapping.swift` Journal extensions (Phase 3) | `makeLocal()` + `apply(to:)` extension methods on each DTO. |
| Sync engine extension | `Seedkeep/Core/Sync/SyncEngine.swift` `pullJournalEntries` + `upsertJournalEntries` | Per-resource `pull<X>` paginated drain; `upsert<X>` with soft-delete-aware hard-delete; cascade-clean children where applicable. |
| SeedkeepClient style | `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift` Journal methods (Phase 3) | All methods inside the actor body, private `request`/`postJSON`/`patchJSON` helpers, `DeltaPage<T>` typealiases for delta-sync feeds. |
| Settings view pattern | `Seedkeep/Features/Settings/HomeLocationSettingsView.swift` (Phase 2) | Single-purpose Form, configured/not-configured branching, async work + error display. |

**Conventions** (verified against the codebase — follow exactly):
- `SeedkeepKit` is a pure Swift package; DTOs in `Models/`, `SeedkeepClient` is a `public actor`. Tests are Swift Testing.
- SwiftData `@Model` types live in `Seedkeep/Core/Models/`, registered in `AppEnvironment.makeModelContainer()`.
- `AppEnvironment` (`@MainActor @Observable`) owns stores; views access via `@Environment(AppEnvironment.self)`.
- App build: `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build -quiet`. `xcodegen generate` first when `project.yml` changes.
- Release: `scripts/release.sh --minor` for version bump; `--build` for build-only.

**Plan-level decisions (refinements of the spec):**
- **The API key itself never lives in iOS storage.** Only a "is the key configured server-side" flag in `LocalAssistantKeyStatus`. The Settings field is write-only — never reads the key back.
- **Streaming is single-device.** When user A initiates a stream on phone, the messages persist to the server; phone B sees them after the next delta-sync but won't get the SSE in real time. Acceptable for v1.
- **Tool-call cards render inline within the assistant message they belong to.** Each `LocalAssistantToolCall` has a `messageID` FK; render in the message's content view at the location indicated by the assistant message's `content_json` blocks.

---

## File Structure

**Create:**
- `SeedkeepKit/Sources/SeedkeepKit/Models/Assistant.swift` — DTOs.
- `SeedkeepKit/Tests/SeedkeepKitTests/AssistantDecodeTests.swift`
- `Seedkeep/Core/Models/LocalAssistantThread.swift`
- `Seedkeep/Core/Models/LocalAssistantMessage.swift`
- `Seedkeep/Core/Models/LocalAssistantToolCall.swift`
- `Seedkeep/Core/Models/LocalAssistantKeyStatus.swift`
- `Seedkeep/Core/Assistant/AIAssistantCoordinator.swift`
- `Seedkeep/Core/Assistant/PageContextPublisher.swift` — view modifier.
- `Seedkeep/Features/Assistant/AssistantView.swift` — top-level tab body.
- `Seedkeep/Features/Assistant/AssistantThreadView.swift` — thread detail.
- `Seedkeep/Features/Assistant/AssistantToolCallCard.swift`
- `Seedkeep/Features/Assistant/ProposedChangeCard.swift`
- `Seedkeep/Features/Assistant/MessageBubble.swift` — single message rendering.
- `Seedkeep/DesignSystem/Components/TopBarSparkleButton.swift`
- `Seedkeep/Features/Settings/AssistantKeySettingsView.swift`

**Modify:**
- `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift` — add assistant client methods incl. streaming.
- `Seedkeep/App/AppEnvironment.swift` — register 4 new `@Model`s; construct `AIAssistantCoordinator`.
- `Seedkeep/Core/Models/Mapping.swift` — 4 new mapping extensions.
- `Seedkeep/Core/Sync/SyncEngine.swift` — drain 3 new entity types.
- `Seedkeep/Features/MainTabView.swift` — add Assistant tab (becomes 7 tabs).
- `Seedkeep/Features/Settings/SettingsView.swift` — add "AI Assistant" row → AssistantKeySettingsView.
- Primary page toolbars (`LibraryView`, `GardenView`, `JournalView`, etc.) — add `TopBarSparkleButton` to each. **This is the most cross-cutting modification** — about 6-8 view files.
- `project.yml` — no new entitlements needed (no network entitlements required for HTTPS).

---

## Task 1: SeedkeepKit — Assistant DTOs + key/thread client methods

**Goal**: Wire up the non-streaming routes first (key management, thread CRUD). Streaming comes in Task 2.

**Files:**
- Create: `SeedkeepKit/Sources/SeedkeepKit/Models/Assistant.swift`
- Modify: `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift`
- Create: `SeedkeepKit/Tests/SeedkeepKitTests/AssistantDecodeTests.swift`

- [ ] **Step 1: Read the Phase 3 reference**

```bash
cat SeedkeepKit/Sources/SeedkeepKit/Models/JournalEntry.swift
```

Match the same style: camelCase property names, `Codable, Sendable, Equatable` structs, `CodingKeys` only when wire format differs (e.g. `has_more`).

- [ ] **Step 2: Define the DTOs**

`SeedkeepKit/Sources/SeedkeepKit/Models/Assistant.swift`:

```swift
import Foundation

public struct AssistantThreadDTO: Codable, Sendable, Equatable {
    public let id: String
    public let householdId: String
    public let title: String
    public let threadKind: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let deletedAt: Int64?
}

/// Anthropic-style content block. The server stores assistant_messages.content_json
/// as the raw Anthropic content array; we decode it as a `[ContentBlock]`.
public enum AssistantContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: AnyCodable])
    case toolResult(toolUseId: String, content: String, isError: Bool?)

    // CodingKeys + custom init/encode to match Anthropic's tagged-union shape:
    //   {"type": "text", "text": "..."}
    //   {"type": "tool_use", "id": "...", "name": "...", "input": {...}}
    //   {"type": "tool_result", "tool_use_id": "...", "content": "...", "is_error": false}
}

public struct AssistantMessageDTO: Codable, Sendable, Equatable {
    public let id: String
    public let threadId: String
    public let role: String                  // 'user' | 'assistant' | 'tool' | 'system'
    public let contentJson: String           // raw JSON string from server
    public let pageContext: String?          // JSON string
    public let model: String?
    public let usageJson: String?
    public let createdAt: Int64

    /// Decoded content blocks (lazy, computed property — not in the wire format).
    public func contentBlocks() throws -> [AssistantContentBlock]
}

public struct AssistantToolCallDTO: Codable, Sendable, Equatable {
    public let id: String
    public let messageId: String
    public let threadId: String
    public let toolName: String
    public let argsJson: String
    public let status: String                // 'proposed' | 'running' | 'done' | 'failed' | 'cancelled'
    public let resultJson: String?
    public let proposedChangeJson: String?
    public let confirmedAt: Int64?
    public let createdAt: Int64
    public let updatedAt: Int64
}

public struct AssistantThreadDetailDTO: Codable, Sendable, Equatable {
    public let thread: AssistantThreadDTO
    public let messages: [AssistantMessageDTO]
    public let toolCalls: [AssistantToolCallDTO]
}

public struct AssistantKeyStatusDTO: Codable, Sendable, Equatable {
    public let providers: [AssistantKeyProviderStatus]
}

public struct AssistantKeyProviderStatus: Codable, Sendable, Equatable {
    public let provider: String              // 'anthropic'
    public let configured: Bool
    public let updatedAt: Int64?
}

/// Thread feed uses the existing DeltaPage envelope.
public typealias AssistantThreadFeedDTO = DeltaPage<AssistantThreadDTO>

/// Helper for JSON-passthrough payloads.
public struct AnyCodable: Codable, Sendable, Equatable {
    public let value: Any
    // implementation: decode/encode arbitrary JSON; mark Equatable via NSObject comparison or
    // by re-encoding to data and byte-comparing.
}
```

**Note on `AnyCodable`**: this is a common pattern. If SeedkeepKit already has one (grep `class AnyCodable\|struct AnyCodable` first), reuse it. If not, write a minimal one — it just needs to handle dicts/arrays/strings/numbers/bools/null. The decoded `input` for tool_use blocks is conceptually a JSON object the LLM produced; we don't validate it client-side (server validates).

- [ ] **Step 3: Add client methods**

In `SeedkeepClient`, add methods inside the actor body (matching the Phase 3 Journal section's pattern — `MARK: - Assistant (Phase 4)`):

```swift
// Thread CRUD
public func assistantThreads(since: Int64 = 0, limit: Int? = nil) async throws -> AssistantThreadFeedDTO
public func createAssistantThread(title: String = "", threadKind: String = "chat") async throws -> AssistantThreadDTO
public func assistantThread(id: String) async throws -> AssistantThreadDetailDTO
public func deleteAssistantThread(_ id: String) async throws
public func updateAssistantThread(_ id: String, title: String) async throws -> AssistantThreadDTO

// Key management
public func setAssistantKey(provider: String, key: String) async throws -> AssistantKeyProviderStatus
public func deleteAssistantKey(provider: String) async throws
public func assistantKeyStatus() async throws -> AssistantKeyStatusDTO

// Tool-call confirmation (the cancel route; confirm opens a stream so it lives in Task 2)
public func cancelAssistantToolCall(_ id: String) async throws -> AssistantToolCallDTO
```

Reuse the existing private `getJSON`/`postJSON`/`patchJSON`/`deleteJSON`/`perform` helpers from the actor.

- [ ] **Step 4: Write decode tests**

`SeedkeepKit/Tests/SeedkeepKitTests/AssistantDecodeTests.swift` — Swift Testing style, mirroring `JournalDecodeTests.swift`. Cover:

- Round-trip an `AssistantThreadDTO`.
- Round-trip a thread detail with messages + tool calls.
- Decode a content_json containing all three block types (text, tool_use, tool_result) — verify the typed `AssistantContentBlock` enum cases.
- Decode a feed envelope (`DeltaPage`) — verify items/cursor/has_more.
- Decode a key-status response with providers array.

- [ ] **Step 5: Run tests + build**

```bash
cd /Users/tfinklea/git/seedkeep-ios/.worktrees/phase-4-sprout-ios/SeedkeepKit
swift test 2>&1 | tail -5
```
Expected: 18 baseline + 5 new = 23 passing.

```bash
cd /Users/tfinklea/git/seedkeep-ios/.worktrees/phase-4-sprout-ios
xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add SeedkeepKit/
git commit -m "SeedkeepKit: add Assistant DTOs + thread/key client methods"
```

---

## Task 2: SeedkeepKit — SSE streaming method

**Goal**: Add `streamAssistantResponse` that parses SSE events from the server and yields typed events via `AsyncThrowingStream`.

**Files:**
- Modify: `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift`
- Modify: `SeedkeepKit/Sources/SeedkeepKit/Models/Assistant.swift` — add `AssistantStreamEvent`.
- Create: `SeedkeepKit/Tests/SeedkeepKitTests/AssistantStreamParserTests.swift`

- [ ] **Step 1: Read the SimmerSmith stream parser**

```bash
grep -B 2 -A 60 "streamAssistantResponse\|URLSession.AsyncBytes\|data:" ~/git/simmersmith/SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift | head -120
```

Understand the parser shape. Mirror it.

- [ ] **Step 2: Define `AssistantStreamEvent`**

Add to `Models/Assistant.swift`:

```swift
public enum AssistantStreamEvent: Sendable, Equatable {
    case textDelta(messageId: String, delta: String)
    case toolUseStart(toolCallId: String, messageId: String, toolName: String)
    case toolUseDone(toolCallId: String, argsJson: String)
    case toolResult(toolCallId: String, status: String, resultJson: String?)
    case proposedChange(toolCallId: String, proposedChangeJson: String)
    case done(messageId: String)
    case streamError(code: String, message: String)
}
```

These match the SSE event types from the server spec (§ Streaming protocol).

- [ ] **Step 3: Add the streaming method**

```swift
/// Stream Sprout's response to a user message. Yields parsed events as they
/// arrive from the server's SSE endpoint.
///
/// Page context can be passed to attach the user's current view to the
/// first message metadata (server stores it on the user message row).
public func streamAssistantResponse(
    threadId: String,
    text: String,
    pageContext: AssistantPageContextPayload? = nil
) -> AsyncThrowingStream<AssistantStreamEvent, Error>

/// Same shape as the send-message stream but resumes after a confirmed
/// proposed change. Server runs the deferred tool execution and continues
/// the LLM conversation.
public func confirmAssistantToolCall(
    _ id: String
) -> AsyncThrowingStream<AssistantStreamEvent, Error>
```

Implementation pattern (mirror SimmerSmith):
1. Build the `URLRequest` with bearer token + JSON body.
2. Use `URLSession.shared.bytes(for: request)` → returns `(URLSession.AsyncBytes, URLResponse)`.
3. Iterate `.lines` on the AsyncBytes; group consecutive lines until a blank line — that's one SSE event.
4. Each event's `data:` line is JSON `{ "type": "text_delta", ... }`. Decode based on type → yield the matching `AssistantStreamEvent` case.
5. Handle `URLError.cancelled` → close the stream cleanly; other errors → throw.
6. Wrap in `AsyncThrowingStream` so callers can `for try await event in stream`.

**Verify against Anthropic's SSE format**: the line termination is `\n\n` (two newlines between events). Lines starting with `:` are comments to be ignored. SimmerSmith's parser handles both — mirror exactly.

- [ ] **Step 4: Write parser tests**

`AssistantStreamParserTests.swift`. Cover:

- Single event: `data: {"type":"text_delta","message_id":"m1","delta":"hello"}\n\n` → yields `.textDelta(...)`.
- Multiple events concatenated → yields each in order.
- Event split across two buffer reads (simulate by chunking the input bytes) → buffers correctly.
- Comment line ignored.
- Malformed JSON in a data line → throws decode error, stream closes.
- `done` event → final event before stream closes.
- `proposed_change` → yields `.proposedChange(...)`, stream closes after this without explicit `done`.

For the test, you'll need to mock `URLSession.AsyncBytes`. The cleanest way: extract the SSE-line-to-event parser as a separate pure function that takes an `AsyncSequence<String>` and yields events. Test the parser in isolation; integration with URLSession is exercised in Task 10 smoke.

- [ ] **Step 5: Run tests + build**

```bash
cd SeedkeepKit && swift test 2>&1 | tail -3
```
Passing.

```bash
cd .. && xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -5
```
BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add SeedkeepKit/
git commit -m "SeedkeepKit: add SSE streaming for assistant responses"
```

---

## Task 3: SwiftData models + mapping

**Goal**: 4 new `@Model` types (the 13th–16th) + DTO↔Model mapping + Schema registration.

**Files:**
- Create: `Seedkeep/Core/Models/LocalAssistantThread.swift`
- Create: `Seedkeep/Core/Models/LocalAssistantMessage.swift`
- Create: `Seedkeep/Core/Models/LocalAssistantToolCall.swift`
- Create: `Seedkeep/Core/Models/LocalAssistantKeyStatus.swift`
- Modify: `Seedkeep/Core/Models/Mapping.swift`
- Modify: `Seedkeep/App/AppEnvironment.swift`

- [ ] **Step 1: Read the Phase 3 pattern**

```bash
cat Seedkeep/Core/Models/LocalJournalEntry.swift
cat Seedkeep/Core/Models/LocalJournalEntryPhoto.swift
```

Match the style: `@Model final class`, `@Attribute(.unique) var id`, init param-per-line.

- [ ] **Step 2: Write `LocalAssistantThread`**

Fields: `id, householdID, title, threadKind, createdAt, updatedAt, deletedAt`. Match the DTO field list from Task 1.

- [ ] **Step 3: Write `LocalAssistantMessage`**

Fields: `id, threadID, role, contentJSON, pageContext, model, usageJSON, createdAt`. Computed property `contentBlocks() throws -> [AssistantContentBlock]` that decodes contentJSON.

- [ ] **Step 4: Write `LocalAssistantToolCall`**

Fields: `id, messageID, threadID, toolName, argsJSON, status, resultJSON, proposedChangeJSON, confirmedAt, createdAt, updatedAt`. Computed property `requiresConfirmation: Bool { status == "proposed" }`.

- [ ] **Step 5: Write `LocalAssistantKeyStatus`**

Fields: `id, provider, configured, updatedAt`. Note: `id` is per-household-per-provider constant (e.g. `"household_<id>_anthropic"`). Stores nothing sensitive.

- [ ] **Step 6: Add mapping extensions to `Mapping.swift`**

For each of `AssistantThreadDTO`, `AssistantMessageDTO`, `AssistantToolCallDTO`, `AssistantKeyProviderStatus`: add `makeLocal()` + `apply(to:)` extensions. Match the Phase 3 Journal pattern at the bottom of the file.

- [ ] **Step 7: Register in `AppEnvironment` schema**

Add to the Schema array:

```swift
LocalAssistantThread.self,
LocalAssistantMessage.self,
LocalAssistantToolCall.self,
LocalAssistantKeyStatus.self,
```

Now 16 models total (was 12 after Phase 3).

- [ ] **Step 8: Build + test**

```bash
xcodegen generate >/dev/null
xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -5
cd SeedkeepKit && swift test 2>&1 | tail -3
```
Both green.

- [ ] **Step 9: Commit**

```bash
git add Seedkeep/Core/Models/ Seedkeep/App/AppEnvironment.swift
git commit -m "Add LocalAssistantThread/Message/ToolCall/KeyStatus SwiftData models + mapping"
```

---

## Task 4: Sync engine extension

**Goal**: Drain threads + messages + tool calls through the existing delta-sync flow. Hard-delete local on server soft-delete.

**Files:**
- Modify: `Seedkeep/Core/Sync/SyncEngine.swift`

- [ ] **Step 1: Read the Phase 3 reference**

```bash
grep -A 15 "pullJournalEntries\|upsertJournalEntries" Seedkeep/Core/Sync/SyncEngine.swift | head -40
```

Match the exact pattern.

- [ ] **Step 2: Add three new pulls**

In `syncAll`, after `pullJournalEntries`:

```swift
try await pullAssistantThreads(householdID: householdID)
// Messages and tool calls are nested in thread detail; we fetch them via
// GET /assistant/threads/:id when a thread is opened in the UI, not in
// the syncAll background sweep. They DO sync via separate delta-page calls
// for cross-device — see pullAssistantMessages and pullAssistantToolCalls.
try await pullAssistantMessages(householdID: householdID)
try await pullAssistantToolCalls(householdID: householdID)
```

Add the three corresponding `pull<X>` methods + `upsert<X>` methods. For each, mirror `pullJournalEntries` + `upsertJournalEntries`:
- `pull`: cursor → paginated loop → upsert → save cursor → break on `!has_more`.
- `upsert`: per-item fetch → if found + `deletedAt != nil`, hard-delete locally (cascade-clean children for threads — call a `cleanupAssistantThreadChildren` helper that deletes messages + tool calls with matching threadID); else apply DTO; else insert new.

**Open question**: do `pullAssistantMessages` and `pullAssistantToolCalls` have their own server endpoints, or do they come down only via `GET /threads/:id`?

[Reading the server plan...] The server plan adds `GET /api/assistant/threads?since=&limit=` (delta-sync), and `GET /api/assistant/threads/:id` (full detail with messages + tool_calls). It does NOT add `GET /api/assistant/messages?since=` as a top-level resource. So messages + tool calls are fetched per-thread, NOT via the global delta-sync.

This means:
- `pullAssistantThreads` is straightforward (delta-sync).
- Messages + tool calls come down nested in thread detail when the user opens a thread.
- Skip `pullAssistantMessages` + `pullAssistantToolCalls` in this task.

Replace the prescribed code above with: just `pullAssistantThreads`. Messages/tool calls are loaded by `AssistantThreadView` on appear via `client.assistantThread(id:)`.

- [ ] **Step 3: Add the cascade helper**

When a thread is soft-deleted (hard-delete locally), also hard-delete its local messages + tool calls:

```swift
private func cleanupAssistantThreadChildren(threadID: String, context: ModelContext) throws {
    // Fetch + delete all LocalAssistantMessage with this threadID.
    // Fetch + delete all LocalAssistantToolCall with this threadID.
}
```

Call from `upsertAssistantThreads` when soft-deleting.

- [ ] **Step 4: Build + test**

```bash
xcodebuild ... build -quiet 2>&1 | tail -5
cd SeedkeepKit && swift test 2>&1 | tail -3
```
Green.

- [ ] **Step 5: Commit**

```bash
git add Seedkeep/Core/Sync/SyncEngine.swift
git commit -m "Extend SyncEngine to drain assistant threads; cascade-clean children on soft-delete"
```

---

## Task 5: AIAssistantCoordinator skeleton

**Goal**: Centralized state for the assistant — current thread, messages, streaming state, page-context bus, key-status flag.

**Files:**
- Create: `Seedkeep/Core/Assistant/AIAssistantCoordinator.swift`
- Modify: `Seedkeep/App/AppEnvironment.swift`

- [ ] **Step 1: Read the SimmerSmith reference**

```bash
head -200 ~/git/simmersmith/SimmerSmith/SimmerSmith/App/AppState+Assistant.swift
```

This is the canonical pattern for thread management + launch context. Mirror it.

- [ ] **Step 2: Write the coordinator**

`Seedkeep/Core/Assistant/AIAssistantCoordinator.swift`:

```swift
import Foundation
import SwiftData
import SeedkeepKit

@MainActor
@Observable
final class AIAssistantCoordinator {
    private let client: SeedkeepClient
    private let container: ModelContainer

    // MARK: - Conversation state
    private(set) var currentThreadID: String?
    private(set) var streamingState: StreamingState = .idle
    private(set) var lastError: String?

    // MARK: - Page context bus
    private(set) var pageContext: AIPageContext?
    private(set) var assistantLaunchContext: AssistantLaunchContext?

    // MARK: - Key status
    private(set) var keyConfigured: Bool = false
    private(set) var keyCheckError: String?

    enum StreamingState: Equatable {
        case idle
        case streaming(messageID: String)
        case awaitingConfirmation(toolCallID: String)
        case error(String)
    }

    struct AIPageContext: Equatable, Hashable {
        let pageType: String         // 'seed' | 'bed' | 'planting_event' | 'garden' | etc.
        let entityID: String?
        let label: String?           // e.g. "Habanada Pepper"
    }

    struct AssistantLaunchContext: Equatable {
        let threadID: String
        let initialText: String      // pre-fill the composer with this
        let pageContext: AIPageContext?
    }

    init(client: SeedkeepClient, container: ModelContainer) {
        self.client = client; self.container = container
    }

    // MARK: - Thread management
    func openThread(_ id: String)
    func createThread(title: String = "") async throws -> LocalAssistantThread
    func deleteThread(_ id: String) async throws

    // MARK: - Messaging
    /// Send a user message; opens an SSE stream; appends events into local store.
    func send(text: String, pageContextOverride: AIPageContext? = nil) async throws

    /// Confirm a proposed tool call → opens a new SSE stream resuming the conversation.
    func confirmToolCall(_ toolCallID: String) async throws

    /// Cancel a proposed tool call.
    func cancelToolCall(_ toolCallID: String) async throws

    // MARK: - Page context bus
    func setPageContext(_ context: AIPageContext)
    func clearPageContext()

    /// Consume + pop the launch context. Used by AssistantView on appear so it
    /// can pre-fill the composer.
    func consumeAssistantLaunchContext() -> AssistantLaunchContext?

    // MARK: - Sparkle button entry
    /// Called by TopBarSparkleButton tap. Creates a new thread with the current
    /// pageContext attached, sets it as currentThread, returns the new thread ID
    /// so the caller can navigate.
    func launchFromSparkle(initialText: String = "") async throws -> String

    // MARK: - Key status
    func refreshKeyStatus() async
}
```

Implementation notes (per task; not exhaustive):
- `send(text:)`: insert a local user message → start `client.streamAssistantResponse(...)` → for each event, update local SwiftData (text_delta accumulates into the current assistant message's contentJSON; tool_use_start creates a LocalAssistantToolCall row; etc.).
- State machine guards: only one in-flight stream at a time per thread; `streamingState` transitions are explicit.
- Persistence: every event mutates SwiftData immediately so background sync sees them (eventually).

The actual streaming-loop code goes in Task 7. **This task is the coordinator skeleton + thread/key methods.** Streaming send/confirm/cancel internals are stubbed with `try await { }; fatalError("implemented in Task 7")`.

- [ ] **Step 3: Construct in AppEnvironment**

```swift
public let assistant: AIAssistantCoordinator

// In init:
self.assistant = AIAssistantCoordinator(client: client, container: container)

// On first launch (or in an .onAppear somewhere), kick refreshKeyStatus.
```

- [ ] **Step 4: Build**

```bash
xcodebuild ... build -quiet 2>&1 | tail -5
```
BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Seedkeep/Core/Assistant/AIAssistantCoordinator.swift Seedkeep/App/AppEnvironment.swift
git commit -m "Add AIAssistantCoordinator skeleton with thread + key state"
```

---

## Task 6: Assistant tab + thread list view (read-only)

**Goal**: Visible Assistant tab. Renders the list of threads. Tap a thread → push a detail view that renders persisted messages from SwiftData (no streaming yet — that's Task 7).

**Files:**
- Modify: `Seedkeep/Features/MainTabView.swift`
- Create: `Seedkeep/Features/Assistant/AssistantView.swift`
- Create: `Seedkeep/Features/Assistant/AssistantThreadView.swift`
- Create: `Seedkeep/Features/Assistant/MessageBubble.swift`

- [ ] **Step 1: Read SimmerSmith's AssistantView**

```bash
sed -n '1,200p' ~/git/simmersmith/SimmerSmith/SimmerSmith/Features/Assistant/AssistantView.swift
```

Structure to mirror:
- `NavigationStack(path:)` with thread list at root.
- Empty state with starter prompt buttons.
- Tap thread row → push detail.
- Per-thread loading + error states.

Adapt to Seedkeep's design system (no Smith-specific styling — use SwiftUI defaults).

- [ ] **Step 2: Write `AssistantView.swift`**

Top-level view for the tab. Pseudocode:

```swift
struct AssistantView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Query(filter: #Predicate<LocalAssistantThread> { $0.deletedAt == nil },
           sort: \.updatedAt, order: .reverse)
    private var threads: [LocalAssistantThread]

    @State private var path: [String] = []   // thread IDs

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !appEnv.assistant.keyConfigured {
                    // Empty state: "Set your Anthropic API key in Settings to get started"
                    ContentUnavailableView(...)
                } else if threads.isEmpty {
                    // Empty state with starter prompts:
                    // "What did I plant in May 2024?"
                    // "Help me plan Bed A for June"
                    // Tapping a prompt creates a new thread + pre-fills it.
                    starterPromptsList
                } else {
                    ForEach(threads) { thread in
                        NavigationLink(value: thread.id) {
                            threadRow(thread)
                        }
                    }
                }
            }
            .navigationTitle("Assistant")
            .navigationDestination(for: String.self) { threadID in
                AssistantThreadView(threadID: threadID)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await createAndOpen() } } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(!appEnv.assistant.keyConfigured)
                }
            }
            .task {
                await appEnv.assistant.refreshKeyStatus()
            }
            .refreshable {
                // Trigger background sync — threads update via @Query.
            }
        }
    }
}
```

Starter prompts list: hardcoded 3-4 examples ("What did I plant in May 2024?" / "Help me plan Bed A for June" / "Did peppers do well last year?" / "Add a journal entry for today: watered everything"). Tapping creates a thread + sets the launch context.

- [ ] **Step 3: Write `AssistantThreadView.swift`**

```swift
struct AssistantThreadView: View {
    let threadID: String

    @Environment(AppEnvironment.self) private var appEnv

    @Query private var messages: [LocalAssistantMessage]
    @Query private var toolCalls: [LocalAssistantToolCall]

    init(threadID: String) {
        self.threadID = threadID
        let id = threadID
        _messages = Query(
            filter: #Predicate<LocalAssistantMessage> { $0.threadID == id },
            sort: \.createdAt)
        _toolCalls = Query(
            filter: #Predicate<LocalAssistantToolCall> { $0.threadID == id },
            sort: \.createdAt)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(messages) { message in
                    MessageBubble(message: message, toolCalls: toolCallsForMessage(message.id))
                }
            }
        }
        // Composer comes in Task 7.
        .task {
            // Refresh thread detail from server (messages + tool calls) so we
            // get any updates synced from other devices.
            do {
                let detail = try await appEnv.client.assistantThread(id: threadID)
                try upsertLocal(detail)
            } catch {
                // silent — render what we have
            }
        }
    }
}
```

`MessageBubble` is the per-message view: user messages right-aligned, assistant messages left-aligned, tool calls rendered inline within the assistant message at their content-block positions.

For this task, the rendering is **read-only** — display persisted messages from SwiftData. No compose, no streaming. Verify thread navigation works by creating a thread + a message via curl, then watching it appear in the simulator after a sync.

- [ ] **Step 4: Write `MessageBubble.swift`**

Simple version: alignment by role, text content rendered. Tool call cards (the rich UI) come in Task 8 — for now, render `[Tool call: <toolName> – <status>]` as a placeholder.

- [ ] **Step 5: Add Assistant tab to MainTabView**

Insert between Journal and Random (matching the spec's tab order: Library | Garden | Journal | Random | **Assistant** | Settings | You — wait, the spec said Assistant comes BEFORE Settings; let me match the spec):

Per the spec: `Library | Garden | Journal | Random | Assistant | Settings | You`. Insert Assistant between Random and Settings.

Update the doc comment to "Seven-tab root: Library / Garden / Journal / Random / Assistant / Settings / You."

- [ ] **Step 6: Build + run**

Run the app on simulator. Confirm the Assistant tab appears with the empty state. Without a key configured (server-side), it should say "Set your Anthropic API key in Settings to get started." (The Settings UI lands in Task 9 — for now, the empty state is enough to verify the tab renders.)

- [ ] **Step 7: Commit**

```bash
git add Seedkeep/Features/Assistant/ Seedkeep/Features/MainTabView.swift
git commit -m "Add Assistant tab + read-only thread list + thread detail"
```

---

## Task 7: Compose + streaming + message rendering

**Goal**: Wire up `AIAssistantCoordinator.send(...)` to actually call the streaming SSE endpoint, accumulate deltas into SwiftData, and render the live updates in `AssistantThreadView`.

**Files:**
- Modify: `Seedkeep/Core/Assistant/AIAssistantCoordinator.swift` — implement `send(text:)` body.
- Modify: `Seedkeep/Features/Assistant/AssistantThreadView.swift` — add composer.
- Modify: `Seedkeep/Features/Assistant/MessageBubble.swift` — handle streaming state.

- [ ] **Step 1: Implement `send(text:)` in the coordinator**

The core streaming loop. Pseudocode:

```swift
func send(text: String, pageContextOverride: AIPageContext? = nil) async throws {
    guard let threadID = currentThreadID else { throw ... }
    guard streamingState == .idle else { return }  // already streaming
    let ctx = ModelContext(container)
    let now = Int64(Date().timeIntervalSince1970 * 1000)

    // 1. Insert local user message (optimistic).
    let userMessage = LocalAssistantMessage(
        id: nanoid(), threadID: threadID, role: "user",
        contentJSON: try encodeContentBlocks([.text(text)]),
        pageContext: try? encode(pageContextOverride ?? pageContext),
        model: nil, usageJSON: nil, createdAt: now)
    ctx.insert(userMessage)
    try ctx.save()

    // 2. Insert an empty assistant message that we'll append deltas into.
    let assistantMessage = LocalAssistantMessage(
        id: nanoid(), threadID: threadID, role: "assistant",
        contentJSON: try encodeContentBlocks([.text("")]),
        pageContext: nil, model: nil, usageJSON: nil,
        createdAt: now + 1)
    ctx.insert(assistantMessage)
    try ctx.save()
    streamingState = .streaming(messageID: assistantMessage.id)

    // 3. Open the SSE stream.
    let payload = AssistantPageContextPayload(...)   // from pageContextOverride or pageContext
    let stream = client.streamAssistantResponse(
        threadId: threadID, text: text, pageContext: payload)

    do {
        for try await event in stream {
            try handleStreamEvent(event, assistantMessageID: assistantMessage.id, ctx: ctx)
        }
        streamingState = .idle
    } catch {
        streamingState = .error(error.localizedDescription)
        lastError = error.localizedDescription
        throw error
    }
}

private func handleStreamEvent(
    _ event: AssistantStreamEvent,
    assistantMessageID: String,
    ctx: ModelContext
) throws {
    switch event {
    case .textDelta(let messageID, let delta):
        // Find the assistant message; append delta to its last text content block.
        // ctx.save() — SwiftData will re-render any view observing this row.
    case .toolUseStart(let toolCallID, let messageID, let toolName):
        let call = LocalAssistantToolCall(
            id: toolCallID, messageID: assistantMessageID, threadID: currentThreadID!,
            toolName: toolName, argsJSON: "{}", status: "running",
            resultJSON: nil, proposedChangeJSON: nil, confirmedAt: nil,
            createdAt: now, updatedAt: now)
        ctx.insert(call)
        try ctx.save()
    case .toolUseDone(let toolCallID, let argsJson):
        // Update the call's argsJSON.
    case .toolResult(let toolCallID, let status, let resultJson):
        // Update status + resultJSON. Status transitions running→done/failed.
    case .proposedChange(let toolCallID, let proposedChangeJson):
        // Update status='proposed' + proposedChangeJSON.
        // Set streamingState = .awaitingConfirmation(toolCallID).
        // The stream will close after this event; the for-await loop exits.
    case .done(let messageID):
        // Stream complete; final save.
    case .streamError(let code, let message):
        throw StreamError(code: code, message: message)
    }
}
```

Important: every event mutates SwiftData and `ctx.save()` is called. SwiftUI views observing the assistant message via `@Query` will re-render on each save — that's the typewriter effect.

- [ ] **Step 2: Implement `confirmToolCall` and `cancelToolCall`**

```swift
func confirmToolCall(_ toolCallID: String) async throws {
    // Open the confirm-stream (server's POST /tool_calls/:id/confirm returns SSE).
    let stream = client.confirmAssistantToolCall(toolCallID)
    // Same event-handling loop as send(). The assistant message it appends
    // to is the one currently in progress — find it by threadID + latest.
}

func cancelToolCall(_ toolCallID: String) async throws {
    let updated = try await client.cancelAssistantToolCall(toolCallID)
    // Mirror to local SwiftData: find the toolCall, apply the updated status.
    streamingState = .idle
    // Optionally: trigger a fresh send() with a "tool was cancelled" follow-up
    // so the LLM can respond. Or leave it to the user to send their next message.
}
```

- [ ] **Step 3: Add the composer to `AssistantThreadView`**

```swift
@State private var composerText: String = ""

// At the bottom of the body:
HStack {
    TextField("Ask Sprout…", text: $composerText, axis: .vertical)
        .lineLimit(1...4)
    Button {
        Task { await send() }
    } label: {
        Image(systemName: "arrow.up.circle.fill")
    }
    .disabled(composerText.trimmingCharacters(in: .whitespaces).isEmpty
              || appEnv.assistant.streamingState != .idle)
}
.padding()

private func send() async {
    let text = composerText.trimmingCharacters(in: .whitespaces)
    composerText = ""
    do {
        try await appEnv.assistant.send(text: text)
    } catch {
        // surface via error overlay
    }
}
```

- [ ] **Step 4: Update `MessageBubble` to handle streaming state**

When the message is the one currently streaming (`appEnv.assistant.streamingState == .streaming(messageID: this.id)`), append a blinking cursor or just show the content as it grows (the @Query re-renders on each save will produce the typewriter effect automatically).

- [ ] **Step 5: Build + test against local server**

```bash
xcodebuild ... build -quiet 2>&1 | tail -5
```
BUILD SUCCEEDED.

Manual smoke: in simulator, set a fake API key via the existing server (or run dev server with the mock), open a thread, type a message, watch it stream.

- [ ] **Step 6: Commit**

```bash
git add Seedkeep/Core/Assistant/AIAssistantCoordinator.swift Seedkeep/Features/Assistant/
git commit -m "Implement streaming send + cancel; composer + typewriter rendering"
```

---

## Task 8: Tool-call cards + proposed-change confirmations

**Goal**: Render tool calls inline with rich UI (status, expandable details). For destructive ops, show a `ProposedChangeCard` with Confirm/Cancel buttons.

**Files:**
- Create: `Seedkeep/Features/Assistant/AssistantToolCallCard.swift`
- Create: `Seedkeep/Features/Assistant/ProposedChangeCard.swift`
- Modify: `Seedkeep/Features/Assistant/MessageBubble.swift` — embed the cards inline.

- [ ] **Step 1: Read the SimmerSmith tool-call card**

```bash
cat ~/git/simmersmith/SimmerSmith/SimmerSmith/Features/Assistant/AssistantToolCallCard.swift
```

268 lines. Mirror exactly — the visual treatment, status pills, icon selection logic, expand-for-details. Strip SimmerSmith-specific design tokens (SMColor, SMSpacing, etc.) and use Seedkeep's existing design tokens or SwiftUI defaults.

- [ ] **Step 2: Write `AssistantToolCallCard.swift`**

Mirror SimmerSmith's structure:
- HStack: icon (per tool category) + VStack(title, subtitle/status) + Spacer + status indicator (ProgressView for running, checkmark for done, alert for failed).
- Tap to expand → shows full args + result as a code block.
- When `call.status == "proposed"`, switch to `ProposedChangeCard` (next step).

Map tool name → icon + category:
- `list_*` / `get_*` → magnifying glass
- `create_*` → plus circle
- `update_*` → pencil
- `delete_*` → trash
- `add_checklist_item` / `toggle_checklist_item` → checklist
- `search_catalog` → book

Status → color:
- running: blue
- done: green
- failed: red
- cancelled: gray
- proposed: yellow (with confirmation card)

- [ ] **Step 3: Write `ProposedChangeCard.swift`**

```swift
struct ProposedChangeCard: View {
    let toolCall: LocalAssistantToolCall
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(actionTitle)
                    .font(.headline)
            }
            // "Was → Becomes" diff rendering
            diffView

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    onCancel()
                } label: { Text("Cancel").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)

                Button {
                    onConfirm()
                } label: { Text("Confirm").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }

    private var actionTitle: String {
        // "Update planting event?" / "Delete seed?" / etc.
    }

    @ViewBuilder
    private var diffView: some View {
        // Parse toolCall.proposedChangeJSON into a { was, becomes } structure;
        // render line-by-line diffs. For delete ops, just show the entity
        // being deleted with a "(removed)" marker.
    }
}
```

- [ ] **Step 4: Wire into `MessageBubble`**

When rendering an assistant message, walk its `contentBlocks()`. For each `.toolUse(id, ...)` block, look up the matching `LocalAssistantToolCall` and render `AssistantToolCallCard` or `ProposedChangeCard` inline.

Confirm/Cancel wiring:
```swift
.onConfirm = {
    Task { await appEnv.assistant.confirmToolCall(toolCall.id) }
}
.onCancel = {
    Task { await appEnv.assistant.cancelToolCall(toolCall.id) }
}
```

- [ ] **Step 5: Build + manual smoke**

Build green. Manual smoke against dev server with mock-Anthropic returning proposed-change events; verify card renders + Confirm/Cancel route correctly.

- [ ] **Step 6: Commit**

```bash
git add Seedkeep/Features/Assistant/
git commit -m "Add inline tool-call cards + proposed-change Confirm/Cancel UI"
```

---

## Task 9: TopBarSparkleButton + PageContextPublisher + AssistantKeySettingsView

**Goal**: Global "ask Sprout" affordance on every primary page; page-context bus; Settings entry for key management.

**Files:**
- Create: `Seedkeep/DesignSystem/Components/TopBarSparkleButton.swift`
- Create: `Seedkeep/Core/Assistant/PageContextPublisher.swift`
- Create: `Seedkeep/Features/Settings/AssistantKeySettingsView.swift`
- Modify: primary page views (LibraryView, GardenView, JournalView, RandomPickView, SeedDetailView, BedDetailView, etc.) — add sparkle button to toolbar + publish page context.
- Modify: `Seedkeep/Features/Settings/SettingsView.swift` — add row → AssistantKeySettingsView.

- [ ] **Step 1: Read the SimmerSmith sparkle button**

```bash
cat ~/git/simmersmith/SimmerSmith/SimmerSmith/DesignSystem/Components/TopBarSparkleButton.swift
```

Mirror the structure. Sparkle icon (`sparkles` SF Symbol), tap launches the assistant with the current page context.

- [ ] **Step 2: Write `TopBarSparkleButton.swift`**

```swift
struct TopBarSparkleButton: View {
    @Environment(AppEnvironment.self) private var appEnv

    var body: some View {
        Button {
            Task { await launch() }
        } label: {
            Image(systemName: "sparkles")
        }
        .disabled(!appEnv.assistant.keyConfigured)
    }

    private func launch() async {
        do {
            let threadID = try await appEnv.assistant.launchFromSparkle()
            // Navigate to Assistant tab + push the new thread.
            // Mechanism: appEnv.routing.selectedTab = .assistant + path = [threadID]
            //   (use whatever app-level routing exists — read MainTabView for the pattern)
        } catch {
            // Surface error
        }
    }
}
```

Tab routing — check how MainTabView handles programmatic tab selection. SimmerSmith uses `selectedTab = .assistant` on a `@Bindable` AppState. Mirror that. If Seedkeep doesn't have one, add a `selectedTab` property to AppEnvironment.

- [ ] **Step 3: Write `PageContextPublisher.swift`**

A view modifier:

```swift
struct PageContextPublisher: ViewModifier {
    @Environment(AppEnvironment.self) private var appEnv
    let context: AIAssistantCoordinator.AIPageContext

    func body(content: Content) -> some View {
        content
            .onAppear { appEnv.assistant.setPageContext(context) }
            .onDisappear { appEnv.assistant.clearPageContext() }
    }
}

extension View {
    func publishesAssistantContext(_ context: AIAssistantCoordinator.AIPageContext) -> some View {
        modifier(PageContextPublisher(context: context))
    }
}
```

- [ ] **Step 4: Wire sparkle button + page context into primary pages**

For each of the primary views (LibraryView, GardenView, JournalView, RandomPickView, SeedDetailView, BedDetailView, JournalEntryView, AddPlantingEventView, etc.):

1. Add `.toolbar { ToolbarItem(placement: .topBarTrailing) { TopBarSparkleButton() } }`.
2. Add `.publishesAssistantContext(AIPageContext(pageType: "seed", entityID: seed.id, label: seed.customName))` or equivalent for each view.

For top-level views (LibraryView etc.), pageType is `'library'`, `'garden'`, `'journal'`, etc. — no entityID. For detail views, include the entityID.

This is the cross-cutting modification — ~8 view files. Commit per logical group (top-level views → 1 commit; detail views → 1 commit) if the change is too big to land in one.

- [ ] **Step 5: Write `AssistantKeySettingsView.swift`**

```swift
struct AssistantKeySettingsView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @State private var keyInput: String = ""
    @State private var working: Bool = false
    @State private var errorMessage: String?
    @State private var testResult: TestResult?

    enum TestResult { case ok, failed(String) }

    var body: some View {
        Form {
            if appEnv.assistant.keyConfigured {
                Section {
                    Label("Anthropic key configured", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Test connection") { Task { await testConnection() } }
                    Button("Replace key") { /* surface SecureField */ }
                    Button("Revoke key", role: .destructive) {
                        Task { await revoke() }
                    }
                }
            } else {
                Section("Anthropic API key") {
                    SecureField("sk-ant-…", text: $keyInput)
                    Button("Save key") {
                        Task { await save() }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Privacy") {
                    Text("Your API key is encrypted (AES-256-GCM) and stored on Seedkeep's server. We use it to make assistant calls on your behalf. We never display the key back to you after saving.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("AI Assistant")
        .task { await appEnv.assistant.refreshKeyStatus() }
    }

    private func save() async {
        working = true; defer { working = false }
        do {
            _ = try await appEnv.client.setAssistantKey(provider: "anthropic", key: keyInput)
            keyInput = ""
            await appEnv.assistant.refreshKeyStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testConnection() async { /* send a no-op chat completion */ }
    private func revoke() async { /* delete */ }
}
```

- [ ] **Step 6: Add Settings row**

In `SettingsView.swift`, add a `NavigationLink("AI Assistant") { AssistantKeySettingsView() }` row.

- [ ] **Step 7: Build + manual smoke**

Build green. In the simulator: Settings → AI Assistant → enter a fake key → "Save key" → key reported configured. Then go to any primary page → tap sparkle button → assistant tab opens with a new empty thread.

- [ ] **Step 8: Commit (likely 2 commits — split if useful)**

```bash
git add Seedkeep/DesignSystem/Components/TopBarSparkleButton.swift Seedkeep/Core/Assistant/PageContextPublisher.swift
git commit -m "Add TopBarSparkleButton + PageContextPublisher view modifier"

git add Seedkeep/Features/Library/ Seedkeep/Features/Garden/ Seedkeep/Features/Journal/ Seedkeep/Features/SeedDetail/
git commit -m "Mount sparkle button + page context on primary views"

git add Seedkeep/Features/Settings/
git commit -m "Add AssistantKeySettingsView for BYOK key management"
```

---

## Task 10: TestFlight cut + device verify

**Files**: bumps `project.yml` via `scripts/release.sh`.

- [ ] **Step 1: Final gate**

```bash
cd /Users/tfinklea/git/seedkeep-ios/.worktrees/phase-4-sprout-ios
xcodegen generate >/dev/null
xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -3
cd SeedkeepKit && swift test 2>&1 | tail -3
```
Both green.

- [ ] **Step 2: Push the worktree branch + merge to main**

```bash
cd /Users/tfinklea/git/seedkeep-ios
git fetch origin
git merge --ff-only phase-4-sprout-ios
git push origin main
```

If denied by the auto-mode classifier, push the branch (`git push -u origin phase-4-sprout-ios`) and ask the user.

- [ ] **Step 3: Cut TestFlight build**

```bash
./scripts/release.sh --minor    # 0.3.x → 0.4.0
```

Expected: `Bumping version (minor)`, `Archiving Release for generic iOS`, `** ARCHIVE SUCCEEDED **`, `** EXPORT SUCCEEDED **`, `Seedkeep 0.4.0 (build N) uploaded to TestFlight`.

- [ ] **Step 4: Push the release commit**

```bash
git push origin main
```

- [ ] **Step 5: Clean up worktree**

```bash
git worktree remove --force .worktrees/phase-4-sprout-ios
git branch -d phase-4-sprout-ios
```

- [ ] **Step 6: Device verify checklist**

Wait for TestFlight processing. Install build N on a real device. Verify each surface:

- Assistant tab visible between Random and Settings; empty state with "Set your Anthropic API key" prompt when key is not configured.
- Settings → AI Assistant → enter a real Anthropic key → save → returns to configured state.
- Assistant tab now shows starter prompts.
- Tap a starter prompt → new thread opens → composer pre-filled → send → response streams in.
- Type "what seeds do I have?" → assistant calls `list_seeds` → result rendered as a tool-call card → assistant summarizes.
- Type "add a journal entry for today: watered the peppers" → assistant calls `create_journal_entry` → tool card → confirms creation in chat.
- Type "delete the Habanada Pepper seed" → assistant proposes the change → ProposedChangeCard renders → tap Confirm → deletion executes → tool card updates to done.
- Same scenario but tap Cancel → tool card updates to cancelled.
- Sparkle button on Seed detail (open Habanada Pepper, tap sparkle) → new thread opens with page context attached → ask "what's the planting window for this?" → assistant answers using `get_recommendation` for that catalog seed.
- Kill app + relaunch → thread + messages persist; can continue conversation.

- [ ] **Step 7: Update AI docs**

Append to `.docs/ai/current-state.md`:

```markdown
**Date**: YYYY-MM-DD — Phase 4 (Sprout) shipped to TestFlight (build N, 0.4.0)

- 4 new SwiftData models (13th-16th): LocalAssistantThread, LocalAssistantMessage, LocalAssistantToolCall, LocalAssistantKeyStatus.
- AIAssistantCoordinator with streaming send + confirm/cancel state machine.
- 7-tab MainTabView (added Assistant between Random and Settings).
- AssistantView (thread list + starter prompts) + AssistantThreadView (per-thread chat) + MessageBubble + AssistantToolCallCard + ProposedChangeCard.
- TopBarSparkleButton + PageContextPublisher view modifier; mounted on N primary views.
- AssistantKeySettingsView for BYOK key entry.
- SSE streaming via URLSession.AsyncBytes; SimmerSmith-derived parser.
- TestFlight build N (0.4.0). Server: Fly v16.
- Pending: device verification of every tool-call path, App Store submission.
```

- [ ] **Step 8: Push docs**

```bash
git add .docs/ai/current-state.md
git commit -m "Update current-state: Phase 4 shipped to TestFlight (build N, 0.4.0)"
git push origin main
```

---

## Self-review checklist (verify before marking plan complete)

- [ ] Every server route added by the Phase 4 server plan has a matching client method in iOS T1 or T2.
- [ ] 4 new SwiftData models registered in the AppEnvironment schema (Schema array length = 16).
- [ ] Sync engine drains assistant threads (T4). Messages + tool calls fetched per-thread via `client.assistantThread(id:)`.
- [ ] AIAssistantCoordinator owns the live streaming state machine + the page-context bus.
- [ ] Assistant tab visible in MainTabView between Random and Settings.
- [ ] Read-only thread list works after T6; full compose + streaming works after T7; tool-call cards + proposed-change works after T8.
- [ ] TopBarSparkleButton mounted on every primary page (T9).
- [ ] AssistantKeySettingsView lives in Settings; SecureField for key entry; never displays the key back.
- [ ] Stream parser handles partial buffer reads + malformed events without crashing (T2 tests).
- [ ] TestFlight 0.4.0 build cut + device verify checklist completed (T10).

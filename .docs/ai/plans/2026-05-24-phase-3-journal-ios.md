# Phase 3 — Journal — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the iOS client side of the Phase 3 journal — three new SwiftData models, a new top-level Journal tab with a chronological feed, entry create/edit with text + photos + checklists, entity-scoped journal sections inside seed/bed/event detail views, and a year-over-year retrospective card at the top of the feed.

**Architecture:** SeedkeepKit gains journal DTOs + client methods against the Phase 3 server API. Three new SwiftData models (`LocalJournalEntry`, `LocalJournalEntryPhoto`, `LocalJournalChecklistItem`) join the existing 8, registered in `AppEnvironment.makeModelContainer()`. A `JournalStore` (`@MainActor @Observable`, owned by `AppEnvironment`) coordinates fetch/cache/optimistic-mutation; the existing `SyncEngine` is extended to drain the three new entity types via the existing delta-sync flow. The Journal tab is a top-level tab in the root navigation. Photos reuse the `nonisolated` resize/base64 pipeline already shipped in `ScanFlow.swift`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, PhotosUI, Swift Testing. XcodeGen (`project.yml`).

**Spec:** `~/git/seedkeep/.docs/ai/specs/2026-05-24-phase-3-journal-design.md`.

**Prerequisite:** The Phase 3 server side (see `seedkeep-server/.docs/ai/plans/2026-05-24-phase-3-journal-server.md`) deployed to `https://seedkeep-server.fly.dev` — migration 0011 applied, 10 new routes live, sync envelope extended. Tasks 1–9 can be built against the local dev server; Task 10 (TestFlight + device verify) needs prod.

**Conventions** (verified against the codebase — follow exactly):
- `SeedkeepKit` is a pure Swift package (no SwiftData/UIKit); DTOs are flat `Codable, Sendable, Equatable` structs in `Models/`. `SeedkeepClient` is a `public actor`. Tests are **Swift Testing** in `Tests/SeedkeepKitTests/`, run via `cd SeedkeepKit && swift test`.
- SwiftData `@Model` types live in `Seedkeep/Core/Models/`, registered in the `Schema([...])` in `AppEnvironment.makeModelContainer()`. Enums stored as raw strings; arrays/JSON as JSON `String` with typed computed accessors. DTO↔Model conversion in `Core/Models/Mapping.swift` (`makeLocal()` / `apply(to:)`).
- `AppEnvironment` (`@MainActor @Observable`) owns services; views read `@Environment(AppEnvironment.self)`.
- App build: `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build`. `.xcodeproj` is generated from `project.yml` (`xcodegen generate` after pulling; do not hand-edit the `.xcodeproj`).
- Photos: the existing `seed_photos` upload path uses `nonisolated` UIImage resize off MainActor (shipped 2026-05-19 in `ScanFlow.swift`); reuse the same `resizedJPEG` helper.
- Release: `scripts/release.sh --build` for build-only bumps within a minor; `--minor` for a version bump. Default is `--build`.

**Plan-level decisions (refinements of the spec):**
- **JSON wire field naming**: server uses camelCase (`occurredOn`, `seedId`, etc. — see `rowToDto` in the server plan Task 3); DTOs use the synthesized-Codable camelCase mapping. No CodingKeys overrides needed.
- **`LocalJournalEntry.parentKind`** is a computed `enum` (`.seed`/`.bed`/`.plantingEvent`/`.garden`) derived from which FK is non-nil. Stored as four nullable string fields (`seedID`, `bedID`, `plantingEventID`); a `parentKind` computed property dispatches in views.
- **Photo upload from iOS** posts multipart to `POST /api/journal/:id/photos` with the same resize+base64-then-decode-on-server pattern the seed-photo flow uses. Reuse — don't reimplement.

---

## File Structure

**Create:**
- `SeedkeepKit/Sources/SeedkeepKit/Models/JournalEntry.swift` — `JournalEntryDTO`, `JournalEntryPhotoDTO`, `JournalChecklistItemDTO`, `JournalFeedResponseDTO`, `RetrospectiveResponseDTO`.
- `Seedkeep/Core/Models/LocalJournalEntry.swift` — the 10th `@Model` (current count is 9, last added: `LocalRecommendation`).
- `Seedkeep/Core/Models/LocalJournalEntryPhoto.swift` — the 11th `@Model`.
- `Seedkeep/Core/Models/LocalJournalChecklistItem.swift` — the 12th `@Model`.
- `Seedkeep/Core/Journal/JournalStore.swift` — fetch/cache/optimistic-mutation coordinator.
- `Seedkeep/Features/Journal/JournalView.swift` — top-level tab body (feed).
- `Seedkeep/Features/Journal/JournalEntryView.swift` — create/edit detail view.
- `Seedkeep/Features/Journal/RetrospectiveCard.swift` — top-of-feed card.
- `Seedkeep/Features/Journal/EntityScopedJournalSection.swift` — collapsible section for seed/bed/event details.
- `Seedkeep/Features/Journal/AttachedEntityPicker.swift` — None / Seed / Bed / Planting event picker.

**Modify:**
- `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift` — journal client methods.
- `SeedkeepKit/Tests/SeedkeepKitTests/` — new DTO decode tests.
- `Seedkeep/App/AppEnvironment.swift` — register the 3 new `@Model` types, construct `JournalStore`.
- `Seedkeep/Core/Models/Mapping.swift` — DTO↔Model conversion for the 3 new types.
- `Seedkeep/Core/Sync/SyncEngine.swift` — drain `journal_entries`, `journal_entry_photos`, `journal_checklist_items` (verify exact filename — search for the existing seeds/beds sync path).
- `Seedkeep/App/RootView.swift` (or the actual file owning the root TabView — find via grep) — add the Journal tab.
- `Seedkeep/Features/SeedDetail/SeedDetailView.swift` — mount `EntityScopedJournalSection(parent: .seed(...))`.
- `Seedkeep/Features/Garden/BedDetailView.swift` — same.
- `Seedkeep/Features/Garden/AddPlantingEventView.swift` (or the event-detail view if it exists separately) — same.
- `project.yml` — no entitlement changes needed (photo library access is already declared for the scan flow).

---

## Task 1: SeedkeepKit — Journal DTOs + client methods

**Files:**
- Create: `SeedkeepKit/Sources/SeedkeepKit/Models/JournalEntry.swift`
- Modify: `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift`
- Test: `SeedkeepKit/Tests/SeedkeepKitTests/JournalDecodeTests.swift`

- [ ] **Step 1: Write the DTOs**

Create `SeedkeepKit/Sources/SeedkeepKit/Models/JournalEntry.swift`:

```swift
import Foundation

public struct JournalEntryDTO: Codable, Sendable, Equatable {
    public let id: String
    public let householdId: String
    public let occurredOn: String           // 'YYYY-MM-DD'
    public let body: String
    public let seedId: String?
    public let bedId: String?
    public let plantingEventId: String?
    public let createdAt: Int64             // ms-epoch
    public let updatedAt: Int64
    public let deletedAt: Int64?

    public init(id: String, householdId: String, occurredOn: String, body: String,
                seedId: String?, bedId: String?, plantingEventId: String?,
                createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) {
        self.id = id; self.householdId = householdId
        self.occurredOn = occurredOn; self.body = body
        self.seedId = seedId; self.bedId = bedId; self.plantingEventId = plantingEventId
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

public struct JournalEntryPhotoDTO: Codable, Sendable, Equatable {
    public let id: String
    public let entryId: String
    public let storageKey: String
    public let sortOrder: Int
    public let width: Int?
    public let height: Int?
    public let createdAt: Int64

    public init(id: String, entryId: String, storageKey: String, sortOrder: Int,
                width: Int?, height: Int?, createdAt: Int64) {
        self.id = id; self.entryId = entryId; self.storageKey = storageKey
        self.sortOrder = sortOrder; self.width = width; self.height = height
        self.createdAt = createdAt
    }
}

public struct JournalChecklistItemDTO: Codable, Sendable, Equatable {
    public let id: String
    public let entryId: String
    public let text: String
    public let completed: Bool
    public let sortOrder: Int
    public let updatedAt: Int64

    public init(id: String, entryId: String, text: String, completed: Bool,
                sortOrder: Int, updatedAt: Int64) {
        self.id = id; self.entryId = entryId; self.text = text
        self.completed = completed; self.sortOrder = sortOrder; self.updatedAt = updatedAt
    }
}

public struct JournalFeedResponseDTO: Codable, Sendable, Equatable {
    public let entries: [JournalEntryDTO]
    public init(entries: [JournalEntryDTO]) { self.entries = entries }
}

public struct RetrospectiveYearDTO: Codable, Sendable, Equatable {
    public let year: Int
    public let entries: [JournalEntryDTO]
    public init(year: Int, entries: [JournalEntryDTO]) {
        self.year = year; self.entries = entries
    }
}

public struct RetrospectiveResponseDTO: Codable, Sendable, Equatable {
    public let anchor: String               // 'MM-DD'
    public let years: [RetrospectiveYearDTO]
    public init(anchor: String, years: [RetrospectiveYearDTO]) {
        self.anchor = anchor; self.years = years
    }
}
```

- [ ] **Step 2: Add client methods**

Modify `SeedkeepKit/Sources/SeedkeepKit/API/SeedkeepClient.swift`. Find the existing extension that holds the recommendation methods and add a new extension at the same level:

```swift
// MARK: - Journal

public extension SeedkeepClient {
    /// GET /api/journal — paginated chronological feed.
    func journalFeed(seedId: String? = nil, bedId: String? = nil,
                     plantingEventId: String? = nil,
                     fromDate: String? = nil, toDate: String? = nil,
                     limit: Int = 50) async throws -> JournalFeedResponseDTO {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/journal"),
                                        resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let seedId { items.append(URLQueryItem(name: "seed_id", value: seedId)) }
        if let bedId { items.append(URLQueryItem(name: "bed_id", value: bedId)) }
        if let plantingEventId { items.append(URLQueryItem(name: "planting_event_id", value: plantingEventId)) }
        if let fromDate { items.append(URLQueryItem(name: "from_date", value: fromDate)) }
        if let toDate { items.append(URLQueryItem(name: "to_date", value: toDate)) }
        components.queryItems = items
        return try await request(components.url!, method: "GET", decode: JournalFeedResponseDTO.self)
    }

    /// POST /api/journal — create an entry.
    struct CreateJournalEntryInput: Codable, Sendable {
        public let occurredOn: String           // 'YYYY-MM-DD'
        public let body: String
        public let seedId: String?
        public let bedId: String?
        public let plantingEventId: String?

        public init(occurredOn: String, body: String,
                    seedId: String? = nil, bedId: String? = nil, plantingEventId: String? = nil) {
            self.occurredOn = occurredOn; self.body = body
            self.seedId = seedId; self.bedId = bedId; self.plantingEventId = plantingEventId
        }

        private enum CodingKeys: String, CodingKey {
            case occurredOn = "occurred_on", body, seedId = "seed_id"
            case bedId = "bed_id", plantingEventId = "planting_event_id"
        }
    }

    func createJournalEntry(_ input: CreateJournalEntryInput) async throws -> JournalEntryDTO {
        struct Wrapper: Codable { let entry: JournalEntryDTO }
        let r: Wrapper = try await request(baseURL.appendingPathComponent("api/journal"),
                                            method: "POST", body: input, decode: Wrapper.self)
        return r.entry
    }

    /// PATCH /api/journal/:id
    struct UpdateJournalEntryInput: Codable, Sendable {
        public var occurredOn: String?
        public var body: String?
        public var seedId: String??           // nested optional = "explicitly clear"
        public var bedId: String??
        public var plantingEventId: String??

        public init() {}
        private enum CodingKeys: String, CodingKey {
            case occurredOn = "occurred_on", body
            case seedId = "seed_id", bedId = "bed_id", plantingEventId = "planting_event_id"
        }
    }

    func updateJournalEntry(_ id: String, _ patch: UpdateJournalEntryInput) async throws -> JournalEntryDTO {
        struct Wrapper: Codable { let entry: JournalEntryDTO }
        let r: Wrapper = try await request(
            baseURL.appendingPathComponent("api/journal/\(id)"),
            method: "PATCH", body: patch, decode: Wrapper.self)
        return r.entry
    }

    /// DELETE /api/journal/:id — soft-delete.
    func deleteJournalEntry(_ id: String) async throws {
        _ = try await request(baseURL.appendingPathComponent("api/journal/\(id)"),
                              method: "DELETE", decode: EmptyResponse.self)
    }

    /// POST /api/journal/:id/photos — multipart upload.
    func uploadJournalPhoto(entryId: String, jpegData: Data,
                            width: Int?, height: Int?) async throws -> JournalEntryPhotoDTO {
        // Use the existing multipart-upload helper used by uploadSeedPhoto(...).
        // (If that helper is private, lift it into a shared internal helper
        // first, then call it here.)
        return try await multipartUpload(
            path: "api/journal/\(entryId)/photos",
            fileFieldName: "photo",
            fileData: jpegData,
            additionalFields: [
                "width": width.map(String.init) ?? "",
                "height": height.map(String.init) ?? "",
            ],
            decode: { wrapper in wrapper.photo },
            wrapper: PhotoWrapper.self,
        )
    }

    /// DELETE /api/journal/photos/:photoId
    func deleteJournalPhoto(_ photoId: String) async throws {
        _ = try await request(baseURL.appendingPathComponent("api/journal/photos/\(photoId)"),
                              method: "DELETE", decode: EmptyResponse.self)
    }

    /// POST /api/journal/:id/checklist
    struct AddChecklistItemInput: Codable, Sendable {
        public let text: String
        public init(text: String) { self.text = text }
    }

    func addChecklistItem(entryId: String, text: String) async throws -> JournalChecklistItemDTO {
        struct Wrapper: Codable { let item: JournalChecklistItemDTO }
        let r: Wrapper = try await request(
            baseURL.appendingPathComponent("api/journal/\(entryId)/checklist"),
            method: "POST", body: AddChecklistItemInput(text: text), decode: Wrapper.self)
        return r.item
    }

    /// PATCH /api/journal/checklist/:itemId
    struct UpdateChecklistItemInput: Codable, Sendable {
        public var text: String?
        public var completed: Bool?
        public var sortOrder: Int?
        private enum CodingKeys: String, CodingKey { case text, completed, sortOrder = "sort_order" }
        public init() {}
    }

    func updateChecklistItem(_ itemId: String, _ patch: UpdateChecklistItemInput)
      async throws -> JournalChecklistItemDTO {
        struct Wrapper: Codable { let item: JournalChecklistItemDTO }
        let r: Wrapper = try await request(
            baseURL.appendingPathComponent("api/journal/checklist/\(itemId)"),
            method: "PATCH", body: patch, decode: Wrapper.self)
        return r.item
    }

    /// DELETE /api/journal/checklist/:itemId
    func deleteChecklistItem(_ itemId: String) async throws {
        _ = try await request(baseURL.appendingPathComponent("api/journal/checklist/\(itemId)"),
                              method: "DELETE", decode: EmptyResponse.self)
    }

    /// GET /api/journal/retrospective?on=MM-DD
    func journalRetrospective(on anchor: String) async throws -> RetrospectiveResponseDTO {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/journal/retrospective"),
                                        resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "on", value: anchor)]
        return try await request(components.url!, method: "GET", decode: RetrospectiveResponseDTO.self)
    }
}

private struct PhotoWrapper: Codable { let photo: JournalEntryPhotoDTO }
```

If `multipartUpload(...)` and `EmptyResponse` don't already exist as internal helpers, find what `uploadSeedPhoto(...)` uses and either reuse it directly or extract the shared mechanics into an internal helper before calling here. Don't duplicate multipart-encoding logic.

- [ ] **Step 3: Write decode tests**

Create `SeedkeepKit/Tests/SeedkeepKitTests/JournalDecodeTests.swift`:

```swift
import Testing
import Foundation
@testable import SeedkeepKit

@Suite("Journal DTOs decode correctly")
struct JournalDecodeTests {
    @Test func entryRoundTrip() throws {
        let entry = JournalEntryDTO(
            id: "e1", householdId: "h1", occurredOn: "2026-05-24",
            body: "Planted Ozark Giant peppers.",
            seedId: nil, bedId: "b1", plantingEventId: nil,
            createdAt: 1234567890000, updatedAt: 1234567890000, deletedAt: nil)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(JournalEntryDTO.self, from: data)
        #expect(decoded == entry)
    }

    @Test func serverFeedShape() throws {
        // Wire shape that matches what `rowToDto` produces on the server.
        let json = """
        {
          "entries": [{
            "id": "e1", "householdId": "h1", "occurredOn": "2026-05-24",
            "body": "Test", "seedId": null, "bedId": "b1", "plantingEventId": null,
            "createdAt": 1234567890000, "updatedAt": 1234567890000, "deletedAt": null
          }]
        }
        """
        let r = try JSONDecoder().decode(JournalFeedResponseDTO.self, from: Data(json.utf8))
        #expect(r.entries.count == 1)
        #expect(r.entries[0].bedId == "b1")
        #expect(r.entries[0].seedId == nil)
    }

    @Test func retrospectiveShape() throws {
        let json = """
        {
          "anchor": "05-24",
          "years": [
            {"year": 2025, "entries": []},
            {"year": 2024, "entries": []}
          ]
        }
        """
        let r = try JSONDecoder().decode(RetrospectiveResponseDTO.self, from: Data(json.utf8))
        #expect(r.years.map(\.year) == [2025, 2024])
    }
}
```

- [ ] **Step 4: Run kit tests**

Run: `cd SeedkeepKit && swift test`
Expected: all tests pass, including the 3 new journal decode tests.

- [ ] **Step 5: Commit**

```bash
git add SeedkeepKit/
git commit -m "SeedkeepKit: add Journal DTOs + client methods (11 routes)"
```

---

## Task 2: SwiftData models + mapping

**Files:**
- Create: `Seedkeep/Core/Models/LocalJournalEntry.swift`
- Create: `Seedkeep/Core/Models/LocalJournalEntryPhoto.swift`
- Create: `Seedkeep/Core/Models/LocalJournalChecklistItem.swift`
- Modify: `Seedkeep/Core/Models/Mapping.swift`
- Modify: `Seedkeep/App/AppEnvironment.swift`

- [ ] **Step 1: Write `LocalJournalEntry`**

Create `Seedkeep/Core/Models/LocalJournalEntry.swift`:

```swift
import Foundation
import SwiftData

/// One journal entry — text body, optional attached entity (at most one of
/// seed/bed/plantingEvent), optional photos + checklist items (children).
///
/// Children are not modeled as `@Relationship` arrays here — SwiftData's
/// inverse-relationship migrations cost more than they save us, and the
/// sync engine treats each entity type as its own delta-sync table anyway.
/// Children fetch on demand via `@Query` with a predicate on entryID.
@Model
final class LocalJournalEntry {
    @Attribute(.unique) var id: String
    var householdID: String
    var occurredOn: String                 // 'YYYY-MM-DD'
    var body: String
    var seedID: String?
    var bedID: String?
    var plantingEventID: String?
    var createdAt: Int64
    var updatedAt: Int64
    var deletedAt: Int64?

    init(id: String, householdID: String, occurredOn: String, body: String,
         seedID: String?, bedID: String?, plantingEventID: String?,
         createdAt: Int64, updatedAt: Int64, deletedAt: Int64?) {
        self.id = id; self.householdID = householdID
        self.occurredOn = occurredOn; self.body = body
        self.seedID = seedID; self.bedID = bedID; self.plantingEventID = plantingEventID
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Which entity this entry is attached to, derived from the FK columns.
    enum ParentKind: Equatable {
        case seed(String)
        case bed(String)
        case plantingEvent(String)
        case garden
    }

    var parentKind: ParentKind {
        if let id = seedID { return .seed(id) }
        if let id = bedID { return .bed(id) }
        if let id = plantingEventID { return .plantingEvent(id) }
        return .garden
    }
}
```

- [ ] **Step 2: Write the photo + checklist models**

Create `Seedkeep/Core/Models/LocalJournalEntryPhoto.swift`:

```swift
import Foundation
import SwiftData

@Model
final class LocalJournalEntryPhoto {
    @Attribute(.unique) var id: String
    var entryID: String
    var storageKey: String                 // S3 key — image URL is derived
    var sortOrder: Int
    var width: Int?
    var height: Int?
    var createdAt: Int64

    init(id: String, entryID: String, storageKey: String, sortOrder: Int,
         width: Int?, height: Int?, createdAt: Int64) {
        self.id = id; self.entryID = entryID; self.storageKey = storageKey
        self.sortOrder = sortOrder; self.width = width; self.height = height
        self.createdAt = createdAt
    }
}
```

Create `Seedkeep/Core/Models/LocalJournalChecklistItem.swift`:

```swift
import Foundation
import SwiftData

@Model
final class LocalJournalChecklistItem {
    @Attribute(.unique) var id: String
    var entryID: String
    var text: String
    var completed: Bool
    var sortOrder: Int
    var updatedAt: Int64

    init(id: String, entryID: String, text: String, completed: Bool,
         sortOrder: Int, updatedAt: Int64) {
        self.id = id; self.entryID = entryID; self.text = text
        self.completed = completed; self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 3: Add DTO↔Model mapping**

Modify `Seedkeep/Core/Models/Mapping.swift`. Find the existing pattern (it should have `RecommendationDTO`-style extensions) and add at the bottom:

```swift
// MARK: - JournalEntry

extension JournalEntryDTO {
    func makeLocal() -> LocalJournalEntry {
        LocalJournalEntry(
            id: id, householdID: householdId, occurredOn: occurredOn, body: body,
            seedID: seedId, bedID: bedId, plantingEventID: plantingEventId,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    func apply(to local: LocalJournalEntry) {
        local.householdID = householdId; local.occurredOn = occurredOn; local.body = body
        local.seedID = seedId; local.bedID = bedId; local.plantingEventID = plantingEventId
        local.createdAt = createdAt; local.updatedAt = updatedAt; local.deletedAt = deletedAt
    }
}

extension JournalEntryPhotoDTO {
    func makeLocal() -> LocalJournalEntryPhoto {
        LocalJournalEntryPhoto(
            id: id, entryID: entryId, storageKey: storageKey, sortOrder: sortOrder,
            width: width, height: height, createdAt: createdAt)
    }
    func apply(to local: LocalJournalEntryPhoto) {
        local.entryID = entryId; local.storageKey = storageKey; local.sortOrder = sortOrder
        local.width = width; local.height = height; local.createdAt = createdAt
    }
}

extension JournalChecklistItemDTO {
    func makeLocal() -> LocalJournalChecklistItem {
        LocalJournalChecklistItem(
            id: id, entryID: entryId, text: text, completed: completed,
            sortOrder: sortOrder, updatedAt: updatedAt)
    }
    func apply(to local: LocalJournalChecklistItem) {
        local.entryID = entryId; local.text = text; local.completed = completed
        local.sortOrder = sortOrder; local.updatedAt = updatedAt
    }
}
```

- [ ] **Step 4: Register the new models**

Modify `Seedkeep/App/AppEnvironment.swift`. Find `makeModelContainer()` and the `Schema([...])` call inside. Add the three new types to the schema array:

```swift
let schema = Schema([
    LocalSeed.self,
    LocalSeedPhoto.self,
    LocalTag.self,
    LocalLocation.self,
    LocalBed.self,
    LocalPlantingEvent.self,
    LocalPendingWrite.self,
    LocalSyncCursor.self,
    LocalRecommendation.self,
    LocalJournalEntry.self,            // NEW
    LocalJournalEntryPhoto.self,       // NEW
    LocalJournalChecklistItem.self,    // NEW
])
```

- [ ] **Step 5: Build + test**

Run: `xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

Run: `cd SeedkeepKit && swift test` — passes (no regressions).

- [ ] **Step 6: Commit**

```bash
git add Seedkeep/Core/Models/ Seedkeep/App/AppEnvironment.swift
git commit -m "Add LocalJournalEntry/Photo/ChecklistItem SwiftData models + mapping"
```

---

## Task 3: Sync engine extension

**Files:**
- Modify: the iOS sync engine (find via `grep -rln "delta.*sync\|SyncEngine" Seedkeep/ | head`)

- [ ] **Step 1: Locate the sync entry point**

Find the file that owns the delta-sync drain. Likely candidates: `Seedkeep/Core/Sync/SyncEngine.swift`, `Seedkeep/Core/Sync/SyncCoordinator.swift`. Look for where existing entity types (seeds, beds, planting_events) are drained from the sync envelope.

- [ ] **Step 2: Add the three new entity types**

Pattern (the exact API surface depends on what the existing engine looks like — match its existing shape). For each entity type, the drain function should:
1. Look up an existing `LocalX` by id.
2. If found, `dto.apply(to: existing)`.
3. If not found, insert `dto.makeLocal()`.
4. Update the sync cursor watermark.

Concrete code, assuming the engine has a generic `drain<DTO, Local>` helper:

```swift
// In whatever function drains the sync response envelope, after the
// existing seeds/beds/events drains:

try drain(
    response.journalEntries,
    cursorKey: "journal_entries",
    fetch: { id in
        try modelContext.fetch(FetchDescriptor<LocalJournalEntry>(
            predicate: #Predicate { $0.id == id })).first
    },
    insert: { dto in modelContext.insert(dto.makeLocal()) },
    update: { dto, local in dto.apply(to: local) }
)
try drain(
    response.journalEntryPhotos,
    cursorKey: "journal_entry_photos",
    fetch: { id in
        try modelContext.fetch(FetchDescriptor<LocalJournalEntryPhoto>(
            predicate: #Predicate { $0.id == id })).first
    },
    insert: { dto in modelContext.insert(dto.makeLocal()) },
    update: { dto, local in dto.apply(to: local) }
)
try drain(
    response.journalChecklistItems,
    cursorKey: "journal_checklist_items",
    fetch: { id in
        try modelContext.fetch(FetchDescriptor<LocalJournalChecklistItem>(
            predicate: #Predicate { $0.id == id })).first
    },
    insert: { dto in modelContext.insert(dto.makeLocal()) },
    update: { dto, local in dto.apply(to: local) }
)
```

If the sync engine doesn't have a `drain<>` helper, follow the explicit pattern used for seeds/beds — inline the fetch-or-insert-or-update logic.

- [ ] **Step 3: Handle soft-delete of journal entries**

When an entry is soft-deleted on the server, its `deleted_at` becomes non-null. The local model should mirror that (its `deletedAt` is settable). On read, views filter `deletedAt == nil`.

When an entry is soft-deleted, its child photos + checklist items were CASCADE-removed server-side. On the sync, the iOS client needs to mirror this. Pick the approach that matches what existing entity relationships do (e.g. how seed_photos handles a deleted seed):

- **Option A**: After applying a DTO with `deletedAt != nil`, query + hard-delete local children whose `entryID == dto.id`.
- **Option B**: Trust the server to also include the children in the sync response with their own deletion signal.

Choose A unless B is already the established pattern.

- [ ] **Step 4: Build + run**

Run: `xcodebuild ... build -quiet | tail -10` — must succeed.

- [ ] **Step 5: Commit**

```bash
git add Seedkeep/Core/Sync/
git commit -m "Extend SyncEngine to drain journal entries, photos, checklist items"
```

---

## Task 4: JournalStore + new top-level Journal tab + read-only feed

**Files:**
- Create: `Seedkeep/Core/Journal/JournalStore.swift`
- Create: `Seedkeep/Features/Journal/JournalView.swift`
- Modify: `Seedkeep/App/AppEnvironment.swift` (construct the store)
- Modify: the file owning the root TabView (find via `grep -rln "TabView" Seedkeep/App/`)

- [ ] **Step 1: Write `JournalStore`**

Create `Seedkeep/Core/Journal/JournalStore.swift`:

```swift
import Foundation
import SwiftData
import SeedkeepKit

@MainActor
@Observable
final class JournalStore {
    private let client: SeedkeepClient
    private let modelContext: ModelContext
    private(set) var isLoading = false
    private(set) var lastError: String?

    init(client: SeedkeepClient, modelContext: ModelContext) {
        self.client = client; self.modelContext = modelContext
    }

    /// Fetch the latest server feed and merge into the local store.
    /// Views use `@Query` to read from SwiftData; this method just refills.
    func refresh(seedID: String? = nil, bedID: String? = nil,
                 plantingEventID: String? = nil) async {
        isLoading = true; defer { isLoading = false }
        do {
            let dto = try await client.journalFeed(
                seedId: seedID, bedId: bedID, plantingEventId: plantingEventID,
                limit: 200)
            for entry in dto.entries {
                let id = entry.id
                let existing = try modelContext.fetch(FetchDescriptor<LocalJournalEntry>(
                    predicate: #Predicate { $0.id == id })).first
                if let existing { entry.apply(to: existing) }
                else { modelContext.insert(entry.makeLocal()) }
            }
            try modelContext.save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Optimistic create — inserts the local model immediately, then awaits
    /// the server response and reconciles the ID. Returns the local model
    /// so the caller (entry editor) can navigate to it.
    func create(occurredOn: String, body: String,
                seedID: String? = nil, bedID: String? = nil,
                plantingEventID: String? = nil) async throws -> LocalJournalEntry {
        let dto = try await client.createJournalEntry(.init(
            occurredOn: occurredOn, body: body,
            seedId: seedID, bedId: bedID, plantingEventId: plantingEventID))
        let local = dto.makeLocal()
        modelContext.insert(local)
        try modelContext.save()
        return local
    }

    /// Soft-delete on server, mirror locally.
    func softDelete(_ entry: LocalJournalEntry) async throws {
        try await client.deleteJournalEntry(entry.id)
        entry.deletedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try modelContext.save()
    }

    /// Retrospective fetch (anchor MM-DD).
    func retrospective(on anchor: String) async throws -> RetrospectiveResponseDTO {
        try await client.journalRetrospective(on: anchor)
    }
}
```

- [ ] **Step 2: Construct in AppEnvironment**

Modify `Seedkeep/App/AppEnvironment.swift`. Add a `journal: JournalStore` property and construct it alongside the existing stores (`recommendations`, `sync`, etc.):

```swift
public let journal: JournalStore

// In the initializer / build function, after `recommendations` is constructed:
self.journal = JournalStore(client: client, modelContext: modelContainer.mainContext)
```

- [ ] **Step 3: Write `JournalView`**

Create `Seedkeep/Features/Journal/JournalView.swift`. Read-only feed with filter chips. Create entry button added in Task 5.

```swift
import SwiftUI
import SwiftData

struct JournalView: View {
    @Environment(AppEnvironment.self) private var appEnv

    @Query(filter: #Predicate<LocalJournalEntry> { $0.deletedAt == nil },
           sort: \.occurredOn, order: .reverse)
    private var entries: [LocalJournalEntry]

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "Start your garden journal",
                        systemImage: "book.closed",
                        description: Text("Track what happened in the garden over time. Tap + to add your first entry.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry.id) {
                            entryRow(entry)
                        }
                    }
                }
            }
            .navigationTitle("Journal")
            .navigationDestination(for: String.self) { id in
                // JournalEntryView added in Task 5
                Text("Entry detail — TBD in Task 5: \(id)")
            }
            .refreshable {
                await appEnv.journal.refresh()
            }
            .task {
                await appEnv.journal.refresh()
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LocalJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.occurredOn)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.body.isEmpty ? "(empty)" : entry.body)
                .font(.body)
                .lineLimit(3)
        }
    }
}
```

- [ ] **Step 4: Add the Journal tab to root navigation**

Modify the root TabView. Add the new tab between Garden and Settings:

```swift
TabView {
    // ... existing tabs ...

    JournalView()
        .tabItem { Label("Journal", systemImage: "book") }
        .tag(AppTab.journal)            // adjust to whatever enum the codebase uses

    // ... settings tab ...
}
```

If there's an `AppTab` enum, add `case journal` to it. Otherwise just add the tab inline.

- [ ] **Step 5: Build + run on simulator**

Run: `xcodebuild ... build -quiet | tail -10`
Expected: success. Run the app and confirm the Journal tab is visible in the tab bar.

- [ ] **Step 6: Commit**

```bash
git add Seedkeep/Core/Journal/ Seedkeep/Features/Journal/ Seedkeep/App/
git commit -m "Add Journal tab + read-only feed view + JournalStore"
```

---

## Task 5: JournalEntryView — create + edit (text + entity picker)

**Files:**
- Create: `Seedkeep/Features/Journal/JournalEntryView.swift`
- Create: `Seedkeep/Features/Journal/AttachedEntityPicker.swift`
- Modify: `Seedkeep/Features/Journal/JournalView.swift` (wire navigation + "+ new entry" button)

- [ ] **Step 1: Write `AttachedEntityPicker`**

Create `Seedkeep/Features/Journal/AttachedEntityPicker.swift`:

```swift
import SwiftUI
import SwiftData

/// Lets the user attach the entry to None / a Seed / a Bed / a Planting event.
/// Backing storage is three nullable IDs on the LocalJournalEntry — exactly
/// one (or zero) is set at a time.
struct AttachedEntityPicker: View {
    @Binding var seedID: String?
    @Binding var bedID: String?
    @Binding var plantingEventID: String?

    @Query(filter: #Predicate<LocalSeed> { $0.deletedAt == nil },
           sort: \.customName) private var seeds: [LocalSeed]
    @Query(filter: #Predicate<LocalBed> { $0.deletedAt == nil },
           sort: \.sortOrder) private var beds: [LocalBed]
    @Query(filter: #Predicate<LocalPlantingEvent> { $0.deletedAt == nil },
           sort: \.plannedFor, order: .reverse) private var events: [LocalPlantingEvent]

    enum Choice: Hashable {
        case none, seed(String), bed(String), plantingEvent(String)
    }

    private var current: Choice {
        if let id = seedID { return .seed(id) }
        if let id = bedID { return .bed(id) }
        if let id = plantingEventID { return .plantingEvent(id) }
        return .none
    }

    var body: some View {
        Picker("Attached to", selection: Binding(
            get: { current },
            set: { newValue in
                seedID = nil; bedID = nil; plantingEventID = nil
                switch newValue {
                case .none: break
                case .seed(let id): seedID = id
                case .bed(let id): bedID = id
                case .plantingEvent(let id): plantingEventID = id
                }
            }
        )) {
            Text("Garden (none)").tag(Choice.none)
            Section("Seeds") {
                ForEach(seeds) { s in
                    Text(s.customName ?? "Unnamed seed").tag(Choice.seed(s.id))
                }
            }
            Section("Beds") {
                ForEach(beds) { b in Text(b.name).tag(Choice.bed(b.id)) }
            }
            Section("Recent plantings") {
                ForEach(events.prefix(20).map { $0 }) { e in
                    Text("\(e.kind.rawValue) · \(e.plannedFor)").tag(Choice.plantingEvent(e.id))
                }
            }
        }
    }
}
```

- [ ] **Step 2: Write `JournalEntryView`**

Create `Seedkeep/Features/Journal/JournalEntryView.swift`. This is the create/edit detail view; photos + checklist UI are added in later tasks (Steps below scaffold their slots).

```swift
import SwiftUI
import SwiftData

struct JournalEntryView: View {
    let entryID: String?     // nil = creating new, non-nil = editing existing

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var occurredOn: Date = Date()
    @State private var body: String = ""
    @State private var seedID: String?
    @State private var bedID: String?
    @State private var plantingEventID: String?
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Date") {
                DatePicker("Occurred on", selection: $occurredOn, displayedComponents: .date)
            }
            Section("Entry") {
                TextField("What happened?", text: $body, axis: .vertical)
                    .lineLimit(3...12)
            }
            Section {
                AttachedEntityPicker(
                    seedID: $seedID, bedID: $bedID, plantingEventID: $plantingEventID)
            } header: { Text("Attached to") }

            // PHOTOS — added in Task 7
            // CHECKLIST — added in Task 8

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(entryID == nil ? "New entry" : "Edit entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || body.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(saving)
            }
        }
        .task {
            if let id = entryID,
               let existing = try? modelContext.fetch(FetchDescriptor<LocalJournalEntry>(
                    predicate: #Predicate { $0.id == id })).first {
                load(from: existing)
            }
        }
    }

    private func load(from entry: LocalJournalEntry) {
        if let date = Self.parseYYYYMMDD(entry.occurredOn) { occurredOn = date }
        body = entry.body
        seedID = entry.seedID; bedID = entry.bedID; plantingEventID = entry.plantingEventID
    }

    private func save() async {
        saving = true; errorMessage = nil; defer { saving = false }
        let dateStr = Self.yyyymmdd(occurredOn)
        do {
            if let id = entryID,
               let local = try? modelContext.fetch(FetchDescriptor<LocalJournalEntry>(
                    predicate: #Predicate { $0.id == id })).first {
                var patch = SeedkeepClient.UpdateJournalEntryInput()
                patch.occurredOn = dateStr
                patch.body = body
                patch.seedId = .some(seedID)
                patch.bedId = .some(bedID)
                patch.plantingEventId = .some(plantingEventID)
                let dto = try await appEnv.client.updateJournalEntry(local.id, patch)
                dto.apply(to: local); try modelContext.save()
            } else {
                _ = try await appEnv.journal.create(
                    occurredOn: dateStr, body: body,
                    seedID: seedID, bedID: bedID, plantingEventID: plantingEventID)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func yyyymmdd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: date)
    }

    static func parseYYYYMMDD(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.date(from: s)
    }
}
```

- [ ] **Step 3: Wire navigation + "+ new entry" button into `JournalView`**

Modify `Seedkeep/Features/Journal/JournalView.swift`. Replace the placeholder navigation destination + add a toolbar:

```swift
.navigationDestination(for: String.self) { id in
    JournalEntryView(entryID: id)
}
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        NavigationLink(value: NewEntryRoute.new) {
            Label("New entry", systemImage: "plus")
        }
    }
}
.navigationDestination(for: NewEntryRoute.self) { _ in
    JournalEntryView(entryID: nil)
}

// ... near the bottom of the file
enum NewEntryRoute: Hashable { case new }
```

- [ ] **Step 4: Build + run**

Run: `xcodebuild ... build -quiet | tail -10`
Expected: success. Run the app, tap the Journal tab, tap "+", create an entry, see it appear in the feed after dismiss.

- [ ] **Step 5: Commit**

```bash
git add Seedkeep/Features/Journal/
git commit -m "Add JournalEntryView (create + edit, text body, entity picker)"
```

---

## Task 6: Entity-scoped journal sections in SeedDetail / BedDetail / PlantingEvent

**Files:**
- Create: `Seedkeep/Features/Journal/EntityScopedJournalSection.swift`
- Modify: `Seedkeep/Features/SeedDetail/SeedDetailView.swift`
- Modify: `Seedkeep/Features/Garden/BedDetailView.swift`
- Modify: `Seedkeep/Features/Garden/AddPlantingEventView.swift` (or wherever the event-detail surface is)

- [ ] **Step 1: Write the scoped section**

Create `Seedkeep/Features/Journal/EntityScopedJournalSection.swift`:

```swift
import SwiftUI
import SwiftData

/// Collapsible "Journal" section for embedding inside a parent entity's
/// detail view. Shows the most recent N entries for that entity with a
/// "See all" link that pushes the full Journal tab pre-filtered.
struct EntityScopedJournalSection: View {
    enum Parent: Equatable {
        case seed(String)
        case bed(String)
        case plantingEvent(String)
    }

    let parent: Parent
    var maxEntries: Int = 3

    @Query private var entries: [LocalJournalEntry]

    init(parent: Parent, maxEntries: Int = 3) {
        self.parent = parent
        self.maxEntries = maxEntries
        let predicate: Predicate<LocalJournalEntry>
        switch parent {
        case .seed(let id):
            predicate = #Predicate { $0.seedID == id && $0.deletedAt == nil }
        case .bed(let id):
            predicate = #Predicate { $0.bedID == id && $0.deletedAt == nil }
        case .plantingEvent(let id):
            predicate = #Predicate { $0.plantingEventID == id && $0.deletedAt == nil }
        }
        _entries = Query(filter: predicate, sort: \.occurredOn, order: .reverse)
    }

    var body: some View {
        Section("Journal") {
            if entries.isEmpty {
                Text("No entries yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(maxEntries)) { entry in
                    NavigationLink(value: entry.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.occurredOn).font(.caption).foregroundStyle(.secondary)
                            Text(entry.body).font(.body).lineLimit(2)
                        }
                    }
                }
                if entries.count > maxEntries {
                    Text("\(entries.count - maxEntries) more")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                // Push the Journal tab pre-filtered. The pre-filter is conveyed
                // via the destination, not state, so navigating back doesn't
                // leave stale filters.
                JournalView(filterParent: parent)
            } label: {
                Label("See all journal entries", systemImage: "book")
                    .font(.footnote)
            }
        }
    }
}
```

- [ ] **Step 2: Update `JournalView` to accept an optional filter parent**

Modify `Seedkeep/Features/Journal/JournalView.swift`:

```swift
struct JournalView: View {
    var filterParent: EntityScopedJournalSection.Parent? = nil

    // ... existing properties

    // Change the @Query to be filter-aware:
    @Query private var entries: [LocalJournalEntry]

    init(filterParent: EntityScopedJournalSection.Parent? = nil) {
        self.filterParent = filterParent
        let predicate: Predicate<LocalJournalEntry>
        switch filterParent {
        case .none:
            predicate = #Predicate { $0.deletedAt == nil }
        case .seed(let id):
            predicate = #Predicate { $0.seedID == id && $0.deletedAt == nil }
        case .bed(let id):
            predicate = #Predicate { $0.bedID == id && $0.deletedAt == nil }
        case .plantingEvent(let id):
            predicate = #Predicate { $0.plantingEventID == id && $0.deletedAt == nil }
        }
        _entries = Query(filter: predicate, sort: \.occurredOn, order: .reverse)
    }

    // ... body uses `entries` as before
}
```

- [ ] **Step 3: Mount the section in detail views**

In `SeedDetailView.swift`, find the Form body and add at an appropriate place (probably between the existing identity section and the catalog section):

```swift
EntityScopedJournalSection(parent: .seed(seed.id))
```

In `BedDetailView.swift`:

```swift
EntityScopedJournalSection(parent: .bed(bed.id))
```

For planting events: if there's a separate detail view, add the section there. If the existing flow is just edit-in-place (`AddPlantingEventView`), add the section near the bottom of the form (visible only when editing an existing event, not creating a new one).

- [ ] **Step 4: Build + run + verify in simulator**

Open a seed → see Journal section (empty initially) → tap "See all" → arrive on filtered Journal tab.

- [ ] **Step 5: Commit**

```bash
git add Seedkeep/Features/Journal/EntityScopedJournalSection.swift \
        Seedkeep/Features/Journal/JournalView.swift \
        Seedkeep/Features/SeedDetail/SeedDetailView.swift \
        Seedkeep/Features/Garden/BedDetailView.swift \
        Seedkeep/Features/Garden/AddPlantingEventView.swift
git commit -m "Add EntityScopedJournalSection + mount in seed/bed/event detail"
```

---

## Task 7: Photo gallery in JournalEntryView

**Files:**
- Modify: `Seedkeep/Features/Journal/JournalEntryView.swift`
- (Maybe extract) `Seedkeep/Features/Journal/JournalPhotoGallery.swift` — if the photo logic grows beyond 80 lines, lift into its own file.

- [ ] **Step 1: Add photo gallery section**

Modify `JournalEntryView.swift`. Add after the "Attached to" section, before checklist (which is Task 8):

```swift
@Query private var photos: [LocalJournalEntryPhoto]
@State private var photosPickerItems: [PhotosPickerItem] = []
@State private var uploadingPhotos: Bool = false

// In the init, scope the photos query by entry id:
init(entryID: String?) {
    self.entryID = entryID
    let id = entryID ?? "__none__"   // empty query when creating new
    _photos = Query(filter: #Predicate<LocalJournalEntryPhoto> { $0.entryID == id },
                    sort: \.sortOrder)
}

// In the Form body, add a new section between AttachedEntityPicker and (future) checklist:
Section("Photos") {
    if photos.isEmpty && entryID == nil {
        Text("Save the entry to attach photos")
            .font(.footnote)
            .foregroundStyle(.secondary)
    } else {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    photoThumb(photo)
                }
            }
        }
        PhotosPicker(
            selection: $photosPickerItems,
            maxSelectionCount: 5,
            matching: .images
        ) {
            Label(uploadingPhotos ? "Uploading…" : "Add photos",
                  systemImage: "photo.badge.plus")
        }
        .disabled(uploadingPhotos || entryID == nil)
        .onChange(of: photosPickerItems) { _, newItems in
            guard !newItems.isEmpty, let entryID else { return }
            Task { await uploadPicked(newItems, entryID: entryID) }
        }
    }
}

@ViewBuilder
private func photoThumb(_ photo: LocalJournalEntryPhoto) -> some View {
    AsyncImage(url: appEnv.client.photoURL(forStorageKey: photo.storageKey)) { phase in
        switch phase {
        case .success(let img): img.resizable().scaledToFill()
        case .empty: ProgressView()
        case .failure: Image(systemName: "photo")
        @unknown default: Image(systemName: "photo")
        }
    }
    .frame(width: 88, height: 88)
    .clipShape(.rect(cornerRadius: 8))
    .contextMenu {
        Button(role: .destructive) {
            Task { await deletePhoto(photo) }
        } label: { Label("Delete photo", systemImage: "trash") }
    }
}

@MainActor
private func uploadPicked(_ items: [PhotosPickerItem], entryID: String) async {
    uploadingPhotos = true; defer { uploadingPhotos = false; photosPickerItems = [] }
    for item in items {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { continue }
            // Reuse the shared resize helper from ScanFlow.swift (commit cbbb991).
            // If `resizedJPEG` isn't visible from this file, import its module
            // or expose it via a small public function in Seedkeep/Core/Photos/.
            let (jpeg, width, height) = await Self.resizedJPEG(from: data)
            let dto = try await appEnv.client.uploadJournalPhoto(
                entryId: entryID, jpegData: jpeg, width: width, height: height)
            modelContext.insert(dto.makeLocal())
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func deletePhoto(_ photo: LocalJournalEntryPhoto) async {
    do {
        try await appEnv.client.deleteJournalPhoto(photo.id)
        modelContext.delete(photo)
        try modelContext.save()
    } catch {
        errorMessage = error.localizedDescription
    }
}

/// Wraps the existing scan-flow resize helper. Re-uses the off-MainActor
/// resize pipeline from ScanFlow.swift commit `cbbb991` so the UI stays
/// responsive while big-image JPEG encoding runs on a detached task.
nonisolated static func resizedJPEG(from data: Data) async -> (Data, Int, Int) {
    // Implementation reuses the existing ScanFlow helpers. If those helpers
    // aren't accessible from here, the cleanest move is to lift them into
    // `Seedkeep/Core/Photos/PhotoResize.swift` as `nonisolated` functions
    // and import from both call sites. See Task 7 Step 0 below.
    fatalError("Wire to Seedkeep/Core/Photos/PhotoResize.swift — see Step 0")
}
```

- [ ] **Step 0: Lift the resize helper into a shared module (if not already shared)**

Check whether `ScanFlow.swift`'s `resizedJPEG` is already in a shared module. If it's still local to `ScanFlow.swift`:

1. Create `Seedkeep/Core/Photos/PhotoResize.swift` and move the helper there (`nonisolated` function, returns `(Data, Int, Int)`).
2. Update `ScanFlow.swift` to import from the new location.
3. Then `JournalEntryView` and the scan flow share the same code path.

This is a refactor-as-you-touch-it — it pays back the moment a third photo surface lands (Phase 5 sensors, etc.).

- [ ] **Step 2: Build + run**

Run: `xcodebuild ... build -quiet | tail -15` — must succeed. Pick a few photos; confirm they upload, appear in the gallery, and survive a kill-relaunch.

- [ ] **Step 3: Commit**

```bash
git add Seedkeep/Features/Journal/JournalEntryView.swift \
        Seedkeep/Core/Photos/PhotoResize.swift \
        Seedkeep/Features/Scan/ScanFlow.swift
git commit -m "Add photo gallery to JournalEntryView; lift resize helper to shared module"
```

---

## Task 8: Checklist UI in JournalEntryView

**Files:**
- Modify: `Seedkeep/Features/Journal/JournalEntryView.swift`

- [ ] **Step 1: Add checklist state + section**

Modify `JournalEntryView.swift`. Add after the Photos section:

```swift
@Query private var checklistItems: [LocalJournalChecklistItem]
@State private var newItemText: String = ""

// In init, scope checklist by entry id:
let id = entryID ?? "__none__"
_checklistItems = Query(filter: #Predicate<LocalJournalChecklistItem> { $0.entryID == id },
                        sort: \.sortOrder)

// New section in the Form body:
Section("Checklist") {
    if checklistItems.isEmpty && entryID == nil {
        Text("Save the entry to add checklist items")
            .font(.footnote)
            .foregroundStyle(.secondary)
    } else {
        ForEach(checklistItems) { item in
            checklistRow(item)
        }
        if let entryID {
            HStack {
                TextField("New item", text: $newItemText)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await addItem(entryID: entryID) } }
                Button {
                    Task { await addItem(entryID: entryID) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newItemText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

@ViewBuilder
private func checklistRow(_ item: LocalJournalChecklistItem) -> some View {
    HStack {
        Button {
            Task { await toggle(item) }
        } label: {
            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.completed ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        Text(item.text)
            .strikethrough(item.completed, color: .secondary)
            .foregroundStyle(item.completed ? .secondary : .primary)
        Spacer()
    }
    .swipeActions(edge: .trailing) {
        Button(role: .destructive) {
            Task { await deleteItem(item) }
        } label: { Label("Delete", systemImage: "trash") }
    }
}

private func addItem(entryID: String) async {
    let text = newItemText.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    do {
        let dto = try await appEnv.client.addChecklistItem(entryId: entryID, text: text)
        modelContext.insert(dto.makeLocal())
        try modelContext.save()
        newItemText = ""
    } catch {
        errorMessage = error.localizedDescription
    }
}

private func toggle(_ item: LocalJournalChecklistItem) async {
    let newCompleted = !item.completed
    do {
        var patch = SeedkeepClient.UpdateChecklistItemInput()
        patch.completed = newCompleted
        let dto = try await appEnv.client.updateChecklistItem(item.id, patch)
        dto.apply(to: item)
        try modelContext.save()
    } catch {
        errorMessage = error.localizedDescription
    }
}

private func deleteItem(_ item: LocalJournalChecklistItem) async {
    do {
        try await appEnv.client.deleteChecklistItem(item.id)
        modelContext.delete(item)
        try modelContext.save()
    } catch {
        errorMessage = error.localizedDescription
    }
}
```

- [ ] **Step 2: Build + verify**

Run: `xcodebuild ... build -quiet | tail -10`
In the simulator: add an entry, toggle two checklist items, delete one. Confirm sync round-trips.

- [ ] **Step 3: Commit**

```bash
git add Seedkeep/Features/Journal/JournalEntryView.swift
git commit -m "Add checklist UI to JournalEntryView (add/toggle/delete/swipe)"
```

---

## Task 9: Retrospective card at the top of the feed

**Files:**
- Create: `Seedkeep/Features/Journal/RetrospectiveCard.swift`
- Modify: `Seedkeep/Features/Journal/JournalView.swift`

- [ ] **Step 1: Write `RetrospectiveCard`**

Create `Seedkeep/Features/Journal/RetrospectiveCard.swift`:

```swift
import SwiftUI
import SeedkeepKit

/// Top-of-feed card that surfaces journal entries from the same MM-DD in
/// prior years. Hidden when the user has no prior-year data near today.
struct RetrospectiveCard: View {
    @Environment(AppEnvironment.self) private var appEnv
    @State private var response: RetrospectiveResponseDTO?
    @State private var loading = false

    private static var todayAnchor: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: Date())
    }

    var body: some View {
        Group {
            if let response, !response.years.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.tint)
                        Text("Today in your garden")
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(response.years, id: \.year) { yearBlock in
                        DisclosureGroup {
                            ForEach(yearBlock.entries, id: \.id) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.occurredOn).font(.caption).foregroundStyle(.secondary)
                                    Text(entry.body).font(.body).lineLimit(3)
                                }
                                .padding(.vertical, 2)
                            }
                        } label: {
                            Text("\(String(yearBlock.year)) · \(yearBlock.entries.count) " +
                                 "\(yearBlock.entries.count == 1 ? "entry" : "entries")")
                                .font(.footnote)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            response = try await appEnv.journal.retrospective(on: Self.todayAnchor)
        } catch {
            response = nil
        }
    }
}
```

- [ ] **Step 2: Mount the card at the top of `JournalView`**

Modify `JournalView.swift`. Add the card as a non-filtered top item (only on the unfiltered feed, not when filter parent is set):

```swift
List {
    if filterParent == nil {
        RetrospectiveCard()
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
    }
    // ... existing content
}
```

- [ ] **Step 3: Build + verify (no prior data → card hidden)**

Run + verify the card is hidden in the simulator (first-year garden). To test the populated case, manually insert a `LocalJournalEntry` with `occurredOn` set to a prior-year MM-DD matching today (e.g. if today is May 24, set `occurredOn` to `2025-05-24`), sync push, and reload — confirm the card appears.

- [ ] **Step 4: Commit**

```bash
git add Seedkeep/Features/Journal/RetrospectiveCard.swift Seedkeep/Features/Journal/JournalView.swift
git commit -m "Add RetrospectiveCard to top of Journal feed"
```

---

## Task 10: TestFlight cut + device verification

**Files:**
- Bumps `project.yml` via `scripts/release.sh`.

- [ ] **Step 1: Final gate — build + tests**

Run all three:

```bash
xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' build -quiet 2>&1 | tail -5
cd SeedkeepKit && swift test
cd .. && xcodebuild -scheme Seedkeep -destination 'generic/platform=iOS Simulator' test -quiet 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED, all kit tests pass, all app tests pass.

- [ ] **Step 2: Push main**

```bash
git push origin main
```

- [ ] **Step 3: Cut TestFlight build**

```bash
./scripts/release.sh --minor    # 0.2.X → 0.3.0
```

Expected output: `Bumping version (minor)`, `Archiving Release for generic iOS`, `** ARCHIVE SUCCEEDED **`, `** EXPORT SUCCEEDED **`, `Seedkeep 0.3.0 (build N) uploaded to TestFlight`. The script auto-commits the version bump on success.

- [ ] **Step 4: Push the release commit**

```bash
git push origin main
```

- [ ] **Step 5: Wait for TestFlight processing + on-device verify**

Once App Store Connect shows the build as ready:

1. Install build N on a real device via TestFlight.
2. Verify each surface end-to-end against `seedkeep-server.fly.dev`:
   - Journal tab visible, empty state shows.
   - "+" → create an entry → reload → entry appears.
   - Tap entry → edit → save → change persists.
   - Add 2 photos → upload → confirm thumbnails render.
   - Add 3 checklist items → toggle 2 → confirm completed state persists across kill-relaunch.
   - Open a seed with a journal entry → confirm `EntityScopedJournalSection` shows the entry.
   - "See all" link from the section → confirm filtered Journal tab opens.
   - Migrated legacy `kind='note'` entries (if any existed on prod) — confirm they appear in the feed.

- [ ] **Step 6: Update AI docs**

Edit `.docs/ai/current-state.md`:

```markdown
**Date**: YYYY-MM-DD — Phase 3 (Journal) shipped to TestFlight (build N, 0.3.0)

- Three new SwiftData models: LocalJournalEntry, LocalJournalEntryPhoto, LocalJournalChecklistItem.
- New top-level Journal tab with chronological feed + retrospective card.
- JournalEntryView: text body + entity picker + photo gallery + checklist UI.
- EntityScopedJournalSection mounted in seed/bed/planting-event detail views.
- SyncEngine extended to drain the three new entity types.
- Photo gallery reuses the shared resize helper (lifted from ScanFlow into Seedkeep/Core/Photos/PhotoResize.swift).
- Tests: kit X/X, app Y/Y (counts updated).
- TestFlight build N (0.3.0). Server: Fly v15.
- Pending: device verification, App Store submission.
```

- [ ] **Step 7: Push docs**

```bash
git add .docs/ai/current-state.md
git commit -m "Update current-state: Phase 3 shipped to TestFlight (build N, 0.3.0)"
git push origin main
```

---

## Self-review checklist (verify before marking plan complete)

- [ ] Every server route from the Phase 3 server plan has a matching client method in SeedkeepKit Task 1.
- [ ] Three new SwiftData models registered in the schema (Task 2).
- [ ] Sync engine drains all three new entity types (Task 3).
- [ ] Journal tab visible in root navigation (Task 4).
- [ ] Create + edit + delete round-trips work end-to-end (Tasks 4 + 5).
- [ ] Entity-scoped sections show in seed / bed / planting-event detail (Task 6).
- [ ] Photo upload uses the shared resize helper, not a duplicate implementation (Task 7).
- [ ] Checklist add/toggle/delete syncs per-item (Task 8).
- [ ] Retrospective card hidden when no prior data, visible otherwise (Task 9).
- [ ] TestFlight build cut + device verification checklist completed (Task 10).

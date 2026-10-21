import Foundation
import Testing
@testable import Seedkeep

/// `NotesDraft`: a commit writes only the draft's own event and only after an edit, whatever order
/// SwiftUI runs the details' selection, stored-notes and focus handlers in. An edit stays pending until
/// the store takes it.
@Suite("Garden — notes draft")
struct GardenNotesDraftTests {
    static func loaded(_ eventID: String = "A", stored: String? = "a notes") -> NotesDraft {
        var draft = NotesDraft()
        draft.load(eventID: eventID, stored: stored)
        return draft
    }

    /// What the details view does on a successful save.
    static func save(_ draft: inout NotesDraft) -> (eventID: String, text: String)? {
        guard let pending = draft.pending else { return nil }
        draft.markSaved(eventID: pending.eventID, text: pending.text)
        return pending
    }

    @Test func anUneditedDraftCommitsNothing() {
        let draft = Self.loaded()
        #expect(draft.text == "a notes")
        #expect(!draft.isDirty)
        #expect(draft.pending == nil)
        #expect(NotesDraft().isDirty == false)
        #expect(NotesDraft().pending == nil)
    }

    @Test func anEditCommitsOnceToItsOwnEvent() throws {
        var draft = Self.loaded()
        draft.edit("thinned")
        let pending = try #require(Self.save(&draft))
        #expect(pending.eventID == "A" && pending.text == "thinned")
        #expect(draft.pending == nil, "the same edit is never committed twice")
    }

    @Test func aFailedSaveStaysPendingForTheNextCommit() throws {
        var draft = Self.loaded()
        draft.edit("thinned")
        _ = try #require(draft.pending)
        // The save threw, so markSaved never ran: the edit is still pending and is retried.
        let retry = try #require(draft.pending)
        #expect(retry.eventID == "A" && retry.text == "thinned")
        #expect(draft.isDirty)
    }

    @Test func aFailedSaveSurvivesSwitchingEventsAndComesBack() {
        var draft = Self.loaded("A", stored: "a notes")
        draft.edit("mine")
        // A's save threw (no markSaved), then the selection moves to B.
        draft.load(eventID: "B", stored: "b notes")
        #expect(draft.eventID == "B" && draft.text == "b notes" && draft.pending == nil)
        #expect(draft.pendingWrites.map { "\($0.eventID)=\($0.text)" } == ["A=mine"])
        // A's edit is never written into B, and comes back when A is shown again.
        draft.load(eventID: "A", stored: "a notes")
        #expect(draft.text == "mine" && draft.isDirty)
        #expect(draft.unsaved.isEmpty)
        #expect(draft.pendingWrites.map { "\($0.eventID)=\($0.text)" } == ["A=mine"])
    }

    @Test func savingAnUnsavedEditClearsIt() {
        var draft = Self.loaded("A", stored: "a notes")
        draft.edit("mine")
        draft.load(eventID: "B", stored: "b notes")
        draft.edit("theirs")
        #expect(draft.pendingWrites.map(\.eventID) == ["B", "A"], "the shown draft first")
        draft.markSaved(eventID: "A", text: "mine")
        #expect(draft.pendingWrites.map(\.eventID) == ["B"])
        draft.markSaved(eventID: "B", text: "theirs")
        #expect(draft.pendingWrites.isEmpty)
    }

    @Test func markingAnotherEventSavedLeavesTheDraftPending() {
        var draft = Self.loaded("A")
        draft.edit("mine")
        draft.markSaved(eventID: "B", text: "mine")
        #expect(draft.isDirty)
    }

    @Test func editingBackToTheStoredNotesCommitsNothing() {
        var draft = Self.loaded()
        draft.edit("changed")
        draft.edit("a notes")
        #expect(draft.pending == nil)
    }

    @Test func clearingNotesCommitsAnEmptyString() throws {
        var draft = Self.loaded()
        draft.edit("")
        let pending = try #require(draft.pending)
        #expect(pending.eventID == "A" && pending.text == "")
    }

    // (a) Switching A → B when B's stored-notes change is seen before the selection change: B's
    // notes must not land in A.
    @Test func anotherEventsNotesNeverEnterTheDraft() {
        var draft = Self.loaded("A", stored: "a notes")
        draft.remoteChanged(eventID: "B", stored: "b notes")
        #expect(draft.text == "a notes")
        #expect(draft.pending == nil)
        draft.load(eventID: "B", stored: "b notes")
        #expect(draft.eventID == "B" && draft.text == "b notes")
        #expect(draft.pending == nil)
    }

    // (b) Typing in A, then selecting B: A's text is committed to A, never to B, whichever handler
    // runs first.
    @Test func typingInAThenSelectingBCommitsToA() throws {
        var draft = Self.loaded("A", stored: "a notes")
        draft.edit("a edited")
        // B's stored notes arrive first: ignored.
        draft.remoteChanged(eventID: "B", stored: "b notes")
        // The selection change commits the old draft, then loads B.
        let pending = try #require(Self.save(&draft))
        #expect(pending.eventID == "A" && pending.text == "a edited")
        draft.load(eventID: "B", stored: "b notes")
        // Blur after the switch: B is unedited, nothing is written.
        #expect(draft.pending == nil)
        #expect(draft.text == "b notes")
    }

    // (c) Focus A's notes without typing, a remote edit to A arrives, then blur: the remote text
    // stays and nothing is written over it.
    @Test func aRemoteEditReplacesAnUneditedFocusedDraft() {
        var draft = Self.loaded("A", stored: "a notes")
        draft.remoteChanged(eventID: "A", stored: "remote text")
        #expect(draft.text == "remote text")
        #expect(draft.pending == nil)
    }

    @Test func aRemoteEditLeavesAnEditedDraftAlone() throws {
        var draft = Self.loaded("A", stored: "a notes")
        draft.edit("mine")
        draft.remoteChanged(eventID: "A", stored: "remote text")
        #expect(draft.text == "mine")
        let pending = try #require(draft.pending)
        #expect(pending.eventID == "A" && pending.text == "mine")
    }

    @Test func theCommittedWriteEchoingBackKeepsTheDraftClean() {
        var draft = Self.loaded("A", stored: nil)
        draft.edit("  sown deep ")
        _ = Self.save(&draft)
        // The store saves the trimmed text; the echo replaces the clean draft.
        draft.remoteChanged(eventID: "A", stored: "sown deep")
        #expect(draft.text == "sown deep")
        #expect(!draft.isDirty)
    }
}

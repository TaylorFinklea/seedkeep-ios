import Testing
import Foundation
@testable import SeedkeepKit

@Suite("Assistant DTOs decode correctly")
struct AssistantDecodeTests {
    @Test func threadRoundTrip() throws {
        let t = AssistantThreadDTO(
            id: "t1", householdId: "h1", title: "Garden chat", threadKind: "chat",
            createdAt: 1, updatedAt: 2, deletedAt: nil)
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(AssistantThreadDTO.self, from: data)
        #expect(decoded == t)
    }

    @Test func threadDetailDecode() throws {
        let json = """
        {
          "thread": {
            "id": "t1", "householdId": "h1", "title": "test", "threadKind": "chat",
            "createdAt": 1, "updatedAt": 2, "deletedAt": null
          },
          "messages": [
            {
              "id": "m1", "threadId": "t1", "role": "user",
              "contentJson": "[{\\"type\\":\\"text\\",\\"text\\":\\"hi\\"}]",
              "pageContext": null, "model": null, "usageJson": null, "createdAt": 100
            }
          ],
          "toolCalls": []
        }
        """
        let d = try JSONDecoder().decode(AssistantThreadDetailDTO.self, from: Data(json.utf8))
        #expect(d.thread.id == "t1")
        #expect(d.messages.count == 1)
        #expect(d.messages[0].role == "user")
        #expect(d.toolCalls.isEmpty)
    }

    @Test func keyStatusDecode() throws {
        let json = """
        {
          "providers": [
            { "provider": "anthropic", "configured": true, "updatedAt": 1234567890 }
          ]
        }
        """
        let d = try JSONDecoder().decode(AssistantKeyStatusDTO.self, from: Data(json.utf8))
        #expect(d.providers.count == 1)
        #expect(d.providers[0].provider == "anthropic")
        #expect(d.providers[0].configured == true)
    }

    @Test func feedReusesDeltaPage() throws {
        let json = """
        {
          "items": [
            { "id": "t1", "householdId": "h1", "title": "", "threadKind": "chat",
              "createdAt": 1, "updatedAt": 2, "deletedAt": null }
          ],
          "cursor": 2,
          "has_more": false
        }
        """
        let d = try JSONDecoder().decode(AssistantThreadFeedDTO.self, from: Data(json.utf8))
        #expect(d.items.count == 1)
        #expect(d.cursor == 2)
        #expect(d.has_more == false)
    }

    @Test func streamEventTextDelta() {
        let json = """
        { "type": "text_delta", "message_id": "m1", "delta": "Hello" }
        """
        let ev = AssistantStreamEvent.decode(Data(json.utf8))
        guard case .textDelta(let mid, let d) = ev else { Issue.record("expected textDelta"); return }
        #expect(mid == "m1")
        #expect(d == "Hello")
    }

    @Test func streamEventToolUseStart() {
        let json = """
        { "type": "tool_use_start", "tool_call_id": "tc1", "message_id": "m1", "tool_name": "list_seeds" }
        """
        let ev = AssistantStreamEvent.decode(Data(json.utf8))
        guard case .toolUseStart(let id, let mid, let n) = ev else { Issue.record("expected toolUseStart"); return }
        #expect(id == "tc1")
        #expect(mid == "m1")
        #expect(n == "list_seeds")
    }

    @Test func streamEventProposedChange() {
        let json = """
        { "type": "proposed_change", "tool_call_id": "tc1", "proposed_change_json": "{\\"was\\":1,\\"becomes\\":2}" }
        """
        let ev = AssistantStreamEvent.decode(Data(json.utf8))
        guard case .proposedChange(let id, let pc) = ev else { Issue.record("expected proposedChange"); return }
        #expect(id == "tc1")
        #expect(pc.contains("becomes"))
    }

    @Test func streamEventDone() {
        let json = #"{ "type": "done", "message_id": "m1" }"#
        let ev = AssistantStreamEvent.decode(Data(json.utf8))
        guard case .done(let mid) = ev else { Issue.record("expected done"); return }
        #expect(mid == "m1")
    }

    @Test func streamEventErrorAndUnknown() {
        let err = AssistantStreamEvent.decode(Data(#"{"type":"error","code":"timeout","message":"slow"}"#.utf8))
        guard case .streamError(let code, let msg) = err else { Issue.record("expected error"); return }
        #expect(code == "timeout")
        #expect(msg == "slow")

        let unknown = AssistantStreamEvent.decode(Data(#"{"type":"who_knows"}"#.utf8))
        #expect(unknown == nil)
    }
}

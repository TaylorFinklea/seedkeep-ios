import Testing
import Foundation
@testable import SeedkeepKit

@Suite("Envelope decoding")
struct EnvelopeTests {

    @Test func decodesSuccess() throws {
        let json = #"""
        { "ok": true, "data": { "user": { "id": "u1", "email": "a@b.c", "name": null } }, "request_id": "req_abc" }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<WireResponses.Me>.self, from: json)
        switch env {
        case .ok(let me, let requestID):
            #expect(me.user.id == "u1")
            #expect(me.user.email == "a@b.c")
            #expect(requestID == "req_abc")
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesFailure() throws {
        let json = #"""
        { "ok": false, "error": { "code": "unauthorized", "message": "Missing authorization token" } }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<WireResponses.Me>.self, from: json)
        switch env {
        case .ok:
            Issue.record("Expected failure")
        case .failure(let err):
            #expect(err.code == "unauthorized")
            #expect(err.message.contains("authorization"))
        }
    }

    @Test func decodesDeltaPageOfTags() throws {
        let json = #"""
        {
          "ok": true,
          "data": {
            "items": [
              { "id": "t1", "household_id": "h", "name": "Heirloom", "color": "#7d5e3c",
                "created_at": 1, "updated_at": 2, "deleted_at": null }
            ],
            "cursor": 2,
            "has_more": false
          }
        }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<DeltaPage<TagDTO>>.self, from: json)
        switch env {
        case .ok(let page, _):
            #expect(page.items.count == 1)
            #expect(page.items.first?.name == "Heirloom")
            #expect(page.cursor == 2)
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesExtractionResult() throws {
        let json = #"""
        {
          "ok": true,
          "data": {
            "extraction_id": "xt_1",
            "catalog_seed_id": "cs_1",
            "decision": { "status": "published" },
            "extraction": {
              "common_name": "Tomato",
              "variety": "Cherokee Purple",
              "company": "Baker Creek",
              "instructions": "Sow indoors 6–8 weeks before last frost…",
              "self_confidence": 0.92
            },
            "review": { "score": 0.91, "notes": "Plausible heirloom variety; instructions match real planting guidance." },
            "photo_keys": { "front": "households/h/extractions/xt_1/front-abc.jpg", "back": "households/h/extractions/xt_1/back-def.jpg" }
          }
        }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<WireResponses.ExtractionResult>.self, from: json)
        switch env {
        case .ok(let result, _):
            #expect(result.extraction_id == "xt_1")
            #expect(result.catalog_seed_id == "cs_1")
            #expect(result.decision.status == "published")
            #expect(result.extraction.variety == "Cherokee Purple")
            #expect(result.review.score == 0.91)
            #expect(result.photo_keys.front.hasSuffix("front-abc.jpg"))
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesDeleteResult() throws {
        let json = #"""
        { "ok": true, "data": { "id": "loc_1", "deleted_at": 1777577200927 } }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<SeedkeepClient.DeleteResult>.self, from: json)
        switch env {
        case .ok(let result, _):
            #expect(result.id == "loc_1")
            #expect(result.deleted_at == 1777577200927)
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesPreExtractedResult() throws {
        let json = #"""
        {
          "ok": true,
          "data": {
            "extraction_id": "xt_pre_1",
            "catalog_seed_id": "cs_pre_1",
            "decision": { "status": "published" },
            "extraction": {
              "common_name": "Sunflower",
              "variety": "Mammoth",
              "company": "Burpee",
              "instructions": "Direct sow after last frost; full sun.",
              "self_confidence": 0.88
            },
            "review": { "score": 0.88, "notes": "pre-extracted: self_confidence used as proxy" },
            "photo_keys": [
              "households/h/extractions/xt_pre_1/front-aaa.jpg",
              "households/h/extractions/xt_pre_1/back-bbb.jpg"
            ]
          }
        }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<WireResponses.PreExtractedResult>.self, from: json)
        switch env {
        case .ok(let result, _):
            #expect(result.extraction_id == "xt_pre_1")
            #expect(result.catalog_seed_id == "cs_pre_1")
            #expect(result.decision.status == "published")
            #expect(result.extraction.variety == "Mammoth")
            #expect(result.review.score == 0.88)
            #expect(result.photo_keys.count == 2)
            #expect(result.photo_keys.first?.hasSuffix("front-aaa.jpg") == true)
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesPreExtractedWithoutPhotos() throws {
        // Pre-extracted submissions can omit photos entirely. Server still
        // returns the same shape with an empty photo_keys array.
        let json = #"""
        {
          "ok": true,
          "data": {
            "extraction_id": "xt_pre_2",
            "catalog_seed_id": null,
            "decision": { "status": "pending", "reason": "low_confidence" },
            "extraction": {
              "common_name": null, "variety": null, "company": null,
              "instructions": null, "self_confidence": 0.42
            },
            "review": { "score": 0.42, "notes": "pre-extracted: self_confidence used as proxy" },
            "photo_keys": []
          }
        }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<WireResponses.PreExtractedResult>.self, from: json)
        switch env {
        case .ok(let result, _):
            #expect(result.catalog_seed_id == nil)
            #expect(result.decision.status == "pending")
            #expect(result.decision.reason == "low_confidence")
            #expect(result.photo_keys.isEmpty)
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesSubscriptionMe() throws {
        let json = #"""
        {
          "ok": true,
          "data": {
            "tier": "hosted",
            "subscription": {
              "id": "sub_1", "user_id": "u1", "product_id": "app.seedkeep.ios.hosted.monthly",
              "original_transaction_id": "ot_1", "latest_transaction_id": "lt_2",
              "status": "active", "expires_at": 1777580000000, "last_verified_at": 1777570000000,
              "environment": "production", "created_at": 1777560000000, "updated_at": 1777570000000
            }
          }
        }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<SeedkeepClient.SubscriptionMeResponse>.self, from: json)
        switch env {
        case .ok(let me, _):
            #expect(me.tier == "hosted")
            #expect(me.subscription?.status == "active")
            #expect(me.subscription?.environment == "production")
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesVerifyReceiptResponse() throws {
        let json = #"""
        {
          "ok": true,
          "data": {
            "tier": "hosted",
            "environment": "sandbox",
            "subscription": {
              "product_id": "app.seedkeep.ios.hosted.monthly",
              "original_transaction_id": "ot_abc",
              "status": "active",
              "expires_at": 1777580000000
            }
          }
        }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<SeedkeepClient.VerifyReceiptResponse>.self, from: json)
        switch env {
        case .ok(let res, _):
            #expect(res.tier == "hosted")
            #expect(res.environment == "sandbox")
            #expect(res.subscription.product_id == "app.seedkeep.ios.hosted.monthly")
            #expect(res.subscription.status == "active")
            #expect(res.subscription.expires_at == 1777580000000)
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesSubscriptionMeFreeTierNoSubscription() throws {
        let json = #"""
        { "ok": true, "data": { "tier": "free", "subscription": null } }
        """#.data(using: .utf8)!

        let env = try JSONDecoder().decode(Envelope<SeedkeepClient.SubscriptionMeResponse>.self, from: json)
        switch env {
        case .ok(let me, _):
            #expect(me.tier == "free")
            #expect(me.subscription == nil)
        case .failure(let err):
            Issue.record("Expected success, got \(err)")
        }
    }

    @Test func decodesSeedDTOWithTagIds() throws {
        let json = #"""
        {
          "id": "s1", "household_id": "h", "catalog_id": null, "state": "active",
          "packet_count": 2, "location_id": null, "year_packed": 2024, "source": "store",
          "custom_name": "Cherokee Purple", "custom_variety": null, "custom_company": "Baker Creek",
          "notes": null, "created_at": 1, "updated_at": 2, "deleted_at": null,
          "tag_ids": ["t1","t2"]
        }
        """#.data(using: .utf8)!

        let seed = try JSONDecoder().decode(SeedDTO.self, from: json)
        #expect(seed.state == .active)
        #expect(seed.source == .store)
        #expect(seed.tag_ids == ["t1", "t2"])
        #expect(seed.year_packed == 2024)
    }
}

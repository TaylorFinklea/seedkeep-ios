import Foundation
import SeedkeepKit

/// DTO → SwiftData @Model conversions used by the SyncEngine to upsert.
/// Kept narrow on purpose — the views never touch DTOs directly.

extension LocationDTO {
    func makeLocal() -> LocalLocation {
        LocalLocation(
            id: id,
            householdID: household_id,
            name: name,
            sortOrder: sort_order,
            createdAt: created_at,
            updatedAt: updated_at,
            deletedAt: deleted_at
        )
    }

    func apply(to local: LocalLocation) {
        local.householdID = household_id
        local.name = name
        local.sortOrder = sort_order
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
    }
}

extension TagDTO {
    func makeLocal() -> LocalTag {
        LocalTag(
            id: id,
            householdID: household_id,
            name: name,
            color: color,
            createdAt: created_at,
            updatedAt: updated_at,
            deletedAt: deleted_at
        )
    }

    func apply(to local: LocalTag) {
        local.householdID = household_id
        local.name = name
        local.color = color
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
    }
}

extension SeedDTO {
    func makeLocal() -> LocalSeed {
        LocalSeed(
            id: id,
            householdID: household_id,
            catalogID: catalog_id,
            state: state,
            packetCount: packet_count,
            locationID: location_id,
            yearPacked: year_packed,
            source: source,
            customName: custom_name,
            customVariety: custom_variety,
            customCompany: custom_company,
            notes: notes,
            tagIDs: tag_ids,
            createdAt: created_at,
            updatedAt: updated_at,
            deletedAt: deleted_at
        )
    }

    func apply(to local: LocalSeed) {
        local.householdID = household_id
        local.catalogID = catalog_id
        local.state = state
        local.packetCount = packet_count
        local.locationID = location_id
        local.yearPacked = year_packed
        local.source = source
        local.customName = custom_name
        local.customVariety = custom_variety
        local.customCompany = custom_company
        local.notes = notes
        local.tagIDs = tag_ids
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
    }
}

extension BedDTO {
    func makeLocal() -> LocalBed {
        LocalBed(
            id: id,
            householdID: household_id,
            name: name,
            bedDescription: description,
            widthFeet: width_feet,
            lengthFeet: length_feet,
            sortOrder: sort_order,
            createdAt: created_at,
            updatedAt: updated_at,
            deletedAt: deleted_at
        )
    }

    func apply(to local: LocalBed) {
        local.householdID = household_id
        local.name = name
        local.bedDescription = description
        local.widthFeet = width_feet
        local.lengthFeet = length_feet
        local.sortOrder = sort_order
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
    }
}

extension RecommendationDTO {
    func makeLocal(fetchedAt: Int64) -> LocalRecommendation {
        LocalRecommendation(
            catalogSeedID: catalogSeedId,
            locationSignature: locationSignature,
            computedAt: computedAt,
            source: source,
            confidence: confidence,
            verdict: verdict,
            rangeStart: recommendedRange?.start,
            rangeEnd: recommendedRange?.end,
            indoorStart: indoorRange?.start,
            indoorEnd: indoorRange?.end,
            scoresAnchorDate: dailyScores.anchorDate,
            dailyScoresJSON: (try? String(data: JSONEncoder().encode(dailyScores.scores), encoding: .utf8)) ?? "[]",
            reasoning: reasoning,
            fetchedAt: fetchedAt
        )
    }

    func apply(to local: LocalRecommendation, fetchedAt: Int64) {
        local.locationSignature = locationSignature
        local.computedAt = computedAt
        local.source = source
        local.confidence = confidence
        local.verdict = verdict
        local.rangeStart = recommendedRange?.start
        local.rangeEnd = recommendedRange?.end
        local.indoorStart = indoorRange?.start
        local.indoorEnd = indoorRange?.end
        local.scoresAnchorDate = dailyScores.anchorDate
        local.dailyScoresJSON = (try? String(data: JSONEncoder().encode(dailyScores.scores), encoding: .utf8)) ?? "[]"
        local.reasoning = reasoning
        local.fetchedAt = fetchedAt
    }
}

extension PlantingEventDTO {
    func makeLocal() -> LocalPlantingEvent {
        LocalPlantingEvent(
            id: id,
            householdID: household_id,
            bedID: bed_id,
            seedID: seed_id,
            catalogSeedID: catalog_seed_id,
            kindRaw: kind,
            plannedFor: planned_for,
            completedAt: completed_at,
            notes: notes,
            xFeet: x_feet,
            yFeet: y_feet,
            createdAt: created_at,
            updatedAt: updated_at,
            deletedAt: deleted_at,
            // Phase 5 — plant-pet identity from the server. Streak
            // columns are iOS-local and stay at their defaults on
            // first insert.
            petSeed: pet_seed,
            petRarity: pet_rarity,
            petCreatureKind: pet_creature_kind,
            petName: pet_name,
            petPersonalityJSON: pet_personality,
            petSpawnedAt: pet_spawned_at
        )
    }

    func apply(to local: LocalPlantingEvent) {
        local.householdID = household_id
        local.bedID = bed_id
        local.seedID = seed_id
        local.catalogSeedID = catalog_seed_id
        local.kindRaw = kind
        local.plannedFor = planned_for
        local.completedAt = completed_at
        local.notes = notes
        local.xFeet = x_feet
        local.yFeet = y_feet
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
        // Phase 5 — refresh the six pet identity columns from the
        // server payload. The streak columns
        // (`petWiltedStreakDays`, `petLastMoodTickAt`) are deliberately
        // **not** touched here: they're iOS-local state that must
        // survive a sync round so departure progress isn't lost across
        // foregrounds / pulls (spec test invariant).
        local.petSeed = pet_seed
        local.petRarity = pet_rarity
        local.petCreatureKind = pet_creature_kind
        local.petName = pet_name
        local.petPersonalityJSON = pet_personality
        local.petSpawnedAt = pet_spawned_at
    }
}

// MARK: - JournalEntry

extension JournalEntryDTO {
    func makeLocal() -> LocalJournalEntry {
        LocalJournalEntry(
            id: id,
            householdID: householdId,
            occurredOn: occurredOn,
            body: body,
            seedID: seedId,
            bedID: bedId,
            plantingEventID: plantingEventId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    func apply(to local: LocalJournalEntry) {
        local.householdID = householdId
        local.occurredOn = occurredOn
        local.body = body
        local.seedID = seedId
        local.bedID = bedId
        local.plantingEventID = plantingEventId
        local.createdAt = createdAt
        local.updatedAt = updatedAt
        local.deletedAt = deletedAt
    }
}

extension JournalEntryPhotoDTO {
    func makeLocal() -> LocalJournalEntryPhoto {
        LocalJournalEntryPhoto(
            id: id,
            entryID: entryId,
            storageKey: storageKey,
            sortOrder: sortOrder,
            width: width,
            height: height,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func apply(to local: LocalJournalEntryPhoto) {
        local.entryID = entryId
        local.storageKey = storageKey
        local.sortOrder = sortOrder
        local.width = width
        local.height = height
        local.createdAt = createdAt
        local.updatedAt = updatedAt
    }
}

extension JournalChecklistItemDTO {
    func makeLocal() -> LocalJournalChecklistItem {
        LocalJournalChecklistItem(
            id: id,
            entryID: entryId,
            text: text,
            completed: completed,
            sortOrder: sortOrder,
            updatedAt: updatedAt
        )
    }

    func apply(to local: LocalJournalChecklistItem) {
        local.entryID = entryId
        local.text = text
        local.completed = completed
        local.sortOrder = sortOrder
        local.updatedAt = updatedAt
    }
}

// MARK: - Assistant (Phase 4)

extension AssistantThreadDTO {
    func makeLocal() -> LocalAssistantThread {
        LocalAssistantThread(
            id: id, householdID: householdId, title: title, threadKind: threadKind,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt)
    }
    func apply(to local: LocalAssistantThread) {
        local.householdID = householdId
        local.title = title
        local.threadKind = threadKind
        local.createdAt = createdAt
        local.updatedAt = updatedAt
        local.deletedAt = deletedAt
    }
}

extension AssistantMessageDTO {
    func makeLocal() -> LocalAssistantMessage {
        LocalAssistantMessage(
            id: id, threadID: threadId, role: role, contentJSON: contentJson,
            pageContext: pageContext, model: model, usageJSON: usageJson, createdAt: createdAt)
    }
    func apply(to local: LocalAssistantMessage) {
        local.threadID = threadId
        local.role = role
        local.contentJSON = contentJson
        local.pageContext = pageContext
        local.model = model
        local.usageJSON = usageJson
        local.createdAt = createdAt
    }
}

extension AssistantToolCallDTO {
    func makeLocal() -> LocalAssistantToolCall {
        LocalAssistantToolCall(
            id: id, messageID: messageId, threadID: threadId, toolName: toolName,
            argsJSON: argsJson, status: status, resultJSON: resultJson,
            proposedChangeJSON: proposedChangeJson, confirmedAt: confirmedAt,
            createdAt: createdAt, updatedAt: updatedAt)
    }
    func apply(to local: LocalAssistantToolCall) {
        local.messageID = messageId
        local.threadID = threadId
        local.toolName = toolName
        local.argsJSON = argsJson
        local.status = status
        local.resultJSON = resultJson
        local.proposedChangeJSON = proposedChangeJson
        local.confirmedAt = confirmedAt
        local.createdAt = createdAt
        local.updatedAt = updatedAt
    }
}

// MARK: - PetDeparture (Phase 5.1.2)

extension PetDepartureDTO {
    func makeLocal() -> LocalPetDeparture {
        LocalPetDeparture(
            plantingEventID: planting_event_id,
            goodbyeNoteJSON: goodbye_note,
            reason: reason,
            fallback: decodedGoodbyeNote()?.fallback ?? false,
            createdAt: created_at,
            updatedAt: updated_at,
            departedAt: departed_at,
            deletedAt: deleted_at
        )
    }

    func apply(to local: LocalPetDeparture) {
        local.goodbyeNoteJSON = goodbye_note
        local.reason = reason
        local.fallback = decodedGoodbyeNote()?.fallback ?? false
        local.createdAt = created_at
        local.updatedAt = updated_at
        local.departedAt = departed_at
        local.deletedAt = deleted_at
    }
}

// MARK: - CatalogCorrection (Phase 4D)

extension CatalogCorrectionDTO {
    func makeLocal() -> LocalCatalogCorrection {
        LocalCatalogCorrection(
            id: id,
            catalogSeedID: catalog_seed_id,
            catalogSeedName: catalog_seed_name,
            fieldName: field_name,
            valueType: value_type,
            suggestedValue: suggested_value,
            clientSeenValue: client_seen_value,
            body: body,
            status: status,
            aiReviewScore: ai_review_score,
            aiNotes: ai_notes,
            dismissedReason: dismissed_reason,
            conflictWithID: conflict_with_id,
            userAcknowledgedBounds: user_acknowledged_bounds,
            createdAt: created_at,
            reviewedAt: reviewed_at,
            appliedAt: applied_at,
            escalatedAt: escalated_at,
            updatedAt: updated_at,
            deletedAt: deleted_at,
            appliedFieldName: applied_patch?.field_name,
            appliedNewValue: applied_patch?.new_value
        )
    }

    func apply(to local: LocalCatalogCorrection) {
        local.catalogSeedID = catalog_seed_id
        local.catalogSeedName = catalog_seed_name
        local.fieldName = field_name
        local.valueType = value_type
        local.suggestedValue = suggested_value
        local.clientSeenValue = client_seen_value
        local.body = body
        local.status = status
        local.aiReviewScore = ai_review_score
        local.aiNotes = ai_notes
        local.dismissedReason = dismissed_reason
        local.conflictWithID = conflict_with_id
        local.userAcknowledgedBounds = user_acknowledged_bounds
        local.createdAt = created_at
        local.reviewedAt = reviewed_at
        local.appliedAt = applied_at
        local.escalatedAt = escalated_at
        local.updatedAt = updated_at
        local.deletedAt = deleted_at
        // `applied_patch` is delivered only on the row's transition to
        // `applied`; preserve any previously captured patch values when
        // the server omits the field on subsequent syncs.
        if let patch = applied_patch {
            local.appliedFieldName = patch.field_name
            local.appliedNewValue = patch.new_value
        }
    }
}

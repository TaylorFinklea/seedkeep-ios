import SwiftUI
import SwiftData
import SeedkeepKit

/// Phase 4D — structured catalog correction sheet.
///
/// Lets the user file a correction against a specific field of a catalog
/// entry. Numeric + short-choice (enum) fields may be auto-applied
/// server-side when the AI moderator clears every gate in
/// `decideCorrectionOutcome`; free-text fields always queue for human
/// review. The sheet enforces the auto-apply contract upfront so users
/// know what they're signing up for.
///
/// Surface contract (mirrors spec §7):
///
/// - Header copy discloses the auto-apply policy in plain English.
/// - `.menu`-style field picker driven by
///   `CatalogFieldBounds.correctableFields`. Labels carry the catalog's
///   current value plus a `· auto` / `· reviewed` tag.
/// - Pre-flight `@Query LocalCatalogCorrection` for an existing open
///   correction on this (user, catalogSeedID, fieldName). Inline banner
///   offers "View status" / "Withdraw and replace" so the race past the
///   server's partial unique index is reconciled before the user types.
/// - Body editor swaps per field type:
///   - Numeric: single-line `TextField` with italic bounds hint.
///   - Enum: segmented `Picker` over `CatalogFieldBounds.enumValues`.
///   - Single-line text (`scientific_name` / `common_name` / `variety` /
///     `company`): `TextField(lineLimit: 1...3)`.
///   - Multi-line: free-form "Something else" `TextField(axis: .vertical)`.
/// - Idempotency-Key UUID is generated once at `.onAppear` and persisted
///   in `@State` so a withdraw-and-replace replay (or a retry after a
///   transient error) doesn't double-insert.
/// - Free-form body text is preserved across `withdraw and replace` via
///   `@SceneStorage` so a user re-uses their drafted "Why?" instead of
///   retyping.
/// - Errors render as structured `GroupBox` blocks with action buttons:
///   - 400 `bounds_violation`: "File anyway" sets
///     `userAcknowledgedBounds=true` and resubmits.
///   - 409 `open_correction_exists`: "View existing" / "Withdraw and
///     replace" buttons.
///   - 429 `rate_limited`: copy adapts to the `retry_after_seconds`
///     bucket.
///
/// Spec: `.docs/ai/specs/2026-06-09-phase-4d-catalog-corrections-design.md`
/// §7 ("CatalogFeedbackSheet rewrite").
struct CatalogFeedbackSheet: View {
    let catalogID: String
    let catalogName: String?
    /// Optional snapshot of the catalog's current growing-info values so
    /// the field picker can render "(current value)" alongside each row.
    /// Passed in by the call site (`SeedDetailView`) which already owns
    /// the effective snapshot — keeps this sheet self-contained and
    /// testable without a `@Query` hop.
    let currentValues: GrowingInfoSnapshot?

    init(
        catalogID: String,
        catalogName: String?,
        currentValues: GrowingInfoSnapshot? = nil
    ) {
        self.catalogID = catalogID
        self.catalogName = catalogName
        self.currentValues = currentValues
        // Draft key is scoped per catalog entry so a drafted "Why?" for
        // seed A never bleeds into seed B's correction sheet.
        _bodyText = SceneStorage(
            wrappedValue: "",
            Self.draftKey(catalogID: catalogID)
        )
    }

    /// Per-catalog-entry `@SceneStorage` key for the drafted body text.
    static func draftKey(catalogID: String) -> String {
        "seedkeep.catalogFeedback.body.\(catalogID)"
    }

    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.dismiss) private var dismiss

    /// Pre-flight conflict check. `@Query` filtered in-memory below by
    /// `(catalogSeedID, fieldName, status == "open")` because SwiftData's
    /// macro predicate can't take a runtime String comparison against a
    /// String? cleanly across both nil and non-nil cases.
    @Query private var allCorrections: [LocalCatalogCorrection]

    /// Selected catalog field. Defaults to the structured-correction
    /// sentinel `"other"` so first-open lands on the free-form editor
    /// (matches the legacy behavior pre-Phase-4D).
    @State private var selectedField: String = "other"

    /// Structured "suggested value" for numeric / enum / single-line
    /// fields. Empty string until the user types.
    @State private var suggestedValue: String = ""

    /// Free-form "Why?" body. Preserved across withdraw-and-replace via
    /// `@SceneStorage` so the user doesn't lose their drafted reasoning
    /// when reconciling a pre-flight conflict. Keyed per catalog entry
    /// (see `draftKey(catalogID:)`, assigned in `init`).
    @SceneStorage private var bodyText: String

    /// Generated once at `.onAppear`. Sent as the `Idempotency-Key`
    /// header so the server's partial unique index on
    /// `(idempotency_key, user_id)` deduplicates retries to the same row.
    @State private var idempotencyKey: String = ""

    /// Set true once the user taps "File anyway" on a 400
    /// bounds_violation response. Carried into the resubmit payload as
    /// `user_acknowledged_bounds=true`, which short-circuits
    /// `decideCorrectionOutcome` to `queue_for_review`.
    @State private var userAcknowledgedBounds: Bool = false

    @State private var submitting = false
    @State private var didSubmit = false

    /// Structured error state. Drives the GroupBox rendered below the
    /// editor. Nil while the request is in-flight or has not yet been
    /// attempted.
    @State private var pendingError: PendingError?

    /// 409 race-past-pre-flight payload. When the server returns
    /// `open_correction_exists` we surface the conflicting DTO so the
    /// user can choose to withdraw-and-replace.
    @State private var serverConflict: CatalogCorrectionDTO?

    /// Surface label for an existing open correction (either from
    /// pre-flight `@Query` or a server 409). Picked at render time.
    private struct PendingError: Equatable {
        let kind: Kind
        let message: String
        /// Optional retry-after window in seconds, parsed from the 429
        /// response message when present.
        var retryAfterSeconds: Int?
        /// Optional bounds_hint from server 400, when present. Falls
        /// back to the iOS-side `describeBounds` when missing.
        var boundsHint: String?

        enum Kind: Equatable {
            case boundsViolation
            case openCorrectionExists
            case rateLimited
            case other
        }
    }

    // MARK: - Computed state

    /// Existing open correction for this (catalogSeedID, selectedField).
    /// Drives the pre-flight banner above the body editor. Returns nil
    /// when the picker is on `"other"` (free-form has no per-field key).
    private var existingOpenCorrection: LocalCatalogCorrection? {
        guard selectedField != "other" else { return nil }
        return allCorrections.first { row in
            row.catalogSeedID == catalogID
                && row.fieldName == selectedField
                && row.status == "open"
                && row.deletedAt == nil
        }
    }

    private var isFreeFormField: Bool {
        selectedField == "other"
    }

    private var fieldValueType: FieldValueType {
        if selectedField == "other" {
            return .freeForm
        }
        if CatalogFieldBounds.enumValues[selectedField] != nil {
            return .enumeration
        }
        if CatalogFieldBounds.sanityBounds[selectedField] != nil {
            return .numeric
        }
        return .singleLineText
    }

    private enum FieldValueType {
        case numeric
        case enumeration
        case singleLineText
        case freeForm
    }

    var canSubmit: Bool {
        guard !submitting else { return false }
        if isFreeFormField {
            return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !suggestedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - View

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                fieldPickerSection
                if let existing = existingOpenCorrection {
                    preflightBanner(existing: existing)
                }
                bodySection
                if let error = pendingError {
                    errorSection(error)
                }
                if didSubmit {
                    successSection
                }
            }
            .vellumForm()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !didSubmit {
                        Button("Submit") { Task { await submit(forceAcknowledged: false) } }
                            .disabled(!canSubmit)
                    }
                }
            }
            .onAppear {
                if idempotencyKey.isEmpty {
                    idempotencyKey = UUID().uuidString
                }
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: HerbSpace.tight) {
                Text("Suggest a correction")
                    .font(HerbFont.display(size: 28))
                    .foregroundStyle(HerbColor.ink)
                if let name = catalogName {
                    Text("for \(name)")
                        .font(HerbFont.bodyItalic(size: 13))
                        .foregroundStyle(HerbColor.inkSoft)
                }
                Text("Numbers and short choices may be applied automatically when our AI moderator is highly confident. Text suggestions always go to a person for review. Your suggestion is private — only you can see who submitted it.")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
                    .padding(.top, HerbSpace.tight)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: HerbSpace.gutter, bottom: 8, trailing: HerbSpace.gutter))
            .listRowSeparator(.hidden)
        }
    }

    private var fieldPickerSection: some View {
        Section {
            Picker("Field to correct", selection: $selectedField) {
                Section("numbers · auto-applied when AI is confident") {
                    ForEach(Self.numericFieldsOrdered, id: \.self) { field in
                        Text(pickerLabel(for: field)).tag(field)
                    }
                }
                Section("pick one · auto-applied when AI is confident") {
                    ForEach(Self.enumFieldsOrdered, id: \.self) { field in
                        Text(pickerLabel(for: field)).tag(field)
                    }
                }
                Section("text · always reviewed by a person") {
                    ForEach(Self.freeTextFieldsOrdered, id: \.self) { field in
                        Text(pickerLabel(for: field)).tag(field)
                    }
                }
                Text("Something else (free-form note) · reviewed").tag("other")
            }
            .pickerStyle(.menu)
            .onChange(of: selectedField) { _, _ in
                // Clear structured value when the user pivots to a
                // different field — keeping a stale number in the editor
                // while the bounds hint flips is confusing.
                suggestedValue = ""
                userAcknowledgedBounds = false
                pendingError = nil
                serverConflict = nil
            }
        } header: {
            Rubric(text: "which field")
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        switch fieldValueType {
        case .numeric:
            numericEditorSection
        case .enumeration:
            enumEditorSection
        case .singleLineText:
            singleLineTextEditorSection
        case .freeForm:
            freeFormEditorSection
        }
        whyEditorSection
    }

    private var numericEditorSection: some View {
        Section {
            TextField("value", text: $suggestedValue)
                .font(HerbFont.body(size: 14))
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .onChange(of: suggestedValue) { _, _ in
                    userAcknowledgedBounds = false
                    pendingError = nil
                }
            if let current = currentLabel(for: selectedField) {
                Text("Currently: \(current)")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            Text(boundsHintLine)
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
            if let suspect = suspectWarning(for: selectedField, value: suggestedValue) {
                Text(suspect)
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.ochre)
            }
        } header: {
            Rubric(text: "new value")
        }
    }

    private var enumEditorSection: some View {
        Section {
            if let options = CatalogFieldBounds.enumValues[selectedField] {
                Picker("Value", selection: $suggestedValue) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { option in
                        Text(humanizeEnum(option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: suggestedValue) { _, _ in pendingError = nil }
            }
            if let current = currentLabel(for: selectedField) {
                Text("Currently: \(current)")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
        } header: {
            Rubric(text: "new value")
        }
    }

    private var singleLineTextEditorSection: some View {
        Section {
            TextField("value", text: $suggestedValue, axis: .vertical)
                .font(HerbFont.body(size: 14))
                .lineLimit(1...3)
                .onChange(of: suggestedValue) { _, _ in pendingError = nil }
            if let current = currentLabel(for: selectedField) {
                Text("Currently: \(current)")
                    .font(HerbFont.bodyItalic(size: 12))
                    .foregroundStyle(HerbColor.inkSoft)
            }
            Text("Text corrections always go to a human reviewer.")
                .font(HerbFont.bodyItalic(size: 12))
                .foregroundStyle(HerbColor.inkSoft)
        } header: {
            Rubric(text: "new value")
        }
    }

    private var freeFormEditorSection: some View {
        Section {
            TextField(
                "e.g. \"Days to maturity is 75–85, not 60. Confirmed at my farm last year.\"",
                text: $bodyText,
                axis: .vertical
            )
            .font(HerbFont.body(size: 14))
            .lineLimit(5...12)
            .onChange(of: bodyText) { _, _ in pendingError = nil }
        } header: {
            Rubric(text: "what should be fixed")
        }
    }

    private var whyEditorSection: some View {
        // The free-form variant uses `bodyText` AS the primary editor;
        // a separate "Why?" row is redundant. For every other variant
        // surface the optional reviewer-context capture.
        Group {
            if !isFreeFormField {
                Section {
                    TextField(
                        "Source, photo, or 'confirmed at my farm last year' — helps reviewers trust the fix.",
                        text: $bodyText,
                        axis: .vertical
                    )
                    .font(HerbFont.body(size: 14))
                    .lineLimit(1...4)
                } header: {
                    Rubric(text: "why? (optional)")
                }
            }
        }
    }

    private var successSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("✓")
                    .foregroundStyle(HerbColor.sage)
                Text("Thanks — your suggestion was filed.")
                    .font(HerbFont.bodyItalic(size: 13))
                    .foregroundStyle(HerbColor.ink)
            }
        }
    }

    // MARK: - Pre-flight + error banners

    private func preflightBanner(existing: LocalCatalogCorrection) -> some View {
        Section {
            GroupBox {
                VStack(alignment: .leading, spacing: HerbSpace.tight) {
                    Text("You already have an open suggestion for this field")
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.4)
                        .foregroundStyle(HerbColor.sepia)
                        .textCase(.uppercase)
                    Text("submitted \(relativeTime(existing.createdAt)): \(existing.suggestedValue ?? "")")
                        .font(HerbFont.bodyItalic(size: 13))
                        .foregroundStyle(HerbColor.ink)
                    HStack(spacing: HerbSpace.sectionRhythm) {
                        Button("View status") {
                            // Closes this sheet; the user navigates to
                            // YouView → ContributionDetailSheet via the
                            // existing tab. Keeps the sheet purely
                            // submit-focused.
                            dismiss()
                        }
                        Button("Withdraw and replace") {
                            Task { await withdrawAndReplace(existing: existing) }
                        }
                        .foregroundStyle(HerbColor.rose)
                    }
                }
            }
        }
    }

    private func errorSection(_ error: PendingError) -> some View {
        Section {
            GroupBox {
                VStack(alignment: .leading, spacing: HerbSpace.tight) {
                    Text(errorHeadline(for: error))
                        .font(HerbFont.smallCaps(size: 10))
                        .tracking(1.4)
                        .foregroundStyle(HerbColor.rose)
                        .textCase(.uppercase)
                    Text(errorBodyCopy(for: error))
                        .font(HerbFont.bodyItalic(size: 12))
                        .foregroundStyle(HerbColor.ink)
                    errorActions(for: error)
                }
            }
        }
    }

    @ViewBuilder
    private func errorActions(for error: PendingError) -> some View {
        switch error.kind {
        case .boundsViolation:
            HStack(spacing: HerbSpace.sectionRhythm) {
                Button("File anyway") {
                    Task { await submit(forceAcknowledged: true) }
                }
                .foregroundStyle(HerbColor.rose)
                Button("Edit value") { pendingError = nil }
            }
        case .openCorrectionExists:
            HStack(spacing: HerbSpace.sectionRhythm) {
                Button("View existing") { dismiss() }
                Button("Withdraw and replace") {
                    Task { await withdrawAndReplaceServerConflict() }
                }
                .foregroundStyle(HerbColor.rose)
            }
        case .rateLimited, .other:
            EmptyView()
        }
    }

    private func errorHeadline(for error: PendingError) -> String {
        switch error.kind {
        case .boundsViolation: return "Outside the typical range"
        case .openCorrectionExists: return "Pending suggestion exists"
        case .rateLimited: return "Slow down a moment"
        case .other: return "Couldn't submit"
        }
    }

    private func errorBodyCopy(for error: PendingError) -> String {
        switch error.kind {
        case .boundsViolation:
            let hint = error.boundsHint
                ?? CatalogFieldBounds.describeBounds(field: selectedField)
            return "That value is outside the typical range (\(hint)). We can still send it to a human reviewer."
        case .openCorrectionExists:
            return "You already have a pending suggestion for this field."
        case .rateLimited:
            return "You've sent a lot of corrections in the last hour — thanks for the careful eye. We'll be ready for more \(retryWindowCopy(seconds: error.retryAfterSeconds))."
        case .other:
            return error.message
        }
    }

    // MARK: - Submission

    /// Build the structured payload and submit. `forceAcknowledged` is
    /// `true` only when the user has tapped "File anyway" on a prior 400
    /// bounds_violation response — short-circuits the server's
    /// validateFieldValue rejection and routes the row to
    /// `queue_for_review`.
    private func submit(forceAcknowledged: Bool) async {
        submitting = true
        pendingError = nil
        serverConflict = nil
        defer { submitting = false }

        let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSuggested = suggestedValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let ack = forceAcknowledged || userAcknowledgedBounds
        if forceAcknowledged { userAcknowledgedBounds = true }

        // Build call args. For free-form ("other") submissions we omit
        // field_name + suggested_value so the server records the legacy
        // shape (catalog_feedback rows with NULL field_name are picked
        // up by the admin triage queue, not the moderation worker).
        let fieldName: String? = isFreeFormField ? nil : selectedField
        let suggested: String? = isFreeFormField ? nil : trimmedSuggested
        let clientSeen: String? = isFreeFormField ? nil : rawCurrentValue(for: selectedField)
        let submittedBody: String = isFreeFormField
            ? trimmedBody
            : (trimmedBody.isEmpty ? "" : trimmedBody)

        do {
            let response = try await appEnv.client.submitCatalogFeedback(
                catalogID: catalogID,
                body: submittedBody,
                fieldHint: fieldName,
                fieldName: fieldName,
                suggestedValue: suggested,
                clientSeenValue: clientSeen,
                userAcknowledgedBounds: ack,
                idempotencyKey: idempotencyKey
            )
            if response.status == "open_correction_exists",
               let dto = response.existingDTO {
                serverConflict = dto
                pendingError = PendingError(
                    kind: .openCorrectionExists,
                    message: "open_correction_exists"
                )
                return
            }
            didSubmit = true
            // Clear the persisted draft on success so a future sheet
            // open starts fresh.
            bodyText = ""
        } catch let err as SeedkeepError {
            pendingError = mapServerError(err)
        } catch {
            pendingError = PendingError(
                kind: .other,
                message: humanizeError(error)
            )
        }
    }

    /// Pre-flight `Withdraw and replace`: DELETE the user's existing
    /// open correction (server flips it to dismissed) then leave the
    /// sheet open so the user can resubmit. Body text is preserved via
    /// `@SceneStorage`; a fresh `Idempotency-Key` is generated so the
    /// new submission isn't deduped against the withdrawn row.
    private func withdrawAndReplace(existing: LocalCatalogCorrection) async {
        submitting = true
        defer { submitting = false }
        do {
            try await appEnv.client.withdrawCatalogCorrection(
                catalogID: catalogID,
                correctionID: existing.id
            )
            // Close the local row immediately so the pre-flight banner
            // clears and a second tap can't double-withdraw; the next
            // sync confirms the terminal state from the feed.
            Self.markWithdrawnLocally(existing)
            // Refresh idempotency so the replacement isn't a replay of
            // the withdrawn row.
            idempotencyKey = UUID().uuidString
            pendingError = nil
        } catch let err as SeedkeepError {
            pendingError = PendingError(
                kind: .other,
                message: "\(err.code): \(err.message)"
            )
        } catch {
            pendingError = PendingError(
                kind: .other,
                message: humanizeError(error)
            )
        }
    }

    /// Race-past-pre-flight 409 variant: server returned the conflicting
    /// DTO directly, so we don't need the local-row hop. Withdraws the
    /// server-side row by id and refreshes the idempotency key.
    private func withdrawAndReplaceServerConflict() async {
        guard let conflict = serverConflict else { return }
        submitting = true
        defer { submitting = false }
        do {
            try await appEnv.client.withdrawCatalogCorrection(
                catalogID: catalogID,
                correctionID: conflict.id
            )
            // If the conflicting row has already synced locally, close
            // it too so YouView and the pre-flight banner don't keep
            // presenting it as open.
            if let local = allCorrections.first(where: { $0.id == conflict.id }) {
                Self.markWithdrawnLocally(local)
            }
            idempotencyKey = UUID().uuidString
            pendingError = nil
            serverConflict = nil
        } catch let err as SeedkeepError {
            pendingError = PendingError(
                kind: .other,
                message: "\(err.code): \(err.message)"
            )
        } catch {
            pendingError = PendingError(
                kind: .other,
                message: humanizeError(error)
            )
        }
    }

    // MARK: - Helpers

    /// Optimistically flips a local correction row to
    /// `dismissed/user_withdrawn` after a successful server withdraw,
    /// mirroring what the next sync will pull. Keeps the pre-flight
    /// banner (driven by the local `@Query`) honest immediately.
    static func markWithdrawnLocally(_ row: LocalCatalogCorrection) {
        row.status = "dismissed"
        row.dismissedReason = "user_withdrawn"
        row.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try? row.modelContext?.save()
    }

    /// Translate a typed `SeedkeepError` into the structured
    /// `PendingError` shape the GroupBox renders against. Error code
    /// values mirror the server route's discriminated responses
    /// (`bounds_violation`, `open_correction_exists`, `rate_limited`).
    private func mapServerError(_ err: SeedkeepError) -> PendingError {
        switch err.code {
        case "bounds_violation":
            return PendingError(
                kind: .boundsViolation,
                message: err.message,
                boundsHint: extractBoundsHint(from: err.message)
            )
        case "open_correction_exists":
            return PendingError(
                kind: .openCorrectionExists,
                message: err.message
            )
        case "rate_limited":
            // `retry_after_seconds` rides as an envelope-level sibling
            // of `error` and lands on the typed SeedkeepError — the
            // server messages carry no digits to parse.
            return PendingError(
                kind: .rateLimited,
                message: err.message,
                retryAfterSeconds: err.retryAfterSeconds
            )
        default:
            return PendingError(
                kind: .other,
                message: "\(err.code): \(err.message)"
            )
        }
    }

    /// Pull a bounds hint string out of a 400 message, when present.
    /// Format: best-effort substring after the first colon. Falls back
    /// to nil so the renderer reaches for `describeBounds(field:)`.
    private func extractBoundsHint(from message: String) -> String? {
        guard let colon = message.firstIndex(of: ":") else { return nil }
        let after = message[message.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return after.isEmpty ? nil : after
    }

    /// Bucket-aware retry-after copy (spec §7).
    private func retryWindowCopy(seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "in about an hour" }
        if s < 60 { return "in a few seconds" }
        if s < 300 { return "in a few minutes" }
        if s < 1_800 {
            let minutes = max(5, Int((Double(s) / 60.0 / 5.0).rounded()) * 5)
            return "in about \(minutes) minutes"
        }
        return "in about an hour"
    }

    /// Label for a single field row inside the picker. Carries the
    /// current value (when known) plus the auto/reviewed routing tag.
    private func pickerLabel(for field: String) -> String {
        let title = Self.humanFieldName(field)
        let tag = CatalogFieldBounds.autoApplyFields.contains(field) ? "· auto" : "· reviewed"
        if let current = currentLabel(for: field) {
            return "\(title)   \(current)   \(tag)"
        }
        return "\(title)   (not set)   \(tag)"
    }

    /// Italic helper line under the numeric editor. Mirrors the server's
    /// `describeBounds` so the iOS hint stays in lockstep with 400-response
    /// bounds_hint payloads. Spec §7 ("Typical range … — outside that,
    /// we'll route to a human reviewer — no timeline yet").
    private var boundsHintLine: String {
        "Typical range: \(CatalogFieldBounds.describeBounds(field: selectedField)). Outside that, we'll route to a human reviewer — no timeline yet."
    }

    /// Non-blocking warning when the user's number trips the
    /// `suspectThresholds` table — usually a unit confusion (cm vs in).
    /// Stays in-bounds so the submission is still permitted; the server
    /// routes the row to `queue_for_review` regardless of AI score.
    private func suspectWarning(for field: String, value: String) -> String? {
        guard let threshold = CatalogFieldBounds.suspectThresholds[field],
              let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > threshold else {
            return nil
        }
        return "Did you mean centimeters? Enter inches."
    }

    /// Surface the current catalog value as a string for the picker row
    /// + the "Currently: X" hint. Returns `nil` when the snapshot
    /// doesn't carry the field (caller renders "(not set)").
    private func currentLabel(for field: String) -> String? {
        guard let snap = currentValues else { return nil }
        switch field {
        case "days_to_germinate_min", "days_to_germinate_max":
            return Self.formatRange(snap.days_to_germinate_min, snap.days_to_germinate_max, unit: "days")
        case "days_to_maturity_min", "days_to_maturity_max":
            return Self.formatRange(snap.days_to_maturity_min, snap.days_to_maturity_max, unit: "days")
        case "soil_temp_min_f", "soil_temp_max_f":
            return Self.formatRange(snap.soil_temp_min_f, snap.soil_temp_max_f, unit: "°F")
        case "seed_depth_inches":
            return snap.seed_depth_inches.map { "\($0) in" }
        case "plant_spacing_inches":
            return snap.plant_spacing_inches.map { "\($0) in" }
        case "row_spacing_inches":
            return snap.row_spacing_inches.map { "\($0) in" }
        case "hardiness_zone_min", "hardiness_zone_max":
            return Self.formatRange(snap.hardiness_zone_min, snap.hardiness_zone_max, unit: nil)
        case "viability_years":
            return snap.viability_years.map { "\($0) years" }
        case "sun_requirement":
            return snap.sun_requirement.map { humanizeEnum($0) }
        case "frost_tolerance":
            return snap.frost_tolerance.map { humanizeEnum($0) }
        case "sow_method":
            return snap.sow_method.map { humanizeEnum($0) }
        case "life_cycle":
            return snap.life_cycle.map { humanizeEnum($0) }
        case "scientific_name":
            return snap.scientific_name
        case "common_name":
            return catalogName
        case "variety", "company":
            return nil
        case "instructions":
            return snap.instructions.map { Self.previewSingleLine($0) }
        default:
            return nil
        }
    }

    /// Raw "current value" submitted as `client_seen_value` for the
    /// optimistic-concurrency check. Stringified so it matches the
    /// server's text comparison; nil when the catalog has no value
    /// (server treats NULL ↔ NULL as a match).
    private func rawCurrentValue(for field: String) -> String? {
        guard let snap = currentValues else { return nil }
        switch field {
        case "days_to_germinate_min": return snap.days_to_germinate_min.map(String.init)
        case "days_to_germinate_max": return snap.days_to_germinate_max.map(String.init)
        case "days_to_maturity_min":  return snap.days_to_maturity_min.map(String.init)
        case "days_to_maturity_max":  return snap.days_to_maturity_max.map(String.init)
        case "soil_temp_min_f":       return snap.soil_temp_min_f.map(String.init)
        case "soil_temp_max_f":       return snap.soil_temp_max_f.map(String.init)
        case "seed_depth_inches":     return snap.seed_depth_inches.map { String($0) }
        case "plant_spacing_inches":  return snap.plant_spacing_inches.map(String.init)
        case "row_spacing_inches":    return snap.row_spacing_inches.map(String.init)
        case "hardiness_zone_min":    return snap.hardiness_zone_min.map(String.init)
        case "hardiness_zone_max":    return snap.hardiness_zone_max.map(String.init)
        case "viability_years":       return snap.viability_years.map(String.init)
        case "sun_requirement":       return snap.sun_requirement
        case "frost_tolerance":       return snap.frost_tolerance
        case "sow_method":            return snap.sow_method
        case "life_cycle":            return snap.life_cycle
        case "scientific_name":       return snap.scientific_name
        case "common_name":           return catalogName
        case "instructions":          return snap.instructions
        default: return nil
        }
    }

    private func humanizeEnum(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Relative-time stub for the pre-flight banner. Keeps copy tight
    /// without pulling in `RelativeDateTimeFormatter` — the spec just
    /// asks for "submitted 2 hours ago" feel.
    private func relativeTime(_ epochMs: Int64) -> String {
        let now = Date()
        let then = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000.0)
        let seconds = max(0, Int(now.timeIntervalSince(then)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) minutes ago" }
        if seconds < 86_400 { return "\(seconds / 3600) hours ago" }
        return "\(seconds / 86_400) days ago"
    }

    // MARK: - Static field ordering + formatting

    /// Numeric fields in the spec's visual order (numbers section).
    private static let numericFieldsOrdered: [String] = [
        "days_to_maturity_min", "days_to_maturity_max",
        "days_to_germinate_min", "days_to_germinate_max",
        "soil_temp_min_f", "soil_temp_max_f",
        "plant_spacing_inches", "row_spacing_inches",
        "seed_depth_inches",
        "hardiness_zone_min", "hardiness_zone_max",
        "viability_years",
    ]

    /// Enum fields in the spec's visual order (pick-one section).
    private static let enumFieldsOrdered: [String] = [
        "sun_requirement", "frost_tolerance", "sow_method", "life_cycle",
    ]

    /// Free-text fields in the spec's visual order (text section).
    private static let freeTextFieldsOrdered: [String] = [
        "scientific_name", "common_name", "variety", "company", "instructions",
    ]

    private static func humanFieldName(_ field: String) -> String {
        switch field {
        case "days_to_germinate_min", "days_to_germinate_max":
            return "Days to germinate"
        case "days_to_maturity_min", "days_to_maturity_max":
            return "Days to maturity"
        case "soil_temp_min_f", "soil_temp_max_f":
            return "Soil temp"
        case "seed_depth_inches": return "Seed depth"
        case "plant_spacing_inches": return "Plant spacing"
        case "row_spacing_inches": return "Row spacing"
        case "hardiness_zone_min", "hardiness_zone_max":
            return "Hardiness zones"
        case "viability_years": return "Viability"
        case "sun_requirement": return "Sun"
        case "frost_tolerance": return "Frost tolerance"
        case "sow_method": return "Sow method"
        case "life_cycle": return "Life cycle"
        case "scientific_name": return "Scientific name"
        case "common_name": return "Common name"
        case "variety": return "Variety"
        case "company": return "Company"
        case "instructions": return "Instructions"
        default: return field
        }
    }

    private static func formatRange<T: Numeric & CustomStringConvertible>(
        _ minVal: T?, _ maxVal: T?, unit: String?
    ) -> String? {
        switch (minVal, maxVal) {
        case let (lo?, hi?):
            let body = "\(lo)–\(hi)"
            return unit.map { "\(body) \($0)" } ?? body
        case let (lo?, nil):
            let body = "\(lo)+"
            return unit.map { "\(body) \($0)" } ?? body
        case let (nil, hi?):
            let body = "≤\(hi)"
            return unit.map { "\(body) \($0)" } ?? body
        default:
            return nil
        }
    }

    private static func previewSingleLine(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 32
        if collapsed.count <= limit { return "\"\(collapsed)\"" }
        let prefix = collapsed.prefix(limit)
        return "\"\(prefix)…\""
    }
}

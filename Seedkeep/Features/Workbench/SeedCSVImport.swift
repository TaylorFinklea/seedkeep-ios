// CSV import for the Seeds table (R4, slice C). It reads back what `SeedCSV` exports: a row that
// matches an existing seed (name, variety, company and year) updates it, any other valid row creates
// one, and missing locations and tags are created by name.
//
// Everything in this file is pure and runs off the main actor: reading the file, decoding it,
// parsing it, and planning the import over value snapshots. The writes are `SeedCSVImportWriter`'s.
import Foundation
import SwiftData
import SeedkeepKit

enum SeedCSVImport {
    /// Files over this size are refused before they are read whole.
    static let maxFileBytes = 5 * 1024 * 1024
    /// Files with more data rows than this are refused, and nothing is imported.
    static let maxDataRows = 5_000

    /// The columns the import reads. `window` is exported but ignored, like any unknown column.
    enum Column: String, CaseIterable, Hashable, Sendable {
        case name, variety, type, company, year, packets, status
        case storedIn = "stored_in"
        case tags, notes
    }

    /// Matching is on only when the header has all four.
    static let identityColumns: Set<Column> = [.name, .variety, .company, .year]

    // MARK: - Errors

    /// A problem with the whole file. Nothing is imported.
    struct FatalError: Error, Equatable, Sendable {
        let message: String

        static let tooLarge = FatalError(message: "This file is larger than 5 MB. Split it into smaller files and import each one.")
        static let notUTF8 = FatalError(message: "This file isn't UTF-8 text. Save it as “CSV UTF-8” and try again.")
        static let unreadable = FatalError(message: "Couldn't read this file. Check that it's downloaded and try again.")
        static let noHeader = FatalError(message: "This file is empty. The first line should name the columns, starting with “name”.")
        static let noNameColumn = FatalError(message: "This file has no “name” column, so no seed can be read from it.")
        static let tooManyRows = FatalError(message: "This file has more than 5,000 seeds. Split it into smaller files and import each one.")

        static func unterminatedQuote(line: Int) -> FatalError {
            FatalError(message: "Line \(line): a quoted value is never closed, so the file can't be read.")
        }

        static func duplicateColumn(_ name: String, line: Int) -> FatalError {
            FatalError(message: "Line \(line): the column “\(name)” appears more than once.")
        }
    }

    /// A problem with one row (or one cell). That row is left out; the others go on.
    struct RowIssue: Equatable, Sendable {
        let line: Int
        /// The column header as the file spells it, or nil for the row as a whole.
        let column: String?
        let message: String

        var text: String {
            if let column { return "Line \(line), \(column): \(message)" }
            return "Line \(line): \(message)"
        }
    }

    // MARK: - Reading

    /// Reads a picked file with balanced security-scoped access: access stops on every path, including
    /// a refusal. Files over `maxBytes` are refused from their size before they are read, and the read
    /// itself is bounded, so a file that grows or misreports its size is still refused.
    static func readFile(
        at url: URL,
        maxBytes: Int = maxFileBytes,
        startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) throws(FatalError) -> Data {
        let accessing = startAccess(url)
        defer { if accessing { stopAccess(url) } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            throw .tooLarge
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw .unreadable
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            throw .unreadable
        }
        guard data.count <= maxBytes else { throw .tooLarge }
        return data
    }

    /// UTF-8 with or without a byte order mark. Anything else is refused.
    static func decode(_ data: Data) throws(FatalError) -> String {
        var bytes = data[...]
        if bytes.starts(with: SeedCSV.byteOrderMark) {
            bytes = bytes.dropFirst(SeedCSV.byteOrderMark.count)
        }
        guard let text = String(validating: bytes, as: UTF8.self) else { throw .notUTF8 }
        return text
    }

    // MARK: - Records (RFC 4180)

    /// One CSV record and the physical line it starts on.
    struct Record: Equatable, Sendable {
        var fields: [String]
        let line: Int
    }

    /// Splits text into records: CRLF, LF or a bare CR ends a record; quoted fields may hold commas,
    /// doubled quotes and line breaks. Line numbers are physical lines, so a record after a quoted
    /// line break reports the line it starts on. Lines with no values (empty, whitespace only, or only commas) are skipped. An unterminated quote is fatal.
    static func records(_ text: String) throws(FatalError) -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var line = 1
        var recordLine = 1
        var inQuotes = false
        var quoteLine = 1
        var fieldStarted = false
        var recordHasContent = false

        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let scalar = pending {
                pending = nil
                return scalar
            }
            return iterator.next()
        }

        func endField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }

        func endRecord() {
            endField()
            // A line with no values at all (empty, whitespace only, or only commas) is skipped.
            if fields.contains(where: { !$0.allSatisfy(\.isWhitespace) }) {
                records.append(Record(fields: fields, line: recordLine))
            }
            fields = []
            recordHasContent = false
        }

        while let scalar = next() {
            if inQuotes {
                switch scalar {
                case "\"":
                    if let following = next() {
                        if following == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                case "\r":
                    field.append(scalar)
                    if let following = next() {
                        if following == "\n" { field.append(following) } else { pending = following }
                    }
                    line += 1
                case "\n":
                    field.append(scalar)
                    line += 1
                default:
                    field.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where !fieldStarted:
                inQuotes = true
                fieldStarted = true
                recordHasContent = true
                quoteLine = line
            case ",":
                recordHasContent = true
                endField()
            case "\r", "\n":
                if scalar == "\r", let following = next(), following != "\n" {
                    pending = following
                }
                endRecord()
                line += 1
                recordLine = line
            default:
                fieldStarted = true
                field.append(scalar)
            }
        }
        if inQuotes { throw .unterminatedQuote(line: quoteLine) }
        if recordHasContent || !field.isEmpty || !fields.isEmpty {
            endRecord()
        }
        return records
    }

    // MARK: - Values

    /// Removes the formula guard once: one leading apostrophe followed by a guarded character
    /// (`=`, `+`, `-`, `@`, a tab, a CR or another apostrophe). Any other apostrophe is kept.
    static func unguard(_ cell: String) -> String {
        let scalars = cell.unicodeScalars
        guard scalars.first == "'",
              let second = scalars.dropFirst().first,
              SeedCSV.guardedLeads.contains(second) else { return cell }
        return String(String.UnicodeScalarView(scalars.dropFirst()))
    }

    /// Splits an (unguarded) Tags cell on unescaped `;`, unescapes `\;` and `\\`, trims each name, and
    /// drops blanks and case-insensitive duplicates (the first spelling stays).
    static func splitTags(_ cell: String) -> [String] {
        var names: [String] = []
        var current = String.UnicodeScalarView()
        var escaping = false
        for scalar in cell.unicodeScalars {
            if escaping {
                // Only `\;` and `\\` are escapes (what export writes). Any other backslash is kept, so a
                // legacy tag such as `C:\Garden` imports unchanged.
                if scalar != ";" && scalar != "\\" { current.append("\\") }
                current.append(scalar)
                escaping = false
            } else if scalar == "\\" {
                escaping = true
            } else if scalar == ";" {
                names.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if escaping { current.append("\\") }
        names.append(String(current))

        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(normalized(trimmed)).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The one normalization for seed keys, location and tag lookup, and every de-duplication.
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: posix)
    }

    // MARK: - Parsed file

    /// One valid row. Text values are unguarded and trimmed; a blank is "". Values of columns the
    /// header doesn't have stay at their blanks (see `ParsedFile.present`).
    struct Row: Equatable, Sendable {
        let line: Int
        var name: String
        var variety = ""
        var type = ""
        var company = ""
        var year: Int?
        var packets: Int?
        var status: SeedState?
        var storedIn = ""
        var tags: [String] = []
        var notes = ""
    }

    struct ParsedFile: Equatable, Sendable {
        /// The known columns the header has.
        let present: Set<Column>
        /// Valid rows, in file order.
        let rows: [Row]
        /// Every row and cell problem, in file order.
        let issues: [RowIssue]
        /// How many rows had a problem (a row with two bad cells counts once).
        let errorRowCount: Int

        var matchingEnabled: Bool { SeedCSVImport.identityColumns.isSubset(of: present) }
    }

    /// Parses decoded text. Fatal problems throw; row problems are collected.
    static func parse(_ text: String) throws(FatalError) -> ParsedFile {
        // A byte order mark already decoded into the text is not part of the first header.
        let all = try records(text.unicodeScalars.first == "\u{FEFF}" ? String(text.unicodeScalars.dropFirst()) : text)
        guard let header = all.first else { throw .noHeader }

        var columnIndex: [Column: Int] = [:]
        var headerNames: [Column: String] = [:]
        var seenHeaders: Set<String> = []
        for (index, raw) in header.fields.enumerated() {
            let spelled = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let folded = normalized(spelled)
            guard !folded.isEmpty else { continue }
            guard seenHeaders.insert(folded).inserted else {
                throw .duplicateColumn(spelled, line: header.line)
            }
            if let column = Column(rawValue: folded) {
                columnIndex[column] = index
                headerNames[column] = spelled
            }
        }
        guard columnIndex[.name] != nil else { throw .noNameColumn }
        let dataRecords = all.dropFirst()
        guard dataRecords.count <= maxDataRows else { throw .tooManyRows }

        let width = header.fields.count
        var rows: [Row] = []
        rows.reserveCapacity(dataRecords.count)
        var issues: [RowIssue] = []
        var errorRows = 0

        for record in dataRecords {
            guard record.fields.count == width else {
                issues.append(RowIssue(
                    line: record.line,
                    column: nil,
                    message: "has \(record.fields.count) values, but the header has \(width) columns."
                ))
                errorRows += 1
                continue
            }
            var rowIssues: [RowIssue] = []
            func cell(_ column: Column) -> String? {
                columnIndex[column].map { record.fields[$0] }
            }
            func text(_ column: Column) -> String {
                guard let raw = cell(column) else { return "" }
                return unguard(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func fail(_ column: Column, _ message: String) {
                rowIssues.append(RowIssue(line: record.line, column: headerNames[column], message: message))
            }

            var row = Row(line: record.line, name: text(.name))
            if row.name.isEmpty { fail(.name, "a name is required.") }
            row.variety = text(.variety)
            row.type = text(.type)
            row.company = text(.company)
            row.storedIn = text(.storedIn)
            row.notes = text(.notes)
            if let raw = cell(.tags) { row.tags = splitTags(unguard(raw)) }

            if let raw = cell(.year)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                if let year = Int(raw), (1900...2100).contains(year) {
                    row.year = year
                } else {
                    fail(.year, "“\(raw)” isn't a year from 1900 to 2100.")
                }
            }
            if let raw = cell(.packets)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                if let packets = Int(raw), packets >= 0 {
                    row.packets = packets
                } else {
                    fail(.packets, "“\(raw)” isn't a whole number of packets (0 or more).")
                }
            }
            if let raw = cell(.status)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                if let state = SeedState(rawValue: raw.lowercased()) {
                    row.status = state
                } else {
                    fail(.status, "“\(raw)” isn't a status. Use active, wishlist, saved or archived.")
                }
            }

            if rowIssues.isEmpty {
                rows.append(row)
            } else {
                issues += rowIssues
                errorRows += 1
            }
        }
        return ParsedFile(
            present: Set(columnIndex.keys),
            rows: rows,
            issues: issues,
            errorRowCount: errorRows
        )
    }

    /// Decodes and parses file bytes.
    static func parse(data: Data) throws(FatalError) -> ParsedFile {
        try parse(try decode(data))
    }

    // MARK: - Snapshots

    /// The household's live seeds as export shows them, and its live locations and tags.
    struct Snapshot: Equatable, Sendable {
        struct Named: Equatable, Sendable {
            let id: String
            let name: String
        }

        let householdID: String
        let seeds: [SeedTableRow]
        let locations: [Named]
        let tags: [Named]
    }

    /// Reads a snapshot from the store in its own context, so it can run off the main actor. Seeds
    /// map the way `SeedTableRow.rows` maps them for export (a test pins the two together): the
    /// display name, trimmed text, and location and tag names resolved among live ones only.
    static func snapshot(householdID: String, container: ModelContainer) throws -> Snapshot {
        let context = ModelContext(container)
        let seeds = try context.fetch(FetchDescriptor<LocalSeed>(
            predicate: #Predicate { $0.householdID == householdID && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.id)]
        ))
        let locations = try context.fetch(FetchDescriptor<LocalLocation>(
            predicate: #Predicate { $0.householdID == householdID && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.id)]
        ))
        let tags = try context.fetch(FetchDescriptor<LocalTag>(
            predicate: #Predicate { $0.householdID == householdID && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.id)]
        ))
        var locationNames: [String: String] = [:]
        for location in locations { locationNames[location.id] = location.name }
        var tagNames: [String: String] = [:]
        for tag in tags { tagNames[tag.id] = tag.name }
        let rows = seeds.map { seed in
            let tagIDs = seed.tagIDs
            return SeedTableRow(
                id: seed.id,
                name: seed.displayName,
                variety: seed.customVariety?.trimmedNonEmpty ?? "",
                type: seed.customType?.trimmedNonEmpty ?? "",
                company: seed.customCompany?.trimmedNonEmpty ?? "",
                year: seed.yearPacked,
                packets: seed.packetCount,
                state: seed.stateRaw,
                locationID: seed.locationID,
                locationName: seed.locationID.flatMap { locationNames[$0] } ?? "",
                tagIDs: tagIDs,
                tagNames: tagIDs.compactMap { tagNames[$0] },
                notes: seed.notes ?? "",
                verdict: nil,
                verdictLabel: "",
                catalogID: seed.catalogID,
                updatedAt: seed.updatedAt
            )
        }
        return Snapshot(
            householdID: householdID,
            seeds: rows,
            locations: locations.map { Snapshot.Named(id: $0.id, name: $0.name) },
            tags: tags.map { Snapshot.Named(id: $0.id, name: $0.name) }
        )
    }

    /// The snapshot and plan, both off the main actor.
    static func detachedPlan(
        _ file: ParsedFile,
        householdID: String,
        container: ModelContainer,
        savedSeedIDs: [Int: String]
    ) async throws -> (plan: Plan, snapshot: Snapshot) {
        try await Task.detached(priority: .userInitiated) {
            let snapshot = try snapshot(householdID: householdID, container: container)
            return (plan(file, snapshot: snapshot, savedSeedIDs: savedSeedIDs), snapshot)
        }.value
    }

    // MARK: - Plan

    /// A location or tag: one that exists, or one this import creates (by its normalized name).
    enum Ref: Hashable, Sendable {
        case existing(String)
        case new(String)
    }

    /// A location or tag the import creates, with the file's first spelling.
    struct NewDependency: Equatable, Sendable {
        let key: String
        let name: String
    }

    /// A new seed's values. `type` is applied with `setLocalCustomType` after the create.
    struct NewSeed: Equatable, Sendable {
        var name: String
        var variety: String?
        var company: String?
        var year: Int?
        var packets: Int
        var state: SeedState
        var location: Ref?
        var tags: [Ref]
        var notes: String?
        var type: String?
    }

    /// The fields an update changes. `nil` leaves a field alone; `.some(nil)` clears it.
    struct Changes: Equatable, Sendable {
        var state: SeedState?
        var packets: Int?
        var location: Ref??
        var notes: String??
        /// The whole new list: the file's named tags, then the seed's unresolved tag ids.
        var tags: [Ref]?
        /// Applied with `setLocalCustomType`, not in the patch.
        var type: String??

        /// True when nothing in the `enqueueUpdateSeed` patch changes.
        var patchIsEmpty: Bool {
            state == nil && packets == nil && location == nil && notes == nil && tags == nil
        }

        var isEmpty: Bool { patchIsEmpty && type == nil }
    }

    enum SkipReason: Equatable, Sendable {
        case ambiguousSeed(count: Int)
        case duplicateInFile(firstLine: Int)
        case ambiguousLocation(String)
        case ambiguousTag(String)
        /// A seed saved by an earlier attempt of this import is gone.
        case savedSeedGone
        /// Another row already updates (or leaves unchanged) the same seed.
        case seedUsedByLine(Int)

        var text: String {
            switch self {
            case .ambiguousSeed(let count):
                return "\(count) seeds already have this name, variety, company and year, so it's unclear which to update."
            case .duplicateInFile(let firstLine):
                return "the same seed is on line \(firstLine), which is used instead."
            case .ambiguousLocation(let name):
                return "more than one location is named “\(name)”."
            case .ambiguousTag(let name):
                return "more than one tag is named “\(name)”."
            case .savedSeedGone:
                return "the seed saved from this row earlier was removed."
            case .seedUsedByLine(let line):
                return "line \(line) already updates the same seed."
            }
        }
    }

    enum Action: Equatable, Sendable {
        case create(NewSeed)
        /// `targetUpdatedAt` pins the snapshot the change was planned against.
        case update(seedID: String, targetUpdatedAt: Int64, changes: Changes)
        case unchanged(seedID: String, targetUpdatedAt: Int64)
        case skipped(SkipReason)

        var writes: Bool {
            switch self {
            case .create, .update: return true
            case .unchanged, .skipped: return false
            }
        }
    }

    struct PlannedRow: Equatable, Sendable {
        let line: Int
        let name: String
        let action: Action
    }

    struct Plan: Equatable, Sendable {
        let householdID: String
        let matchingEnabled: Bool
        let rows: [PlannedRow]
        let newLocations: [NewDependency]
        let newTags: [NewDependency]
        let issues: [RowIssue]
        let errorRowCount: Int

        var newCount: Int { rows.count(where: { if case .create = $0.action { true } else { false } }) }
        var updatedCount: Int { rows.count(where: { if case .update = $0.action { true } else { false } }) }
        var unchangedCount: Int { rows.count(where: { if case .unchanged = $0.action { true } else { false } }) }
        var skippedCount: Int { rows.count(where: { if case .skipped = $0.action { true } else { false } }) }
        var writeCount: Int { rows.count(where: { $0.action.writes }) }

        /// Skipped rows with their reasons, as preview lines.
        var skippedTexts: [String] {
            rows.compactMap { row in
                guard case .skipped(let reason) = row.action else { return nil }
                return "Line \(row.line) (\(row.name)): \(reason.text)"
            }
        }
    }

    struct SeedKey: Hashable, Sendable {
        let name: String
        let variety: String
        let company: String
        let year: Int?

        init(name: String, variety: String, company: String, year: Int?) {
            self.name = SeedCSVImport.normalized(name)
            self.variety = SeedCSVImport.normalized(variety)
            self.company = SeedCSVImport.normalized(company)
            self.year = year
        }
    }

    /// Plans the import over value snapshots. Pure. `savedSeedIDs` maps a row's line to the seed an
    /// earlier attempt of this import saved from it: that row targets the same seed again, so a retry
    /// never creates a second one.
    static func plan(
        _ file: ParsedFile,
        snapshot: Snapshot,
        savedSeedIDs: [Int: String] = [:]
    ) -> Plan {
        let present = file.present
        let matching = file.matchingEnabled

        var seedsByID: [String: SeedTableRow] = [:]
        seedsByID.reserveCapacity(snapshot.seeds.count)
        var seedIndex: [SeedKey: [String]] = [:]
        for seed in snapshot.seeds {
            seedsByID[seed.id] = seed
            if matching {
                let key = SeedKey(name: seed.name, variety: seed.variety, company: seed.company, year: seed.year)
                seedIndex[key, default: []].append(seed.id)
            }
        }
        var locationIndex: [String: [String]] = [:]
        for location in snapshot.locations {
            locationIndex[normalized(location.name), default: []].append(location.id)
        }
        var tagIndex: [String: [String]] = [:]
        for tag in snapshot.tags {
            tagIndex[normalized(tag.name), default: []].append(tag.id)
        }
        let liveLocationIDs = Set(snapshot.locations.map(\.id))
        let liveTagIDs = Set(snapshot.tags.map(\.id))

        var firstLineByKey: [SeedKey: Int] = [:]
        // A seed is targeted by one row at most (a retry's saved row and another row could both reach
        // it). Rows an earlier attempt saved keep their seeds.
        var lineBySeedID: [String: Int] = [:]
        for (line, seedID) in savedSeedIDs where lineBySeedID[seedID].map({ line < $0 }) ?? true {
            lineBySeedID[seedID] = line
        }
        var newLocations: [NewDependency] = []
        var newLocationKeys: Set<String> = []
        var newTags: [NewDependency] = []
        var newTagKeys: Set<String> = []
        var planned: [PlannedRow] = []
        planned.reserveCapacity(file.rows.count)

        rowLoop: for row in file.rows {
            func skip(_ reason: SkipReason) {
                planned.append(PlannedRow(line: row.line, name: row.name, action: .skipped(reason)))
            }

            // The target seed, if any.
            var target: SeedTableRow?
            // The first row with a key that's used (created, updated or unchanged) wins; a later row with
            // the same key is a duplicate. A skipped row doesn't claim its key.
            let rowKey = matching
                ? SeedKey(name: row.name, variety: row.variety, company: row.company, year: row.year)
                : nil
            if let rowKey, let first = firstLineByKey[rowKey] {
                skip(.duplicateInFile(firstLine: first))
                continue
            }
            if let savedID = savedSeedIDs[row.line] {
                guard let saved = seedsByID[savedID] else {
                    skip(.savedSeedGone)
                    continue
                }
                target = saved
            } else if let rowKey {
                let matches = seedIndex[rowKey] ?? []
                if matches.count > 1 {
                    skip(.ambiguousSeed(count: matches.count))
                    continue
                }
                target = matches.first.flatMap { seedsByID[$0] }
            }
            if let target, let claimant = lineBySeedID[target.id], claimant != row.line {
                skip(.seedUsedByLine(claimant))
                continue
            }

            // Locations and tags, by name.
            var spellings: [String: String] = [:]
            var location: Ref?
            if present.contains(.storedIn), !row.storedIn.isEmpty {
                let key = normalized(row.storedIn)
                let ids = locationIndex[key] ?? []
                if ids.count > 1 {
                    skip(.ambiguousLocation(row.storedIn))
                    continue
                }
                location = ids.first.map(Ref.existing) ?? .new(key)
                spellings[key] = row.storedIn
            }
            var tags: [Ref] = []
            var tagSpellings: [String: String] = [:]
            if present.contains(.tags) {
                for name in row.tags {
                    let key = normalized(name)
                    let ids = tagIndex[key] ?? []
                    if ids.count > 1 {
                        skip(.ambiguousTag(name))
                        continue rowLoop
                    }
                    tags.append(ids.first.map(Ref.existing) ?? .new(key))
                    tagSpellings[key] = name
                }
            }

            let action: Action
            var usedLocation: Ref?
            var usedTags: [Ref] = []
            if let target {
                let changes = diff(
                    row, against: target, present: present, location: location, tags: tags,
                    liveLocationIDs: liveLocationIDs, liveTagIDs: liveTagIDs
                )
                if changes.isEmpty {
                    action = .unchanged(seedID: target.id, targetUpdatedAt: target.updatedAt)
                } else {
                    action = .update(seedID: target.id, targetUpdatedAt: target.updatedAt, changes: changes)
                    if case .some(.some(let ref)) = changes.location { usedLocation = ref }
                    usedTags = changes.tags ?? []
                }
            } else {
                action = .create(NewSeed(
                    name: row.name,
                    variety: row.variety.isEmpty ? nil : row.variety,
                    company: row.company.isEmpty ? nil : row.company,
                    year: row.year,
                    // As Add Seed: no packets on the wishlist, one otherwise.
                    packets: row.packets ?? ((row.status ?? .active) == .wishlist ? 0 : 1),
                    state: row.status ?? .active,
                    location: location,
                    tags: tags,
                    notes: row.notes.isEmpty ? nil : row.notes,
                    type: row.type.isEmpty ? nil : row.type
                ))
                usedLocation = location
                usedTags = tags
            }

            // New locations and tags, once each, only for rows that will run.
            if case .new(let key) = usedLocation, newLocationKeys.insert(key).inserted {
                newLocations.append(NewDependency(key: key, name: spellings[key] ?? key))
            }
            for case .new(let key) in usedTags where newTagKeys.insert(key).inserted {
                newTags.append(NewDependency(key: key, name: tagSpellings[key] ?? key))
            }
            if let rowKey { firstLineByKey[rowKey] = row.line }
            if let target { lineBySeedID[target.id] = row.line }
            planned.append(PlannedRow(line: row.line, name: row.name, action: action))
        }

        return Plan(
            householdID: snapshot.householdID,
            matchingEnabled: matching,
            rows: planned,
            newLocations: newLocations,
            newTags: newTags,
            issues: file.issues,
            errorRowCount: file.errorRowCount
        )
    }

    /// The round-trip rules for an update, for the columns the file has. Identity values (name,
    /// variety, company, year) and values export doesn't carry are never changed.
    static func diff(
        _ row: Row,
        against seed: SeedTableRow,
        present: Set<Column>,
        location: Ref?,
        tags: [Ref],
        liveLocationIDs: Set<String>,
        liveTagIDs: Set<String>
    ) -> Changes {
        var changes = Changes()
        // A blank status or packets leaves the field alone.
        if present.contains(.status), let state = row.status, state.rawValue != seed.state {
            changes.state = state
        }
        if present.contains(.packets), let packets = row.packets, packets != seed.packets {
            changes.packets = packets
        }
        // A blank type or notes clears it.
        if present.contains(.type), row.type != seed.type.trimmingCharacters(in: .whitespacesAndNewlines) {
            changes.type = .some(row.type.isEmpty ? nil : row.type)
        }
        if present.contains(.notes) {
            let current = seed.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if row.notes != current {
                changes.notes = .some(row.notes.isEmpty ? nil : row.notes)
            }
        }
        if present.contains(.storedIn) {
            if let location {
                if case .existing(let id) = location, id == seed.locationID {
                    // Same location.
                } else {
                    changes.location = .some(location)
                }
            } else if let current = seed.locationID, liveLocationIDs.contains(current) {
                // Blank clears a location that resolves. A blank because the seed's location no longer
                // resolves leaves it alone.
                changes.location = .some(nil)
            }
        }
        if present.contains(.tags) {
            let named = seed.tagIDs.filter { liveTagIDs.contains($0) }
            let unresolved = seed.tagIDs.filter { !liveTagIDs.contains($0) }
            var fileIDs: Set<String> = []
            var hasNew = false
            for ref in tags {
                switch ref {
                case .existing(let id): fileIDs.insert(id)
                case .new: hasNew = true
                }
            }
            if hasNew || fileIDs != Set(named) {
                // Unresolved tag ids are always kept.
                changes.tags = tags + unresolved.map(Ref.existing)
            }
        }
        return changes
    }
}

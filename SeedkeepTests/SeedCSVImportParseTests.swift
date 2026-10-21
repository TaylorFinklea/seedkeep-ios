import Foundation
import Testing
@testable import Seedkeep
import SeedkeepKit

/// CSV import, slice C: reading, decoding, RFC 4180 records, the header rules and every value rule.
@Suite("Seeds CSV import — reading and parsing")
struct SeedCSVImportParseTests {
    static let header = "name,variety,type,company,year,packets,status,stored_in,tags,notes,window"

    private static func parse(_ text: String) throws -> SeedCSVImport.ParsedFile {
        try SeedCSVImport.parse(text)
    }

    private static func fatal(_ text: String) -> SeedCSVImport.FatalError? {
        do {
            _ = try SeedCSVImport.parse(text)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Records

    @Test("CRLF and LF both end records, and quoted fields keep commas, doubled quotes and line breaks")
    func quotesAndNewlines() throws {
        let records = try SeedCSVImport.records("a,b\r\n\"x, y\",\"say \"\"hi\"\"\"\n\"one\r\ntwo\nthree\",z\n")
        #expect(records.map(\.fields) == [
            ["a", "b"],
            ["x, y", "say \"hi\""],
            ["one\r\ntwo\nthree", "z"],
        ])
        #expect(records.map(\.line) == [1, 2, 3])
    }

    @Test("line numbers are physical lines, after quoted line breaks and skipped blank lines")
    func physicalLineNumbers() throws {
        let text = "name,notes\n\"A\",\"line\nline\nline\"\n\nB,ok\n,\nC,\"x\r\ny\"\nD,\n"
        let records = try SeedCSVImport.records(text)
        #expect(records.map { $0.fields[0] } == ["name", "A", "B", "C", "D"])
        #expect(records.map(\.line) == [1, 2, 6, 8, 10])
    }

    @Test("a bare CR ends a record outside quotes and stays inside a quoted field")
    func bareCR() throws {
        let records = try SeedCSVImport.records("name,notes\rA,\"x\ry\"\rB,z")
        #expect(records.map(\.fields) == [["name", "notes"], ["A", "x\ry"], ["B", "z"]])
        #expect(records.map(\.line) == [1, 2, 4])
    }

    @Test("whitespace-only lines are skipped like blank ones, not reported as ragged rows")
    func whitespaceLines() throws {
        let file = try Self.parse("name,variety\n   \nBasil,Genovese\n \t \n,,\n , \nDill,\n")
        #expect(file.rows.map(\.name) == ["Basil", "Dill"])
        #expect(file.issues.isEmpty)
    }

    @Test("a file without a final line break keeps its last record")
    func noTrailingNewline() throws {
        #expect(try SeedCSVImport.records("a,b\nc,d").map(\.fields) == [["a", "b"], ["c", "d"]])
        #expect(try SeedCSVImport.records("a,b\nc,").map(\.fields) == [["a", "b"], ["c", ""]])
    }

    @Test("an unterminated quote is fatal, naming the line it starts on")
    func unterminatedQuote() {
        let error = Self.fatal("name,notes\nA,ok\nB,\"never\nends\n")
        #expect(error == .unterminatedQuote(line: 3))
    }

    // MARK: - Decoding and reading

    @Test("UTF-8 decodes with or without a byte order mark; anything else is refused")
    func decoding() throws {
        let plain = Data("name\nÑandú\n".utf8)
        #expect(try SeedCSVImport.decode(plain) == "name\nÑandú\n")
        let marked = Data(SeedCSV.byteOrderMark) + plain
        #expect(try SeedCSVImport.decode(marked) == "name\nÑandú\n")
        let parsed = try SeedCSVImport.parse(data: marked)
        #expect(parsed.rows.map(\.name) == ["Ñandú"], "the mark doesn't leak into the first header")

        let utf16 = try #require("name\nBasil\n".data(using: .utf16))
        #expect(throws: SeedCSVImport.FatalError.notUTF8) { try SeedCSVImport.decode(utf16) }
        let latin1 = try #require("name\nÑandú\n".data(using: .isoLatin1))
        #expect(throws: SeedCSVImport.FatalError.notUTF8) { try SeedCSVImport.decode(latin1) }
    }

    @Test("reading balances security-scoped access on success, an oversized file and a missing file")
    func readBalancesAccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var starts = 0
        var stops = 0
        func read(_ url: URL, maxBytes: Int) throws -> Data {
            try SeedCSVImport.readFile(
                at: url, maxBytes: maxBytes,
                startAccess: { _ in starts += 1; return true },
                stopAccess: { _ in stops += 1 }
            )
        }

        let small = directory.appendingPathComponent("small.csv")
        try Data("name\nBasil\n".utf8).write(to: small)
        #expect(try read(small, maxBytes: 100) == Data("name\nBasil\n".utf8))
        #expect((starts, stops) == (1, 1))

        let large = directory.appendingPathComponent("large.csv")
        try Data(repeating: 0x41, count: 101).write(to: large)
        #expect(throws: SeedCSVImport.FatalError.tooLarge) { try read(large, maxBytes: 100) }
        #expect((starts, stops) == (2, 2))

        let missing = directory.appendingPathComponent("missing.csv")
        #expect(throws: SeedCSVImport.FatalError.unreadable) { try read(missing, maxBytes: 100) }
        #expect((starts, stops) == (3, 3))

        // Access that wasn't granted isn't stopped.
        _ = try SeedCSVImport.readFile(
            at: small, maxBytes: 100,
            startAccess: { _ in false },
            stopAccess: { _ in Issue.record("stopped access that never started") }
        )
    }

    @Test("the size limit is 5 MB")
    func sizeLimit() {
        #expect(SeedCSVImport.maxFileBytes == 5 * 1024 * 1024)
    }

    // MARK: - Header

    @Test("no header, a missing name column and duplicate headers are fatal")
    func headerErrors() {
        #expect(Self.fatal("") == .noHeader)
        #expect(Self.fatal("\n\n") == .noHeader)
        #expect(Self.fatal("variety,company\nA,B\n") == .noNameColumn)
        #expect(Self.fatal("name,Notes, notes \nA,x,y\n") == .duplicateColumn("notes", line: 1))
        #expect(Self.fatal("Name,NAME\nA,B\n") == .duplicateColumn("NAME", line: 1))
        #expect(Self.fatal("name,Stored_In,STORED_IN\nA,B,C\n") == .duplicateColumn("STORED_IN", line: 1),
                "headers fold with the same POSIX normalization as everything else")
    }

    @Test("headers match case-insensitively after trimming; unknown columns and window are ignored")
    func headerMatching() throws {
        let file = try Self.parse(" Name ,VARIETY,Color,window\nBasil,Genovese,green,Plant now\n")
        #expect(file.present == [.name, .variety])
        #expect(file.rows.map(\.name) == ["Basil"])
        #expect(file.rows.first?.variety == "Genovese")
        #expect(!file.matchingEnabled)
    }

    @Test("blank header cells are ignored rather than counted as duplicates")
    func blankHeaderCells() throws {
        let file = try Self.parse("name,,\nBasil,,\n")
        #expect(file.rows.map(\.name) == ["Basil"])
    }

    @Test("more than 5,000 data rows is fatal; exactly 5,000 is fine")
    func rowLimit() throws {
        let ok = "name\n" + String(repeating: "Basil\n", count: 5_000)
        #expect(try Self.parse(ok).rows.count == 5_000)
        let over = "name\n" + String(repeating: "Basil\n", count: 5_001)
        #expect(Self.fatal(over) == .tooManyRows)
    }

    @Test("a ragged row is a row error, and the other rows go on")
    func raggedRows() throws {
        let file = try Self.parse("name,variety\nBasil\nDill,Bouquet\nKale,Red,extra\n")
        #expect(file.rows.map(\.name) == ["Dill"])
        #expect(file.errorRowCount == 2)
        #expect(file.issues.map(\.line) == [2, 4])
        #expect(file.issues.allSatisfy { $0.column == nil })
    }

    // MARK: - Values

    @Test("name is required and trimmed")
    func nameRule() throws {
        let file = try Self.parse("name,variety\n  Basil  ,\n   ,x\n")
        #expect(file.rows.map(\.name) == ["Basil"])
        #expect(file.issues == [SeedCSVImport.RowIssue(line: 3, column: "name", message: "a name is required.")])
    }

    @Test("year is blank or an integer from 1900 to 2100")
    func yearRule() throws {
        let file = try Self.parse("name,Year\nA,\nB,1900\nC,2100\nD,1899\nE,2101\nF,20x4\nG, 2024 \n")
        #expect(file.rows.map(\.name) == ["A", "B", "C", "G"])
        #expect(file.rows.map(\.year) == [nil, 1900, 2100, 2024])
        #expect(file.issues.map(\.line) == [5, 6, 7])
        #expect(file.issues.allSatisfy { $0.column == "Year" }, "the column is named as the file spells it")
    }

    @Test("packets is blank or an integer of 0 or more")
    func packetsRule() throws {
        let file = try Self.parse("name,packets\nA,\nB,0\nC,12\nD,-1\nE,1.5\nF,many\n")
        #expect(file.rows.map(\.packets) == [nil, 0, 12])
        #expect(file.issues.map(\.line) == [5, 6, 7])
    }

    @Test("status is blank or a seed state, case-insensitive")
    func statusRule() throws {
        let file = try Self.parse("name,status\nA,\nB,Active\nC,WISHLIST\nD,saved\nE,archived\nF,gone\n")
        #expect(file.rows.map(\.status) == [nil, .active, .wishlist, .saved, .archived])
        #expect(file.issues.map(\.line) == [7])
        #expect(file.issues.first?.column == "status")
    }

    @Test("a row with two bad cells reports both and counts as one error row")
    func twoBadCells() throws {
        let file = try Self.parse("name,year,packets\nA,1800,-2\nB,2020,1\n")
        #expect(file.rows.map(\.name) == ["B"])
        #expect(file.errorRowCount == 1)
        #expect(file.issues.map(\.column) == ["year", "packets"])
    }

    @Test("text columns are trimmed; stored_in is a name")
    func textColumns() throws {
        let file = try Self.parse("name,variety,type,company,stored_in,notes\nA, Genovese , Herb , Baker , Shed , Water well \n")
        let row = try #require(file.rows.first)
        #expect(row.variety == "Genovese")
        #expect(row.type == "Herb")
        #expect(row.company == "Baker")
        #expect(row.storedIn == "Shed")
        #expect(row.notes == "Water well")
    }

    @Test("tags split on ;, are trimmed, and drop blanks and case-insensitive duplicates")
    func tagsRule() throws {
        let file = try Self.parse("name,tags\nA, Herb ;; herb; Annual ;HERB;\n")
        #expect(file.rows.first?.tags == ["Herb", "Annual"])
    }

    // MARK: - Formula guard and tag escaping

    @Test("the guard is removed once from text cells, and other apostrophes are kept")
    func unguard() {
        #expect(SeedCSVImport.unguard("'=SUM(A1)") == "=SUM(A1)")
        #expect(SeedCSVImport.unguard("'+1") == "+1")
        #expect(SeedCSVImport.unguard("'-2") == "-2")
        #expect(SeedCSVImport.unguard("'@x") == "@x")
        #expect(SeedCSVImport.unguard("'\tx") == "\tx")
        #expect(SeedCSVImport.unguard("'\rx") == "\rx")
        #expect(SeedCSVImport.unguard("''x") == "'x", "new files: a leading apostrophe was doubled")
        #expect(SeedCSVImport.unguard("'''x") == "''x", "only one guard is removed")
        #expect(SeedCSVImport.unguard("'x") == "'x", "an apostrophe before a plain character is the value's own")
        #expect(SeedCSVImport.unguard("'") == "'")
        #expect(SeedCSVImport.unguard("it's") == "it's")
        #expect(SeedCSVImport.unguard("=x") == "=x")
    }

    @Test("every text value survives export and import, including guarded and apostrophe values")
    func guardRoundTrip() {
        for value in ["=x", "+1", "-", "@a", "'", "''", "'=x", "'quoted", "it's", "plain", "\tx", "\rx"] {
            #expect(SeedCSVImport.unguard(SeedCSV.text(value)) == value, "value: \(value.debugDescription)")
        }
    }

    @Test("legacy files (exported before R4) import best-effort")
    func legacyGuard() throws {
        // Old exports guarded =,+,-,@,tab,CR but not a leading apostrophe.
        let file = try Self.parse("name,notes\n'=cmd,'plain\n")
        #expect(file.rows.first?.name == "=cmd")
        #expect(file.rows.first?.notes == "'plain")
        // An old value that really started with an apostrophe before a guarded character is ambiguous:
        // it loses that apostrophe.
        #expect(SeedCSVImport.unguard("'-dash") == "-dash")
    }

    @Test("tags are unguarded before splitting, then unescaped")
    func tagEscapingRoundTrip() throws {
        let names = ["=x;y", "a\\b", "plain", "semi;", "'q"]
        let cell = SeedCSV.text(SeedCSV.tagsField(names))
        #expect(SeedCSVImport.splitTags(SeedCSVImport.unguard(cell)) == names)

        let csv = SeedCSV.make([SeedTableRow(
            id: "s1", name: "Dill", variety: "", type: "", company: "", year: nil, packets: 1, state: "active",
            locationID: nil, locationName: "", tagIDs: [], tagNames: names, notes: "", verdict: nil,
            verdictLabel: "", catalogID: nil, updatedAt: 1
        )])
        let file = try Self.parse(csv)
        #expect(file.rows.first?.tags == names)
    }

    @Test("legacy tag cells split on every ;, and backslashes that escape nothing are kept")
    func legacyTags() {
        #expect(SeedCSVImport.splitTags("Herb; Annual") == ["Herb", "Annual"])
        #expect(SeedCSVImport.splitTags("ends\\") == ["ends\\"])
        #expect(SeedCSVImport.splitTags("C:\\Garden; Herb") == ["C:\\Garden", "Herb"])
        #expect(SeedCSVImport.splitTags("a\\;b; c\\\\d") == ["a;b", "c\\d"])
    }

    @Test("a full export with every column parses back to its values")
    func exportParsesBack() throws {
        let csv = SeedCSV.make([SeedTableRow(
            id: "s1", name: "Cherokee Purple", variety: "Heirloom", type: "Tomato", company: "Baker Creek",
            year: 2024, packets: 3, state: "saved", locationID: "l1", locationName: "Shed", tagIDs: ["t1", "t2"],
            tagNames: ["Heirloom", "Winter"], notes: "Sunny, \"warm\"\nspot", verdict: nil, verdictLabel: "Plant now",
            catalogID: nil, updatedAt: 1
        )])
        let file = try Self.parse(csv)
        #expect(file.matchingEnabled)
        #expect(file.issues.isEmpty)
        let row = try #require(file.rows.first)
        #expect(row == SeedCSVImport.Row(
            line: 2, name: "Cherokee Purple", variety: "Heirloom", type: "Tomato", company: "Baker Creek",
            year: 2024, packets: 3, status: .saved, storedIn: "Shed", tags: ["Heirloom", "Winter"],
            notes: "Sunny, \"warm\"\nspot"
        ))
    }

    @Test("normalization trims and folds case with the POSIX locale")
    func normalization() {
        #expect(SeedCSVImport.normalized("  Basil ") == SeedCSVImport.normalized("BASIL"))
        #expect(SeedCSVImport.normalized("Ñandú") == SeedCSVImport.normalized("ñANDÚ"))
        #expect(SeedCSVImport.normalized("Ñandú") != SeedCSVImport.normalized("Nandu"), "accents still count")
    }
}

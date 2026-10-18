import Testing
import Foundation
@testable import Seedkeep

/// Seeds table, slice B: CSV export follows RFC 4180, with the columns in the agreed order.
@MainActor
@Suite("Seeds table — CSV export")
struct SeedsCSVTests {

    private static func row(
        _ id: String,
        name: String = "Basil",
        variety: String = "",
        type: String = "",
        company: String = "",
        year: Int? = nil,
        packets: Int = 1,
        state: String = "active",
        location: String = "",
        tags: [String] = [],
        notes: String = "",
        window: String = ""
    ) -> SeedTableRow {
        SeedTableRow(
            id: id,
            name: name,
            variety: variety,
            type: type,
            company: company,
            year: year,
            packets: packets,
            state: state,
            locationID: nil,
            locationName: location,
            tagIDs: [],
            tagNames: tags,
            notes: notes,
            verdict: nil,
            verdictLabel: window,
            catalogID: nil,
            updatedAt: 1
        )
    }

    /// Splits a CSV the way a reader would, for the simple cases in these tests (no embedded newlines).
    private static func lines(_ csv: String) -> [String] {
        csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    @Test("the header lists the columns in the agreed order")
    func headerOrder() {
        #expect(SeedCSV.columns == [
            "name", "variety", "type", "company", "year", "packets",
            "status", "stored_in", "tags", "notes", "window",
        ])
        let csv = SeedCSV.make([])
        #expect(csv == "name,variety,type,company,year,packets,status,stored_in,tags,notes,window\r\n")
    }

    @Test("each record has the fields in column order, and CRLF line endings")
    func recordOrder() {
        let csv = SeedCSV.make([
            Self.row(
                "s1",
                name: "Cherokee Purple",
                variety: "Heirloom",
                type: "Tomato",
                company: "Baker Creek",
                year: 2024,
                packets: 3,
                state: "saved",
                location: "Shed",
                tags: ["Heirloom", "Winter"],
                notes: "Sunny",
                window: "Plant now"
            ),
        ])

        #expect(csv.hasSuffix("\r\n"))
        #expect(Self.lines(csv) == [
            "name,variety,type,company,year,packets,status,stored_in,tags,notes,window",
            "Cherokee Purple,Heirloom,Tomato,Baker Creek,2024,3,saved,Shed,Heirloom; Winter,Sunny,Plant now",
        ])
    }

    @Test("a blank year is an empty field, and tags are joined with a semicolon and a space")
    func blanksAndTags() {
        let csv = SeedCSV.make([
            Self.row("s1", name: "Dill", year: nil, tags: ["Herb", "Annual"]),
        ])
        #expect(Self.lines(csv).last == "Dill,,,,,1,active,,Herb; Annual,,")
    }

    @Test("fields with commas and quotes are quoted, and embedded quotes are doubled")
    func quotesCommasAndQuotes() {
        #expect(SeedCSV.escape("plain") == "plain")
        #expect(SeedCSV.escape("a, b") == "\"a, b\"")
        #expect(SeedCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(SeedCSV.escape("\"") == "\"\"\"\"")
    }

    @Test("embedded CRLF, LF and bare CR each force quoting")
    func lineBreaksAreQuoted() {
        #expect(SeedCSV.escape("line one\r\nline two") == "\"line one\r\nline two\"")
        #expect(SeedCSV.escape("line one\nline two") == "\"line one\nline two\"")
        #expect(SeedCSV.escape("line one\rline two") == "\"line one\rline two\"")
    }

    @Test("notes with commas, quotes and line breaks stay inside one quoted field")
    func notesWithLineBreaks() {
        let csv = SeedCSV.make([
            Self.row("s1", name: "Kale", notes: "Water, \"deeply\"\nthen rest\r\nlast"),
        ])
        let expected = "name,variety,type,company,year,packets,status,stored_in,tags,notes,window\r\n"
            + "Kale,,,,,1,active,,,\"Water, \"\"deeply\"\"\nthen rest\r\nlast\",\r\n"
        #expect(csv == expected)
    }

    @Test("the CSV is UTF-8, with non-ASCII names intact")
    func utf8() throws {
        let data = SeedCSV.data(for: [Self.row("s1", name: "Ñandú chili")])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("Ñandú chili"))
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF], "a UTF-8 byte order mark leads the file")
        #expect(Array(data.dropFirst(3)).starts(with: Array("name,".utf8)), "the header follows the mark")
    }

    @Test("the file name is seedkeep-seeds-YYYY-MM-DD.csv for the given day")
    func fileName() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12)))

        #expect(SeedCSV.fileName(on: date, calendar: calendar) == "seedkeep-seeds-2026-10-07.csv")
        #expect(SeedCSV.baseFileName(on: date, calendar: calendar) == "seedkeep-seeds-2026-10-07")
    }

    @Test("the exporter document carries the bytes it was given")
    func documentCarriesData() {
        let data = SeedCSV.data(for: [Self.row("s1", name: "Mint")])
        #expect(SeedCSVDocument(data: data).data == data)
    }

    @Test("text values that start with a formula character get a leading apostrophe")
    func formulaGuard() {
        #expect(SeedCSV.text("=HYPERLINK(\"http://x\")") == "'=HYPERLINK(\"http://x\")")
        #expect(SeedCSV.text("+1 555") == "'+1 555")
        #expect(SeedCSV.text("-2+3") == "'-2+3")
        #expect(SeedCSV.text("@SUM(A1)") == "'@SUM(A1)")
        #expect(SeedCSV.text("\tcmd") == "'\tcmd")
        #expect(SeedCSV.text("\rcmd") == "'\rcmd")
        #expect(SeedCSV.text("Cherokee Purple") == "Cherokee Purple")
        #expect(SeedCSV.text("Ñandú") == "Ñandú")
        #expect(SeedCSV.text("") == "")
        #expect(SeedCSV.text("a=b") == "a=b", "only a leading character counts")
        #expect(SeedCSV.escape(SeedCSV.text("\r=x")) == "\"'\r=x\"", "the guard runs before quoting")
    }

    @Test("the guard covers text columns only, and numbers and status are unchanged")
    func formulaGuardColumns() {
        let csv = SeedCSV.make([
            Self.row("s1", name: "=cmd", variety: "+v", type: "-t", company: "@c", year: 2024, packets: 3,
                     state: "active", location: "=loc", tags: ["-tag"], notes: "=note", window: "Plant now"),
        ])
        let record = Self.lines(csv).last
        #expect(record == "'=cmd,'+v,'-t,'@c,2024,3,active,'=loc,'-tag,'=note,Plant now")
    }

    @Test("the exported bytes start with the UTF-8 byte order mark")
    func byteOrderMark() {
        let data = SeedCSV.data(for: [])
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(SeedCSV.byteOrderMark == [0xEF, 0xBB, 0xBF])
    }
}

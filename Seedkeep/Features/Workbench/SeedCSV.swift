// CSV export for the Seeds table (redesign R1, slice B). RFC 4180: CRLF records, fields with a
// comma, double quote, CR or LF are quoted with embedded quotes doubled, header row first. The file
// starts with a UTF-8 byte order mark so spreadsheets read non-ASCII text correctly.
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum SeedCSV {
    static let columns = [
        "name", "variety", "type", "company", "year", "packets",
        "status", "stored_in", "tags", "notes", "window",
    ]

    static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func make(_ rows: [SeedTableRow], includeRecommendationWindow: Bool = true) -> String {
        var output = record(columns)
        for row in rows {
            output += record([
                text(row.name),
                text(row.variety),
                text(row.type),
                text(row.company),
                row.year.map { String($0) } ?? "",
                String(row.packets),
                row.state,
                text(row.locationName),
                text(row.tagsText),
                text(row.notes),
                includeRecommendationWindow ? text(row.verdictLabel) : "",
            ])
        }
        return output
    }

    /// The exported file: the byte order mark, then the CSV as UTF-8.
    static func data(for rows: [SeedTableRow], includeRecommendationWindow: Bool = true) -> Data {
        Data(byteOrderMark + Array(make(rows, includeRecommendationWindow: includeRecommendationWindow).utf8))
    }

    /// Base name for the exporter, `seedkeep-seeds-YYYY-MM-DD`. The system adds `.csv` from the
    /// content type.
    static func baseFileName(on date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "seedkeep-seeds-%04ld-%02ld-%02ld", year, month, day)
    }

    /// Full file name, `seedkeep-seeds-YYYY-MM-DD.csv`.
    static func fileName(on date: Date, calendar: Calendar = .current) -> String {
        baseFileName(on: date, calendar: calendar) + ".csv"
    }

    /// Guards a free-text value against spreadsheet formula injection. A value that starts with
    /// `=`, `+`, `-`, `@`, a tab or a CR gets a leading apostrophe, so it is read as text. Applied to
    /// text columns only; numbers (year, packets) and the stored status are never changed.
    static func text(_ value: String) -> String {
        guard let first = value.unicodeScalars.first else { return value }
        switch first {
        case "=", "+", "-", "@", "\t", "\r":
            return "'" + value
        default:
            return value
        }
    }

    /// One RFC 4180 record, CRLF-terminated. Checks unicode scalars, not characters: "\r\n" is a
    /// single Character in Swift, so a Character test would miss a bare CR or LF.
    static func record(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\r\n"
    }

    static func escape(_ field: String) -> String {
        let needsQuoting = field.unicodeScalars.contains { scalar in
            scalar == "," || scalar == "\"" || scalar == "\r" || scalar == "\n"
        }
        guard needsQuoting else { return field }
        return "\"" + field.replacing("\"", with: "\"\"") + "\""
    }
}

/// The document handed to `fileExporter`. It only writes; the file is produced in memory first.
struct SeedCSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

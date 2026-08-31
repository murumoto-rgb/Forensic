import Foundation

/// Only derivative spreadsheet text is prefixed. Original evidence is unchanged.
enum SpreadsheetText {
    static func neutralize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let formula = trimmed.first.map { "=+-@".contains($0) } ?? false
        let control = value.first.map { "\t\r\n".contains($0) } ?? false
        return formula || control ? "'" + value : value
    }
}

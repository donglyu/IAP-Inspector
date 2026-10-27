import Foundation

enum ReconciliationCSV {
    static func failure(_ message: String) -> NSError { NSError(domain: "Reconciliation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    // Handles quoted commas, escaped quotes, multiline cells, and CRLF.
    static func cells(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," || c == "\n" {
                row.append(field); field = ""; closed = false
                if c == "\n" { rows.append(row); row = [] }
            } else if c == "\"", field.isEmpty, !closed { quoted = true }
            else {
                guard !closed, c != "\"" else { throw failure("CSV 引号格式有误。") }
                field.append(c)
            }
            i += 1
        }
        guard !quoted else { throw failure("CSV 引号未闭合。") }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); rows.append(row) }
        return rows
    }

    static func encode(_ rows: [[String]]) -> String {
        "\u{feff}" + rows.map { row in
            row.map { value in
                // Avoid formula execution when a colleague opens the export in Excel.
                let safe = ["=", "+", "-", "@", "\t", "\r", "\n"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
                return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\r\n")
    }
}

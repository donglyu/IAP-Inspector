import Foundation

/// A values-only workbook. Formula cells use their saved Excel value; formulas are never executed.
struct ImportedSheet: Codable, Identifiable {
    var id: String { name }
    var name: String
    var rows: [[String]]
    var unsafeNumericCells: Set<String> = []
    var formulaCells: Set<String> = []
}

struct WorkbookFile: Codable {
    var sheets: [ImportedSheet]

    static func read(_ url: URL) throws -> Self {
        if url.pathExtension.lowercased() == "csv" {
            return Self(sheets: [ImportedSheet(name: "CSV", rows: try ReconciliationCSV.cells(String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\u{feff}", with: "")))])
        }
        guard url.pathExtension.lowercased() == "xlsx" else { throw ReconciliationCSV.failure("请使用 .xlsx 或 UTF-8 CSV；旧版 .xls 请先在 Excel 中另存为 .xlsx。") }
        let archive = try XLSXArchive(url: url)
        let workbook = try XMLTree.parse(archive.read("xl/workbook.xml"))
        let rels = try XMLTree.parse(archive.read("xl/_rels/workbook.xml.rels"))
        let relationships = Dictionary(rels.descendants("Relationship").compactMap { node -> (String, String)? in
            guard let id = node.attributes["Id"], let target = node.attributes["Target"], node.attributes["TargetMode"] != "External" else { return nil }
            return (id, target)
        }, uniquingKeysWith: { first, _ in first })
        var strings: [String] = []
        if archive.entries.contains("xl/sharedStrings.xml") {
            strings = try XMLTree.parse(archive.read("xl/sharedStrings.xml")).descendants("si").map { $0.descendants("t").map(\.text).joined() }
        }
        var sheets: [ImportedSheet] = []
        for sheet in workbook.descendants("sheet") {
            guard let name = sheet.attributes["name"], let id = sheet.attributes["r:id"], let target = relationships[id] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard !path.split(separator: "/").contains("..") else { throw ReconciliationCSV.failure("工作表路径不受支持。") }
            let root = try XMLTree.parse(archive.read(path))
            var result = ImportedSheet(name: name, rows: [])
            for row in root.descendants("sheetData").flatMap({ $0.children.filter { $0.name == "row" } }) {
                guard let number = Int(row.attributes["r"] ?? ""), number > 0, number <= 100_000 else { throw ReconciliationCSV.failure("工作表行号异常或超过 100,000 行。") }
                while result.rows.count < number { result.rows.append([]) }
                for cell in row.children where cell.name == "c" {
                    guard let ref = cell.attributes["r"] else { continue }
                    let col = columnIndex(ref)
                    guard col >= 0, col < 16_384 else { throw ReconciliationCSV.failure("工作表列号异常。") }
                    while result.rows[number - 1].count <= col { result.rows[number - 1].append("") }
                    let type = cell.attributes["t"] ?? "n"
                    let raw = cell.children.first(where: { $0.name == "v" })?.text ?? ""
                    let value: String
                    if type == "s" {
                        guard let index = Int(raw), strings.indices.contains(index) else { throw ReconciliationCSV.failure("Excel 共享文本索引无效。") }
                        value = strings[index]
                    } else if type == "inlineStr" { value = cell.descendants("t").map(\.text).joined() }
                    else { value = raw }
                    result.rows[number - 1][col] = value
                    if cell.children.contains(where: { $0.name == "f" }) { result.formulaCells.insert("\(number - 1):\(col)") }
                    if type == "n", !raw.isEmpty, (raw.contains("e") || raw.contains("E") || raw.filter(\.isNumber).count > 15) {
                        result.unsafeNumericCells.insert("\(number - 1):\(col)")
                    }
                }
            }
            sheets.append(result)
        }
        guard !sheets.isEmpty else { throw ReconciliationCSV.failure("Excel 中没有可读取的工作表。") }
        return Self(sheets: sheets)
    }

    static func columnIndex(_ ref: String) -> Int {
        var value = 0
        for c in ref.prefix(while: { $0.isLetter }) {
            guard let ascii = c.asciiValue, (65...90).contains(ascii) else { return -1 }
            value = value * 26 + Int(ascii - 64)
        }
        return value - 1
    }
    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { n -= 1; name = String(UnicodeScalar(65 + n % 26)!) + name; n /= 26 }
        return name
    }

    func write(to url: URL) throws {
        let escape: (String) -> String = { value in
            String(value.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) })
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var files: [(String, Data)] = []
        func add(_ path: String, _ xml: String) { files.append((path, Data(xml.utf8))) }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" + sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined() + "</Types>")
        add("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        add("xl/workbook.xml", "<workbook xmlns=\"\(ns)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>" + sheets.enumerated().map { "<sheet name=\"\(escape($0.element.name))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined() + "</sheets></workbook>")
        add("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined() + "</Relationships>")
        for (index, sheet) in sheets.enumerated() {
            guard sheet.rows.count <= 1_048_576, sheet.rows.allSatisfy({ $0.count <= 16_384 }) else { throw ReconciliationCSV.failure("导出超出 Excel 行列上限，请改为 CSV。") }
            var xml = "<worksheet xmlns=\"\(ns)\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" state=\"frozen\"/></sheetView></sheetViews><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    guard value.utf16.count <= 32_767 else { throw ReconciliationCSV.failure("单元格超过 Excel 32,767 字符限制；请改为导出 CSV。") }
                    xml += "<c r=\"\(Self.columnName(c))\(r + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            add("xl/worksheets/sheet\(index + 1).xml", xml)
        }
        try StoredZIP.encode(files).write(to: url, options: .atomic)
    }
}

private final class XMLTree: NSObject, XMLParserDelegate {
    final class Node {
        let name: String; let attributes: [String: String]
        var text = "", children: [Node] = []
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func descendants(_ name: String) -> [Node] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
    }
    var stack: [Node] = [], root = Node("root", [:])
    static func parse(_ data: Data) throws -> Node {
        let delegate = XMLTree(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw ReconciliationCSV.failure("Excel XML 无法解析：\(parser.parserError?.localizedDescription ?? "未知错误")") }
        return delegate.root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = Node(elementName, attributeDict)
        (stack.last ?? root).children.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
}

private struct XLSXArchive {
    let url: URL
    let entries: Set<String>
    init(url: URL) throws {
        self.url = url
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50_000_000 else { throw ReconciliationCSV.failure("文件超过 50 MB，请先拆分。") }
        entries = Set(String(decoding: try Self.command(["-Z1", url.path]), as: UTF8.self).split(separator: "\n").map(String.init))
    }
    func read(_ path: String) throws -> Data {
        guard entries.contains(path) else { throw ReconciliationCSV.failure("Excel 缺少 \(path)") }
        return try Self.command(["-p", url.path, path])
    }
    static func command(_ args: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 100_000_000 { process.terminate(); process.waitUntilExit(); throw ReconciliationCSV.failure("解压后数据过大，请拆分工作表。") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReconciliationCSV.failure("无法读取 Excel，文件可能加密或损坏。") }
        return data
    }
}

/// Uncompressed ZIP output keeps export independent of Python, Excel, and third-party runtimes.
private enum StoredZIP {
    static func encode(_ files: [(String, Data)]) -> Data {
        var output = Data(), central = Data()
        func le(_ value: UInt32, _ count: Int = 4) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        for (name, bytes) in files {
            let path = Data(name.utf8), size = UInt32(bytes.count), offset = UInt32(output.count)
            var crc: UInt32 = 0xffffffff
            for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
            crc ^= 0xffffffff
            for (value, count) in [(UInt32(0x04034b50), 4), (20, 2), (0, 2), (0, 2), (0, 2), (33, 2), (crc, 4), (size, 4), (size, 4), (UInt32(path.count), 2), (0, 2)] { output += le(value, count) }
            output += path; output += bytes
            for (value, count) in [(UInt32(0x02014b50), 4), (20, 2), (20, 2), (0, 2), (0, 2), (0, 2), (33, 2), (crc, 4), (size, 4), (size, 4), (UInt32(path.count), 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (offset, 4)] { central += le(value, count) }
            central += path
        }
        let offset = UInt32(output.count); output += central
        for (value, count) in [(UInt32(0x06054b50), 4), (0, 2), (0, 2), (UInt32(files.count), 2), (UInt32(files.count), 2), (UInt32(central.count), 4), (offset, 4), (0, 2)] { output += le(value, count) }
        return output
    }
}

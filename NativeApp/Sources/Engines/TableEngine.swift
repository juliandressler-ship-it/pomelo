import Foundation

/// Tabellen (Phase 6, L14): CSV, TSV und XLSX untereinander, ohne Zusatzbibliothek.
/// Übernommen werden die Werte des ersten Blatts, keine Formeln, Formatierungen oder weiteren Blätter.
struct TableEngine: ConversionEngine {
    static let maxInputBytes: Int64 = 50_000_000
    static let maxCells = 5_000_000

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from != to && FileFormat.tables.contains(from) && FileFormat.tables.contains(to)
    }

    func convert(_ request: ConversionRequest) async throws {
        guard FileSizeFormatter.size(of: request.source) <= Self.maxInputBytes else {
            throw OpenTangerineError.invalidInput("Tables up to 50 MB can be converted.")
        }
        request.progress(0.1)
        let rows = try await Self.read(request.source, format: request.sourceFormat)
        request.progress(0.6)
        try await Self.write(rows, as: request.target, to: request.destination)
        request.progress(1)
    }

    static func read(_ url: URL, format: FileFormat) async throws -> [[String]] {
        switch format {
        case .csv:
            let text = try decode(url)
            return try CSV.parse(text, delimiter: CSV.guessDelimiter(text))
        case .tsv: return try CSV.parse(try decode(url), delimiter: "\t")
        case .xlsx: return try await XLSX.read(url)
        default: throw OpenTangerineError.unsupportedConversion(format, .csv)
        }
    }

    static func write(_ rows: [[String]], as format: FileFormat, to destination: URL) async throws {
        switch format {
        case .csv:
            // Mit UTF-8-Kennung, damit Excel Umlaute richtig anzeigt
            try Data([0xEF, 0xBB, 0xBF] + Array(CSV.format(rows, delimiter: ",").utf8)).write(to: destination)
        case .tsv:
            try CSV.format(rows, delimiter: "\t").write(to: destination, atomically: true, encoding: .utf8)
        case .xlsx:
            try await XLSX.write(rows, to: destination)
        default:
            throw OpenTangerineError.unsupportedConversion(.csv, format)
        }
    }

    /// UTF-8 (auch mit Kennung), sonst Windows-1252, wie ältere Excel-Exporte es schreiben.
    static func decode(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: bytes, encoding: .windowsCP1252) { return text }
        throw OpenTangerineError.unreadable(url)
    }
}

// MARK: - CSV / TSV

enum CSV {
    /// Komma oder Semikolon (deutsches Excel) anhand der ersten Zeile erkennen.
    static func guessDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let counts: [(Character, Int)] = [",", ";", "\t"].map { d in (d, firstLine.filter { $0 == d }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// RFC 4180: Anführungszeichen, verdoppelte Anführungszeichen, Zeilenumbrüche in Feldern.
    static func parse(_ text: String, delimiter: Character) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var cells = 0
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return iterator.next() }
        while let ch = next() {
            if quoted {
                if ch == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { quoted = false; pending = following }
                    } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" && field.isEmpty {
                quoted = true
            } else if ch == delimiter {
                row.append(field); field = ""; cells += 1
            } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); field = ""; cells += 1
                rows.append(row); row = []
            } else {
                field.append(ch)
            }
            if cells > TableEngine.maxCells { throw OpenTangerineError.invalidInput("This table has more than 5 million cells.") }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func format(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { row in
            row.map { value in
                let needsQuotes = value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
                    || value.hasPrefix(" ") || value.hasSuffix(" ")
                guard needsQuotes else { return value }
                if delimiter == "\t" {
                    // TSV kennt keine Anführungszeichen: Tabs und Umbrüche durch Leerzeichen ersetzen
                    return value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                }
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: String(delimiter))
        }.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - XLSX

enum XLSX {
    /// Liest die Werte des ersten Blatts. Das Archiv wird vorher geprüft (wie bei ZIP).
    static func read(_ url: URL) async throws -> [[String]] {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-xlsx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do { try await ArchiveEngine.extract(url, format: .zip, into: work) } catch {
            throw OpenTangerineError.invalidInput("This is not a readable Excel file (.xlsx). Older .xls files are not supported.")
        }
        let workbook = try xml(work, "xl/workbook.xml")
        let relations = (try? xml(work, "xl/_rels/workbook.xml.rels")) ?? ""
        // erstes Blatt: r:id aus workbook.xml, Ziel aus den Beziehungen
        var sheetPath = "xl/worksheets/sheet1.xml"
        if let rid = match("<sheet\\b[^>]*\\br:id=\"([^\"]+)\"", workbook) ?? match("<sheet\\b[^>]*\\bid=\"([^\"]+)\"", workbook),
           let tag = matchAll("<Relationship\\b[^>]*>", relations).first(where: { $0.contains("Id=\"\(rid)\"") }),
           let target = match("Target=\"([^\"]+)\"", tag) {
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            if ArchiveEngine.isSafe(path) { sheetPath = path }
        }
        let shared = (try? xml(work, "xl/sharedStrings.xml")).map(SharedStrings.parse) ?? []
        let dateStyles = (try? xml(work, "xl/styles.xml")).map(Styles.dateStyleIndexes) ?? []
        let date1904 = workbook.contains("date1904=\"1\"") || workbook.contains("date1904=\"true\"")
        let sheet = try Data(contentsOf: work.appendingPathComponent(sheetPath))
        return try SheetReader.read(sheet, shared: shared, dateStyles: dateStyles, date1904: date1904)
    }

    private static func xml(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func match(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func matchAll(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// "B12" -> Spalte 1 (0-basiert)
    static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        var found = false
        for ch in reference.uppercased() {
            guard let value = ch.asciiValue, value >= 65, value <= 90 else { break }
            index = index * 26 + Int(value - 64); found = true
        }
        return found ? index - 1 : nil
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(UInt8(65 + r))) + name; n = (n - 1) / 26 }
        return name
    }

    /// Zahl schreiben, wenn es eindeutig eine ist; "007", "+49", "1e5" und Ähnliches bleiben Text.
    static func isPlainNumber(_ value: String) -> Bool {
        value.range(of: "^-?(0|[1-9][0-9]{0,14})(\\.[0-9]{1,10})?$", options: .regularExpression) != nil
    }

    static func write(_ rows: [[String]], to destination: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-xlsxout-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: work.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: work) }
        var sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = columnName(c) + String(r + 1)
                if isPlainNumber(value) {
                    sheet += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    let preserve = value.hasPrefix(" ") || value.hasSuffix(" ") || value.contains("\n") ? " xml:space=\"preserve\"" : ""
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t\(preserve)>\(escape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        let files: [(String, String)] = [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """),
            ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """),
            ("xl/styles.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <fonts count="1"><font><sz val="12"/><name val="Calibri"/></font></fonts>
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
            <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
            </styleSheet>
            """),
            ("xl/worksheets/sheet1.xml", sheet),
        ]
        for (path, content) in files {
            try content.write(to: work.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try await ZipTool.zipOrdered(directory: work, entries: files.map(\.0), to: destination)
    }

    static func escape(_ text: String) -> String {
        // Steuerzeichen sind in XML 1.0 nicht erlaubt (außer Tab, LF, CR)
        let cleaned = String(text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        return cleaned.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Gemeinsame Texte (xl/sharedStrings.xml): jedes <si> ist ein Eintrag, auch mit mehreren <r><t>-Teilen.
private final class SharedStrings: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false
    private var inPhonetic = false

    static func parse(_ xml: String) -> [String] {
        let delegate = SharedStrings()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "si": current = ""
        case "t": inText = !inPhonetic
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "t": inText = false
        case "rPh": inPhonetic = false
        case "si": strings.append(current)
        default: break
        }
    }
}

/// Erkennt Zellformate für Datum/Uhrzeit (eingebaute Nummern 14–22, 45–47 und eigene Formate mit d/m/y/h/s).
private enum Styles {
    static func dateStyleIndexes(_ xml: String) -> Set<Int> {
        var custom: [Int: String] = [:]
        for tag in XLSX.matchAll("<numFmt\\b[^>]*>", xml) {
            if let id = XLSX.match("numFmtId=\"(\\d+)\"", tag).flatMap(Int.init), let code = XLSX.match("formatCode=\"([^\"]*)\"", tag) { custom[id] = code }
        }
        func isDate(_ id: Int) -> Bool {
            if (14...22).contains(id) || (45...47).contains(id) { return true }
            guard let code = custom[id] else { return false }
            // Text in Anführungszeichen und Farbangaben ignorieren
            let stripped = code.replacingOccurrences(of: "\"[^\"]*\"|\\[[^\\]]*\\]", with: "", options: .regularExpression).lowercased()
            return stripped.rangeOfCharacter(from: CharacterSet(charactersIn: "dmyhs")) != nil && !stripped.contains("0.0")
        }
        guard let cellXfs = XLSX.match("(?s)<cellXfs\\b[^>]*>(.*?)</cellXfs>", xml) else { return [] }
        var result = Set<Int>()
        for (index, xf) in XLSX.matchAll("<xf\\b[^>]*>", cellXfs).enumerated() {
            if let id = XLSX.match("numFmtId=\"(\\d+)\"", xf).flatMap(Int.init), isDate(id) { result.insert(index) }
        }
        return result
    }
}

/// Liest die Zellen eines Blatts in Zeilen und Spalten (Lücken werden mit leeren Feldern gefüllt).
private final class SheetReader: NSObject, XMLParserDelegate {
    let shared: [String]
    let dateStyles: Set<Int>
    let date1904: Bool
    var rows: [Int: [Int: String]] = [:]
    private var rowIndex = 0
    private var column = 0
    private var type = "n"
    private var style = 0
    private var value = ""
    private var collecting = false
    private var inInline = false
    private var cells = 0
    private var failure: Error?

    init(shared: [String], dateStyles: Set<Int>, date1904: Bool) {
        self.shared = shared; self.dateStyles = dateStyles; self.date1904 = date1904
    }

    static func read(_ data: Data, shared: [String], dateStyles: Set<Int>, date1904: Bool) throws -> [[String]] {
        let reader = SheetReader(shared: shared, dateStyles: dateStyles, date1904: date1904)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() || reader.failure != nil else { throw OpenTangerineError.invalidInput("The first sheet of this Excel file cannot be read.") }
        if let failure = reader.failure { throw failure }
        guard let last = reader.rows.keys.max() else { return [] }
        return (0...last).map { r in
            let row = reader.rows[r] ?? [:]
            guard let width = row.keys.max() else { return [] }
            return (0...width).map { row[$0] ?? "" }
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row":
            if let r = attributes["r"].flatMap(Int.init) { rowIndex = r - 1 } else { rowIndex = (rows.keys.max() ?? -1) + 1 }
            column = 0
        case "c":
            if let ref = attributes["r"], let col = XLSX.columnIndex(ref) { column = col }
            type = attributes["t"] ?? "n"
            style = attributes["s"].flatMap(Int.init) ?? 0
            value = ""
            cells += 1
            if cells > TableEngine.maxCells {
                failure = OpenTangerineError.invalidInput("This table has more than 5 million cells.")
                parser.abortParsing()
            }
        case "v": collecting = true; value = ""
        case "is": inInline = true; value = ""
        case "t": if inInline { collecting = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { value += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": collecting = false
        case "is": inInline = false
        case "c":
            rows[rowIndex, default: [:]][column] = display()
            column += 1
        default: break
        }
    }

    private func display() -> String {
        switch type {
        case "s": return Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
        case "b": return value == "1" ? "TRUE" : "FALSE"
        case "str", "inlineStr", "e": return value
        default:
            guard let number = Double(value) else { return value }
            if dateStyles.contains(style) { return Self.date(number, date1904: date1904) }
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return String(number) // kürzeste genaue Darstellung, z.B. 0.1 statt 0.1000000000000000055
        }
    }

    /// Excel-Seriennummer in ISO-Datum (mit Uhrzeit, wenn vorhanden).
    static func date(_ serial: Double, date1904: Bool) -> String {
        // Basis 1899-12-30 gleicht Excels 1900-Schaltjahrfehler für Daten ab März 1900 aus
        let base = date1904 ? DateComponents(year: 1904, month: 1, day: 1) : DateComponents(year: 1899, month: 12, day: 30)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = calendar.date(from: base) else { return String(serial) }
        let seconds = (serial * 86400).rounded()
        let date = start.addingTimeInterval(seconds)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fraction = serial - serial.rounded(.down)
        formatter.dateFormat = serial < 1 ? "HH:mm:ss" : fraction > 0.000001 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

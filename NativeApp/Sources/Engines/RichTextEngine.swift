import AppKit
import Foundation

/// Dokumente untereinander (Phase 6, L13): DOCX, RTF, RTFD, HTML, TXT, Markdown, EPUB, dazu PDF als Ziel.
/// DOCX/RTF/RTFD/HTML/TXT liest und schreibt Apples Textsystem (NSAttributedString).
/// Markdown und EPUB sind hier selbst geschrieben, ohne pandoc oder andere Zusatzprogramme.
/// Kein Netzzugriff: HTML wird vor dem Import von allen entfernten Verweisen befreit.
struct RichTextEngine: ConversionEngine {
    static let maxInputBytes: Int64 = 50_000_000

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from != to, FileFormat.richText.contains(from) else { return false }
        return FileFormat.richText.contains(to) || to == .pdf
    }

    func convert(_ request: ConversionRequest) async throws {
        if request.sourceFormat != .rtfd, FileSizeFormatter.size(of: request.source) > Self.maxInputBytes {
            throw OpenTangerineError.invalidInput("Documents up to 50 MB can be converted.")
        }
        request.progress(0.1)
        let document = try await Self.read(request.source, format: request.sourceFormat)
        request.progress(0.5)
        let title = ConversionMatrix.strippedBaseName(request.source.lastPathComponent)
        try await Self.write(document, as: request.target, title: title, to: request.destination)
        request.progress(1)
    }

    // MARK: Lesen

    @MainActor
    static func read(_ url: URL, format: FileFormat) async throws -> NSAttributedString {
        switch format {
        case .docx:
            return try load { try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil) }
        case .rtf:
            return try load { try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
        case .rtfd:
            return try load { try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) }
        case .txt:
            return plain(try TextFile.read(url))
        case .html:
            return try html(try TextFile.read(url), baseURL: url.deletingLastPathComponent())
        case .md:
            return try html(Markdown.toHTML(try TextFile.read(url)), baseURL: url.deletingLastPathComponent())
        case .epub:
            return try await EPUB.read(url)
        default:
            throw OpenTangerineError.unsupportedConversion(format, .txt)
        }
    }

    private static func load(_ work: () throws -> NSAttributedString) throws -> NSAttributedString {
        do { return try work() } catch {
            throw OpenTangerineError.invalidInput("This document cannot be read. It may be damaged or protected.")
        }
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }

    /// HTML in formatierten Text, ohne Netz: entfernte Bilder, Skripte und Stylesheets werden vorher entfernt.
    @MainActor
    static func html(_ source: String, baseURL: URL?) throws -> NSAttributedString {
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>body{font-family:-apple-system,Helvetica,sans-serif;font-size:12pt;color:#000}code,pre{font-family:Menlo,monospace}</style>
        </head><body>\(HTMLSafety.offline(source))</body></html>
        """
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL { options[.baseURL] = baseURL }
        return try load { try NSAttributedString(data: Data(page.utf8), options: options, documentAttributes: nil) }
    }

    // MARK: Schreiben

    @MainActor
    static func write(_ document: NSAttributedString, as format: FileFormat, title: String, to destination: URL) async throws {
        let range = NSRange(location: 0, length: document.length)
        switch format {
        case .docx:
            try document.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: destination)
        case .rtf:
            try document.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: destination)
        case .rtfd:
            guard let wrapper = document.rtfdFileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else {
                throw OpenTangerineError.encodeFailed(destination.lastPathComponent)
            }
            try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)
        case .html:
            try document.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                                .characterEncoding: String.Encoding.utf8.rawValue]).write(to: destination)
        case .txt:
            try document.string.write(to: destination, atomically: true, encoding: .utf8)
        case .md:
            try Markdown.from(Blocks.parse(document)).write(to: destination, atomically: true, encoding: .utf8)
        case .epub:
            try await EPUB.write(Blocks.parse(document), title: title, to: destination)
        case .pdf:
            try RichPDF.write(document, to: destination)
        default:
            throw OpenTangerineError.unsupportedConversion(.txt, format)
        }
    }
}

// MARK: - HTML ohne Netz

enum HTMLSafety {
    /// Entfernt alles, was beim Anzeigen etwas aus dem Netz laden könnte. Links (href) bleiben als Text-Links.
    static func offline(_ html: String) -> String {
        var s = html
        let patterns: [(String, String)] = [
            ("(?is)<script\\b.*?</script\\s*>", ""),
            ("(?is)<(iframe|object|embed|video|audio|frame|frameset)\\b.*?(</\\1\\s*>|/>)", ""),
            ("(?is)<(link|base|meta)\\b[^>]*>", ""),
            ("(?is)@import[^;]*;", ""),
            ("(?is)url\\(\\s*['\"]?\\s*(https?:|ftp:|//)[^)]*\\)", "none"),
            ("(?is)\\s(src|srcset|background|poster|data|lowsrc|dynsrc)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", ""),
        ]
        // Lokale Bilder (relative Pfade, file:) bleiben erlaubt: erst merken, dann alle src entfernen, dann lokale zurück.
        s = preserveLocalImages(s)
        for (pattern, replacement) in patterns {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s.replacingOccurrences(of: "data-ot-local-src=", with: "src=")
    }

    private static func preserveLocalImages(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?i)\\ssrc\\s*=\\s*(\"([^\"]*)\"|'([^']*)')") else { return html }
        var result = html
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            guard let range = Range(match.range, in: html), let value = Range(valueRange, in: html) else { continue }
            let src = html[value].trimmingCharacters(in: .whitespaces).lowercased()
            let remote = src.hasPrefix("http:") || src.hasPrefix("https:") || src.hasPrefix("ftp:") || src.hasPrefix("//") || src.contains("://") && !src.hasPrefix("file:")
            if !remote, !src.isEmpty, !src.hasPrefix("javascript:") {
                result.replaceSubrange(range, with: " data-ot-local-src=\"\(html[value])\"")
            }
        }
        return result
    }
}

// MARK: - Absätze mit Bedeutung (für Markdown und EPUB)

struct Run: Equatable { var text: String; var bold = false; var italic = false; var code = false; var link: String? }

struct Block: Equatable {
    enum Kind: Equatable { case heading(Int), paragraph, bullet, numbered, code }
    var kind: Kind
    var runs: [Run]
    var plainText: String { runs.map(\.text).joined() }
}

enum Blocks {
    /// Zerlegt formatierten Text in Überschriften, Absätze, Listen und Code.
    static func parse(_ document: NSAttributedString) -> [Block] {
        let string = document.string as NSString
        guard string.length > 0 else { return [] }
        // Grundschriftgröße = häufigste Größe nach Zeichenzahl
        var sizes: [CGFloat: Int] = [:]
        document.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize.rounded(), default: 0] += range.length }
        }
        let base = sizes.max { $0.value < $1.value }?.key ?? 12
        var blocks: [Block] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs]) { _, range, _, _ in
            guard range.length > 0 else { return }
            let style = document.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            var runs: [Run] = []
            var largest: CGFloat = 0
            var allBold = true
            var allMono = true
            document.enumerateAttributes(in: range) { attributes, sub, _ in
                var text = string.substring(with: sub)
                text = text.replacingOccurrences(of: "\u{FFFC}", with: "") // Anhänge (Bilder) haben keinen Text
                guard !text.isEmpty else { return }
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                largest = max(largest, font?.pointSize ?? base)
                let link: String? = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
                let run = Run(text: text, bold: traits.contains(.bold), italic: traits.contains(.italic), code: traits.contains(.monoSpace), link: link)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    allBold = allBold && run.bold
                    allMono = allMono && run.code
                }
                runs.append(run)
            }
            // Listenmarke ("•\t" oder "1.\t") aus dem Text entfernen, wenn eine echte Liste vorliegt
            let lists = style?.textLists ?? []
            var kind: Block.Kind = .paragraph
            if let list = lists.last {
                let format = list.markerFormat.rawValue.lowercased()
                kind = format.contains("decimal") || format.contains("roman") || format.contains("alpha") ? .numbered : .bullet
                if let first = runs.first, let tab = first.text.firstIndex(of: "\t") {
                    runs[0].text = String(first.text[first.text.index(after: tab)...])
                }
            } else if largest >= base * 1.25 {
                kind = .heading(largest >= base * 1.8 ? 1 : largest >= base * 1.45 ? 2 : 3)
            } else if allMono, !runs.isEmpty {
                kind = .code
            } else if let first = runs.first?.text,
                      let match = first.range(of: "^\\s*(?:[•◦▪●○–*-][\\t ]+|\\d+[.)]?\\t+|\\d+[.)] +)", options: .regularExpression) {
                // Aufzählung nur als Text (so liefert z.B. Apples DOCX-Leser Listen zurück)
                let marker = first[match].trimmingCharacters(in: .whitespaces)
                kind = marker.first?.isNumber == true ? .numbered : .bullet
                runs[0].text = String(first[match.upperBound...])
            }
            if case .heading = kind, allBold { runs = runs.map { var r = $0; r.bold = false; return r } }
            if kind == .code { runs = runs.map { var r = $0; r.code = false; return r } }
            let block = Block(kind: kind, runs: runs.filter { !$0.text.isEmpty })
            if !block.plainText.trimmingCharacters(in: .whitespaces).isEmpty || kind == .code { blocks.append(block) }
        }
        return blocks
    }
}

// MARK: - Markdown

enum Markdown {
    static func from(_ blocks: [Block]) -> String {
        var lines: [String] = []
        var counter = 0
        for (index, block) in blocks.enumerated() {
            let previous = index > 0 ? blocks[index - 1].kind : nil
            let next = index + 1 < blocks.count ? blocks[index + 1].kind : nil
            let isList = block.kind == .bullet || block.kind == .numbered
            let wasList = previous == .bullet || previous == .numbered
            // Leerzeile zwischen Blöcken, nicht innerhalb einer Liste oder eines Codeblocks
            if !lines.isEmpty, !(isList && wasList), !(block.kind == .code && previous == .code) { lines.append("") }
            if block.kind != .numbered { counter = 0 }
            switch block.kind {
            case .heading(let level): lines.append(String(repeating: "#", count: level) + " " + inline(block.runs))
            case .paragraph: lines.append(inline(block.runs))
            case .bullet: lines.append("- " + inline(block.runs))
            case .numbered: counter += 1; lines.append("\(counter). " + inline(block.runs))
            case .code:
                if previous != .code { lines.append("```") }
                lines.append(block.plainText)
                if next != .code { lines.append("```") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func inline(_ runs: [Run]) -> String {
        runs.map { run in
            var text = run.code ? "`\(run.text)`" : escape(run.text)
            let core = text.trimmingCharacters(in: .whitespaces)
            if !core.isEmpty, !run.code {
                let lead = String(text.prefix { $0 == " " }), trail = String(text.reversed().prefix { $0 == " " })
                var wrapped = core
                if run.italic { wrapped = "*\(wrapped)*" }
                if run.bold { wrapped = "**\(wrapped)**" }
                text = lead + wrapped + trail
            }
            if let link = run.link { text = "[\(text)](\(link))" }
            return text
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for ch in text { if "*_`[]\\".contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }

    /// Markdown nach HTML: Überschriften, Absätze, Listen, Zitate, Code, Trennlinien, fett, kursiv, Links.
    static func toHTML(_ markdown: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var list: String?
        var inCode = false
        var code: [String] = []
        func flushParagraph() { if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>"); paragraph = [] } }
        func closeList() { if let tag = list { html.append("</\(tag)>"); list = nil } }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode { html.append("<pre><code>\(escapeHTML(code.joined(separator: "\n")))</code></pre>"); code = []; inCode = false }
                else { flushParagraph(); closeList(); inCode = true }
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }
            if let match = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushParagraph(); closeList()
                let level = line[match].filter { $0 == "#" }.count
                html.append("<h\(level)>\(inline(String(line[match.upperBound...]).replacingOccurrences(of: "\\s#+$", with: "", options: .regularExpression)))</h\(level)>")
            } else if line.range(of: "^(\\*\\s*){3,}$|^(-\\s*){3,}$|^(_\\s*){3,}$", options: .regularExpression) != nil {
                flushParagraph(); closeList(); html.append("<hr>")
            } else if let match = line.range(of: "^[-*+]\\s+", options: .regularExpression) {
                flushParagraph()
                if list != "ul" { closeList(); html.append("<ul>"); list = "ul" }
                html.append("<li>\(inline(String(line[match.upperBound...])))</li>")
            } else if let match = line.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
                flushParagraph()
                if list != "ol" { closeList(); html.append("<ol>"); list = "ol" }
                html.append("<li>\(inline(String(line[match.upperBound...])))</li>")
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote><p>\(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</p></blockquote>")
            } else {
                closeList(); paragraph.append(line)
            }
        }
        if inCode { html.append("<pre><code>\(escapeHTML(code.joined(separator: "\n")))</code></pre>") }
        flushParagraph(); closeList()
        return html.joined(separator: "\n")
    }

    static func inline(_ text: String) -> String {
        var s = escapeHTML(text)
        // geschützte Zeichen (\* usw.) vorübergehend ersetzen
        let escapes = ["\\*": "\u{E001}", "\\_": "\u{E002}", "\\`": "\u{E003}", "\\[": "\u{E004}", "\\]": "\u{E005}", "\\\\": "\u{E006}"]
        for (key, value) in escapes { s = s.replacingOccurrences(of: key, with: value) }
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", "$1"), // Bilder: nur der Alternativtext (kein Nachladen)
            ("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>"),
            ("\\*\\*([^*]+)\\*\\*", "<b>$1</b>"),
            ("__([^_]+)__", "<b>$1</b>"),
            ("\\*([^*]+)\\*", "<i>$1</i>"),
            ("(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])", "<i>$1</i>"),
        ]
        for (pattern, template) in rules { s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        let restore = ["\u{E001}": "*", "\u{E002}": "_", "\u{E003}": "`", "\u{E004}": "[", "\u{E005}": "]", "\u{E006}": "\\"]
        for (key, value) in restore { s = s.replacingOccurrences(of: key, with: value) }
        return s
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - EPUB

enum EPUB {
    /// Liest den Text eines EPUB in Lesereihenfolge (Spine). Das Archiv wird dabei geprüft entpackt.
    @MainActor
    static func read(_ url: URL) async throws -> NSAttributedString {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try await ArchiveEngine.extract(url, format: .zip, into: work)
        let container = try String(contentsOf: work.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = first("full-path=\"([^\"]+)\"", in: container), ArchiveEngine.isSafe(opfPath) else {
            throw OpenTangerineError.invalidInput("This EPUB has no readable table of contents.")
        }
        let opfURL = work.appendingPathComponent(opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        var manifest: [String: String] = [:]
        for tag in all("<item\\b[^>]*>", in: opf) {
            if let id = first("\\bid=\"([^\"]+)\"", in: tag), let href = first("\\bhref=\"([^\"]+)\"", in: tag) { manifest[id] = href }
        }
        let spine = all("<itemref\\b[^>]*>", in: opf).compactMap { first("\\bidref=\"([^\"]+)\"", in: $0) }
        var bodies: [String] = []
        for id in spine {
            guard let href = manifest[id]?.removingPercentEncoding, ArchiveEngine.isSafe(href) else { continue }
            let file = opfURL.deletingLastPathComponent().appendingPathComponent(href)
            guard let xhtml = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var body = first("(?is)<body[^>]*>(.*)</body>", in: xhtml) ?? xhtml
            // relative Bilder auf die entpackte Datei zeigen lassen (lokal, kein Netz)
            body = body.replacingOccurrences(of: "(?i)(src|xlink:href)=\"(?![a-z]+:)([^\"]+)\"",
                                             with: "src=\"\(file.deletingLastPathComponent().absoluteString)$2\"", options: .regularExpression)
            bodies.append(body)
        }
        guard !bodies.isEmpty else { throw OpenTangerineError.invalidInput("This EPUB contains no readable chapters.") }
        return try RichTextEngine.html(bodies.joined(separator: "\n<p></p>\n"), baseURL: nil)
    }

    /// Schreibt ein EPUB 3 (ein Kapitel, Inhaltsverzeichnis aus den Überschriften).
    static func write(_ blocks: [Block], title: String, to destination: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-epubout-\(UUID().uuidString)")
        let oebps = work.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let safeTitle = xml(title)
        var body: [String] = []
        var toc: [String] = []
        var list: String?
        var anchor = 0
        func closeList() { if let tag = list { body.append("</\(tag)>"); list = nil } }
        for block in blocks {
            switch block.kind {
            case .heading(let level):
                closeList(); anchor += 1
                body.append("<h\(level) id=\"h\(anchor)\">\(xhtml(block.runs))</h\(level)>")
                if level <= 2 { toc.append("<li><a href=\"text.xhtml#h\(anchor)\">\(xml(block.plainText))</a></li>") }
            case .paragraph: closeList(); body.append("<p>\(xhtml(block.runs))</p>")
            case .code: closeList(); body.append("<pre><code>\(xml(block.plainText))</code></pre>")
            case .bullet, .numbered:
                let tag = block.kind == .bullet ? "ul" : "ol"
                if list != tag { closeList(); body.append("<\(tag)>"); list = tag }
                body.append("<li>\(xhtml(block.runs))</li>")
            }
        }
        closeList()
        if toc.isEmpty { toc.append("<li><a href=\"text.xhtml\">\(safeTitle)</a></li>") }
        let page = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(language)" lang="\(language)">
        <head><meta charset="utf-8"/><title>\(safeTitle)</title></head>
        <body>
        \(body.joined(separator: "\n"))
        </body></html>
        """
        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head><meta charset="utf-8"/><title>\(safeTitle)</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\(toc.joined())</ol></nav></body></html>
        """
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="\(language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(safeTitle)</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="text"/></spine>
        </package>
        """
        let container = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        try "application/epub+zip".write(to: work.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try container.write(to: work.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try opf.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try nav.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        try page.write(to: oebps.appendingPathComponent("text.xhtml"), atomically: true, encoding: .utf8)
        // "mimetype" muss als erste Datei unkomprimiert im Archiv liegen
        var result = try await Shell.run("/usr/bin/zip", ["-X", "-0", "-q", destination.path, "mimetype"], currentDirectory: work)
        guard result.succeeded else { throw OpenTangerineError.toolFailed("zip", result.stderr) }
        result = try await Shell.run("/usr/bin/zip", ["-X", "-r", "-q", destination.path, "META-INF", "OEBPS"], currentDirectory: work)
        guard result.succeeded else { throw OpenTangerineError.toolFailed("zip", result.stderr) }
    }

    static func xhtml(_ runs: [Run]) -> String {
        runs.map { run in
            var text = xml(run.text)
            if run.code { text = "<code>\(text)</code>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if let link = run.link { text = "<a href=\"\(xml(link))\">\(text)</a>" }
            return text
        }.joined()
    }

    static func xml(_ text: String) -> String {
        Markdown.escapeHTML(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text) else { return nil }
        return String(text[range])
    }

    private static func all(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

// MARK: - PDF aus formatiertem Text

enum RichPDF {
    static let pageSize = CGSize(width: 595, height: 842) // A4
    static let margin: CGFloat = 56

    /// Bricht den Text mit dem Textsystem auf Seiten um und schreibt eine PDF mit echtem, durchsuchbarem Text.
    @MainActor
    static func write(_ document: NSAttributedString, to destination: URL) throws {
        let storage = NSTextStorage(attributedString: document)
        // Text ohne eigene Farbe schwarz setzen (sonst hängt die Farbe vom Erscheinungsbild ab)
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value == nil { storage.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let size = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            _ = layout.glyphRange(for: container)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 3000
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(destination as CFURL, mediaBox: &box, nil) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let range = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}

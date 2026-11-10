import AppKit
import Foundation
import PDFKit

@main struct DocumentTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenTangerine-documents-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func convert(_ source: URL, _ from: FileFormat, _ to: FileFormat, _ name: String) async throws -> URL {
            // Die Engine liefert den echten Pfad (bei mehrseitigen PDFs einen Ordner "… pages")
            try await Engines.convert(ConversionRequest(source: source, sourceFormat: from, target: to, destination: url(name), progress: { _ in }))
        }
        let text = "Open Tangerine document test\nCafé & <content>\n\nSecond paragraph."
        try text.write(to: url("input.txt"), atomically: true, encoding: .utf8)
        let pdf = try await convert(url("input.txt"), .txt, .pdf, "text.pdf")
        precondition(PDFDocument(url: pdf)!.string!.contains("Open Tangerine"))
        for target: FileFormat in [.png, .jpg, .srt, .vtt] {
            let out = try await convert(url("input.txt"), .txt, target, "text.\(target.fileExtension)")
            if target == .png || target == .jpg { precondition(try! ImageIOBridge.load(out).width == 1275) }
            else { precondition(try! String(contentsOf: out, encoding: .utf8).contains("Second paragraph")) }
            print("PASS TXT -> \(target)")
        }
        for target: FileFormat in [.png, .jpg, .txt, .docx] {
            let out = try await convert(pdf, .pdf, target, "pdf.\(target.fileExtension)")
            switch target {
            case .png, .jpg: precondition(try! ImageIOBridge.load(out).width == 2550)
            case .txt: precondition(try! String(contentsOf: out, encoding: .utf8).contains("Open Tangerine"))
            case .docx:
                let result = try await Shell.run("/usr/bin/unzip", ["-p", out.path, "word/document.xml"])
                precondition(result.succeeded && result.stdout.contains("Open Tangerine") && result.stdout.contains("&amp;"))
            default: break
            }
            print("PASS PDF -> \(target)")
        }
        let second = url("second.pdf")
        try TextRenderer.writePDF("Second page marker", to: second)
        let merged = url("merged.pdf")
        try PDFOps.merge([pdf, second], to: merged)
        let mergedDoc = try PDFOps.document(merged)
        precondition(mergedDoc.pageCount == 2 && mergedDoc.page(at: 1)!.string!.contains("Second page"))
        for mode: PDFOps.SplitMode in [.everyPage, .everyN, .ranges] {
            let outputs = try PDFOps.split(merged, mode: mode, every: 2, ranges: "2", into: url("split-\(mode.rawValue)"))
            precondition(outputs.count == (mode == .everyPage ? 2 : 1))
            precondition(try! PDFOps.document(outputs[0]).pageCount == (mode == .everyN ? 2 : 1))
            print("PASS PDF split \(mode)")
        }
        try PDFOps.assemble(pages: [PDFPageRef(sourceIndex: 1, rotation: 90, sourceURL: merged), PDFPageRef(sourceIndex: 0, rotation: 0, sourceURL: merged)], to: url("reordered.pdf"))
        // Nachbau: mehrseitige PDF -> Bilder landet in einem klar benannten Ordner, nicht in "merged.jpg"
        let pagesFolder = try await Engines.convert(ConversionRequest(source: merged, sourceFormat: .pdf, target: .jpg, destination: url("merged.jpg"), progress: { _ in }))
        precondition(pagesFolder.lastPathComponent == "merged JPG pages", "got \(pagesFolder.lastPathComponent)")
        precondition(!fm.fileExists(atPath: url("merged.jpg").path))
        precondition(try! fm.contentsOfDirectory(atPath: pagesFolder.path).filter { $0.hasSuffix(".jpg") }.count == 2)
        let pagesFolder2 = try await Engines.convert(ConversionRequest(source: merged, sourceFormat: .pdf, target: .jpg, destination: url("merged.jpg"), progress: { _ in }))
        precondition(pagesFolder2.lastPathComponent == "merged JPG pages 2")
        print("PASS PDF multi-page -> JPG folder name and collision")
        // Nachbau Phase 3: PDF komprimieren behält Formularfelder; PDF/A wird erzeugt
        let form = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("NativeApp/Tests/Fixtures/editable-form.pdf")
        func widgets(_ doc: PDFDocument) -> Int { (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.annotations.count ?? 0) } }
        let formWidgets = widgets(try! PDFOps.document(form))
        precondition(formWidgets > 0, "Fixture has no form fields")
        for (name, strong, target) in [("balanced", false, Int64?.none), ("strong", true, nil), ("target", false, Int64(1_000))] {
            let out = url("form-\(name).pdf")
            let size = try PDFOps.compress(form, strong: strong, targetBytes: target, to: out)
            precondition(size == FileSizeFormatter.size(of: out))
            precondition(widgets(try! PDFOps.document(out)) == formWidgets, "\(name) lost form fields")
        }
        precondition(try! fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".opentangerine-") }, "PDF temp files left behind")
        let imageHeavy = url("photos.pdf")
        try PDFOps.fromImages([url("text.png"), url("text.jpg")], to: imageHeavy, progress: { _ in })
        let small = try PDFOps.compress(imageHeavy, strong: false, targetBytes: FileSizeFormatter.size(of: imageHeavy) / 2, to: url("photos-small.pdf"))
        precondition(small < FileSizeFormatter.size(of: imageHeavy), "Target compression did not shrink")
        let pdfa = url("merged PDF-A.pdf")
        try PDFOps.makePDFA(merged, to: pdfa)
        let pdfaDoc = try PDFOps.document(pdfa)
        precondition(pdfaDoc.pageCount == 2 && pdfaDoc.page(at: 1)!.string!.contains("Second page"), "PDF/A lost pages or text")
        let pdfaBytes = try Data(contentsOf: pdfa)
        // macOS schreibt einen PDF/A-OutputIntent und XMP mit pdfaid:part 2 / conformance B (komprimiert)
        precondition(pdfaBytes.range(of: Data("/GTS_PDFA1".utf8)) != nil && pdfaBytes.range(of: Data("/Metadata".utf8)) != nil, "PDF/A identification missing")
        print("PASS PDF compression keeps \(formWidgets) form fields, target size shrinks, PDF/A-2 written with text")
        // Nachbau Phase 4: echte PDF-Schwärzung
        let secretPage = url("secret.pdf")
        try TextRenderer.writePDF("Customer Max Muster\nIBAN DE89 3704 0044 0532 0130 00\nThis line stays.", to: secretPage)
        let secretDoc = url("secret-two.pdf")
        try PDFOps.merge([secretPage, second], to: secretDoc)
        let secretBefore = try PDFOps.document(secretDoc)
        secretBefore.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Max Muster file"]
        precondition(secretBefore.write(to: secretDoc))
        let redactedPDF = url("secret redacted.pdf")
        let result = try PDFOps.redact(secretDoc, terms: ["Max Muster", "DE89 3704"], to: redactedPDF)
        let redactedDoc = try PDFOps.document(redactedPDF)
        let remaining = redactedDoc.string ?? ""
        precondition(result.pages == 1 && result.areas >= 2, "got \(result)")
        precondition(!remaining.contains("Muster") && !remaining.contains("DE89"), "Redacted text still extractable")
        precondition(redactedDoc.pageCount == 2 && remaining.contains("Second page"), "Untouched page lost")
        precondition((redactedDoc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) == nil, "Title metadata kept")
        let rawBytes = try! Data(contentsOf: redactedPDF)
        precondition(rawBytes.range(of: Data("Muster".utf8)) == nil, "Term still in file bytes")
        do { try PDFOps.redact(secretDoc, terms: ["does-not-exist"], to: url("none.pdf")); fatalError("Empty redaction accepted") } catch OpenTangerineError.invalidInput { }
        print("PASS PDF redaction removes text, keeps untouched pages, strips title")
        // Nachbau Phase 6: Dokumente untereinander
        let doc = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12)
        doc.append(NSAttributedString(string: "Bericht Größe\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)]))
        doc.append(NSAttributedString(string: "Das ist ", attributes: [.font: body]))
        doc.append(NSAttributedString(string: "wichtig", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        doc.append(NSAttributedString(string: " und ", attributes: [.font: body]))
        doc.append(NSAttributedString(string: "kursiv", attributes: [.font: NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)]))
        doc.append(NSAttributedString(string: ", mit ", attributes: [.font: body]))
        doc.append(NSAttributedString(string: "Link", attributes: [.font: body, .link: URL(string: "https://example.com")!]))
        doc.append(NSAttributedString(string: " für 12 €.\n", attributes: [.font: body]))
        let listStyle = NSMutableParagraphStyle()
        listStyle.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        for item in ["Erster Punkt", "Zweiter Punkt"] {
            doc.append(NSAttributedString(string: "\t•\t\(item)\n", attributes: [.font: body, .paragraphStyle: listStyle]))
        }
        let docx = url("bericht.docx")
        try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
        let docxBytes = try! Data(contentsOf: docx)
        func readBack(_ file: URL, _ format: FileFormat) async throws -> String { try await RichTextEngine.read(file, format: format).string }
        var outputs: [FileFormat: URL] = [:]
        for target: FileFormat in [.rtf, .rtfd, .html, .txt, .md, .epub, .pdf] {
            let out = try await Engines.convert(ConversionRequest(source: docx, sourceFormat: .docx, target: target, destination: url("bericht.\(target.fileExtension)"), progress: { _ in }))
            outputs[target] = out
            precondition(out.pathExtension == target.fileExtension, "\(target) output name \(out.lastPathComponent)")
            let text = target == .pdf ? (try PDFOps.document(out).string ?? "") : try await readBack(out, target)
            for word in ["Bericht Größe", "wichtig", "kursiv", "Erster Punkt", "12 €"] {
                precondition(text.contains(word), "\(target) lost '\(word)': \(text.prefix(200))")
            }
        }
        precondition(try! Data(contentsOf: docx) == docxBytes, "DOCX original changed")
        let md = try! String(contentsOf: outputs[.md]!, encoding: .utf8)
        // Links: Apples DOCX-Schreiber lässt sie weg (macOS-Grenze); über RTF und Markdown bleiben sie erhalten
        for part in ["# Bericht Größe", "**wichtig**", "*kursiv*", "- Erster Punkt\n- Zweiter Punkt"] {
            precondition(md.contains(part), "Markdown lacks \(part):\n\(md)")
        }
        var isDir: ObjCBool = false
        precondition(fm.fileExists(atPath: outputs[.rtfd]!.path, isDirectory: &isDir) && isDir.boolValue, "RTFD must be a package folder")
        let epubList = try await Shell.run("/usr/bin/unzip", ["-Z1", outputs[.epub]!.path])
        precondition(epubList.stdout.split(separator: "\n").first == "mimetype" && epubList.stdout.contains("OEBPS/content.opf"), "EPUB layout")
        let mimeEntry = try await Shell.run("/usr/bin/unzip", ["-v", outputs[.epub]!.path, "mimetype"])
        precondition(mimeEntry.stdout.contains("Stored"), "EPUB mimetype must be stored uncompressed")
        let rtfLink = url("link.rtf")
        try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtfLink)
        let linkMD = try await Engines.convert(ConversionRequest(source: rtfLink, sourceFormat: .rtf, target: .md, destination: url("link.md"), progress: { _ in }))
        precondition(try! String(contentsOf: linkMD, encoding: .utf8).contains("[Link](https://example.com)"), "RTF -> Markdown lost the link")
        let linkHTML = try await Engines.convert(ConversionRequest(source: linkMD, sourceFormat: .md, target: .html, destination: url("link.html"), progress: { _ in }))
        precondition(try! String(contentsOf: linkHTML, encoding: .utf8).contains("https://example.com"), "Markdown -> HTML lost the link")
        // Markdown zurück: Überschrift größer, fett bleibt fett
        let mdSource = url("notiz.md")
        try "# Titel\n\nText mit **fett** und `code`.\n\n1. eins\n2. zwei\n".write(to: mdSource, atomically: true, encoding: .utf8)
        let mdDocx = try await Engines.convert(ConversionRequest(source: mdSource, sourceFormat: .md, target: .docx, destination: url("notiz.docx"), progress: { _ in }))
        let mdRead = try await RichTextEngine.read(mdDocx, format: .docx)
        let blocks = Blocks.parse(mdRead)
        precondition(blocks.first?.kind == .heading(1) && blocks.first?.plainText == "Titel", "Heading lost: \(blocks)")
        precondition(blocks.contains { $0.runs.contains { $0.bold && $0.text == "fett" } }, "Bold lost")
        precondition(blocks.filter { $0.kind == .numbered }.count == 2, "Numbered list lost")
        // EPUB wieder lesen und weiter nach Markdown
        let back = try await Engines.convert(ConversionRequest(source: outputs[.epub]!, sourceFormat: .epub, target: .md, destination: url("aus-epub.md"), progress: { _ in }))
        precondition(try! String(contentsOf: back, encoding: .utf8).contains("**wichtig**"), "EPUB -> Markdown lost formatting")
        // Lange Texte werden auf mehrere PDF-Seiten umbrochen
        let long = url("lang.txt")
        try (1...400).map { "Absatz \($0): Ein ganz normaler Satz, der etwas Platz braucht." }.joined(separator: "\n").write(to: long, atomically: true, encoding: .utf8)
        let longPDF = try await Engines.convert(ConversionRequest(source: url("lang.txt"), sourceFormat: .txt, target: .pdf, destination: url("lang.pdf"), progress: { _ in }))
        precondition(try! PDFOps.document(longPDF).pageCount > 3, "PDF pagination")
        let mdLong = url("lang.md")
        try (1...300).map { "Absatz **\($0)** mit Text." }.joined(separator: "\n\n").write(to: mdLong, atomically: true, encoding: .utf8)
        let mdPDF = try await Engines.convert(ConversionRequest(source: mdLong, sourceFormat: .md, target: .pdf, destination: url("lang-md.pdf"), progress: { _ in }))
        let mdPDFDoc = try PDFOps.document(mdPDF)
        precondition(mdPDFDoc.pageCount > 3 && (mdPDFDoc.string ?? "").contains("Absatz 300"), "Rich PDF pagination")
        // HTML ohne Netz: entfernte Bilder und Skripte fliegen raus, Links bleiben
        let unsafe = "<p>Hallo <a href=\"https://example.com/page\">Seite</a><img src=\"https://tracker.example/pixel.png\"><img src='//cdn.example/x.png'><img src=\"bild.png\"></p><script>fetch('https://x')</script><link rel=\"stylesheet\" href=\"https://cdn/x.css\"><div style=\"background:url(https://x/y.png)\">x</div>"
        let cleaned = HTMLSafety.offline(unsafe)
        precondition(!cleaned.contains("tracker.example") && !cleaned.contains("cdn.example") && !cleaned.contains("<script") && !cleaned.contains("cdn/x.css") && !cleaned.contains("url(https"), "Remote references kept: \(cleaned)")
        precondition(cleaned.contains("href=\"https://example.com/page\"") && cleaned.contains("src=\"bild.png\""), "Links or local images removed: \(cleaned)")
        print("PASS documents: DOCX to RTF/RTFD/HTML/TXT/Markdown/EPUB/PDF keep text and formatting, Markdown and EPUB round trips, PDF pagination, offline HTML")
        let reordered = try PDFOps.document(url("reordered.pdf"))
        precondition(reordered.page(at: 0)!.rotation == 90 && reordered.page(at: 0)!.string!.contains("Second page"))
        for strong in [false, true] {
            let out = url("compressed-\(strong).pdf")
            try PDFOps.compress(merged, strong: strong, to: out)
            precondition(try! PDFOps.document(out).pageCount == 2)
            print("PASS PDF compression strong=\(strong), preserves page count (size reduction not guaranteed)")
        }
        let imagePDF = url("images.pdf")
        try PDFOps.fromImages([url("text.png"), url("text.jpg")], to: imagePDF, progress: { _ in })
        precondition(try! PDFOps.document(imagePDF).pageCount == 2)
        let multiImages = try await convert(merged, .pdf, .png, "pages.png")
        let pages = try fm.contentsOfDirectory(at: multiImages, includingPropertiesForKeys: nil)
        precondition(pages.count == 2)
        for page in pages { precondition(try! ImageIOBridge.load(page).width == 2550) }
        let scanDOCX = try await convert(imagePDF, .pdf, .docx, "scanned.docx")
        let listing = try await Shell.run("/usr/bin/unzip", ["-l", scanDOCX.path])
        precondition(listing.stdout.contains("image1.png") && listing.stdout.contains("image2.png"))
        do { _ = try await convert(imagePDF, .pdf, .txt, "scan.txt"); fatalError("Empty scanned text reported as success") } catch { }
        let protected = url("protected.pdf")
        precondition(mergedDoc.write(to: protected, withOptions: [.userPasswordOption: "test-password", .ownerPasswordOption: "owner-password"]))
        do { _ = try await convert(protected, .pdf, .png, "locked.png"); fatalError("Locked PDF accepted") } catch { }
        let mixed = url("mixed.pdf")
        try PDFOps.merge([imagePDF, pdf], to: mixed)
        let mixedDocx = try await convert(mixed, .pdf, .docx, "mixed.docx")
        let mixedXML = try await Shell.run("/usr/bin/unzip", ["-p", mixedDocx.path, "word/document.xml"])
        precondition(mixedXML.stdout.range(of: "<w:drawing>")!.lowerBound < mixedXML.stdout.range(of: "Open Tangerine")!.lowerBound)
        precondition(mixedXML.stdout.contains("w:type=\"page\""))
        print("PASS mixed scanned/text PDF -> DOCX preserves page order and breaks")
        print("PASS PDF merge/reorder/rotate, images-to-PDF, multipage export, scanned DOCX, scanned/locked rejection")
        let srt = "1\n00:00:01,250 --> 00:00:03,000\nHello <i>world</i>\n\n2\n00:00:04,000 --> 00:00:05,000\nSecond cue\n"
        try srt.write(to: url("captions.srt"), atomically: true, encoding: .utf8)
        let vtt = try await convert(url("captions.srt"), .srt, .vtt, "captions.vtt")
        let roundtrip = try await convert(vtt, .vtt, .srt, "roundtrip.srt")
        let cues = SubtitleParser.parse(try String(contentsOf: roundtrip, encoding: .utf8), hint: .srt)
        precondition(cues.count == 2 && cues[0].start == 1.25 && cues[1].end == 5)
        for (source, format) in [(url("captions.srt"), FileFormat.srt), (vtt, .vtt)] {
            let out = try await convert(source, format, .txt, "\(format).txt")
            precondition(try! String(contentsOf: out, encoding: .utf8).contains("Hello world"))
        }
        precondition(SubtitleParser.format(59.9999, separator: ",") == "00:01:00,000")
        precondition(SubtitleParser.parseTimestamp("nan") == nil)
        print("PASS SRT/VTT round trip + both TXT exports; millisecond carry and invalid timestamp")
    }
}

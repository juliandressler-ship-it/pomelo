import AppKit
import Foundation
import PDFKit
import Quartz

struct PDFPageRef: Identifiable, Equatable {
    let id = UUID()
    let sourceIndex: Int
    var rotation: Int
    var sourceURL: URL

    static func == (lhs: PDFPageRef, rhs: PDFPageRef) -> Bool {
        lhs.id == rhs.id && lhs.rotation == rhs.rotation
    }
}

enum PDFOps {
    static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw OpenTangerineError.unreadable(url) }
        if document.isLocked { throw OpenTangerineError.invalidInput("\(url.lastPathComponent) is password protected.") }
        guard document.pageCount > 0 else { throw OpenTangerineError.invalidInput("The PDF has no pages.") }
        return document
    }

    static func merge(_ urls: [URL], to destination: URL) throws {
        guard !urls.isEmpty else { throw OpenTangerineError.invalidInput("Choose at least one PDF to merge.") }
        let output = PDFDocument()
        for url in urls {
            let source = try document(url)
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { continue }
                output.insert(page, at: output.pageCount)
            }
        }
        guard output.write(to: destination) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }

    static func assemble(pages: [PDFPageRef], to destination: URL) throws {
        var cache: [URL: PDFDocument] = [:]
        let output = PDFDocument()
        for ref in pages {
            let source: PDFDocument
            if let cached = cache[ref.sourceURL] {
                source = cached
            } else {
                source = try document(ref.sourceURL)
                cache[ref.sourceURL] = source
            }
            guard let page = source.page(at: ref.sourceIndex), let copy = page.copy() as? PDFPage else { throw OpenTangerineError.invalidInput("A selected PDF page is unavailable.") }
            copy.rotation = ref.rotation
            output.insert(copy, at: output.pageCount)
        }
        guard output.pageCount > 0 else { throw OpenTangerineError.invalidInput("The document would have no pages.") }
        guard output.write(to: destination) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }

    enum SplitMode: String, CaseIterable, Identifiable {
        case everyPage, everyN, ranges
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everyPage: return "One file per page"
            case .everyN: return "Every N pages"
            case .ranges: return "Custom page ranges"
            }
        }
    }

    static func parseRanges(_ text: String, pageCount: Int) -> [ClosedRange<Int>] {
        text.split(separator: ",").compactMap { token in
            let part = token.trimmingCharacters(in: .whitespaces)
            if let dash = part.range(of: "-") {
                let a = Int(part[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1
                let b = Int(part[dash.upperBound...].trimmingCharacters(in: .whitespaces)) ?? pageCount
                let lower = max(1, min(a, b)), upper = min(pageCount, max(a, b))
                return lower <= upper ? lower...upper : nil
            }
            if let single = Int(part), single >= 1, single <= pageCount { return single...single }
            return nil
        }
    }

    static func split(_ url: URL, mode: SplitMode, every: Int, ranges: String, into folder: URL) throws -> [URL] {
        let source = try document(url)
        let count = source.pageCount
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        var groups: [ClosedRange<Int>] = []
        switch mode {
        case .everyPage:
            groups = (1...max(1, count)).map { $0...$0 }
        case .everyN:
            let n = max(1, every)
            var start = 1
            while start <= count {
                groups.append(start...min(count, start + n - 1))
                start += n
            }
        case .ranges:
            groups = parseRanges(ranges, pageCount: count)
        }
        guard !groups.isEmpty else { throw OpenTangerineError.invalidInput("No valid page ranges.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (index, group) in groups.enumerated() {
            let part = PDFDocument()
            for pageNumber in group {
                guard let page = source.page(at: pageNumber - 1) else { continue }
                part.insert(page, at: part.pageCount)
            }
            let name = group.count == 1 ? "\(base) page \(group.lowerBound).pdf" : "\(base) pages \(group.lowerBound)-\(group.upperBound).pdf"
            let output = folder.appendingPathComponent(name.isEmpty ? "\(base) part \(index + 1).pdf" : name)
            guard part.write(to: output) else { throw OpenTangerineError.encodeFailed(output.lastPathComponent) }
            outputs.append(output)
        }
        return outputs
    }

    /// Stufen der PDF-Kompression. Alle behalten Text, Anmerkungen und Formularfelder:
    /// Es werden nur eingebettete Bilder neu komprimiert und verkleinert (Quartz-Filter wie in Vorschau).
    struct CompressionStep { let quality: Double; let resolution: Int; let sizeMax: Int }
    static let compressionSteps: [CompressionStep?] = [
        nil, // nur JPEG-Bilder und Bildschirm-Optimierung
        CompressionStep(quality: 0.7, resolution: 144, sizeMax: 2400),
        CompressionStep(quality: 0.55, resolution: 120, sizeMax: 1800),
        CompressionStep(quality: 0.4, resolution: 96, sizeMax: 1400),
        CompressionStep(quality: 0.3, resolution: 72, sizeMax: 1000),
    ]

    static func quartzFilter(_ step: CompressionStep) -> QuartzFilter? {
        let properties: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "Pomelo Compress",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": step.quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": [
                    "ImageResolution": step.resolution,
                    "ImageScaleInterpolate": true,
                    "ImageSizeMax": step.sizeMax,
                    "ImageSizeMin": 0,
                ],
            ]]],
        ]
        return QuartzFilter(properties: properties)
    }

    private static func write(_ document: PDFDocument, step: CompressionStep?, to destination: URL) throws {
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        if let step, let filter = quartzFilter(step) {
            options[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
        }
        guard document.write(to: destination, withOptions: options) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }

    /// Ohne Ziel: Balanced = Stufe 0, Strong = Stufe 3.
    /// Mit Ziel: Stufen der Reihe nach, bis die Datei klein genug ist; sonst die kleinste Variante.
    /// Gibt die erreichte Größe zurück. Seiten werden nie in Bilder umgewandelt.
    @discardableResult
    static func compress(_ url: URL, strong: Bool, targetBytes: Int64? = nil, to destination: URL) throws -> Int64 {
        let source = try document(url)
        let directory = destination.deletingLastPathComponent()
        let steps: [CompressionStep?] = targetBytes == nil ? [compressionSteps[strong ? 3 : 0]] : compressionSteps
        var best: (url: URL, size: Int64)?
        defer { if let best, FileManager.default.fileExists(atPath: best.url.path) { try? FileManager.default.removeItem(at: best.url) } }
        for step in steps {
            let temp = directory.appendingPathComponent(".opentangerine-\(UUID().uuidString).pdf")
            try write(source, step: step, to: temp)
            let size = FileSizeFormatter.size(of: temp)
            if best == nil || size < best!.size {
                if let old = best { try? FileManager.default.removeItem(at: old.url) }
                best = (temp, size)
            } else {
                try? FileManager.default.removeItem(at: temp)
            }
            if let targetBytes, size <= targetBytes { break }
        }
        guard let result = best else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        let original = FileSizeFormatter.size(of: url)
        if result.size >= original {
            // Nichts zu holen (z.B. reine Text-PDF): unveränderte Kopie statt einer größeren Datei.
            try FileManager.default.copyItem(at: url, to: destination)
            return original
        }
        try FileManager.default.moveItem(at: result.url, to: destination)
        return result.size
    }

    /// PDF/A-2b (ISO 19005-2) mit Apples eigenem Schreiber (kCGPDFContextCreatePDFA;
    /// auf macOS 27 geprüft: XMP mit pdfaid:part 2, conformance B, plus OutputIntent).
    /// Seiten werden neu gezeichnet: Text bleibt Text, Anmerkungen und Formulare werden
    /// mit ihrem Aussehen fest eingezeichnet (PDF/A erlaubt keine nachträglich veränderlichen Inhalte).
    static func makePDFA(_ url: URL, to destination: URL, progress: (Double) -> Void = { _ in }) throws {
        let source = try document(url)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".opentangerine-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        var info: [CFString: Any] = [kCGPDFContextCreatePDFA: true, kCGPDFContextCreator: "Pomelo"]
        let attributes = source.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle] = title }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor] = author }
        if info[kCGPDFContextTitle] == nil { info[kCGPDFContextTitle] = url.deletingPathExtension().lastPathComponent }
        var firstBox = source.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(temp as CFURL, mediaBox: &firstBox, info as CFDictionary) else {
            throw OpenTangerineError.encodeFailed(destination.lastPathComponent)
        }
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            context.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            page.draw(with: .mediaBox, to: context)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            progress(Double(index + 1) / Double(source.pageCount))
        }
        context.closePDF()
        guard let check = PDFDocument(url: temp), check.pageCount == source.pageCount else {
            throw OpenTangerineError.encodeFailed(destination.lastPathComponent)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    // MARK: Echte Schwärzung (Phase 4, L3)

    /// Fundstellen je Seite (Seitenindex -> Rechtecke im Seitenkoordinatensystem).
    static func redactionHits(in document: PDFDocument, terms: [String]) -> [Int: [CGRect]] {
        var hits: [Int: [CGRect]] = [:]
        for term in terms.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !term.isEmpty {
            for selection in document.findString(term, withOptions: [.caseInsensitive]) {
                for page in selection.pages {
                    let index = document.index(for: page)
                    // Jede Zeile einzeln, damit mehrzeilige Treffer nicht als großer Block erscheinen
                    for line in selection.selectionsByLine() where line.pages.contains(page) {
                        hits[index, default: []].append(line.bounds(for: page).insetBy(dx: -1.5, dy: -1.5))
                    }
                }
            }
        }
        return hits
    }

    /// Schwärzt alle Fundstellen. Betroffene Seiten werden als Bild neu aufgebaut (200 dpi):
    /// Der Text darunter ist danach nicht mehr in der Datei. Andere Seiten bleiben unverändert.
    /// Dokument-Metadaten und Lesezeichen werden entfernt, weil sie die Begriffe enthalten können.
    @discardableResult
    static func redact(_ url: URL, terms: [String], to destination: URL, dpi: CGFloat = 200, progress: (Double) -> Void = { _ in }) throws -> (pages: Int, areas: Int) {
        let document = try self.document(url)
        let hits = redactionHits(in: document, terms: terms)
        guard !hits.isEmpty else { throw OpenTangerineError.invalidInput("None of the terms were found as text in this PDF. Scanned pages without a text layer cannot be searched.") }
        let scale = dpi / 72
        for (step, index) in hits.keys.sorted().enumerated() {
            guard let page = document.page(at: index), let raw = page.pageRef else { continue }
            let box = page.bounds(for: .mediaBox)
            let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
            guard width > 0, height > 0, width * height <= 60_000_000,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw OpenTangerineError.encodeFailed("PDF page \(index + 1)") }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(raw) // ohne Drehung, damit die Trefferkoordinaten passen
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for rect in hits[index] ?? [] { context.fill(rect) }
            guard let image = context.makeImage(), let newPage = PDFPage(image: NSImage(cgImage: image, size: box.size)) else {
                throw OpenTangerineError.encodeFailed("PDF page \(index + 1)")
            }
            newPage.rotation = page.rotation
            document.removePage(at: index)
            document.insert(newPage, at: index)
            progress(Double(step + 1) / Double(hits.count))
        }
        document.documentAttributes = [:]
        document.outlineRoot = nil
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".opentangerine-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard document.write(to: temp) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        try FileManager.default.moveItem(at: temp, to: destination)
        return (hits.count, hits.values.reduce(0) { $0 + $1.count })
    }

    static func fromImages(_ urls: [URL], to destination: URL, progress: @escaping (Double) -> Void) throws {
        let output = PDFDocument()
        for (index, url) in urls.enumerated() {
            let image = try ImageIOBridge.load(url)
            let nsImage = ImageOps.nsImage(image)
            if let page = PDFPage(image: nsImage) {
                output.insert(page, at: output.pageCount)
            }
            progress(Double(index + 1) / Double(urls.count))
        }
        guard output.pageCount > 0 else { throw OpenTangerineError.invalidInput("No images could be read.") }
        guard output.write(to: destination) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
    }
}


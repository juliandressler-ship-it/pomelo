import AppKit
import PDFKit

/// Drucken über den normalen macOS-Druckdialog: PDFs, Bilder und Textdokumente (TXT, Markdown, RTF, RTFD).
/// Mehrere Dateien werden zu einem Druckauftrag zusammengefasst. Die Originale bleiben unverändert,
/// es wird nichts gespeichert und keine andere App geöffnet.
/// Bewusst nicht dabei: DOCX, HTML und EPUB (das genaue Layout käme nicht heraus), Tabellen, Audio, Video.
enum Printing {
    static let textFormats: Set<FileFormat> = [.txt, .md, .rtf, .rtfd]
    /// Bilder werden für den Druck höchstens so groß geladen (reicht für A4 mit über 300 dpi).
    static let maxImagePixels = 4000

    static func canPrint(_ format: FileFormat) -> Bool {
        format == .pdf || format.category == .image || textFormats.contains(format)
    }

    static func canPrint(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { url in FileFormat.detect(url).map(canPrint) ?? false }
    }

    /// Alle Dateien als ein PDF-Dokument zum Drucken, in der gewählten Reihenfolge.
    @MainActor
    static func document(for urls: [URL]) async throws -> PDFDocument {
        let output = PDFDocument()
        for url in urls {
            let name = url.lastPathComponent
            guard let format = FileFormat.detect(url), canPrint(format) else {
                throw OpenTangerineError.invalidInput("\(name) cannot be printed. Pomelo prints PDFs, images and text documents.")
            }
            if format == .pdf {
                guard let pdf = PDFDocument(url: url) else { throw OpenTangerineError.invalidInput("\(name) cannot be read. It may be damaged.") }
                guard !pdf.isLocked else { throw OpenTangerineError.invalidInput("\(name) is password protected. Open it in Preview to print it.") }
                guard pdf.allowsPrinting else { throw OpenTangerineError.invalidInput("\(name) does not allow printing.") }
                append(pdf, to: output)
            } else if format.category == .image {
                let image = try ImageIOBridge.load(url, maxPixelSize: maxImagePixels)
                let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                guard let page = PDFPage(image: picture) else { throw OpenTangerineError.invalidInput("\(name) cannot be printed.") }
                output.insert(page, at: output.pageCount)
            } else {
                let text = try await RichTextEngine.read(url, format: format)
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pomelo-print-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: temp) }
                try RichPDF.write(text, to: temp)
                // Erst vollständig in den Speicher laden, dann darf die Zwischendatei weg
                guard let data = try? Data(contentsOf: temp), let pdf = PDFDocument(data: data) else {
                    throw OpenTangerineError.invalidInput("\(name) cannot be printed.")
                }
                append(pdf, to: output)
            }
        }
        guard output.pageCount > 0 else { throw OpenTangerineError.invalidInput("There is nothing to print.") }
        return output
    }

    private static func append(_ pdf: PDFDocument, to output: PDFDocument) {
        for index in 0..<pdf.pageCount {
            if let page = pdf.page(at: index)?.copy() as? PDFPage { output.insert(page, at: output.pageCount) }
        }
    }

    /// Öffnet den macOS-Druckdialog (Drucker, Kopien, Seiten, Papier, Vorschau). Abbrechen druckt nichts.
    @MainActor
    static func print(_ urls: [URL]) {
        Task { @MainActor in
            do {
                let document = try await document(for: urls)
                let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
                // Große Seiten (Fotos) passend verkleinern, kleine nicht aufblasen; Querformat automatisch drehen
                guard let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
                    throw OpenTangerineError.invalidInput("Printing is not available.")
                }
                operation.jobTitle = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "\(urls.count) files"
                operation.showsPrintPanel = true
                operation.showsProgressPanel = true
                operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
                DiagnosticLog.log("print dialog for \(urls.count) file(s), \(document.pageCount) page(s)")
                NSApp.activate(ignoringOtherApps: true)
                operation.run()
            } catch {
                FileAction.alert("Could not print", error.localizedDescription)
            }
        }
    }
}

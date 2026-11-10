import AppKit
import CoreImage
import PDFKit
import Vision

/// Bildfunktionen mit Apples Vision-Framework (Phase 4). Alles läuft auf dem Mac, ohne Netz.
enum VisionOps {
    // MARK: Hintergrund entfernen (L2)

    /// Stellt das Hauptmotiv frei und gibt ein Bild mit transparentem Hintergrund zurück.
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw OpenTangerineError.invalidInput("No clear subject was found in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let output = ImageToolSupport.sharedContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw OpenTangerineError.encodeFailed("Background removal")
        }
        return output
    }

    /// Speichert "name no background.png" am gewählten Ausgabeort. Das Original bleibt unverändert.
    static func removeBackground(from url: URL) throws -> URL {
        let image = try ImageIOBridge.load(url)
        let output = try removeBackground(image)
        let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                                     baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent),
                                                     suffix: "no background", ext: "png")
        try ImageIOBridge.write(output, to: destination, format: .png)
        return destination
    }

    // MARK: QR- und Barcodes lesen (L8)

    struct Code: Equatable { let kind: String; let text: String; let page: Int? }

    static func codes(in image: CGImage, page: Int? = nil) throws -> [Code] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.payloadStringValue, !text.isEmpty else { return nil }
            return Code(kind: name(of: observation.symbology), text: text, page: page)
        }
    }

    /// Bilder direkt, PDFs Seite für Seite (gerendert mit 200 dpi).
    static func codes(in url: URL) throws -> [Code] {
        if FileFormat.detect(url) == .pdf {
            let document = try PDFOps.document(url)
            var found: [Code] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let image = PDFRenderer.render(page: page, dpi: 200) else { continue }
                found += try codes(in: image, page: index + 1)
            }
            return unique(found)
        }
        return unique(try codes(in: ImageIOBridge.load(url)))
    }

    private static func unique(_ codes: [Code]) -> [Code] {
        var seen = Set<String>()
        return codes.filter { seen.insert($0.kind + "\u{0}" + $0.text).inserted }
    }

    private static func name(of symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr, .microQR: return "QR code"
        case .ean13, .ean8, .upce: return "EAN"
        case .code128, .code39, .code93: return "Barcode"
        case .pdf417, .microPDF417: return "PDF417"
        case .aztec: return "Aztec"
        case .dataMatrix: return "Data Matrix"
        default: return "Code"
        }
    }

    /// Liest Codes, kopiert den Inhalt in die Zwischenablage und zeigt ihn an.
    @MainActor static func readAndShow(_ urls: [URL]) {
        Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    try urls.flatMap { url in try codes(in: url).map { (url.lastPathComponent, $0) } }
                }.value
                guard !found.isEmpty else {
                    FileAction.alert("No code found", "There is no readable QR code or barcode in \(urls.count == 1 ? urls[0].lastPathComponent : "these files").")
                    return
                }
                let text = found.map(\.1.text).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let lines = found.map { file, code in
                    "\(code.kind)\(code.page.map { ", page \($0)" } ?? "")\(urls.count > 1 ? " in \(file)" : ""):\n\(code.text)"
                }
                FileAction.alert(found.count == 1 ? "Code copied" : "\(found.count) codes copied", lines.joined(separator: "\n\n"))
            } catch {
                FileAction.alert("Could not read codes", error.localizedDescription)
            }
        }
    }
}

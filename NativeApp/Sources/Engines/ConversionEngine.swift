import Foundation

struct ConversionRequest {
    let source: URL
    let sourceFormat: FileFormat
    let target: FileFormat
    let destination: URL
    let progress: (Double) -> Void
}

protocol ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool
    func convert(_ request: ConversionRequest) async throws
}

enum Engines {
    static let all: [ConversionEngine] = [
        ImageEngine(),
        AudioEngine(),
        VideoEngine(),
        DocumentEngine(),
        RichTextEngine(),
        TableEngine(),
        SubtitleEngine(),
        ArchiveEngine(),
    ]

    static func engine(from: FileFormat, to: FileFormat) -> ConversionEngine? {
        all.first { $0.supports(from: from, to: to) }
    }

    /// Liefert die tatsächliche Ausgabe. Bei mehrseitigen PDFs ist das ein Ordner
    /// ("dokument JPG pages"), damit kein Ordner wie eine Bilddatei heißt.
    @discardableResult
    static func convert(_ request: ConversionRequest) async throws -> URL {
        guard let engine = engine(from: request.sourceFormat, to: request.target) else {
            DiagnosticLog.log("no engine for \(request.sourceFormat.rawValue) -> \(request.target.rawValue)")
            throw OpenTangerineError.unsupportedConversion(request.sourceFormat, request.target)
        }
        DiagnosticLog.log("engine \(type(of: engine)) \(request.sourceFormat.rawValue) -> \(request.target.rawValue) src=\(request.source.path)")
        let temp = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".opentangerine-\(UUID().uuidString).\(request.destination.pathExtension)")
        let staged = ConversionRequest(
            source: request.source,
            sourceFormat: request.sourceFormat,
            target: request.target,
            destination: temp,
            progress: request.progress
        )
        do {
            try await engine.convert(staged)
            try Task.checkCancellation()
            DiagnosticLog.log("engine finished, staged=\(temp.lastPathComponent)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: temp.path, isDirectory: &isDirectory) {
                // moveItem refuses an existing destination; never delete another file.
                var final = request.destination
                if isDirectory.boolValue, !request.target.isPackage {
                    let base = request.destination.deletingPathExtension().lastPathComponent
                    final = ConversionMatrix.uniqueDirectory(directory: request.destination.deletingLastPathComponent(),
                                                             name: "\(base) \(request.target.displayName) pages")
                }
                try FileManager.default.moveItem(at: temp, to: final)
                return final
            } else {
                throw OpenTangerineError.encodeFailed(request.destination.lastPathComponent)
            }
        } catch {
            DiagnosticLog.log("engine threw: \(error)")
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}


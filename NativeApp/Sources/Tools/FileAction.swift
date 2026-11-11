import AppKit
import CryptoKit

enum FileAction: String, CaseIterable, Hashable {
    case reveal = "Reveal", airdrop = "AirDrop", float = "Float", copy = "Copy Files", paths = "Copy Paths"
    case move = "Move", duplicate = "Duplicate", zip = "ZIP", terminal = "Terminal", hash = "SHA-256"
    // Nur im Konvertierungsrad: Archive entpacken, PDF als PDF/A sichern
    case extract = "EXTRACT", pdfa = "PDF/A"
    // Nur im Werkzeugrad (Phase 4)
    case removeBackground = "REMOVE BG", readCodes = "READ CODE"

    /// Reihenfolge im Aktionsrad (Control).
    static let wheel: [FileAction] = [.reveal, .airdrop, .float, .copy, .paths, .move, .duplicate, .zip, .terminal, .hash]

    var symbol: String {
        switch self {
        case .reveal: return "folder"
        case .airdrop: return "airplayaudio"
        case .float: return "rectangle.on.rectangle"
        case .copy: return "doc.on.doc"
        case .paths: return "link"
        case .move: return "arrow.right.doc.on.clipboard"
        case .duplicate: return "plus.square.on.square"
        case .zip: return "archivebox"
        case .terminal: return "terminal"
        case .hash: return "number"
        case .extract: return "shippingbox.and.arrow.backward"
        case .pdfa: return "checkmark.seal"
        case .removeBackground: return "person.crop.rectangle"
        case .readCodes: return "qrcode.viewfinder"
        }
    }

    var detail: String {
        switch self {
        case .reveal: return "Show in Finder"
        case .airdrop: return "Send with AirDrop"
        case .float: return "Keep on the shelf"
        case .copy: return "Copy files"
        case .paths: return "Copy paths"
        case .move: return "Move to a folder"
        case .duplicate: return "Duplicate next to the original"
        case .zip: return "Compress as ZIP"
        case .terminal: return "Open folder in Terminal"
        case .hash: return "Copy SHA-256 checksum"
        case .extract: return "Extract next to the archive"
        case .pdfa: return "Save as PDF/A for archiving"
        case .removeBackground: return "Remove the background"
        case .readCodes: return "Read QR code or barcode"
        }
    }

    static func duplicateFiles(_ urls: [URL]) throws -> [URL] {
        try urls.map { source in
            let destination = ConversionMatrix.uniqueURL(directory: source.deletingLastPathComponent(), baseName: source.deletingPathExtension().lastPathComponent, suffix: "copy", ext: source.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
    }

    static func hashReport(_ urls: [URL]) throws -> String {
        try urls.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw OpenTangerineError.invalidInput("\(url.lastPathComponent) is a folder. SHA-256 works with files only.")
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() + "  " + url.lastPathComponent
        }.joined(separator: "\n")
    }
    @MainActor func run(_ urls: [URL]) {
        switch self {
        case .airdrop:
            NSApp.activate(ignoringOtherApps: true)
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                Self.alert("AirDrop is not available", "Turn on Wi-Fi and Bluetooth, then try again.")
                return
            }
            service.perform(withItems: urls)
        case .float:
            FloatShelf.shared.add(urls)
        case .move:
            Self.move(urls)
        case .zip:
            JobRunner.shared.run(title: "Creating ZIP", detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files", symbol: symbol) { _ in
                [try await ArchiveEngine.zip(urls)]
            }
        case .extract:
            for url in urls {
                JobRunner.shared.run(title: "Extracting", detail: url.lastPathComponent, symbol: symbol) { _ in
                    [try await ArchiveEngine.extractNextToOriginal(url)]
                }
            }
        case .pdfa:
            for url in urls {
                JobRunner.shared.run(title: "Saving as PDF/A", detail: url.lastPathComponent, symbol: symbol) { progress in
                    let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
                    let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url), baseName: base, suffix: "PDF-A", ext: "pdf")
                    try PDFOps.makePDFA(url, to: destination, progress: progress)
                    return [destination]
                }
            }
        case .terminal:
            Self.openInTerminal(urls)
        case .removeBackground:
            for url in urls {
                JobRunner.shared.run(title: "Removing background", detail: url.lastPathComponent, symbol: symbol) { _ in
                    [try VisionOps.removeBackground(from: url)]
                }
            }
        case .readCodes:
            VisionOps.readAndShow(urls)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        case .paths:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .duplicate:
            JobRunner.shared.run(title: "Duplicate", detail: "\(urls.count) files") { _ in
                try Self.duplicateFiles(urls)
            }
        case .hash:
            Task {
                do {
                    let report = try await Task.detached(priority: .userInitiated) {
                        try Self.hashReport(urls)
                    }.value
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    let alert = NSAlert()
                    alert.messageText = "SHA-256 copied"
                    alert.informativeText = report
                    alert.runModal()
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

    @MainActor static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Verschieben in einen gewählten Ordner. Nie überschreiben: bei Namensgleichheit "name 2".
    @MainActor static func move(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = urls.count == 1 ? "Move \(urls[0].lastPathComponent) to" : "Move \(urls.count) files to"
        panel.directoryURL = urls.first?.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            JobRunner.shared.run(title: "Moving", detail: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files", symbol: "arrow.right.doc.on.clipboard") { _ in
                try moveFiles(urls, to: folder)
            }
        }
    }

    static func moveFiles(_ urls: [URL], to folder: URL) throws -> [URL] {
        try urls.map { source in
            if source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return source }
            let destination = ConversionMatrix.uniqueURL(directory: folder, baseName: source.deletingPathExtension().lastPathComponent, suffix: "", ext: source.pathExtension)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
    }

    /// Öffnet den Ordner der ersten Datei in der gewählten Terminal-App.
    @MainActor static func openInTerminal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
        let folder = isDirectory.boolValue ? first : first.deletingLastPathComponent()
        let app = URL(fileURLWithPath: AppSettings.shared.terminalAppPath)
        guard FileManager.default.fileExists(atPath: app.path) else {
            alert("Terminal app not found", "Choose a terminal app in Settings → General.")
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in alert("Could not open the folder", error.localizedDescription) } }
        }
    }
}

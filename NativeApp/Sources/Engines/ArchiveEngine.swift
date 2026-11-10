import Foundation

/// Archive (Phase 3, L1): ZIP, TAR und TAR.GZ erzeugen; ZIP, TAR, GZIP und RAR entpacken.
/// Nur Bordmittel: /usr/bin/tar (bsdtar/libarchive), /usr/bin/zip, /usr/bin/gzip.
///
/// Schutz vor bösartigen Archiven:
/// 1. Vor dem Entpacken wird das Inhaltsverzeichnis gelesen und abgelehnt, wenn es
///    absolute Pfade, ".."-Pfade oder Verknüpfungen nach außen enthält oder zu groß ist.
/// 2. Entpackt wird nur in einen frischen, leeren Ordner (bsdtar ohne -P).
/// 3. Danach wird der Ordner noch einmal geprüft (Größe, Verknüpfungen).
struct ArchiveEngine: ConversionEngine {
    static let maxEntries = 20_000
    static let maxBytes: Int64 = 4_000_000_000

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .archive && to.category == .archive && to != .rar && from != to
    }

    /// Archiv in ein anderes Archivformat umpacken: sicher entpacken, dann neu packen.
    func convert(_ request: ConversionRequest) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        request.progress(0.1)
        try await Self.extract(request.source, format: request.sourceFormat, into: work)
        request.progress(0.6)
        try await Self.pack(contentsOf: work, as: request.target, to: request.destination)
        request.progress(1)
    }

    // MARK: Prüfen

    struct Listing { var entries = 0; var bytes: Int64 = 0 }

    /// Liest das Inhaltsverzeichnis und lehnt gefährliche Archive ab.
    static func inspect(_ archive: URL, format: FileFormat) async throws -> Listing {
        if format == .gz, !isTarball(archive) {
            // Einzelne .gz-Datei: nur die entpackte Größe zählt.
            let result = try await Shell.run("/usr/bin/gzip", ["-l", archive.path])
            guard result.succeeded else { throw OpenTangerineError.invalidInput("This GZIP file cannot be read.") }
            let fields = result.stdout.split(separator: "\n").dropFirst().first?.split(separator: " ") ?? []
            let size = fields.count > 1 ? Int64(fields[1]) ?? 0 : 0
            // gzip speichert die Größe nur modulo 4 GB; deshalb zusätzlich nach dem Entpacken prüfen.
            guard size <= maxBytes else { throw tooLarge }
            return Listing(entries: 1, bytes: size)
        }
        let result = try await Shell.run("/usr/bin/tar", ["-tvf", archive.path])
        guard result.succeeded else {
            throw OpenTangerineError.invalidInput("This archive cannot be read. It may be damaged, encrypted or in an unsupported RAR version.")
        }
        var listing = Listing()
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let entry = try parse(String(line))
            listing.entries += 1
            listing.bytes += entry.size
            guard listing.entries <= maxEntries else {
                throw OpenTangerineError.invalidInput("This archive has more than \(maxEntries) entries. It was not extracted.")
            }
            guard listing.bytes <= maxBytes else { throw tooLarge }
        }
        return listing
    }

    private static var tooLarge: OpenTangerineError {
        .invalidInput("This archive would unpack to more than \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)). It was not extracted.")
    }

    struct Entry { var name: String; var size: Int64; var linkTarget: String? }

    /// Eine Zeile aus `tar -tv` (Format wie `ls -l`):
    /// `-rw-r--r--  0 user staff 1234 Nov  9 19:12 name` bzw. `… name -> ziel` / `… name link to ziel`.
    static func parse(_ line: String) throws -> Entry {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count == 9, let size = Int64(parts[4]) else {
            throw OpenTangerineError.invalidInput("This archive has an entry that cannot be checked. It was not extracted.")
        }
        let mode = parts[0].first ?? "-"
        var name = String(parts[8])
        var target: String?
        if mode == "l", let range = name.range(of: " -> ") {
            target = String(name[range.upperBound...]); name = String(name[..<range.lowerBound])
        } else if let range = name.range(of: " link to ") {
            target = String(name[range.upperBound...]); name = String(name[..<range.lowerBound])
        }
        guard isSafe(name) else {
            throw OpenTangerineError.invalidInput("This archive contains an unsafe path (\(name)). It was not extracted.")
        }
        if let target {
            // Verknüpfungen dürfen nur innerhalb des Archivs zeigen.
            let resolved = mode == "l" ? ((name as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target) : target
            guard !target.hasPrefix("/"), isSafe(normalized(resolved)) else {
                throw OpenTangerineError.invalidInput("This archive contains a link that points outside the archive (\(name)). It was not extracted.")
            }
        }
        return Entry(name: name, size: max(0, size), linkTarget: target)
    }

    /// Kein absoluter Pfad, kein "..", das aus dem Zielordner führt.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        var depth = 0
        for component in path.split(separator: "/") {
            if component == ".." { depth -= 1 } else if component != "." { depth += 1 }
            if depth < 0 { return false }
        }
        return true
    }

    private static func normalized(_ path: String) -> String { path.isEmpty ? "." : path }

    static func isTarball(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
    }

    // MARK: Entpacken

    /// Entpackt in einen leeren Ordner. Bricht ab, wenn das Archiv die Prüfung nicht besteht.
    static func extract(_ archive: URL, format: FileFormat, into directory: URL) async throws {
        let listing = try await inspect(archive, format: format)
        if let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           listing.bytes > free {
            throw OpenTangerineError.invalidInput("Not enough free disk space to extract this archive.")
        }
        if format == .gz, !isTarball(archive) {
            let output = directory.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", archive.path]
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            try process.run()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in done.resume() }
                }
            } onCancel: { process.terminate() }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw OpenTangerineError.toolFailed("gzip", "The GZIP file is damaged.") }
        } else {
            // bsdtar entfernt führende "/" und verweigert ".." ohne -P; Rechte und Besitzer werden nicht übernommen.
            let result = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path, "--no-same-owner", "--no-same-permissions"])
            guard result.succeeded else { throw OpenTangerineError.toolFailed("tar", result.stderr) }
        }
        try verify(directory)
    }

    /// Nachkontrolle: Größe und Verknüpfungen im entpackten Ordner.
    static func verify(_ directory: URL) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: []) else { return }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                let target = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard target == root || target.hasPrefix(root + "/") else {
                    throw OpenTangerineError.invalidInput("The archive contained a link outside its folder. Nothing was kept.")
                }
            }
            total += Int64(values.fileSize ?? 0)
            guard total <= maxBytes else { throw tooLarge }
        }
    }

    /// Entpackt neben das Archiv: "name" (bei Namensgleichheit "name 2").
    /// Enthält das Archiv genau einen Ordner, wird dieser direkt übernommen (kein "name/name").
    static func extractNextToOriginal(_ archive: URL) async throws -> URL {
        guard let format = FileFormat.detect(archive), format.category == .archive else {
            throw OpenTangerineError.invalidInput("\(archive.lastPathComponent) is not a ZIP, TAR, GZIP or RAR archive.")
        }
        let parent = archive.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".opentangerine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await extract(archive, format: format, into: staging)
        let items = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        let base = ConversionMatrix.strippedBaseName(archive.lastPathComponent)
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let destination = ConversionMatrix.uniqueDirectory(directory: parent, name: items[0].lastPathComponent)
            try FileManager.default.moveItem(at: items[0], to: destination)
            return destination
        }
        if items.count == 1 {
            let file = items[0]
            let destination = ConversionMatrix.uniqueURL(directory: parent, baseName: file.deletingPathExtension().lastPathComponent, suffix: "", ext: file.pathExtension)
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
        let destination = ConversionMatrix.uniqueDirectory(directory: parent, name: base)
        try FileManager.default.moveItem(at: staging, to: destination)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false) // für defer
        return destination
    }

    // MARK: Packen

    /// Packt den Inhalt eines Ordners als ZIP, TAR oder TAR.GZ.
    static func pack(contentsOf directory: URL, as format: FileFormat, to destination: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.zip(directory: directory, to: destination)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-cf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw OpenTangerineError.toolFailed("tar", result.stderr) }
        case .gz:
            let result = try await Shell.run("/usr/bin/tar", ["-czf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw OpenTangerineError.toolFailed("tar", result.stderr) }
        default:
            throw OpenTangerineError.unsupportedConversion(.zip, format)
        }
    }

    /// Dateien als ZIP neben die erste Datei legen: "name.zip" bzw. "Archive.zip" bei mehreren.
    static func zip(_ files: [URL]) async throws -> URL {
        guard let first = files.first else { throw OpenTangerineError.invalidInput("Choose at least one file.") }
        let parent = first.deletingLastPathComponent()
        let base = files.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let destination = ConversionMatrix.uniqueURL(directory: parent, baseName: base, suffix: "", ext: "zip")
        let temp = parent.appendingPathComponent(".opentangerine-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temp) }
        if files.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) {
            let result = try await Shell.run("/usr/bin/zip", ["-r", "-X", "-q", "-y", temp.path] + files.map(\.lastPathComponent), currentDirectory: parent)
            guard result.succeeded else { throw OpenTangerineError.toolFailed("zip", result.stderr) }
        } else {
            // Dateien aus verschiedenen Ordnern: erst in einen Arbeitsordner kopieren (auf APFS ohne Platzbedarf).
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("opentangerine-zip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            for file in files {
                let target = ConversionMatrix.uniqueURL(directory: work, baseName: file.deletingPathExtension().lastPathComponent, suffix: "", ext: file.pathExtension)
                try FileManager.default.copyItem(at: file, to: target)
            }
            try await ZipTool.zip(directory: work, to: temp)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }
}

import AppKit
import ImageIO
import PDFKit

@main struct IntegrationTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenTangerine-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let source = root.appendingPathComponent("test.png")
        try ImageIOBridge.write(context.makeImage()!, to: source, format: .png)
        let original = try Data(contentsOf: source)
        for target: FileFormat in [.jpg, .tiff, .pdf] {
            let destination = root.appendingPathComponent("output.\(target.fileExtension)")
            try await Engines.convert(ConversionRequest(source: source, sourceFormat: .png, target: target, destination: destination, progress: { _ in }))
            if target == .pdf {
                guard PDFDocument(url: destination)?.pageCount == 1 else { fatalError("Invalid PDF") }
            } else {
                let image = try ImageIOBridge.load(destination)
                guard image.width == 32 && image.height == 24 else { fatalError("Invalid dimensions") }
            }
            print("PASS PNG -> \(target)")
        }
        // HEIC must either encode correctly or fail without poisoning the next JPEG job.
        let runner = JobRunner(presentsHUD: false)
        let failure = Job(title: "Converting to HEIC", detail: "invalid input")
        runner.enqueue(failure) { _ in
            throw OpenTangerineError.invalidInput("Expected regression test failure")
        }
        await failure.task?.value
        guard case .failed = failure.status else { fatalError("Failure not reported") }
        let jpeg = Job(title: "Converting to JPEG", detail: "recovery")
        runner.enqueue(jpeg) { progress in
            let output = root.appendingPathComponent("recovery.jpg")
            try await Engines.convert(ConversionRequest(source: source, sourceFormat: .png, target: .jpg, destination: output, progress: progress))
            return [output]
        }
        await jpeg.task?.value
        precondition(jpeg.status == .done && runner.jobs.count == 1 && runner.jobs.first?.id == jpeg.id)
        precondition(CompanionState.shared.phase != .failed)
        runner.dismissAll()
        print("PASS failed HEIC job followed by JPEG without restart or stale results")
        do {
            let heic = root.appendingPathComponent("actual.heic")
            try await Engines.convert(ConversionRequest(source: source, sourceFormat: .png, target: .heic, destination: heic, progress: { _ in }))
            let decoded = try ImageIOBridge.load(heic)
            precondition(decoded.width == 32 && decoded.height == 24)
            print("PASS PNG -> HEIC round trip")
        } catch {
            print("HEIC encoder unavailable in this execution environment: \(error.localizedDescription)")
        }
        try ImageIOBridge.validateDimensions(width: 1562, height: 1222)
        do { try ImageIOBridge.validateDimensions(width: 0, height: 0); fatalError("Missing dimensions accepted") }
        catch { precondition(!error.localizedDescription.contains("40 megapixel")) }
        do { try ImageIOBridge.validateDimensions(width: 10000, height: 10000); fatalError("Oversized image accepted") }
        catch { precondition(error.localizedDescription.contains("10000")) }
        let occupied = root.appendingPathComponent("occupied.jpg")
        let sentinel = Data("do not overwrite".utf8)
        try sentinel.write(to: occupied)
        do {
            try await Engines.convert(ConversionRequest(source: source, sourceFormat: .png, target: .jpg, destination: occupied, progress: { _ in }))
            fatalError("Destination overwrite allowed")
        } catch { }
        guard try Data(contentsOf: occupied) == sentinel, try Data(contentsOf: source) == original else { fatalError("Original modified") }
        let bad = root.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        do { _ = try ImageIOBridge.load(bad); fatalError("Malformed image accepted") } catch { }
        // Nachbau Phase 3: Archive mit Schutzprüfung
        let pack = root.appendingPathComponent("pack")
        try fm.createDirectory(at: pack.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("eins".utf8).write(to: pack.appendingPathComponent("eins.txt"))
        try Data("zwei".utf8).write(to: pack.appendingPathComponent("inner/zwei.txt"))
        let archive = root.appendingPathComponent("archive.zip")
        try await ZipTool.zip(directory: pack, to: archive)
        let archiveBytes = try Data(contentsOf: archive)
        for target: FileFormat in [.tar, .gz] {
            let out = try await Engines.convert(ConversionRequest(source: archive, sourceFormat: .zip, target: target, destination: root.appendingPathComponent("archive.\(target.fileExtension)"), progress: { _ in }))
            let check = root.appendingPathComponent("check-\(target.rawValue)")
            try fm.createDirectory(at: check, withIntermediateDirectories: true)
            try await ArchiveEngine.extract(out, format: target, into: check)
            precondition(try! String(contentsOf: check.appendingPathComponent("inner/zwei.txt"), encoding: .utf8) == "zwei", "\(target) round trip")
        }
        precondition(try! Data(contentsOf: archive) == archiveBytes, "Archive original changed")
        // Entpacken neben das Original, Namensregel "name 2"
        let first = try await ArchiveEngine.extractNextToOriginal(archive)
        let second = try await ArchiveEngine.extractNextToOriginal(archive)
        precondition(first.lastPathComponent == "archive" && second.lastPathComponent == "archive 2", "got \(first.lastPathComponent), \(second.lastPathComponent)")
        precondition(fm.fileExists(atPath: first.appendingPathComponent("inner/zwei.txt").path))
        precondition(try! fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".opentangerine-") }, "Staging left behind")
        // ZIP aus mehreren Dateien
        let zipped = try await ArchiveEngine.zip([pack.appendingPathComponent("eins.txt"), pack.appendingPathComponent("inner")])
        precondition(zipped.lastPathComponent == "Archive.zip")
        // Böse Archive: ".."-Pfad und Verknüpfung nach außen werden abgelehnt, nichts wird geschrieben
        let evil = root.appendingPathComponent("evil")
        try fm.createDirectory(at: evil, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: evil.appendingPathComponent("a.txt"))
        try fm.createSymbolicLink(atPath: evil.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        let traversal = root.appendingPathComponent("traversal.tar")
        let linkTar = root.appendingPathComponent("link.tar")
        _ = try await Shell.run("/usr/bin/tar", ["-cf", traversal.path, "-s", ",^a.txt,../../a.txt,", "a.txt"], currentDirectory: evil)
        _ = try await Shell.run("/usr/bin/tar", ["-cf", linkTar.path, "link"], currentDirectory: evil)
        for bad in [traversal, linkTar] {
            let target = root.appendingPathComponent("unpack-\(bad.deletingPathExtension().lastPathComponent)")
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            do {
                try await ArchiveEngine.extract(bad, format: .tar, into: target)
                fatalError("Unsafe archive extracted: \(bad.lastPathComponent)")
            } catch OpenTangerineError.invalidInput { }
            precondition(try! fm.contentsOfDirectory(atPath: target.path).isEmpty, "Something was written for \(bad.lastPathComponent)")
        }
        precondition(ArchiveEngine.isSafe("a/b/../c") && !ArchiveEngine.isSafe("a/../../c") && !ArchiveEngine.isSafe("/etc/x"))
        let result = try await Shell.run("/usr/bin/printf", ["%s", "a;$(echo unsafe)"])
        guard result.stdout == "a;$(echo unsafe)" else { fatalError("Arguments interpolated") }
        print("PASS collision protection, original preservation, malformed input, archive round trip, safe extraction, traversal and link rejection, literal process arguments")
    }
}

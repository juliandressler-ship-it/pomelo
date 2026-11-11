import Foundation
import AppKit
final class UpdateResponse: URLProtocol {
    static var body = ""
    static var status = 200
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct InteractionTests {
    @MainActor static func main() async throws {
        precondition(!DragMonitor.acceptsDrag(hasFiles: false, types: [.string, NSPasteboard.PasteboardType("com.corel.vector")]), "Internal vector drags must not open the wheel")
        precondition(DragMonitor.acceptsDrag(hasFiles: true, types: []))
        precondition(DragMonitor.acceptsDrag(hasFiles: false, types: [.fileURL]))
        let excluded = ["test.design.app": "Design app"]
        precondition(DragMonitor.isExcluded("test.design.app", applications: excluded))
        precondition(!DragMonitor.isExcluded("com.apple.finder", applications: excluded))
        precondition(!DragMonitor.isExcluded(nil, applications: excluded))
        for count in [3, 6, 10] {
            let geometry = RadialGeometry(count: count)
            for index in 0..<count {
                let angles = geometry.angles(for: index)
                let angle = (angles.start + angles.end) / 2
                precondition(geometry.index(at: CGPoint(x: cos(angle) * geometry.labelRadius, y: sin(angle) * geometry.labelRadius)) == index)
            }
            precondition(geometry.index(at: .zero) == nil)
        }
        let settings = AppSettings.shared
        let oldStyle = settings.progressStyle
        settings.progressStyle = .pill
        let runner = JobRunner(presentsHUD: false)
        let completedJob = Job(title: "Test", detail: "test")
        runner.enqueue(completedJob) { _ in [] }
        await completedJob.task?.value
        runner.hoverResults(true)
        try await Task.sleep(nanoseconds: 2_300_000_000)
        precondition(runner.jobs.isEmpty, "Completed notch must dismiss even when hovered")
        settings.progressStyle = oldStyle
        print("PASS vector drag rejection, app exclusions, radial hit regions and two-second notch dismissal")
        precondition(AppVersion("0.1.10")! > AppVersion("0.1.9")!)
        precondition(AppVersion("v1.0.0")! == AppVersion("1.0.0")!)
        precondition(AppVersion("1.2.3-beta") == nil)
        precondition(AppVersion("1.2") == nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateResponse.self]
        let suite = "OpenTangerine-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var openedPage: URL?
        let checker = UpdateChecker(session: URLSession(configuration: config), defaults: defaults, currentVersion: "0.1.2", openPage: { openedPage = $0 })
        precondition(checker.downloadPage.absoluteString == "https://sintaxerrorpvtltd.github.io/Open-Tangerine/?version=0.1.2#download")
        await checker.check(interactive: true)
        precondition(openedPage == checker.downloadPage)
        precondition(UpdateResponse.requests == 1, "Manual checks also refresh the menu")
        UpdateResponse.body = #"{"tag_name":"v0.1.3","draft":false,"prerelease":false,"assets":[{"name":"Open-Tangerine-0.1.3-macOS.zip","state":"uploaded","browser_download_url":"https://github.com/sintaxerrorpvtltd/Open-Tangerine/releases/download/v0.1.3/Open-Tangerine-0.1.3-macOS.zip"}]}"#
        await checker.check(interactive: false)
        precondition(checker.availableVersion == "v0.1.3")
        defaults.removeObject(forKey: "lastUpdateCheck")
        UpdateResponse.body = #"{"tag_name":"v0.1.2","draft":false,"prerelease":false,"assets":[{"name":"Open-Tangerine-0.1.2-macOS.zip","state":"uploaded","browser_download_url":"https://github.com/sintaxerrorpvtltd/Open-Tangerine/releases/download/v0.1.2/Open-Tangerine-0.1.2-macOS.zip"}]}"#
        await checker.check(interactive: false)
        precondition(checker.availableVersion == nil)
        defaults.removeObject(forKey: "lastUpdateCheck")
        UpdateResponse.status = 404
        await checker.check(interactive: false)
        precondition(defaults.object(forKey: "lastUpdateCheck") == nil)
        print("PASS HTTP update detection, current version, unpublished release")
        let state = CompanionState.shared
        state.set(.watching)
        state.watch(label: "PNG", direction: 3)
        precondition(state.gaze == 1 && state.caption.contains("PNG"))
        let interrupted = state.transition(from: .received, to: .processing, after: 0.01)
        state.set(.failed)
        await interrupted.value
        precondition(state.phase == .failed, "Late animation must not overwrite error")
        let completed = state.transition(from: .delivering, to: .success, after: 0.01)
        await completed.value
        precondition(state.phase == .success)
        print("PASS version ordering, invalid version rejection, gaze bounds, interrupted and completion transitions")

        // Nachbau Phase 2: Tasten frei wählbar, nie doppelt belegt
        let keys = AppSettings.shared
        let saved = (keys.key(for: .convert), keys.key(for: .tools), keys.key(for: .actions))
        keys.setKey(.shift, for: .convert); keys.setKey(.command, for: .tools); keys.setKey(.control, for: .actions)
        keys.setKey(.command, for: .convert)
        precondition(keys.key(for: .convert) == .command && keys.key(for: .tools) == .shift, "Konflikt muss Tasten tauschen")
        precondition(Set<DragKey>([keys.key(for: .convert), keys.key(for: .tools), keys.key(for: .actions)]).count == 3)
        keys.setKey(.shift, for: .convert); keys.setKey(.command, for: .tools); keys.setKey(.control, for: .actions)
        var wheel = DragMonitor.wheelState(flags: [.shift], settings: keys)
        precondition(wheel.shift && !wheel.option, "Shift öffnet das Konvertierungsrad")
        wheel = DragMonitor.wheelState(flags: [.command], settings: keys)
        precondition(wheel.shift && wheel.option, "Command öffnet das Werkzeugrad")
        wheel = DragMonitor.wheelState(flags: [.option, .shift], settings: keys)
        precondition(wheel.shift && wheel.option, "Option + Shift bleibt zweiter Weg zum Werkzeugrad")
        wheel = DragMonitor.wheelState(flags: [.option], settings: keys)
        precondition(!wheel.shift, "Option allein öffnet kein Rad")
        keys.setKey(.option, for: .tools)
        wheel = DragMonitor.wheelState(flags: [.option], settings: keys)
        precondition(wheel.shift && wheel.option, "Neu belegte Taste öffnet das Werkzeugrad")
        keys.setKey(saved.0, for: .convert); keys.setKey(saved.1, for: .tools); keys.setKey(saved.2, for: .actions)

        // Schreibtisch: kein zusätzliches Finder-Fenster
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let previousSkip = keys.skipRevealOnDesktop
        keys.skipRevealOnDesktop = true
        precondition(JobRunner.onlyOnDesktop([desktop.appendingPathComponent("a.png")], settings: keys))
        precondition(!JobRunner.onlyOnDesktop([desktop.appendingPathComponent("a.png"), URL(fileURLWithPath: "/tmp/b.png")], settings: keys))
        keys.skipRevealOnDesktop = false
        precondition(!JobRunner.onlyOnDesktop([desktop.appendingPathComponent("a.png")], settings: keys))
        keys.skipRevealOnDesktop = previousSkip
        print("PASS configurable wheel keys without duplicates, Option+Shift fallback, desktop reveal rule")

        // Kontrolle: Tastatursteuerung im Rad wie im Original (Pfeile, Enter, Escape, Command/Control wechseln)
        let quiet = (keys.soundEnabled, keys.hapticsEnabled)
        keys.soundEnabled = false; keys.hapticsEnabled = false
        let wheelView = RadialView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        wheelView.items = [FileFormat.jpg, .png, .webp, .heic].map(RadialItem.init(format:))
        wheelView.interactive = true
        var chosen: RadialItem?
        var cancelled = false
        var switched: [AppSettings.Wheel] = []
        wheelView.onSelect = { chosen = $0 }
        wheelView.onCancel = { cancelled = true }
        wheelView.onWheelChange = { switched.append($0) }
        func press(_ code: UInt16, _ chars: String = "") {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            wheelView.keyDown(with: event)
        }
        func modifiers(_ flags: NSEvent.ModifierFlags, _ code: UInt16) {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            wheelView.flagsChanged(with: event)
        }
        press(125)            // Pfeil runter -> erstes Segment
        precondition(wheelView.highlighted == 0, "arrow selects first")
        press(124); press(124) // Pfeil rechts zweimal
        precondition(wheelView.highlighted == 2, "arrows move forward")
        press(123)            // Pfeil links
        precondition(wheelView.highlighted == 1, "arrows move back")
        press(126); press(126) // hoch zweimal: von 1 über 0 auf das letzte
        precondition(wheelView.highlighted == 3, "wraps around")
        press(36, "\r")       // Enter
        precondition(chosen?.label == "HEIC", "Return chooses highlighted: \(String(describing: chosen?.label))")
        press(53)             // Escape
        precondition(cancelled, "Escape cancels")
        modifiers([.command], 55); modifiers([.control], 59); modifiers([.shift], 56); modifiers([], 56)
        precondition(switched == [.tools, .actions, .convert], "Command/Control/Shift switch wheels: \(switched)")
        wheelView.interactive = false
        modifiers([.command], 55)
        precondition(switched.count == 3, "no switching while dragging")
        keys.soundEnabled = quiet.0; keys.hapticsEnabled = quiet.1
        // Ordner bleiben in der Zieh-Auswahl (für das Aktionsrad)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-folder-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard(name: NSPasteboard.Name("ot-test-\(UUID())"))
        board.clearContents(); board.writeObjects([folder as NSURL])
        precondition(DragMonitor.fileURLs(on: board).map(\.lastPathComponent) == [folder.lastPathComponent], "folder kept for file actions")
        board.releaseGlobally()
        do { _ = try FileAction.hashReport([folder]); fatalError("hash of folder") } catch OpenTangerineError.invalidInput(let message) { precondition(message.contains("folder")) }
        // Tastenkombination lässt sich registrieren und wieder abmelden
        FinderHotKey.shared.register(.controlOptionT)
        precondition(!FinderHotKey.shared.registrationFailed, "hot key registration")
        FinderHotKey.shared.register(.off)
        print("PASS wheel keyboard: arrows, wrap, Return, Escape, Command/Control/Shift switch wheels; folders kept for actions; hot key registers")
    }
}

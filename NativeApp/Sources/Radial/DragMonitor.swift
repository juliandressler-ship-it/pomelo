import AppKit

protocol DragMonitorDelegate: AnyObject {
    func dragMonitor(_ monitor: DragMonitor, didBeginModifiedDrag urls: [URL], at point: NSPoint, wheel: AppSettings.Wheel)
    /// wheel == nil: nur der Zeiger hat sich bewegt
    func dragMonitor(_ monitor: DragMonitor, didChangeWheel wheel: AppSettings.Wheel?, at point: NSPoint)
    func dragMonitor(_ monitor: DragMonitor, didUpdateDraggedURLs urls: [URL])
    func dragMonitorDidEndDrag(_ monitor: DragMonitor)
}

enum DragDebug {
    static let enabled = ProcessInfo.processInfo.environment["POMELO_DEBUG_DRAG"] != nil
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let path = ProcessInfo.processInfo.environment["POMELO_DEBUG_DRAG"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/tmp/pomelo-drag.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled, let handle else { return }
        handle.write(Data((String(format: "%.3f ", Date().timeIntervalSince1970) + message() + "\n").utf8))
    }
}

/// Merkt sich, welche Radtasten frisch gedrückt wurden.
/// Tasten, die beim Start schon gehalten wurden (z.B. ⌘ vom Auswählen mehrerer Dateien oder ⌃⌥ vom Kurzbefehl),
/// öffnen und wechseln nichts. Sie zählen erst wieder, nachdem sie losgelassen und neu gedrückt wurden.
/// Loslassen ändert das Rad nie: Das zuletzt getippte Rad bleibt, bis eine andere Radtaste getippt wird.
struct WheelKeyTracker {
    static let relevant: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
    private(set) var held: NSEvent.ModifierFlags
    private var stale: NSEvent.ModifierFlags

    init(start: NSEvent.ModifierFlags = []) {
        held = start.intersection(Self.relevant)
        stale = held
    }

    /// Diese Taste wurde gerade sicher neu gedrückt (Tastencode aus einem flagsChanged-Ereignis).
    /// Ein verpasstes Loslassen davor (z.B. bevor das Rad Tastatureingaben bekam) blockiert sie so nicht.
    mutating func pressed(keyCode: UInt16, flags: NSEvent.ModifierFlags, settings: AppSettings) -> AppSettings.Wheel? {
        let flag: NSEvent.ModifierFlags? = switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
        if let flag, flags.contains(flag) {
            held.remove(flag)
            stale.remove(flag)
        }
        return update(flags, settings: settings)
    }

    /// Neue Tastenlage; gibt das gewünschte Rad zurück, wenn eine Radtaste frisch gedrückt wurde.
    mutating func update(_ flags: NSEvent.ModifierFlags, settings: AppSettings) -> AppSettings.Wheel? {
        let now = flags.intersection(Self.relevant)
        let pressed = now.subtracting(held)
        stale = stale.intersection(now)
        held = now
        guard !pressed.isEmpty else { return nil }
        let active = now.subtracting(stale)
        let convert = settings.key(for: .convert), tools = settings.key(for: .tools), actions = settings.key(for: .actions)
        if pressed.contains(tools.flag) { return .tools }
        if pressed.contains(actions.flag) { return .actions }
        // Option + Umrechnungstaste bleibt zweiter Weg zum Werkzeugrad (Command verschiebt im Finder).
        if tools == .command, convert != .option, active.contains(.option), active.contains(convert.flag),
           pressed.contains(.option) || pressed.contains(convert.flag) {
            return .tools
        }
        if pressed.contains(convert.flag) { return .convert }
        return nil
    }
}

final class DragMonitor {
    weak var delegate: DragMonitorDelegate?
    private var keys = WheelKeyTracker()
    /// Zuletzt frisch getipptes Rad in diesem Zieh-Vorgang (auch wenn die Taste vor dem Erkennen des Ziehens kam).
    private var requestedWheel: AppSettings.Wheel?

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var activity: NSObjectProtocol?
    private var pressChangeCount = 0
    private var lastReadChange = 0
    private var activeURLs: [URL] = []
    private var dragInFlight = false
    private var presenting = false
    private var handled = false
    private var mouseDown = false
    private var pressOrigin = NSPoint.zero
    private var pressTime = Date.distantPast
    private var pressInFinder = false
    private var pressExcluded = false

    static func acceptsDrag(hasFiles: Bool, types: [NSPasteboard.PasteboardType]) -> Bool {
        hasFiles || types.contains(.fileURL) || types.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) }
    }

    static func isExcluded(_ identifier: String?, applications: [String: String]) -> Bool {
        identifier.map { applications[$0] != nil } ?? false
    }
    private var pollTick = 0

    private static let idleInterval = 1.0 / 30.0
    private static let dragInterval = 1.0 / 60.0
    private static let fallbackDragDistance: CGFloat = 24
    private static let fallbackDelay: TimeInterval = 0.3

    func start() {
        stop()
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            self?.beginPressIfNeeded()
            self?.poll()
        }
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            DragDebug.log("global leftMouseDown flags=\(event.modifierFlags.rawValue)")
            self?.beginPressIfNeeded()
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DragDebug.log("global leftMouseUp")
            self?.finishPress()
        }
        monitors = [dragged, down, up].compactMap { $0 }
        schedulePoll(interval: Self.idleInterval)
        DragDebug.log("DragMonitor started; monitors=\(monitors.count) dragChangeCount=\(NSPasteboard(name: .drag).changeCount)")
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        endActivity()
    }

    func markHandled() {
        handled = true
        presenting = false
        activeURLs = []
    }

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private var buttonPressed: Bool { NSEvent.pressedMouseButtons & 1 == 1 }


    private func beginPressIfNeeded() {
        guard !mouseDown else { return }
        mouseDown = true
        handled = false
        dragInFlight = false
        activeURLs = []
        keys = WheelKeyTracker(start: NSEvent.modifierFlags)
        requestedWheel = nil
        pressOrigin = NSEvent.mouseLocation
        pressTime = Date()
        let sourceApplication = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        pressInFinder = sourceApplication == "com.apple.finder"
        // Latch the origin at mouse-down; changing focus during a drag cannot bypass exclusions.
        pressExcluded = Self.isExcluded(sourceApplication, applications: AppSettings.shared.excludedApplications)
        pressChangeCount = NSPasteboard(name: .drag).changeCount
        lastReadChange = pressChangeCount
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Tracking a file drag")
        schedulePoll(interval: Self.dragInterval)
        DragDebug.log("press began at \(NSEvent.mouseLocation) dragChangeCount=\(pressChangeCount) flags=\(NSEvent.modifierFlags.rawValue)")
    }

    private func poll() {
        guard buttonPressed else {
            if mouseDown { finishPress() }
            return
        }
        beginPressIfNeeded()
        guard !pressExcluded else { return }
        refreshDragPasteboard()
        let changed = keys.update(NSEvent.modifierFlags, settings: AppSettings.shared)
        if let changed {
            requestedWheel = changed
            DragDebug.log("wheel key tapped: \(changed)")
        }
        if !dragInFlight, pressInFinder, requestedWheel != nil, Date().timeIntervalSince(pressTime) >= Self.fallbackDelay, hypot(NSEvent.mouseLocation.x - pressOrigin.x, NSEvent.mouseLocation.y - pressOrigin.y) >= Self.fallbackDragDistance {
            dragInFlight = true
            DragDebug.log("no drag pasteboard content; assuming Finder drag from movement")
        }
        evaluateModifiers(changed: changed)
        pollTick += 1
        if pollTick % 30 == 0 {
            DragDebug.log("poll: loc=\(NSEvent.mouseLocation) wheel=\(String(describing: requestedWheel)) inFlight=\(dragInFlight) urls=\(activeURLs.count) presenting=\(presenting) handled=\(handled)")
        }
    }

    private func refreshDragPasteboard() {
        let pasteboard = NSPasteboard(name: .drag)
        let change = pasteboard.changeCount
        guard change != lastReadChange else { return }
        lastReadChange = change
        guard change > pressChangeCount else { return }
        let items = pasteboard.pasteboardItems ?? []
        activeURLs = Self.fileURLs(on: pasteboard)
        dragInFlight = Self.acceptsDrag(hasFiles: !activeURLs.isEmpty, types: pasteboard.types ?? [])
        DragDebug.log("drag pasteboard change=\(change) types=\(pasteboard.types?.map(\.rawValue) ?? []) items=\(items.count) itemTypes=\(items.map { $0.types.map(\.rawValue) }) urls=\(activeURLs.map(\.path))")
        if presenting, !activeURLs.isEmpty {
            delegate?.dragMonitor(self, didUpdateDraggedURLs: activeURLs)
        }
    }

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty {
            urls = (pasteboard.pasteboardItems ?? []).compactMap { item in
                item.string(forType: .fileURL).flatMap { URL(string: $0) }
            }
        }
        return urls.compactMap { url -> URL? in
            let resolved = (url as NSURL).filePathURL ?? url
            guard resolved.isFileURL else { return nil }
            var isDirectory: ObjCBool = false
            // Keep missing files in the selection so conversion reports a per-file error.
            // Filtering them here silently converted only part of a batch.
            _ = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
            // Ordner bleiben in der Auswahl: das Aktionsrad (AirDrop, ZIP, Kopieren …) gilt auch für sie, wie im Original.
            return resolved.standardizedFileURL
        }
    }

    private func evaluateModifiers(changed: AppSettings.Wheel?) {
        guard mouseDown, dragInFlight, !handled else { return }
        let point = NSEvent.mouseLocation
        if !presenting, let wheel = requestedWheel {
            presenting = true
            DragDebug.log("presenting \(wheel) wheel for \(activeURLs.map(\.lastPathComponent)) at \(point)")
            delegate?.dragMonitor(self, didBeginModifiedDrag: activeURLs, at: point, wheel: wheel)
        } else if presenting {
            delegate?.dragMonitor(self, didChangeWheel: changed, at: point)
        }
    }

    private func finishPress() {
        guard mouseDown else { return }
        mouseDown = false
        dragInFlight = false
        handled = false
        activeURLs = []
        requestedWheel = nil
        endActivity()
        schedulePoll(interval: Self.idleInterval)
        if presenting {
            presenting = false
            DragDebug.log("press ended; dismissing wheel")
            delegate?.dragMonitorDidEndDrag(self)
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}


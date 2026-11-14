import AppKit
import Carbon

/// Tastenkombination, die das Konvertierungsrad für die Finder-Auswahl öffnet (Phase 3, L20).
/// Bewusst nicht Enter: Enter benennt im Finder um, und Abfangen bräuchte "Bedienungshilfen".
/// Eine Carbon-Tastenkombination braucht keine Sonderberechtigung.
enum FinderShortcut: String, CaseIterable, Identifiable {
    case controlOptionSpace, optionShiftSpace, controlOptionT, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOptionSpace: return "⌃⌥ Space"
        case .optionShiftSpace: return "⌥⇧ Space"
        case .controlOptionT: return "⌃⌥ T"
        case .off: return "Off"
        }
    }

    /// Tastencode und Carbon-Zusatztasten.
    var carbon: (code: UInt32, modifiers: UInt32)? {
        switch self {
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionShiftSpace: return (UInt32(kVK_Space), UInt32(optionKey | shiftKey))
        case .controlOptionT: return (UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey))
        case .off: return nil
        }
    }
}

@MainActor
final class FinderHotKey {
    static let shared = FinderHotKey()
    var action: (() -> Void)?
    private(set) var registrationFailed = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ shortcut: FinderShortcut) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registrationFailed = false
        guard let carbon = shortcut.carbon else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DiagnosticLog.log("finder shortcut pressed")
                DispatchQueue.main.async { MainActor.assumeIsolated { FinderHotKey.shared.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4F_54_4B_59), id: 1) // "OTKY"
        let status = RegisterEventHotKey(carbon.code, carbon.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        registrationFailed = status != noErr
        DiagnosticLog.log("finder shortcut \(shortcut.rawValue) registered, status \(status)")
    }
}

/// Liest die markierten Dateien im Finder (Apple Events; macOS fragt beim ersten Mal nach).
enum FinderSelection {
    enum Failure: Error { case notAllowed, other(String) }

    /// Erlaubnis für Apple Events an den Finder einholen, BEVOR das Skript läuft.
    /// Läuft im Hintergrund und darf beliebig lange auf die Antwort im macOS-Dialog warten.
    /// (Vorher lief das Skript direkt und brach mit "AppleEvent timed out" ab, solange der Dialog offen war.)
    static func requestPermission() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let bundle = "com.apple.finder"
            var target = AEAddressDesc()
            let created = bundle.withCString { pointer in
                AECreateDesc(DescType(typeApplicationBundleID), pointer, bundle.utf8.count, &target)
            }
            guard created == noErr else { return false }
            defer { AEDisposeDesc(&target) }
            let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
            return status == noErr
        }.value
    }

    @MainActor static func files() -> Result<[URL], Failure> {
        let source = """
        tell application "Finder"
            set theItems to selection as alias list
        end tell
        set out to ""
        repeat with f in theItems
            set out to out & POSIX path of f & linefeed
        end repeat
        return out
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.other("Script error")) }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: keine Erlaubnis, -1744: Nachfrage abgelehnt
            if code == -1743 || code == -1744 { return .failure(.notAllowed) }
            // -1712: Zeitüberschreitung (z.B. Finder beschäftigt)
            if code == -1712 { return .failure(.other("Finder did not answer in time. Please press the shortcut again.")) }
            return .failure(.other(error[NSAppleScript.errorMessage] as? String ?? "Finder did not answer"))
        }
        let paths = (result.stringValue ?? "").split(separator: "\n").map(String.init)
        // Ordner bleiben drin: dafür gibt es das Aktionsrad
        let urls = paths.map { URL(fileURLWithPath: $0) }
        return .success(urls)
    }
}

import AppKit
import Foundation
import Combine
import ServiceManagement

enum CompressionPreset: String, CaseIterable, Identifiable {
    case balanced
    case strong

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var imageQuality: Double { self == .balanced ? 0.72 : 0.5 }
    var videoScale: Double { self == .balanced ? 1.0 : 0.75 }
    var videoBitrateFactor: Double { self == .balanced ? 0.6 : 0.35 }
    var audioBitrate: Int { self == .balanced ? 128_000 : 64_000 }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal
    case downloads
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideOriginal: return "Next to the original"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        }
    }

    func directory(for source: URL) -> URL {
        switch self {
        case .besideOriginal: return source.deletingLastPathComponent()
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum ProgressStyle: String, CaseIterable, Identifiable {
    case card
    case pill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .card: return "Card"
        case .pill: return "Notch pill"
        }
    }
}

enum NotchSurface: String, CaseIterable, Identifiable {
    case black, glass
    var id: String { rawValue }
    var title: String { self == .black ? "Pure black" : "Glass" }
}

/// Zusatztaste, die beim Ziehen ein Rad öffnet.
enum DragKey: String, CaseIterable, Identifiable {
    case shift, command, option, control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: return "Shift"
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .option: return .option
        case .control: return .control
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var excludedApplications: [String: String] {
        didSet { defaults.set(excludedApplications, forKey: "excludedApplications") }
    }

    @Published var compressionPreset: CompressionPreset {
        didSet { defaults.set(compressionPreset.rawValue, forKey: "compressionPreset") }
    }

    @Published var compressionResizeLongEdge: Int {
        didSet { defaults.set(compressionResizeLongEdge, forKey: "compressionResizeLongEdge") }
    }

    @Published var outputLocation: OutputLocation {
        didSet { defaults.set(outputLocation.rawValue, forKey: "outputLocation") }
    }

    @Published var revealInFinder: Bool {
        didSet { defaults.set(revealInFinder, forKey: "revealInFinder") }
    }

    @Published var notchSurface: NotchSurface {
        didSet { defaults.set(notchSurface.rawValue, forKey: "notchSurface") }
    }

    @Published var progressStyle: ProgressStyle {
        didSet { defaults.set(progressStyle.rawValue, forKey: "progressStyle") }
    }

    @Published var ffmpegPath: String {
        didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") }
    }

    @Published var launchAtLogin: Bool {
        didSet { if !refreshingLoginStatus { applyLaunchAtLogin() } }
    }

    @Published var loginMessage: String?
    private var refreshingLoginStatus = false

    @Published var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: "jpegQuality") }
    }

    /// Tasten für die drei Räder. Sie dürfen sich nicht doppeln; setKey tauscht bei Konflikt.
    @Published private(set) var convertKey: DragKey { didSet { defaults.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published private(set) var toolsKey: DragKey { didSet { defaults.set(toolsKey.rawValue, forKey: "toolsKey") } }
    @Published private(set) var actionsKey: DragKey { didSet { defaults.set(actionsKey.rawValue, forKey: "actionsKey") } }

    enum Wheel { case convert, tools, actions }

    func key(for wheel: Wheel) -> DragKey {
        switch wheel {
        case .convert: return convertKey
        case .tools: return toolsKey
        case .actions: return actionsKey
        }
    }

    func setKey(_ key: DragKey, for wheel: Wheel) {
        let previous = self.key(for: wheel)
        guard key != previous else { return }
        // Belegt ein anderes Rad die Taste schon, bekommt es die alte Taste.
        if convertKey == key { convertKey = previous }
        if toolsKey == key { toolsKey = previous }
        if actionsKey == key { actionsKey = previous }
        switch wheel {
        case .convert: convertKey = key
        case .tools: toolsKey = key
        case .actions: actionsKey = key
        }
    }

    /// Tastenkombination für die Finder-Auswahl.
    @Published var finderShortcut: FinderShortcut { didSet { defaults.set(finderShortcut.rawValue, forKey: "finderShortcut") } }

    /// App für die Aktion "Terminal".
    @Published var terminalAppPath: String { didSet { defaults.set(terminalAppPath, forKey: "terminalAppPath") } }

    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    /// Ergebnisse auf dem Schreibtisch nicht zusätzlich in einem Finder-Fenster zeigen.
    @Published var skipRevealOnDesktop: Bool { didSet { defaults.set(skipRevealOnDesktop, forKey: "skipRevealOnDesktop") } }

    @Published var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    private init() {
        excludedApplications = defaults.dictionary(forKey: "excludedApplications") as? [String: String] ?? [:]
        compressionPreset = CompressionPreset(rawValue: defaults.string(forKey: "compressionPreset") ?? "") ?? .balanced
        compressionResizeLongEdge = defaults.integer(forKey: "compressionResizeLongEdge")
        outputLocation = OutputLocation(rawValue: defaults.string(forKey: "outputLocation") ?? "") ?? .besideOriginal
        revealInFinder = defaults.object(forKey: "revealInFinder") as? Bool ?? true
        notchSurface = NotchSurface(rawValue: defaults.string(forKey: "notchSurface") ?? "") ?? .black
        progressStyle = ProgressStyle(rawValue: defaults.string(forKey: "progressStyle") ?? "") ?? .pill
        // One-time migration requested for existing trial installs; future user choices persist.
        if !defaults.bool(forKey: "notchDefaultV012") {
            progressStyle = .pill
            defaults.set("pill", forKey: "progressStyle")
            defaults.set(true, forKey: "notchDefaultV012")
        }
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? ""
        jpegQuality = defaults.object(forKey: "jpegQuality") as? Double ?? 0.9
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        var keys = [DragKey(rawValue: defaults.string(forKey: "convertKey") ?? "") ?? .shift,
                    DragKey(rawValue: defaults.string(forKey: "toolsKey") ?? "") ?? .command,
                    DragKey(rawValue: defaults.string(forKey: "actionsKey") ?? "") ?? .control]
        if Set(keys).count < 3 { keys = [.shift, .command, .control] }
        convertKey = keys[0]
        toolsKey = keys[1]
        actionsKey = keys[2]
        terminalAppPath = defaults.string(forKey: "terminalAppPath") ?? "/System/Applications/Utilities/Terminal.app"
        finderShortcut = FinderShortcut(rawValue: defaults.string(forKey: "finderShortcut") ?? "") ?? .controlOptionSpace
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        skipRevealOnDesktop = defaults.object(forKey: "skipRevealOnDesktop") as? Bool ?? true
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.appearance
    }

    func refreshLoginStatus(preserveError: Bool = false) {
        refreshingLoginStatus = true
        defer { refreshingLoginStatus = false }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if !preserveError {
            loginMessage = status == .requiresApproval
                ? "Allow Open Tangerine in System Settings → General → Login Items."
                : nil
        }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginStatus()
        } catch {
            loginMessage = "Could not update automatic startup: \(error.localizedDescription)"
            refreshLoginStatus(preserveError: true)
        }
    }
}


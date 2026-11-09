import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let dragMonitor = DragMonitor()
    private let radial = RadialController()
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.start()
        NSApp.setActivationPolicy(.accessory)
        AppSettings.shared.applyAppearance()
        NSApp.applicationIconImage = BrandArtwork.image(size: 256)
        installStatusItem()
        // Nachbau: keine Update-Prüfung, die App nimmt keinen Kontakt zum Netz auf.
        if ScreenshotDriver.isEnabled {
            ScreenshotDriver.run(radial: radial)
            return
        }
        dragMonitor.delegate = radial
        dragMonitor.start()
        // Beim ersten Start einmal das Willkommensfenster zeigen; später bleibt die App still in der Menüleiste.
        if !UserDefaults.standard.bool(forKey: "hasSeenWelcome") {
            UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
            showWelcome()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        radial.presentPicker(for: urls)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 32)
        if let button = item.button {
            button.image = BrandArtwork.image(size: 24, template: true)
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Open Tangerine: hold Shift while dragging a file"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Convert Files…", action: #selector(convertFiles), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Open Tool for Files…", action: #selector(openTool), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "File Actions…", action: #selector(fileActions), keyEquivalent: "a").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "How It Works…", action: #selector(showWelcome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "About Open Tangerine", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Logs", action: #selector(showLogs), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Open Tangerine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let symbols = ["Convert Files…": "arrow.triangle.2.circlepath", "Open Tool for Files…": "wrench.and.screwdriver",
                       "File Actions…": "doc.on.doc", "Settings…": "gearshape", "How It Works…": "questionmark.circle", "About Open Tangerine": "info.circle",
                       "Show Logs": "doc.text.magnifyingglass",
                       "Quit Open Tangerine": "power"]
        for entry in menu.items {
            if let symbol = symbols[entry.title] {
                entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.title)
            }
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func convertFiles() {
        pickFiles { [weak self] urls in self?.radial.presentPicker(for: urls, advanced: false) }
    }

    @objc private func fileActions() {
        pickFiles { [weak self] urls in self?.radial.presentPicker(for: urls, actions: true) }
    }

    @objc private func openTool() {
        pickFiles { [weak self] urls in self?.radial.presentPicker(for: urls, advanced: true) }
    }

    private func pickFiles(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            completion(panel.urls)
        }
    }

    @MainActor
    static func makeSettingsWindow(tab: SettingsTab = .general) -> NSWindow {
        let model = SettingsTabModel()
        model.tab = tab
        let view = SettingsView(model: model).environmentObject(AppSettings.shared)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let window = SettingsWindow(contentViewController: controller)
        window.title = "Open Tangerine"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: SettingsView.width, height: SettingsView.height))
        window.center()
        return window
    }

    @MainActor
    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.makeSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    @objc private func showWelcome() {
        if welcomeWindow == nil {
            welcomeWindow = Self.makeWelcomeWindow(openSettings: { [weak self] in self?.openSettings() })
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.center()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    static func makeWelcomeWindow(openSettings: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: WelcomeView.width, height: WelcomeView.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let close: () -> Void = { [weak window] in window?.performClose(nil) }
        window.contentViewController = NSHostingController(rootView: WelcomeView(
            done: close,
            openSettings: { close(); openSettings() }
        ).environmentObject(AppSettings.shared))
        window.setContentSize(NSSize(width: WelcomeView.width, height: WelcomeView.height))
        return window
    }

    @objc private func showLogs() {
        DiagnosticLog.flush()
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.logFile])
    }

    @MainActor
    @objc private func about() {
        openSettings()
        // The About tab includes attribution and the creator link.
        NotificationCenter.default.post(name: .init("OpenTangerineShowAbout"), object: nil)
    }
}

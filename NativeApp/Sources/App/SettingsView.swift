import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case wheel
    case conversion
    case appearance
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .wheel: return "Keys & Feedback"
        case .conversion: return "Formats"
        case .appearance: return "Appearance"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .wheel: return "keyboard"
        case .conversion: return "arrow.triangle.2.circlepath"
        case .appearance: return "circle.lefthalf.filled"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsTabModel: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// Einstellungen im Stil der macOS-Systemeinstellungen (Phase 2):
/// Seitenleiste links, gruppierte Liste rechts, Orange nur für die Auswahl.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var model: SettingsTabModel
    @State private var ffmpegHealth: FFmpeg.Health = .missing

    static let width: CGFloat = 760
    static let height: CGFloat = 560

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsTab?>(get: { model.tab }, set: { if let tab = $0 { model.tab = tab } })) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Image(nsImage: BrandArtwork.image(size: 40)).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Open Tangerine").font(.system(size: 12, weight: .medium))
                        Text("\(version) · runs offline").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            Form {
                switch model.tab {
                case .general: general
                case .wheel: wheel
                case .conversion: conversion
                case .appearance: appearance
                case .about: about
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.tab.title)
            .id(model.tab)
            .transition(.opacity)
            .animation(Theme.ease, value: model.tab)
        }
        .frame(width: Self.width, height: Self.height)
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .init("OpenTangerineShowAbout"))) { _ in model.tab = .about }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in settings.refreshLoginStatus() }
        .task(id: settings.ffmpegPath) { ffmpegHealth = await FFmpeg.checkHealth() }
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        Section {
            Picker("Save converted files", selection: $settings.outputLocation) {
                ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show results in Finder", isOn: $settings.revealInFinder)
            if settings.revealInFinder {
                Toggle("Skip the Finder window for files on the Desktop", isOn: $settings.skipRevealOnDesktop)
            }
        } header: {
            Text("Output")
        } footer: {
            Text("Originals are never changed. A new file with the same name gets a number, like “photo 2.png”.")
        }
        Section {
            Toggle("Open at login", isOn: $settings.launchAtLogin)
            if let message = settings.loginMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                Button("Open Login Items…") { settings.openLoginSettings() }
            }
        } header: {
            Text("Startup")
        } footer: {
            Text("Move the app to Applications before you turn this on.")
        }
        Section {
            ForEach(settings.excludedApplications.keys.sorted(), id: \.self) { identifier in
                HStack {
                    Text(settings.excludedApplications[identifier] ?? identifier)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        settings.excludedApplications.removeValue(forKey: identifier)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Turn drag shortcuts back on in this app")
                }
            }
            Button("Add App…", action: addExcludedApplication)
        } header: {
            Text("Apps without drag shortcuts")
        } footer: {
            Text("Drags that start in these apps never open a wheel. Convert Files in the menu bar still works.")
        }
    }

    private func addExcludedApplication() {
        let panel = NSOpenPanel()
        panel.title = "Turn off drag shortcuts in apps"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { continue }
                settings.excludedApplications[identifier] =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
            }
        }
    }

    // MARK: Keys & Feedback

    @ViewBuilder private var wheel: some View {
        Section {
            keyRow("Conversion wheel", detail: "PNG to JPEG, MP4 to GIF and more", wheel: .convert)
            keyRow("Tools wheel", detail: "Compress, crop, metadata, PDF tools", wheel: .tools)
            keyRow("File actions", detail: "Reveal, copy paths, checksum", wheel: .actions)
        } header: {
            Text("Keys")
        } footer: {
            Text(settings.key(for: .tools) == .command
                 ? "Hold the key while you drag files in Finder. Option with \(settings.key(for: .convert).title) also opens the tools wheel."
                 : "Hold the key while you drag files in Finder.")
        }
        Section {
            Toggle("Sound", isOn: $settings.soundEnabled)
            Toggle("Trackpad haptics", isOn: $settings.hapticsEnabled)
        } header: {
            Text("Feedback")
        } footer: {
            Text("A soft tick when you move over a segment and a pop when you drop. Haptics need a Force Touch trackpad.")
        }
    }

    private func keyRow(_ title: String, detail: String, wheel: AppSettings.Wheel) -> some View {
        let binding = Binding<DragKey>(get: { settings.key(for: wheel) }, set: { settings.setKey($0, for: wheel) })
        return HStack(spacing: 12) {
            Keycap(key: settings.key(for: wheel), size: .small)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(title, selection: binding) {
                ForEach(DragKey.allCases) { key in
                    Text("\(key.symbol)  \(key.title)").tag(key)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .animation(Theme.ease, value: settings.key(for: wheel))
    }

    // MARK: Formats

    @ViewBuilder private var conversion: some View {
        Section("Images") {
            LabeledContent("JPEG, HEIC and WebP quality") {
                HStack(spacing: 8) {
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0).frame(width: 160)
                    Text("\(Int(settings.jpegQuality * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        Section {
            Picker("Preset", selection: $settings.compressionPreset) {
                ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Resize long edge") {
                HStack(spacing: 6) {
                    TextField("Off", value: $settings.compressionResizeLongEdge, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("px").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Compression")
        } footer: {
            Text(settings.compressionPreset == .balanced
                 ? "Balanced keeps detail and trims size. 0 px keeps the original size."
                 : "Strong makes the smallest file and loses visible quality. 0 px keeps the original size.")
        }
        Section {
            LabeledContent("Location") {
                HStack(spacing: 6) {
                    TextField("Found automatically", text: $settings.ffmpegPath)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("Choose…") { chooseFFmpeg() }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(ffmpegHealthColor).frame(width: 8, height: 8)
                Text(ffmpegHealthText).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if case .missing = ffmpegHealth {
                LabeledContent("Install in Terminal") {
                    Text("brew install ffmpeg").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
        } header: {
            Text("FFmpeg")
        } footer: {
            Text("Most conversions use Apple’s own frameworks. FFmpeg adds MP3, FLAC, OGG, Opus, WMA, MKV, WebM, AVI, WMV and GIF. Searched in /opt/homebrew/bin and /usr/local/bin.")
        }
    }

    private var ffmpegHealthColor: Color {
        switch ffmpegHealth {
        case .ready: return .green
        case .broken: return .red
        case .missing: return .orange
        }
    }

    private var ffmpegHealthText: String {
        switch ffmpegHealth {
        case let .ready(path, version): return "FFmpeg \(version) at \(path)"
        case let .broken(path, reason): return "FFmpeg at \(path) does not start: \(reason)"
        case .missing: return "FFmpeg is not installed. Audio and video conversions that need it stay unavailable."
        }
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            settings.ffmpegPath = url.path
        }
    }

    // MARK: Appearance

    @ViewBuilder private var appearance: some View {
        Section("Theme") {
            Picker("Appearance", selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section {
            Picker("Style", selection: $settings.progressStyle) {
                ForEach(ProgressStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.progressStyle == .pill {
                Picker("Notch surface", selection: $settings.notchSurface) {
                    ForEach(NotchSurface.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Progress")
        } footer: {
            Text(settings.progressStyle == .card
                 ? "A small floating card in the top right corner. It closes when the work is done."
                 : "A panel below the notch. Finished results slide back after two seconds.")
        }
    }

    // MARK: About

    @ViewBuilder private var about: some View {
        Section {
            HStack(spacing: 16) {
                Image(nsImage: BrandArtwork.image(size: 128))
                    .resizable().frame(width: 64, height: 64)
                    .accessibilityLabel("Open Tangerine icon")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Tangerine").font(.system(size: 20, weight: .medium))
                    Text("Version \(version) · Developer build").foregroundStyle(.secondary)
                    Text("Converts files on this Mac. No account, no network access.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
        Section("Credits") {
            LabeledContent("Original app", value: "Sintax Error Private Limited")
            LabeledContent("Created by") {
                Link("Hemaangg", destination: URL(string: "https://www.instagram.com/hemaangg/")!)
            }
            LabeledContent("Based on", value: "Satsuma by plyght (MIT)")
        }
        Section {
            Text("GPL-3.0-only. Independent of Tangerine. Some features are experimental, so check important results.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

final class SettingsWindow: NSWindow {}

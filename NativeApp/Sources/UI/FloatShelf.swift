import AppKit
import QuickLookThumbnailing
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Schwebende Ablage (Phase 3, L9 "Float"): hält Dateien griffbereit über allen Fenstern.
/// Dateien lassen sich herausziehen, hineinlegen und per Doppelklick mit Quick Look ansehen.
/// Die Ablage verändert keine Dateien, sie merkt sich nur Pfade.
@MainActor
final class FloatShelf: NSObject, ObservableObject, QLPreviewPanelDataSource {
    static let shared = FloatShelf()

    @Published private(set) var files: [URL] = []
    private var panel: NSPanel?
    private var previewIndex = 0

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
        show()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        if files.isEmpty { close() }
    }

    func close() {
        files.removeAll()
        panel?.orderOut(nil)
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 320),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.title = "Shelf"
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: FloatShelfView(shelf: self))
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 260 - 24, y: screen.maxY - 320 - 24))
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.files.removeAll() }
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    // MARK: Quick Look

    func preview(_ url: URL) {
        previewIndex = files.firstIndex(of: url) ?? 0
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = previewIndex
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { files.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { files.indices.contains(index) ? files[index] as NSURL : nil }
    }
}

struct FloatShelfView: View {
    @ObservedObject var shelf: FloatShelf
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(shelf.files.count == 1 ? "1 file" : "\(shelf.files.count) files")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Clear") { shelf.close() }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
            .padding(.horizontal, 12).padding(.top, 32).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(shelf.files, id: \.self) { url in
                        ShelfRow(url: url, remove: { shelf.remove(url) })
                            .onTapGesture(count: 2) { shelf.preview(url) }
                            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            Text("Drag files out or double-click to preview")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.bottom, 10)
        }
        .frame(minWidth: 220, minHeight: 200)
        .background(targeted ? Theme.accent.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in shelf.add([url]) } }
                }
            }
            return true
        }
    }
}

private struct ShelfRow: View {
    let url: URL
    let remove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(FileSizeFormatter.string(FileSizeFormatter.size(of: url)))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from the shelf")
            }
        }
        .padding(6)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.ease, value: hovering)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72), scale: 2, representationTypes: .thumbnail)
            if let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = result.nsImage
            }
        }
    }
}

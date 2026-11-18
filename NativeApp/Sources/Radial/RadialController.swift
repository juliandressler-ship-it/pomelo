import AppKit

final class RadialPanel: NSPanel {
    let radialView = RadialView(frame: .zero)

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        radialView.frame = contentView?.bounds ?? .zero
        radialView.autoresizingMask = [.width, .height]
        contentView = radialView
    }

    override var canBecomeKey: Bool { true }
}

final class RadialController: DragMonitorDelegate {
    private var panel: RadialPanel?
    /// Nur für den Screenshot-Modus: Fenster des Rads.
    var panelWindowNumber: Int? { panel?.windowNumber }
    private var urls: [URL] = []
    private var formats: [FileFormat] = []
    private var advanced = false
    private var actions = false
    private var visible = false
    private var pickerMode = false
    private var outsideClickMonitor: Any?

    weak var dragMonitor: DragMonitor?

    func dragMonitor(_ monitor: DragMonitor, didBeginModifiedDrag urls: [URL], at point: NSPoint, wheel: AppSettings.Wheel) {
        dragMonitor = monitor
        pickerMode = false
        actions = wheel == .actions
        present(urls: urls, at: point, advanced: wheel == .tools)
    }

    func dragMonitor(_ monitor: DragMonitor, didChangeWheel wheel: AppSettings.Wheel?, at point: NSPoint) {
        guard !pickerMode else { return }
        if !visible {
            if let wheel {
                actions = wheel == .actions
                present(urls: urls, at: point, advanced: wheel == .tools)
            }
            return
        }
        if let wheel { switchWheel(wheel) }
        // AppKit can delay destination updates while the source app owns the drag.
        // The monitor already polls at 60 Hz; use its screen position for immediate hover.
        if let panel {
            panel.radialView.updateHighlight(forWindowPoint: panel.convertPoint(fromScreen: point))
        }
    }

    func dragMonitor(_ monitor: DragMonitor, didUpdateDraggedURLs urls: [URL]) {
        adopt(urls)
    }

    func dragMonitorDidEndDrag(_ monitor: DragMonitor) {
        guard !pickerMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.pickerMode else { return }
            self.hide()
        }
    }

    func presentPicker(for urls: [URL], advanced: Bool = false, actions: Bool = false) {
        self.actions = actions
        pickerMode = true
        let point = NSEvent.mouseLocation
        present(urls: urls, at: point, advanced: advanced)
        panel?.radialView.interactive = true
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panel?.radialView)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitor()
    }

    private func present(urls: [URL], at point: NSPoint, advanced: Bool) {
        self.urls = urls
        self.advanced = advanced
        formats = urls.compactMap(FileFormat.detect)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = self.panel ?? RadialPanel(screen: screen)
        panel.setFrame(screen.frame, display: false)
        self.panel = panel

        let view = panel.radialView
        view.interactive = pickerMode
        view.advancedMode = advanced
        view.modeKey = modeKey
        let clamped = clampedCenter(point, in: screen.frame, radius: view.discRadius + 48, below: view.discRadius + RadialWheelView.captionHeight + 12)
        view.center = NSPoint(x: clamped.x - screen.frame.minX, y: clamped.y - screen.frame.minY)
        view.onSelect = { [weak self] item in self?.select(item) }
        view.onCancel = { [weak self] in self?.hide() }
        view.onDragEntered = { [weak self] info in self?.adoptDraggedFiles(from: info) }
        view.onDragSessionEnded = { [weak self] in self?.dragSessionEnded() }
        view.onWheelChange = { [weak self] wheel in self?.switchWheel(wheel) }
        view.clearHighlight()
        reloadItems()
        view.animatePresentation()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 1
        }
        visible = true
        Task { @MainActor in JobRunner.shared.beginWatching() }
    }

    /// Rad ganz auf dem Bildschirm halten; unten ist zusätzlich Platz für Aktionszeile und Radleiste nötig.
    private func clampedCenter(_ point: NSPoint, in frame: NSRect, radius: CGFloat, below: CGFloat) -> NSPoint {
        NSPoint(
            x: min(max(point.x, frame.minX + radius), frame.maxX - radius),
            y: min(max(point.y, frame.minY + below), frame.maxY - radius)
        )
    }

    private func adoptDraggedFiles(from info: NSDraggingInfo) {
        guard !pickerMode else { return }
        let dragged = DragMonitor.fileURLs(on: info.draggingPasteboard)
        DragDebug.log("drag entered wheel; pasteboard urls=\(dragged.map(\.lastPathComponent)) known=\(urls.map(\.lastPathComponent))")
        adopt(dragged)
    }

    private func adopt(_ dragged: [URL]) {
        guard !pickerMode, visible, !dragged.isEmpty, dragged != urls else { return }
        urls = dragged
        formats = dragged.compactMap(FileFormat.detect)
        reloadItems()
    }

    private func dragSessionEnded() {
        guard !pickerMode, visible else { return }
        DragDebug.log("drag session ended while wheel visible; dismissing")
        hide()
        dragMonitor?.markHandled()
    }

    /// Taste, die das aktuelle Rad geöffnet hat; im Menü-Modus keine.
    private var modeKey: DragKey? {
        guard !pickerMode else { return nil }
        let settings = AppSettings.shared
        return settings.key(for: actions ? .actions : advanced ? .tools : .convert)
    }

    /// Zwischen Konvertieren, Werkzeugen und Aktionen wechseln (beim Ziehen und im Menü-Modus).
    func switchWheel(_ wheel: AppSettings.Wheel) {
        let newActions = wheel == .actions, newAdvanced = wheel == .tools
        guard newActions != actions || newAdvanced != advanced, let view = panel?.radialView else { return }
        actions = newActions
        advanced = newAdvanced
        view.modeKey = modeKey
        view.clearHighlight()
        reloadItems()
        if pickerMode {
            if !view.items.isEmpty { view.highlight(0) } // löst Ton/Haptik über die Hervorhebung aus
        } else {
            MainActor.assumeIsolated { Feedback.hover() }
        }
    }

    /// Nur für Tests: aktueller Zustand des Rads.
    var currentWheel: AppSettings.Wheel { actions ? .actions : advanced ? .tools : .convert }
    var currentItems: [RadialItem] { panel?.radialView.items ?? [] }

    private func reloadItems() {
        guard let view = panel?.radialView else { return }
        view.advancedMode = advanced
        view.modeKey = modeKey
        view.idleTitle = currentWheel.title
        view.wheel = currentWheel
        let count = urls.count
        if count == 0 {
            view.items = []
            view.subtitle = "Move the files over the wheel"
            view.emptyMessage = advanced ? "Drop here for tools" : "Drop here to convert"
            return
        }
        view.subtitle = count == 1 ? urls[0].lastPathComponent : "\(count) files"
        if actions {
            view.items = FileAction.wheel(for: urls).map(RadialItem.init(fileAction:))
            view.emptyMessage = "No file actions"
            return
        }
        if formats.count != urls.count {
            view.items = []
            let folders = urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && FileFormat.detect($0)?.isPackage != true }
            view.emptyMessage = folders ? "Folders work with file actions" : "Selection includes unsupported files"
            if folders { view.subtitle = "Tap \(AppSettings.shared.key(for: .actions).title) for AirDrop, ZIP, Move and more" }
            return
        }
        if advanced {
            // Bilder: Hintergrund entfernen und Codes lesen; PDFs: Codes lesen
            let images = formats.allSatisfy { $0.category == .image }
            let pdfs = formats.allSatisfy { $0 == .pdf }
            let extras: [FileAction] = images ? [.removeBackground, .readCodes] : pdfs ? [.readCodes] : []
            view.items = ToolID.available(for: formats).map(RadialItem.init(tool:)) + extras.map(RadialItem.init(fileAction:))
            view.emptyMessage = "No tools for this selection"
        } else {
            let allPDF = formats.allSatisfy { $0 == .pdf }
            let pdfTools: [ToolID] = allPDF ? [.annotatePDF, .mergePDF, .organizePDF, .splitPDF] : []
            // Archive: zuerst "Extract"; PDFs: "PDF/A" als eigenes Ziel
            let extras: [FileAction] = formats.allSatisfy { $0.category == .archive } ? [.extract] : allPDF ? [.pdfa] : []
            view.items = extras.map(RadialItem.init(fileAction:))
                + pdfTools.filter { $0.applies(to: formats) }.map(RadialItem.init(tool:))
                + ConversionMatrix.targets(for: formats).map(RadialItem.init(format:))
                + Self.printItems(for: urls)
            view.emptyMessage = count > 1 ? "No shared conversion for these files" : "No conversions available"
        }
    }

    /// "Print" steht auch im Konvertierungsrad (letztes Segment), wenn alle Dateien druckbar sind.
    static func printItems(for urls: [URL]) -> [RadialItem] {
        Printing.canPrint(urls) ? [RadialItem(fileAction: .print, label: "PRINT")] : []
    }

    private func select(_ item: RadialItem) {
        let selectedURLs = urls
        DiagnosticLog.log("radial select \(item.detail) for \(selectedURLs.map(\.lastPathComponent))")
        hide()
        dragMonitor?.markHandled()
        DiagnosticLog.log("radial hidden, dispatching action")
        Task { @MainActor in
            switch item.action {
            case .fileAction(let action):
                action.run(selectedURLs)
            case .convert(let target):
                JobRunner.shared.convert(selectedURLs, to: target)
            case .tool(let tool):
                DiagnosticLog.log("open tool \(tool.rawValue)")
                ToolWindowManager.shared.open(tool, files: selectedURLs)
            }
        }
    }

    func highlight(_ index: Int) {
        panel?.radialView.highlight(index)
    }

    func hide() {
        visible = false
        Task { @MainActor in JobRunner.shared.endWatching() }
        pickerMode = false
        panel?.radialView.clearHighlight()
        panel?.radialView.interactive = false
        panel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func installOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }
}


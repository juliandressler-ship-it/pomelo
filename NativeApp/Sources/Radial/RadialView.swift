import AppKit
import SwiftUI

enum RadialAction: Hashable {
    case convert(FileFormat)
    case tool(ToolID)
    case fileAction(FileAction)
}

struct RadialItem: Identifiable, Hashable {
    let action: RadialAction
    let label: String
    let detail: String
    let symbol: String

    var id: RadialAction { action }

    init(fileAction: FileAction) {
        self.init(fileAction: fileAction, label: fileAction.rawValue)
    }

    init(fileAction: FileAction, label: String) {
        action = .fileAction(fileAction)
        self.label = label
        detail = fileAction.detail
        symbol = fileAction.symbol
    }

    init(format: FileFormat) {
        action = .convert(format)
        label = format.displayName
        detail = "Convert to \(format.displayName)"
        symbol = format.category.symbol
    }

    init(tool: ToolID) {
        action = .tool(tool)
        label = tool.radialLabel
        detail = tool.title
        symbol = tool.symbol
    }
}

struct RadialGeometry {
    var innerRadius: CGFloat = 64
    var outerRadius: CGFloat = 150
    var gap: CGFloat = 4
    var count: Int

    var slice: CGFloat { 2 * .pi / CGFloat(max(count, 1)) }

    var corner: CGFloat {
        let wanted: CGFloat = count > 8 ? 10 : 14
        let limit = (innerRadius * sin(slice * 0.34) - gap / 2) / (1 - sin(slice * 0.34))
        return max(4, min(wanted, limit))
    }

    var labelRadius: CGFloat { innerRadius + (outerRadius - innerRadius) * 0.56 }

    var labelWidth: CGFloat {
        let chord = 2 * labelRadius * sin(slice / 2)
        return max(24, chord - 6)
    }

    func angles(for index: Int) -> (start: CGFloat, end: CGFloat) {
        let end = CGFloat.pi / 2 - slice * CGFloat(index) + slice / 2
        return (end - slice, end)
    }

    func midpoint(for index: Int, in rect: CGRect) -> CGPoint {
        let (start, end) = angles(for: index)
        let mid = (start + end) / 2
        return CGPoint(x: rect.midX + cos(mid) * labelRadius, y: rect.midY - sin(mid) * labelRadius)
    }

    func index(at offset: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let distance = sqrt(offset.x * offset.x + offset.y * offset.y)
        guard distance >= innerRadius, distance <= outerRadius + 24 else { return nil }
        var angle = atan2(offset.y, offset.x)
        if angle < 0 { angle += 2 * .pi }
        var relative = CGFloat.pi / 2 + slice / 2 - angle
        while relative < 0 { relative += 2 * .pi }
        while relative >= 2 * .pi { relative -= 2 * .pi }
        return min(count - 1, Int(relative / slice))
    }
}

struct WedgeShape: Shape {
    var geometry: RadialGeometry
    var index: Int

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let (a0, a1) = geometry.angles(for: index)
        let r0 = geometry.innerRadius
        let r1 = geometry.outerRadius
        let k = geometry.corner
        let half = geometry.gap / 2
        let phiOuter = asin((k + half) / (r1 - k))
        let phiInner = asin((k + half) / (r0 + k))

        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: c.x + cos(angle) * radius, y: c.y - sin(angle) * radius)
        }
        func normal(_ angle: CGFloat, inward: Bool) -> CGVector {
            inward ? CGVector(dx: sin(angle), dy: -cos(angle)) : CGVector(dx: -sin(angle), dy: cos(angle))
        }
        func offset(_ p: CGPoint, _ v: CGVector, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: p.x + v.dx * distance, y: p.y - v.dy * distance)
        }
        func arc(_ path: inout Path, center: CGPoint, radius: CGFloat, from: CGPoint, to: CGPoint) {
            let s = atan2(from.y - center.y, from.x - center.x)
            let e = atan2(to.y - center.y, to.x - center.x)
            path.addArc(center: center, radius: radius, startAngle: .radians(s), endAngle: .radians(e), clockwise: true)
        }

        let outerEndCenter = point(r1 - k, a1 - phiOuter)
        let outerEndTangent = offset(outerEndCenter, normal(a1, inward: true), -k)
        let innerEndCenter = point(r0 + k, a1 - phiInner)
        let innerEndTangent = offset(innerEndCenter, normal(a1, inward: true), -k)
        let innerStartCenter = point(r0 + k, a0 + phiInner)
        let innerStartTangent = offset(innerStartCenter, normal(a0, inward: false), -k)
        let outerStartCenter = point(r1 - k, a0 + phiOuter)
        let outerStartTangent = offset(outerStartCenter, normal(a0, inward: false), -k)

        var path = Path()
        path.move(to: point(r1, a0 + phiOuter))
        path.addArc(center: c, radius: r1, startAngle: .radians(-(a0 + phiOuter)), endAngle: .radians(-(a1 - phiOuter)), clockwise: true)
        arc(&path, center: outerEndCenter, radius: k, from: point(r1, a1 - phiOuter), to: outerEndTangent)
        path.addLine(to: innerEndTangent)
        arc(&path, center: innerEndCenter, radius: k, from: innerEndTangent, to: point(r0, a1 - phiInner))
        path.addArc(center: c, radius: r0, startAngle: .radians(-(a1 - phiInner)), endAngle: .radians(-(a0 + phiInner)), clockwise: false)
        arc(&path, center: innerStartCenter, radius: k, from: point(r0, a0 + phiInner), to: innerStartTangent)
        path.addLine(to: outerStartTangent)
        arc(&path, center: outerStartCenter, radius: k, from: outerStartTangent, to: point(r1, a0 + phiOuter))
        path.closeSubpath()
        return path
    }
}

/// Ring hinter den Segmenten: trägt das Liquid-Glass-Material.
struct RingShape: Shape {
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        path.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return path
    }
}

/// Das Rad (Phase 2): helle Segmente mit leichtem Relief auf einem Glasring,
/// das gewählte Segment mandarinenorange und leicht herausgehoben,
/// in der Mitte eine Pille mit dem Ziel, darunter eine Zeile mit der Aktion.
struct RadialWheelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var appeared = false
    var presentationID: UUID = UUID()
    var items: [RadialItem]
    var highlighted: Int?
    var title: String
    var caption: String
    var modeKey: DragKey?
    var emptyMessage: String
    var emptyDetail: String
    var geometry: RadialGeometry
    var wheel: AppSettings.Wheel = .convert
    @State private var settled = true

    /// Aktionszeile (40) plus Radleiste (34) unter dem Rad.
    static let captionHeight: CGFloat = 52 + 34

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if items.isEmpty {
                    empty
                } else {
                    base
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        wedge(item, index: index)
                    }
                    pill
                }
            }
            .frame(width: geometry.outerRadius * 2 + 40, height: geometry.outerRadius * 2 + 40)
            // Radwechsel: kurz zurücknehmen und weich wieder einfedern, damit der Wechsel sichtbar ist
            .scaleEffect(settled || reduceMotion ? 1 : 0.94)
            .opacity(settled ? 1 : 0.4)
            if !items.isEmpty { captionLine }
            wheelSwitcher
        }
        .frame(height: geometry.outerRadius * 2 + 40 + Self.captionHeight, alignment: .top)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.86, anchor: UnitPoint(x: 0.5, y: 0.43))
        .opacity(appeared ? 1 : 0)
        .onAppear { animateIn() }
        .onChange(of: presentationID) { animateIn() }
        .onChange(of: wheel) { settle() }
    }

    private func settle() {
        settled = false
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeOut(duration: 0.1) : Theme.wheelSpring) { settled = true }
        }
    }

    /// Leiste unter dem Rad: zeigt das aktive Rad und mit welcher Taste man zu den anderen kommt.
    private var wheelSwitcher: some View {
        let settings = AppSettings.shared
        return HStack(spacing: 2) {
            ForEach([AppSettings.Wheel.convert, .tools, .actions], id: \.self) { option in
                let active = option == wheel
                HStack(spacing: 5) {
                    Keycap(key: settings.key(for: option), size: .small, highlighted: active)
                    Text(option.title)
                        .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                }
                .padding(.leading, 4)
                .padding(.trailing, 9)
                .frame(height: 26)
                .background(active ? Theme.pill : Color.clear, in: Capsule())
                .animation(Theme.ease, value: wheel)
            }
        }
        .padding(3)
        .glassSurface(in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(wheel.title) wheel")
    }

    private func animateIn() {
        appeared = false
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : Theme.wheelSpring) {
                appeared = true
            }
        }
    }

    /// Glasring als Untergrund, damit das Rad auf jedem Hintergrund lesbar bleibt.
    private var base: some View {
        let ring = RingShape(inner: geometry.innerRadius - 8, outer: geometry.outerRadius + 8)
        return GlassGroup {
            Color.clear
                .frame(width: geometry.outerRadius * 2 + 40, height: geometry.outerRadius * 2 + 40)
                .glassSurface(in: ring)
        }
        .overlay(ring.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }

    private func wedge(_ item: RadialItem, index: Int) -> some View {
        let shape = WedgeShape(geometry: geometry, index: index)
        let selected = highlighted == index
        return GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let mid = geometry.midpoint(for: index, in: rect)
            let lift: CGFloat = selected && !reduceMotion ? 6 : 0
            ZStack {
                if selected {
                    shape.fill(Theme.accentStrong.shadow(.inner(color: .white.opacity(0.28), radius: 1, y: 1)))
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                } else {
                    shape.fill(Theme.segment
                        .shadow(.inner(color: .white.opacity(0.55), radius: 0.5, y: 1))
                        .shadow(.inner(color: .black.opacity(0.07), radius: 3, y: -1)))
                    shape.stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }
                label(item, selected: selected)
                    .frame(width: geometry.labelWidth)
                    .position(mid)
            }
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(selected && !reduceMotion ? 1.03 : 1)
            .offset(x: (mid.x - rect.midX) / geometry.labelRadius * lift,
                    y: (mid.y - rect.midY) / geometry.labelRadius * lift)
        }
        .zIndex(selected ? 1 : 0)
        .animation(reduceMotion ? nil : Theme.wheelSpring, value: highlighted)
    }

    private func label(_ item: RadialItem, selected: Bool) -> some View {
        let dense = items.count > 8
        let isFormat: Bool = { if case .convert = item.action { return true }; return false }()
        return VStack(spacing: dense ? 3 : 4) {
            if !isFormat || items.count <= 4 {
                Image(systemName: item.symbol)
                    .font(.system(size: dense ? 15 : 17, weight: .regular))
                    .symbolRenderingMode(.monochrome)
            }
            Text(item.label)
                .font(.system(size: dense ? 10.5 : 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
        }
        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.82))
        .contentTransition(.identity)
    }

    private var pill: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(highlighted == nil ? Color.secondary : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: geometry.innerRadius * 2 - 12)
            .background(Theme.pill, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .id(title)
            .transition(.opacity)
            .animation(Theme.ease, value: title)
    }

    /// Zeile unter dem Rad: Taste und Aktion, z.B. "⇧  Convert to PNG".
    private var captionLine: some View {
        HStack(spacing: 8) {
            Text(caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(highlighted == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .frame(maxWidth: geometry.outerRadius * 2)
        .glassSurface(in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.top, 8)
        .animation(Theme.ease, value: caption)
    }

    private var empty: some View {
        VStack(spacing: 4) {
            Text(emptyMessage)
                .font(.system(size: 14, weight: .semibold))
            if !emptyDetail.isEmpty {
                Text(emptyDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: geometry.outerRadius * 2)
        .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RadialView: NSView {
    var items: [RadialItem] = [] { didSet { refresh() } }
    var emptyMessage = "No conversions available" { didSet { refresh() } }
    var subtitle = "" { didSet { refresh() } }
    var center: NSPoint = .zero { didSet { needsLayout = true } }
    var onSelect: ((RadialItem) -> Void)?
    var onCancel: (() -> Void)?
    var onDragEntered: ((NSDraggingInfo) -> Void)?
    var onDragSessionEnded: (() -> Void)?
    /// Menü-Modus: Radtaste gedrückt (z.B. Command) -> anderes Rad zeigen, wie im Original.
    var onWheelChange: ((AppSettings.Wheel) -> Void)?
    /// Menü-Modus: Tasten, die beim Öffnen schon gehalten werden (⌃⌥ vom Kurzbefehl), wechseln nichts.
    var interactive = false { didSet { if interactive { keys = WheelKeyTracker(start: NSEvent.modifierFlags) } } }
    var keys = WheelKeyTracker()
    /// Aktives Rad, für die Radleiste und die Wechsel-Animation.
    var wheel: AppSettings.Wheel = .convert { didSet { if oldValue != wheel { refresh() } } }
    var advancedMode = false { didSet { refresh() } }
    /// Taste, mit der das Rad geöffnet wurde (nil, wenn über das Menü geöffnet).
    var modeKey: DragKey? { didSet { refresh() } }
    /// Text in der Mitte, solange nichts gewählt ist.
    var idleTitle = "Convert" { didSet { refresh() } }

    private(set) var highlighted: Int? {
        didSet {
            guard oldValue != highlighted else { return }
            let label = highlighted.flatMap { items.indices.contains($0) ? items[$0].label : nil }
            let direction: CGFloat = highlighted.map { cos(CGFloat($0) * 2 * .pi / CGFloat(max(items.count, 1)) - .pi / 2) } ?? 0
            Task { @MainActor in JobRunner.shared.watchWheel(label: label, direction: direction) }
            if highlighted != nil { Feedback.hover() }
            refresh()
        }
    }
    private var presentationID = UUID()
    func animatePresentation() { presentationID = UUID(); refresh() }
    private var trackingArea: NSTrackingArea?
    private let host: PassthroughHostingView<RadialWheelView>

    let discRadius: CGFloat = 170

    private var geometry: RadialGeometry { RadialGeometry(count: items.count) }

    override init(frame frameRect: NSRect) {
        host = PassthroughHostingView(rootView: RadialWheelView(items: [], highlighted: nil, title: "", caption: "", modeKey: nil, emptyMessage: "", emptyDetail: "", geometry: RadialGeometry(count: 0)))
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("com.apple.finder.node")] + promiseTypes)
        wantsLayer = true
        host.sizingOptions = []
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        // Das Rad sitzt oben im Host, die Aktionszeile darunter; die Radmitte bleibt am Mauszeiger.
        let extra = RadialWheelView.captionHeight
        host.frame = NSRect(x: center.x - discRadius, y: center.y - discRadius - extra, width: discRadius * 2, height: discRadius * 2 + extra)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func refresh() {
        let title: String
        let caption: String
        if let highlighted, highlighted < items.count {
            title = items[highlighted].label
            caption = items[highlighted].detail
        } else {
            title = items.count == 1 ? items[0].label : idleTitle
            caption = subtitle
        }
        host.rootView = RadialWheelView(
            presentationID: presentationID,
            items: items,
            highlighted: highlighted,
            title: title,
            caption: caption,
            modeKey: modeKey,
            emptyMessage: emptyMessage,
            emptyDetail: subtitle,
            geometry: geometry,
            wheel: wheel
        )
    }

    func index(at point: NSPoint) -> Int? {
        geometry.index(at: CGPoint(x: point.x - center.x, y: point.y - center.y))
    }

    func updateHighlight(forWindowPoint point: NSPoint) {
        layoutSubtreeIfNeeded()
        highlighted = index(at: convert(point, from: nil))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender)
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DragDebug.log("prepareForDragOperation highlighted=\(String(describing: highlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        return highlighted != nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
        guard let window, sender != nil, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        if window.frame.insetBy(dx: 1, dy: 1).contains(NSEvent.mouseLocation) {
            onDragSessionEnded?()
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlighted = nil
        onDragSessionEnded?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        DragDebug.log("performDragOperation highlighted=\(String(describing: highlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        guard let highlighted, highlighted < items.count else {
            onCancel?()
            return false
        }
        let item = items[highlighted]
        Feedback.drop()
        DispatchQueue.main.async { [weak self] in self?.onSelect?(item) }
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
        if let highlighted, highlighted < items.count {
            Feedback.drop()
            onSelect?(items[highlighted])
        } else {
            onCancel?()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard interactive else { return super.flagsChanged(with: event) }
        if let wheel = keys.pressed(keyCode: event.keyCode, flags: event.modifierFlags, settings: AppSettings.shared) { onWheelChange?(wheel) }
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { return }
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            if let highlighted, highlighted < items.count { Feedback.drop(); onSelect?(items[highlighted]) }
        case 123, 126:
            step(-1)
        case 124, 125:
            step(1)
        default:
            super.keyDown(with: event)
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = highlighted ?? -1
        var next = (current + delta) % items.count
        if next < 0 { next += items.count }
        highlighted = next
    }

    func clearHighlight() { highlighted = nil }

    func highlight(_ index: Int) {
        highlighted = items.indices.contains(index) ? index : nil
    }
}


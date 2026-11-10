import AppKit
import SwiftUI

/// Bild beschriften (Phase 4, L10): Rahmen, Pfeile und Text auf ein Bild setzen.
/// Koordinaten aller Markierungen in Bildpixeln, Ursprung oben links.
struct AnnotationMark: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case rectangle, arrow, text
        var id: String { rawValue }
        var title: String { self == .rectangle ? "Frame" : rawValue.capitalized }
        var symbol: String {
            switch self {
            case .rectangle: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .text: return "textformat"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var text = ""
    var color: CGColor
    /// Linienstärke bzw. Schriftgröße in Bildpixeln
    var size: CGFloat
}

enum AnnotationRenderer {
    /// Zeichnet die Markierungen fest in eine Kopie des Bildes.
    static func render(_ image: CGImage, marks: [AnnotationMark]) throws -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw OpenTangerineError.encodeFailed("Annotation") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // In oben-links-Koordinaten zeichnen
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            context.setStrokeColor(mark.color)
            context.setFillColor(mark.color)
            context.setLineWidth(mark.size)
            switch mark.kind {
            case .rectangle:
                context.stroke(CGRect(x: min(mark.start.x, mark.end.x), y: min(mark.start.y, mark.end.y),
                                      width: abs(mark.end.x - mark.start.x), height: abs(mark.end.y - mark.start.y)))
            case .arrow:
                context.addPath(arrowPath(from: mark.start, to: mark.end, width: mark.size))
                context.strokePath()
            case .text:
                guard !mark.text.isEmpty else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: mark.size, weight: .semibold),
                    .foregroundColor: NSColor(cgColor: mark.color) ?? .black,
                ]
                NSAttributedString(string: mark.text, attributes: attributes).draw(at: mark.start)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let output = context.makeImage() else { throw OpenTangerineError.encodeFailed("Annotation") }
        return output
    }

    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = max(10, width * 4)
        for side in [-1.0, 1.0] {
            let a = angle + .pi - side * .pi / 7
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x + cos(a) * head, y: end.y + sin(a) * head))
        }
        return path
    }
}

@MainActor
struct AnnotateImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var marks: [AnnotationMark] = []
    @State private var tool: AnnotationMark.Kind = .arrow
    @State private var color = Color.red
    @State private var weight: Double = 6
    @State private var text = "Text"
    @State private var drawing: UUID?

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 2000))
    }

    /// Stärke relativ zur Bildgröße, damit sie bei kleinen und großen Bildern gleich wirkt.
    private var pixelSize: CGFloat {
        let long = max(document.size.width, document.size.height)
        return CGFloat(weight) * max(long, 1) / 1000 * (tool == .text ? 6 : 1)
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: !marks.isEmpty, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    GeometryReader { proxy in
                        let fit = FitGeometry(container: proxy.size, image: document.size)
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: preview).resizable().interpolation(.high)
                                .frame(width: fit.displayRect.width, height: fit.displayRect.height)
                                .offset(x: fit.displayRect.minX, y: fit.displayRect.minY)
                            Canvas { context, _ in draw(marks, in: &context, fit: fit) }
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            drag(value, fit: fit)
                        }.onEnded { _ in finishDrag() })
                    }
                    .padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Tool") {
                Picker("", selection: $tool) {
                    ForEach(AnnotationMark.Kind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if tool == .text {
                    TextField("Text", text: $text).textFieldStyle(.roundedBorder)
                    Text("Click on the image to place the text.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Drag on the image to draw.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: "Style") {
                ColorSwatchPicker(title: "Color", color: $color)
                LabeledSlider(title: tool == .text ? "Text size" : "Line width", value: $weight, range: 2...20) { String(format: "%.0f", $0) }
            }
            SidebarSection(title: "Marks (\(marks.count))") {
                if marks.isEmpty {
                    Text("Frames, arrows and text appear here.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                    HStack {
                        Image(systemName: mark.kind.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(mark.kind == .text ? mark.text : "\(mark.kind.title) \(index + 1)").font(.callout).lineLimit(1)
                        Spacer()
                        Button { marks.removeAll { $0.id == mark.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                if !marks.isEmpty {
                    Button("Undo last") { marks.removeLast() }.controlSize(.small)
                }
            }
        }
    }

    private func draw(_ marks: [AnnotationMark], in context: inout GraphicsContext, fit: FitGeometry) {
        func display(_ p: CGPoint) -> CGPoint {
            CGPoint(x: fit.displayRect.minX + p.x * fit.scale, y: fit.displayRect.minY + p.y * fit.scale)
        }
        for mark in marks {
            let color = Color(cgColor: mark.color)
            let style = StrokeStyle(lineWidth: max(1, mark.size * fit.scale), lineCap: .round, lineJoin: .round)
            switch mark.kind {
            case .rectangle:
                let a = display(mark.start), b = display(mark.end)
                context.stroke(Path(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))), with: .color(color), style: style)
            case .arrow:
                let path = AnnotationRenderer.arrowPath(from: display(mark.start), to: display(mark.end), width: mark.size * fit.scale)
                context.stroke(Path(path), with: .color(color), style: style)
            case .text:
                let size = max(6, mark.size * fit.scale)
                context.draw(Text(mark.text).font(.system(size: size, weight: .semibold)).foregroundColor(color),
                             at: display(mark.start), anchor: .topLeading)
            }
        }
    }

    private func drag(_ value: DragGesture.Value, fit: FitGeometry) {
        let bounds = CGRect(origin: .zero, size: document.size)
        func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY)) }
        let point = clamp(fit.toImage(value.location))
        if let drawing, let index = marks.firstIndex(where: { $0.id == drawing }) {
            if marks[index].kind == .text { marks[index].start = point } else { marks[index].end = point }
            return
        }
        let start = clamp(fit.toImage(value.startLocation))
        guard tool != .text || !text.isEmpty else { return }
        let mark = AnnotationMark(kind: tool, start: start, end: point, text: text, color: color.nsColor.cgColor, size: pixelSize)
        marks.append(mark)
        drawing = mark.id
    }

    private func finishDrag() {
        // Versehentliche Klicks ohne Ausdehnung verwerfen (außer Text)
        if let drawing, let mark = marks.first(where: { $0.id == drawing }), mark.kind != .text,
           hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) < 4 {
            marks.removeAll { $0.id == drawing }
        }
        drawing = nil
    }

    private func save() {
        guard let original = document.original else { return }
        let marks = marks
        // Vorschau und Original können verschieden groß sein: Markierungen sind in Originalpixeln
        ImageToolSupport.save(session, suffix: "annotated") {
            try AnnotationRenderer.render(original, marks: marks)
        }
    }
}

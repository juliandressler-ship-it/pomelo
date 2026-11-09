import AppKit
import SwiftUI

/// Gestaltungsgrundlagen (Phase 2).
/// Richtung: ruhige, native macOS-Oberfläche. Farbe gibt es nur im Rad, im Icon
/// und im Fortschritt. Erkennungszeichen ist das gefüllte Mandarinensegment.
enum Theme {
    /// Mandarinenorange für Symbole und Flächen ohne Text darauf.
    static let accentNS = NSColor(srgbRed: 0.941, green: 0.353, blue: 0.157, alpha: 1)   // #F05A28
    static let accent = Color(nsColor: accentNS)
    /// Dunklere Stufe für Flächen mit weißer Schrift (Kontrast über 4.5:1).
    static let accentStrong = Color(.sRGB, red: 0.851, green: 0.282, blue: 0.059, opacity: 1) // #D9480F

    static let ink = Color(nsColor: .labelColor)
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)
    static let cardCorner: CGFloat = 12

    /// Eine Kurve und wenige Dauern für die ganze App.
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    static let enter = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.36)
    /// Federn nur für das Rad (Öffnen und Segmentwechsel), wie im Plan verlangt.
    static let wheelSpring = Animation.spring(response: 0.3, dampingFraction: 0.82)

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Segmentfläche im Rad: hell fast weiß, dunkel ein Grauschritt.
    static let segment = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 0.24, alpha: 0.92) : NSColor(white: 1, alpha: 0.86)
    })
    /// Pille in der Radmitte und Oberseite der Tastenkappen.
    static let pill = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 1, alpha: 1)
    })
}

struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.cardCorner

    func body(content: Content) -> some View {
        content
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
    }
}

extension View {
    func card(cornerRadius: CGFloat = Theme.cardCorner) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

struct SegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Tastenkappe

/// Tastenkappe mit leichtem 3D-Effekt: helle Oberseite, dunklere Kante darunter.
struct Keycap: View {
    let key: DragKey
    var size: Size = .regular
    var highlighted = false

    enum Size { case small, regular, large }

    var body: some View {
        let m = metrics
        let shape = RoundedRectangle(cornerRadius: m.radius, style: .continuous)
        HStack(spacing: 4) {
            Text(key.symbol).font(.system(size: m.symbol, weight: .medium))
            if size != .small {
                Text(key.title).font(.system(size: m.text, weight: .medium))
            }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, m.padding)
        .frame(minWidth: m.height, minHeight: m.height)
        .background {
            ZStack {
                shape.fill(highlighted ? Color.black.opacity(0.28) : Color.primary.opacity(0.18))
                    .offset(y: m.depth)
                shape.fill(highlighted ? Theme.accentStrong : Theme.pill)
                shape.strokeBorder(Color.primary.opacity(highlighted ? 0 : 0.10), lineWidth: 1)
                shape.strokeBorder(Color.white.opacity(highlighted ? 0.28 : 0.7), lineWidth: 1)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
            }
        }
        .padding(.bottom, m.depth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.title)
    }

    private var metrics: (symbol: CGFloat, text: CGFloat, height: CGFloat, padding: CGFloat, radius: CGFloat, depth: CGFloat) {
        switch size {
        case .small: return (11, 11, 20, 5, 5, 1.5)
        case .regular: return (13, 12, 26, 8, 6, 2)
        case .large: return (20, 15, 44, 14, 10, 3)
        }
    }
}

// MARK: - Segment-Fortschritt (Erkennungszeichen)

/// Mandarinenscheibe als Fortschrittsanzeige: sieben Segmente füllen sich nacheinander.
struct SegmentProgress: View {
    var fraction: Double
    var failed = false
    var size: CGFloat = 22
    var track: Color = Color.primary.opacity(0.16)

    var body: some View {
        let count = 7
        let filled = min(max(fraction, 0), 1) * Double(count)
        ZStack {
            Circle().strokeBorder(track, lineWidth: max(1, size * 0.07))
            ForEach(0..<count, id: \.self) { index in
                let amount = min(max(filled - Double(index), 0), 1)
                SliceShape(index: index, count: count).fill(track)
                SliceShape(index: index, count: count)
                    .fill(failed ? Color.red : Theme.accent)
                    .opacity(failed ? 1 : amount)
            }
        }
        .frame(width: size, height: size)
        .animation(Theme.ease, value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed ? "Failed" : "\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}

/// Ein Segment der Scheibe, 0 = oben, im Uhrzeigersinn.
struct SliceShape: Shape {
    var index: Int
    var count: Int

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let outer = r * 0.74, inner = r * 0.12
        let step = 2 * Double.pi / Double(count)
        let gap = 0.16
        let start = -Double.pi / 2 + step * Double(index) - step / 2 + gap / 2
        let end = start + step - gap
        var path = Path()
        path.addArc(center: c, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: c, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

// MARK: - Ton und Haptik

/// Rückmeldung beim Überfahren und Ablegen. Ton und Trackpad-Haptik sind getrennt schaltbar.
@MainActor
enum Feedback {
    static func hover() {
        let settings = AppSettings.shared
        if settings.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if settings.soundEnabled { play("Tink", volume: 0.12) }
    }

    static func drop() {
        let settings = AppSettings.shared
        if settings.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        if settings.soundEnabled { play("Pop", volume: 0.35) }
    }

    private static func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}

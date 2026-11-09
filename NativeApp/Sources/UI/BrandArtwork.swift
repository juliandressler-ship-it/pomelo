import AppKit

/// Logo "Mandarine" (Entwurf B, Design/logo/make_logo.py):
/// Querschnitt einer Mandarine mit sieben Segmenten wie das Konvertierungsrad.
/// Ein Segment ist ausgefüllt, so wie das gewählte Ziel im Rad.
/// Koordinaten auf einer 1024er Fläche, y nach unten (wie im SVG).
enum BrandArtwork {
    static let orangeTop = NSColor(srgbRed: 1.0, green: 0.549, blue: 0.259, alpha: 1)    // #FF8C42
    static let orangeBottom = NSColor(srgbRed: 0.941, green: 0.353, blue: 0.157, alpha: 1) // #F05A28

    static func image(size: CGFloat, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
            if template { drawTemplate(ctx) } else { drawIcon(ctx) }
            return true
        }
        image.isTemplate = template
        return image
    }

    // MARK: App-Icon

    private static func drawIcon(_ ctx: CGContext) {
        let tile = squircle(origin: 100, size: 824)
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        let colors = [orangeTop.cgColor, orangeBottom.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
        }
        ctx.restoreGState()
        // feine Lichtkante wie bei den Systemsymbolen
        ctx.addPath(squircle(origin: 102, size: 820))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()

        let white = NSColor.white
        ring(ctx, radius: 264, width: 30, color: white)
        segments(ctx, rIn: 40, rOut: 222, gapDeg: 4, round: 30, active: white, rest: white.withAlphaComponent(0.42))
        leaf(ctx, color: white)
    }

    // MARK: Menüleiste (Vorlage, einfarbig, kräftiger)

    private static func drawTemplate(_ ctx: CGContext) {
        let ink = NSColor.black
        ring(ctx, radius: 380, width: 72, color: ink)
        // Bei 16 bis 18 pt: weniger, aber klarere Formen; das aktive Segment trägt die Aussage.
        segments(ctx, rIn: 110, rOut: 300, gapDeg: 18, round: 48, active: ink, rest: ink.withAlphaComponent(0.3))
    }

    // MARK: Bausteine

    private static let center = CGPoint(x: 512, y: 512)

    /// Superellipse wie das macOS-App-Raster.
    static func squircle(origin: CGFloat, size: CGFloat, n: CGFloat = 4, steps: Int = 240) -> CGPath {
        let a = size / 2
        let c = origin + a
        let path = CGMutablePath()
        for i in 0..<steps {
            let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let ct = cos(t), st = sin(t)
            let x = c + a * copysign(pow(abs(ct), 2 / n), ct)
            let y = c + a * copysign(pow(abs(st), 2 / n), st)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }

    /// 0 Grad = oben, im Uhrzeigersinn (y nach unten).
    private static func polar(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
        let rad = (deg - 90) * .pi / 180
        return CGPoint(x: center.x + r * cos(rad), y: center.y + r * sin(rad))
    }

    private static func ring(_ ctx: CGContext, radius: CGFloat, width: CGFloat, color: NSColor) {
        ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    /// Ringsegmente mit runden Ecken: Geometrie schrumpfen, dann runde Kontur gleicher Farbe.
    private static func segments(_ ctx: CGContext, count: Int = 7, rIn: CGFloat, rOut: CGFloat, gapDeg: CGFloat,
                                 round: CGFloat, active: NSColor, rest: NSColor) {
        let half = round / 2
        let step = 360 / CGFloat(count)
        let pad = gapDeg / 2 + (half / ((rIn + rOut) / 2)) * 180 / .pi
        let inner = rIn + half, outer = rOut - half
        func rad(_ deg: CGFloat) -> CGFloat { (deg - 90) * .pi / 180 }
        for i in 0..<count {
            let mid = CGFloat(i) * step
            let a0 = mid - step / 2 + pad, a1 = mid + step / 2 - pad
            let path = CGMutablePath()
            // Im geflippten Kontext läuft "clockwise: false" optisch im Uhrzeigersinn.
            path.move(to: polar(outer, a0))
            path.addArc(center: center, radius: outer, startAngle: rad(a0), endAngle: rad(a1), clockwise: false)
            path.addLine(to: polar(inner, a1))
            path.addArc(center: center, radius: inner, startAngle: rad(a1), endAngle: rad(a0), clockwise: true)
            path.closeSubpath()
            let color = (i == 0 ? active : rest).cgColor
            // Füllung und Kontur als eine Ebene, damit sich halbtransparente Teile nicht doppeln
            ctx.saveGState()
            ctx.setAlpha(color.alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let opaque = color.copy(alpha: 1) ?? color
            ctx.setFillColor(opaque)
            ctx.setStrokeColor(opaque)
            ctx.setLineWidth(round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    private static func leaf(_ ctx: CGContext, color: NSColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 628, y: 250))
        path.addCurve(to: CGPoint(x: 792, y: 154), control1: CGPoint(x: 650, y: 186), control2: CGPoint(x: 718, y: 150))
        path.addCurve(to: CGPoint(x: 644, y: 268), control1: CGPoint(x: 784, y: 226), control2: CGPoint(x: 722, y: 270))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }
}

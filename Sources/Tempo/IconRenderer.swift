import AppKit

/// Dessine l'icône de la barre de menus. Toutes les mesures sont en points,
/// pour une barre de 22 à 24 points de haut.
enum IconRenderer {
    struct Value {
        /// Pourcentage utilisé, de 0 à 100.
        let used: Double
        /// Couleur de la partie remplie. Nil = couleur du texte de la barre.
        let tint: NSColor?
    }

    /// - Parameters:
    ///   - pace: part de la fenêtre écoulée (0 à 1), pour le repère de rythme. Nil = pas de repère.
    ///   - remaining: dessine le restant plutôt que l'utilisé.
    ///   - template: image monochrome que macOS colore selon la barre (claire ou sombre).
    static func image(
        style: IconStyle, values: [Value], pace: Double?, remaining: Bool, template: Bool, scale: CGFloat = 1
    ) -> NSImage? {
        let values = Array(values.prefix(2))
        guard !values.isEmpty else { return nil }

        func shown(_ used: Double) -> Double {
            let v = min(max(used, 0), 100)
            return remaining ? 100 - v : v
        }
        let paceShown = pace.map { shown($0 * 100) }

        let size: NSSize
        switch style {
        case .ring: size = NSSize(width: 18, height: 18)
        case .gauge: size = NSSize(width: CGFloat(values.count) * 21 + CGFloat(values.count - 1) * 3, height: 13)
        case .bar: size = NSSize(width: 22, height: 10)
        default: return nil
        }

        let scaled = NSSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
        let image = NSImage(size: scaled, flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            transform.concat()
            let primary: NSColor = template ? .black : .labelColor
            let track = primary.withAlphaComponent(0.25)
            switch style {
            case .ring: drawRing(values, shown, paceShown, primary, track)
            case .gauge: drawGauges(values, shown, paceShown, primary, track)
            case .bar: drawBars(values, shown, paceShown, primary, track, size)
            default: break
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    // MARK: - Anneau (double quand il y a deux valeurs)

    private static func drawRing(
        _ values: [Value], _ shown: (Double) -> Double, _ pace: Double?,
        _ primary: NSColor, _ track: NSColor
    ) {
        let center = NSPoint(x: 9, y: 9)
        let specs: [(r: CGFloat, w: CGFloat)] = values.count > 1 ? [(6.45, 1.8), (3.6, 1.8)] : [(6.2, 2.3)]

        for (i, value) in values.enumerated() {
            let spec = specs[i]
            let full = NSBezierPath()
            full.appendArc(withCenter: center, radius: spec.r, startAngle: 0, endAngle: 360)
            full.lineWidth = spec.w
            track.setStroke()
            full.stroke()

            let v = shown(value.used)
            guard v > 0.5 else { continue }
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: spec.r,
                startAngle: 90, endAngle: 90 - 360 * v / 100, clockwise: true
            )
            arc.lineWidth = spec.w
            arc.lineCapStyle = .round
            (value.tint ?? primary).setStroke()
            arc.stroke()
        }

        if let pace {
            let angle = (90 - 360 * pace / 100) * .pi / 180
            let inner = specs[0].r + specs[0].w / 2 - 0.1
            let outer: CGFloat = 8.7
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            tick.line(to: NSPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
            tick.lineWidth = 1.3
            tick.lineCapStyle = .round
            primary.setStroke()
            tick.stroke()
        }
    }

    // MARK: - Cadran à aiguille (un par valeur)

    private static func drawGauges(
        _ values: [Value], _ shown: (Double) -> Double, _ pace: Double?,
        _ primary: NSColor, _ track: NSColor
    ) {
        for (i, value) in values.enumerated() {
            let center = NSPoint(x: CGFloat(i) * 24 + 10.5, y: 1.6)
            let radius: CGFloat = 8.2
            let width: CGFloat = 2.2

            let full = NSBezierPath()
            full.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
            full.lineWidth = width
            full.lineCapStyle = .round
            track.setStroke()
            full.stroke()

            let v = shown(value.used)
            if v > 0.5 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: 180, endAngle: 180 - 180 * v / 100, clockwise: true
                )
                arc.lineWidth = width
                arc.lineCapStyle = .round
                (value.tint ?? primary).setStroke()
                arc.stroke()
            }

            let angle = (180 - 180 * v / 100) * .pi / 180
            let needle = NSBezierPath()
            needle.move(to: center)
            needle.line(to: NSPoint(x: center.x + 5.6 * cos(angle), y: center.y + 5.6 * sin(angle)))
            needle.lineWidth = 1.3
            needle.lineCapStyle = .round
            primary.setStroke()
            needle.stroke()
            primary.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.3, y: center.y - 1.3, width: 2.6, height: 2.6)).fill()

            if let pace, i == 0 {
                let a = (180 - 180 * pace / 100) * .pi / 180
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: center.x + 9.5 * cos(a), y: center.y + 9.5 * sin(a)))
                tick.line(to: NSPoint(x: center.x + 10.6 * cos(a), y: center.y + 10.6 * sin(a)))
                tick.lineWidth = 1.2
                tick.lineCapStyle = .round
                primary.setStroke()
                tick.stroke()
            }
        }
    }

    // MARK: - Barre (deux barres empilées quand il y a deux valeurs)

    private static func drawBars(
        _ values: [Value], _ shown: (Double) -> Double, _ pace: Double?,
        _ primary: NSColor, _ track: NSColor, _ size: NSSize
    ) {
        let two = values.count > 1
        let height: CGFloat = two ? 3.4 : 5
        // Repère non retourné : la première valeur va en haut.
        let ys: [CGFloat] = two ? [5.8, 0.8] : [2.5]

        for (i, value) in values.enumerated() {
            let rect = NSRect(x: 0, y: ys[i], width: size.width, height: height)
            track.setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()

            let v = shown(value.used)
            guard v > 0.5 else { continue }
            let w = max(size.width * v / 100, height)
            let fill = NSRect(x: 0, y: ys[i], width: w, height: height)
            (value.tint ?? primary).setFill()
            NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
        }

        if let pace {
            let x = min(max(size.width * pace / 100, 0.6), size.width - 0.6)
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x, y: 0.3))
            tick.line(to: NSPoint(x: x, y: size.height - 0.3))
            tick.lineWidth = 1.1
            tick.lineCapStyle = .round
            primary.setStroke()
            tick.stroke()
        }
    }
}

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? .gray
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}

/// Choisit la couleur d'une valeur d'après le mode et la palette des réglages.
enum Tint {
    static func rgb(mode: ColorMode, palette: Palette, insight: LimitInsight) -> RGB? {
        switch mode {
        case .mono: return nil
        case .thresholds: return palette.color(forUsage: insight.limit.percent, gradient: false)
        case .gradient: return palette.color(forUsage: insight.limit.percent, gradient: true)
        case .pace: return palette.color(for: insight.status)
        }
    }

    /// Couleur de la valeur principale (l'hebdo). Nil = couleur du texte de la barre.
    static func primary(_ options: DisplayOptions, _ insight: LimitInsight) -> NSColor? {
        rgb(mode: options.colorMode, palette: options.palette, insight: insight)?.nsColor
    }

    /// Couleur du modèle suivi (Fable).
    static func model(_ options: DisplayOptions, _ insight: LimitInsight) -> NSColor? {
        switch options.modelColorMode {
        case .none:
            return nil
        case .fixed:
            return options.modelFixed.nsColor
        case .usage:
            // En monochrome, « selon son usage » suit quand même les seuils.
            let mode = options.colorMode == .mono ? ColorMode.thresholds : options.colorMode
            return rgb(mode: mode, palette: options.palette, insight: insight)?.nsColor
        }
    }
}

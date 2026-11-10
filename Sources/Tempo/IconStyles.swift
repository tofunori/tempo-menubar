import AppKit

/// Ce qu'une icône peut montrer. Les pourcentages sont « utilisés », de 0 à 100.
struct IconInput {
    var primary: Double
    var secondary: Double?
    /// Part de la fenêtre écoulée, de 0 à 1.
    var elapsed: Double?
    var showPace = true
    var remaining = false
    var primaryTint: NSColor?
    var secondaryTint: NSColor?
    var days: [DayUsage] = []
    var template = true
}

extension IconRenderer {
    /// Largeur du dessin (pour une hauteur de 24 unités) et hauteur naturelle dans la barre, en points.
    private static func geometry(_ style: IconStyle) -> (width: CGFloat, height: CGFloat) {
        switch style {
        case .dial: return (24, 18)
        case .parens: return (26, 18)
        case .arcs: return (30, 18)
        case .duo: return (20, 18)
        case .matrix: return (30, 18)
        case .lines: return (40, 22)
        case .monogram: return (24, 20)
        case .book: return (26, 18)
        case .metronome: return (28, 18)
        case .week: return (26, 18)
        case .hourglass: return (20, 18)
        case .moon: return (24, 18)
        case .battery: return (29, 18)
        case .segments: return (29, 18)
        case .ringNumber: return (24, 21)
        case .ring, .gauge, .bar, .none: return (24, 18)
        }
    }

    /// Hauteur du dessin à la grosseur normale, en points.
    static func naturalHeight(_ style: IconStyle) -> CGFloat {
        switch style {
        case .ring: return 18
        case .gauge: return 13
        case .bar: return 10
        case .none: return 0
        default: return geometry(style).height
        }
    }

    /// - Parameter zoom: 1 = taille de la barre de menus ; plus grand pour les aperçus.
    static func image(style: IconStyle, input: IconInput, zoom: CGFloat = 1) -> NSImage? {
        if style == .none { return nil }

        if style.group == .classic {
            var values = [Value(used: input.primary, tint: input.primaryTint)]
            if let second = input.secondary { values.append(Value(used: second, tint: input.secondaryTint)) }
            return image(
                style: style, values: values,
                pace: input.showPace ? input.elapsed : nil,
                remaining: input.remaining, template: input.template, scale: zoom
            )
        }

        let geo = geometry(style)
        let height = geo.height * zoom
        let k = height / 24
        let size = NSSize(width: (geo.width * k).rounded(.up), height: height.rounded(.up))

        // Repère retourné (y vers le bas), en unités de 24 de haut : les mêmes coordonnées que les maquettes.
        let image = NSImage(size: size, flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: k)
            transform.concat()

            let ink: NSColor = input.template ? .black : .labelColor
            let pen = Pen(ink: ink, kw: input.primaryTint ?? ink, kf: input.secondaryTint ?? ink)

            func shown(_ used: Double) -> Double {
                let v = min(max(used, 0), 100)
                return input.remaining ? 100 - v : v
            }
            let used = min(max(input.primary, 0), 100)
            let w = shown(input.primary)
            let f = input.secondary.map(shown)
            let elapsed = input.elapsed.map { min(max($0, 0), 1) * 100 }
            let t = input.showPace ? elapsed.map(shown) : nil
            let rawT = input.showPace ? elapsed : nil

            switch style {
            case .dial: pen.dial(w, f, t)
            case .parens: pen.parens(w, f, t)
            case .arcs: pen.arcs(w, f, t)
            case .duo: pen.duo(w, f, t)
            case .matrix: pen.matrix(w, f, t)
            case .lines: pen.lines(w, f, t)
            case .monogram: pen.monogram(w, f)
            case .book: pen.book(w, f, t)
            case .metronome: pen.metronome(delta: elapsed.map { used - $0 } ?? 0)
            case .week: pen.week(input.days)
            case .hourglass: pen.hourglass(used)
            case .moon: pen.moon(used)
            case .battery: pen.battery(used, rawT)
            case .segments: pen.segments(w, t)
            case .ringNumber: pen.ringNumber(w)
            case .ring, .gauge, .bar, .none: break
            }
            return true
        }
        image.isTemplate = input.template
        return image
    }
}

/// Outils de dessin. Les angles sont « d'horloge » : 0° en haut, sens horaire.
private struct Pen {
    let ink: NSColor
    /// Couleur de la valeur principale (hebdo).
    let kw: NSColor
    /// Couleur de la deuxième valeur (modèle).
    let kf: NSColor

    var track: NSColor { ink.withAlphaComponent(0.25) }

    static func pt(_ c: CGPoint, _ degrees: Double, _ r: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
    }

    func arc(_ c: CGPoint, _ r: Double, _ from: Double, _ to: Double, _ color: NSColor, _ width: CGFloat, round: Bool = true) {
        let path = NSBezierPath()
        let steps = max(2, Int(abs(to - from) / 3))
        for i in 0...steps {
            let p = Pen.pt(c, from + (to - from) * Double(i) / Double(steps), r)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.lineWidth = width
        path.lineCapStyle = round ? .round : .butt
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    func line(_ a: CGPoint, _ b: CGPoint, _ color: NSColor, _ width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    func dot(_ c: CGPoint, _ r: Double, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    }

    func rect(_ r: NSRect, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    func polygon(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        for (i, p) in points.enumerated() {
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    /// Remplit `shape` de bas en haut jusqu'à `fraction` (0 à 1) de la hauteur entre `top` et `bottom`.
    func fillUp(_ shape: NSBezierPath, top: CGFloat, bottom: CGFloat, fraction: Double, _ color: NSColor) {
        guard fraction > 0.005 else { return }
        let level = bottom - (bottom - top) * min(fraction, 1)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        color.setFill()
        NSRect(x: -10, y: level, width: 100, height: bottom - level + 10).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    func text(_ string: String, x: CGFloat, baseline: CGFloat, size: CGFloat, _ color: NSColor, centered: Bool = false) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let width = attributed.size().width
        attributed.draw(at: CGPoint(x: centered ? x - width / 2 : x, y: baseline - font.ascender))
    }

    // MARK: - Deux valeurs

    /// Montre : l'anneau montre l'hebdo, l'aiguille montre le modèle.
    func dial(_ w: Double, _ f: Double?, _ t: Double?) {
        let c = CGPoint(x: 12, y: 12)
        arc(c, 9, 0, 360, track, 2.2)
        if w > 0.5 { arc(c, 9, 0, 3.6 * w, kw, 2.2) }
        if let f {
            line(c, Pen.pt(c, 3.6 * f, 6), kf, 2.3)
            dot(c, 1.5, kf)
        }
        if let t { line(Pen.pt(c, 3.6 * t, 10.4), Pen.pt(c, 3.6 * t, 11.8), ink, 1.4) }
    }

    /// Parenthèses : hebdo à gauche, modèle à droite, du bas vers le haut.
    func parens(_ w: Double, _ f: Double?, _ t: Double?) {
        let l = CGPoint(x: 12, y: 12), r = CGPoint(x: 14, y: 12)
        arc(l, 9.4, 180, 360, track, 2.6, round: false)
        arc(r, 9.4, 180, 0, track, 2.6, round: false)
        if w > 0.5 { arc(l, 9.4, 180, 180 + 1.8 * w, kw, 2.6, round: false) }
        if let f, f > 0.5 { arc(r, 9.4, 180, 180 - 1.8 * f, kf, 2.6, round: false) }
        if let t {
            let a = 180 + 1.8 * t
            line(Pen.pt(l, a, 10.9), Pen.pt(l, a, 12), ink, 1.4)
        }
    }

    /// Arc double : grand arc pour l'hebdo, petit arc pour le modèle.
    func arcs(_ w: Double, _ f: Double?, _ t: Double?) {
        let c = CGPoint(x: 15, y: 19)
        arc(c, 11.5, -90, 90, track, 2.6)
        arc(c, 7, -90, 90, track, 2.6)
        if w > 0.5 { arc(c, 11.5, -90, -90 + 1.8 * w, kw, 2.6) }
        if let f, f > 0.5 { arc(c, 7, -90, -90 + 1.8 * f, kf, 2.6) }
        if let t {
            let a = -90 + 1.8 * t
            line(Pen.pt(c, a, 13.2), Pen.pt(c, a, 14.6), ink, 1.4)
        }
    }

    /// Duo : grosse colonne pour l'hebdo, colonne fine pour le modèle.
    func duo(_ w: Double, _ f: Double?, _ t: Double?) {
        let wide = NSBezierPath(roundedRect: NSRect(x: 4, y: 2, width: 6.5, height: 20), xRadius: 3.25, yRadius: 3.25)
        let thin = NSBezierPath(roundedRect: NSRect(x: 13, y: 2, width: 4.6, height: 20), xRadius: 2.3, yRadius: 2.3)
        track.setFill()
        wide.fill()
        thin.fill()
        fillUp(wide, top: 2, bottom: 22, fraction: w / 100, kw)
        if let f { fillUp(thin, top: 2, bottom: 22, fraction: f / 100, kf) }
        if let t {
            let y = 22 - 20 * t / 100
            line(CGPoint(x: 0.8, y: y), CGPoint(x: 2.8, y: y), ink, 1.5)
        }
    }

    /// Matrice : deux rangées de dix crans.
    func matrix(_ w: Double, _ f: Double?, _ t: Double?) {
        let nw = Int((w / 10).rounded()), nf = Int(((f ?? 0) / 10).rounded())
        for i in 0..<10 {
            let x = CGFloat(i) * 3
            rect(NSRect(x: x, y: 3.5, width: 2.1, height: 6.5), 1, i < nw ? kw : track)
            rect(NSRect(x: x, y: 13.5, width: 2.1, height: 6.5), 1, i < nf ? kf : track)
        }
        if let t {
            let column = min(9, Int(t / 10))
            dot(CGPoint(x: CGFloat(column) * 3 + 1.05, y: 11.75), 1, ink)
        }
    }

    /// Deux lignes : une mini-barre et un chiffre par valeur.
    /// Le dessin remplit toute la hauteur : ce style est déjà aussi haut que la barre de menus.
    func lines(_ w: Double, _ f: Double?, _ t: Double?) {
        func row(_ y: CGFloat, _ value: Double, _ color: NSColor) {
            rect(NSRect(x: 0, y: y, width: 14, height: 4.2), 2.1, track)
            if value > 0.5 {
                rect(NSRect(x: 0, y: y, width: max(4.2, 14 * value / 100), height: 4.2), 2.1, color)
            }
            text("\(Int(value.rounded()))", x: 17.5, baseline: y + 6.3, size: 11.6, color)
        }
        row(3.9, w, kw)
        if let f { row(15.9, f, kf) }
        if let t {
            let x = min(max(14 * t / 100, 0.6), 13.4)
            line(CGPoint(x: x, y: 2.3), CGPoint(x: x, y: 9.7), ink, 1.2)
        }
    }

    /// Monogramme : anneau pour l'hebdo, lettre F qui se remplit avec le modèle.
    func monogram(_ w: Double, _ f: Double?) {
        let c = CGPoint(x: 12, y: 12)
        arc(c, 10, 0, 360, track, 2.2)
        if w > 0.5 { arc(c, 10, 0, 3.6 * w, kw, 2.2) }
        let letter = polygon([
            CGPoint(x: 8.9, y: 6.8), CGPoint(x: 15.6, y: 6.8), CGPoint(x: 15.6, y: 9.1), CGPoint(x: 11.5, y: 9.1),
            CGPoint(x: 11.5, y: 10.9), CGPoint(x: 14.7, y: 10.9), CGPoint(x: 14.7, y: 13.1), CGPoint(x: 11.5, y: 13.1),
            CGPoint(x: 11.5, y: 17.2), CGPoint(x: 8.9, y: 17.2),
        ])
        ink.withAlphaComponent(0.28).setFill()
        letter.fill()
        if let f { fillUp(letter, top: 6.8, bottom: 17.2, fraction: f / 100, kf) }
    }

    /// Livre : arc pour l'hebdo, livre ouvert qui se remplit avec le modèle.
    func book(_ w: Double, _ f: Double?, _ t: Double?) {
        let c = CGPoint(x: 13, y: 14)
        arc(c, 10.5, -90, 90, track, 2.2)
        if w > 0.5 { arc(c, 10.5, -90, -90 + 1.8 * w, kw, 2.2) }

        let pages = NSBezierPath()
        pages.move(to: CGPoint(x: 13, y: 12.6))
        pages.curve(to: CGPoint(x: 6.6, y: 11.4), controlPoint1: CGPoint(x: 11.4, y: 11.3), controlPoint2: CGPoint(x: 8.8, y: 10.9))
        pages.line(to: CGPoint(x: 6.6, y: 19.6))
        pages.curve(to: CGPoint(x: 13, y: 20.8), controlPoint1: CGPoint(x: 8.8, y: 19.1), controlPoint2: CGPoint(x: 11.4, y: 19.5))
        pages.close()
        pages.move(to: CGPoint(x: 13, y: 12.6))
        pages.curve(to: CGPoint(x: 19.4, y: 11.4), controlPoint1: CGPoint(x: 14.6, y: 11.3), controlPoint2: CGPoint(x: 17.2, y: 10.9))
        pages.line(to: CGPoint(x: 19.4, y: 19.6))
        pages.curve(to: CGPoint(x: 13, y: 20.8), controlPoint1: CGPoint(x: 17.2, y: 19.1), controlPoint2: CGPoint(x: 14.6, y: 19.5))
        pages.close()

        if let f { fillUp(pages, top: 10.9, bottom: 20.8, fraction: f / 100, kf) }
        pages.lineWidth = 1.1
        pages.lineJoinStyle = .round
        ink.setStroke()
        pages.stroke()

        if let t {
            let a = -90 + 1.8 * t
            line(Pen.pt(c, a, 11.9), Pen.pt(c, a, 13), ink, 1.3)
        }
    }

    // MARK: - Une valeur

    /// Métronome : l'aiguille penche à gauche avec de la marge, à droite quand ça va trop vite.
    func metronome(delta: Double) {
        let pivot = CGPoint(x: 14, y: 21)
        arc(pivot, 17, -38, 38, ink.withAlphaComponent(0.3), 1.6)
        line(CGPoint(x: 14, y: 1.8), CGPoint(x: 14, y: 5.2), ink.withAlphaComponent(0.75), 1.5)
        let a = min(max(delta * 1.6, -38), 38)
        line(pivot, Pen.pt(pivot, a, 16), kw, 2)
        dot(Pen.pt(pivot, a, 10), 2.5, kw)
        line(CGPoint(x: 9.5, y: 22), CGPoint(x: 18.5, y: 22), ink, 1.8)
    }

    /// Semaine : une barre par jour ; les jours à venir montrent ce qui reste possible.
    func week(_ days: [DayUsage]) {
        let count = max(days.count, 1)
        let step = 26.0 / Double(count)
        let width = step * 0.7
        let peak = max(1, days.map { $0.used + $0.possible }.max() ?? 1)
        if days.isEmpty {
            for i in 0..<7 { rect(NSRect(x: Double(i) * 3.73, y: 20, width: 2.6, height: 2), 1, track) }
            return
        }
        for (i, day) in days.enumerated() {
            let x = Double(i) * step
            let total = max(1.5, (day.used + day.possible) / peak * 20)
            if day.possible > 0.05 {
                rect(NSRect(x: x, y: 22 - total, width: width, height: total), 1, ink.withAlphaComponent(0.28))
            }
            if day.used > 0.05 {
                let h = max(1.5, day.used / peak * 20)
                rect(NSRect(x: x, y: 22 - h, width: width, height: h), 1, day.kind == .today ? kw : ink)
            } else if day.kind == .past {
                rect(NSRect(x: x, y: 20.5, width: width, height: 1.5), 0.75, ink)
            }
        }
    }

    /// Sablier : le haut contient le quota restant, le bas ce qui est utilisé.
    func hourglass(_ used: Double) {
        let u = used / 100
        let top = 8.5 * (1 - u).squareRoot()
        if top > 0.3 {
            let half = 6 * top / 8.5
            kw.setFill()
            polygon([CGPoint(x: 10, y: 12), CGPoint(x: 10 - half, y: 12 - top), CGPoint(x: 10 + half, y: 12 - top)]).fill()
        }
        let bottom = 8.5 * (1 - (1 - u).squareRoot())
        if bottom > 0.3 {
            let half = 6 * (8.5 - bottom) / 8.5
            kw.setFill()
            polygon([
                CGPoint(x: 4, y: 20.5), CGPoint(x: 16, y: 20.5),
                CGPoint(x: 10 + half, y: 20.5 - bottom), CGPoint(x: 10 - half, y: 20.5 - bottom),
            ]).fill()
        }
        for glass in [
            polygon([CGPoint(x: 4, y: 3.5), CGPoint(x: 16, y: 3.5), CGPoint(x: 10, y: 12)]),
            polygon([CGPoint(x: 10, y: 12), CGPoint(x: 16, y: 20.5), CGPoint(x: 4, y: 20.5)]),
        ] {
            glass.lineWidth = 1.4
            glass.lineJoinStyle = .round
            ink.setStroke()
            glass.stroke()
        }
        line(CGPoint(x: 3, y: 2.6), CGPoint(x: 17, y: 2.6), ink, 1.6)
        line(CGPoint(x: 3, y: 21.4), CGPoint(x: 17, y: 21.4), ink, 1.6)
    }

    /// Lune : pleine quand le quota est plein, elle décroît avec l'usage.
    func moon(_ used: Double) {
        let c = CGPoint(x: 12, y: 12)
        let r = 9.5
        arc(c, r, 0, 360, ink.withAlphaComponent(0.4), 1.3)
        let lit = 1 - used / 100
        guard lit > 0.005 else { return }
        if lit > 0.995 {
            dot(c, r, kw)
            return
        }
        let path = NSBezierPath()
        for i in 0...40 {
            let p = Pen.pt(c, 180 * Double(i) / 40, r)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        // Terminateur : une demi-ellipse, bombée à gauche quand la lune est plus qu'à moitié éclairée.
        let rx = r * abs(2 * lit - 1)
        let side: Double = lit > 0.5 ? -1 : 1
        for i in 1...40 {
            let phi = Double.pi * Double(i) / 40
            path.line(to: CGPoint(x: c.x + side * rx * sin(phi), y: c.y + r * cos(phi)))
        }
        path.close()
        kw.setFill()
        path.fill()
    }

    /// Pile : le restant, avec une encoche là où il devrait être au rythme régulier.
    func battery(_ used: Double, _ elapsed: Double?) {
        let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 6.5, width: 23, height: 11), xRadius: 3.2, yRadius: 3.2)
        body.lineWidth = 1.4
        ink.setStroke()
        body.stroke()
        rect(NSRect(x: 25.6, y: 10, width: 2, height: 4), 1, ink.withAlphaComponent(0.6))
        let left = 1 - used / 100
        if left > 0.02 { rect(NSRect(x: 3.2, y: 8.7, width: 18.6 * left, height: 6.6), 1.4, kw) }
        if let elapsed {
            let x = 3.2 + 18.6 * (1 - elapsed / 100)
            line(CGPoint(x: x, y: 2.6), CGPoint(x: x, y: 5), ink, 1.5)
        }
    }

    /// Segments : dix crans, un point sous le cran du rythme.
    func segments(_ w: Double, _ t: Double?) {
        let n = Int((w / 10).rounded())
        for i in 0..<10 {
            rect(NSRect(x: CGFloat(i) * 2.98, y: 5, width: 2.2, height: 12), 1.1, i < n ? kw : track)
        }
        if let t {
            let column = min(9, Int(t / 10))
            dot(CGPoint(x: CGFloat(column) * 2.98 + 1.1, y: 20.6), 1.2, ink)
        }
    }

    /// Anneau chiffré : le pourcentage au centre de l'anneau.
    func ringNumber(_ w: Double) {
        let c = CGPoint(x: 12, y: 12)
        arc(c, 10, 0, 360, track, 2.3)
        if w > 0.5 { arc(c, 10, 0, 3.6 * w, kw, 2.3) }
        let n = Int(w.rounded())
        text("\(n)", x: 12, baseline: n >= 100 ? 14.8 : 15.4, size: n >= 100 ? 7.4 : 9.5, ink, centered: true)
    }
}

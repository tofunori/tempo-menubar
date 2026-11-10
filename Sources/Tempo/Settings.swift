import Foundation

enum StyleGroup: String, CaseIterable, Identifiable {
    case dual, single, classic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dual: return "Hebdo et modèle dans la même icône"
        case .single: return "Une valeur"
        case .classic: return "Classiques"
        }
    }
}

enum IconStyle: String, CaseIterable, Identifiable {
    // Deux valeurs dans le même dessin
    case dial, parens, arcs, duo, matrix, lines, monogram, book
    // Une valeur
    case metronome, week, hourglass, moon, battery, segments, ringNumber
    // Classiques : une ou deux valeurs selon le réglage « Donnée »
    case ring, gauge, bar, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dial: return "Montre"
        case .parens: return "Parenthèses"
        case .arcs: return "Arc double"
        case .duo: return "Duo"
        case .matrix: return "Matrice"
        case .lines: return "Deux lignes"
        case .monogram: return "Monogramme"
        case .book: return "Livre"
        case .metronome: return "Métronome"
        case .week: return "Semaine"
        case .hourglass: return "Sablier"
        case .moon: return "Lune"
        case .battery: return "Pile"
        case .segments: return "Segments"
        case .ringNumber: return "Anneau chiffré"
        case .ring: return "Anneau"
        case .gauge: return "Cadran"
        case .bar: return "Barre"
        case .none: return "Aucune"
        }
    }

    var group: StyleGroup {
        switch self {
        case .dial, .parens, .arcs, .duo, .matrix, .lines, .monogram, .book: return .dual
        case .metronome, .week, .hourglass, .moon, .battery, .segments, .ringNumber: return .single
        case .ring, .gauge, .bar, .none: return .classic
        }
    }

    var isDual: Bool { group == .dual }
}

enum Metric: String, CaseIterable, Identifiable {
    case both, weekly, model
    var id: String { rawValue }
}

enum BarText: String, CaseIterable, Identifiable {
    case none, percent, percentDelta, delta, forecast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Aucun"
        case .percent: return "Pourcentage"
        case .percentDelta: return "Pourcentage et écart"
        case .delta: return "Écart au rythme"
        case .forecast: return "Prévision d'épuisement"
        }
    }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case mono, thresholds, gradient, pace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mono: return "Monochrome"
        case .thresholds: return "Seuils"
        case .gradient: return "Dégradé"
        case .pace: return "Cadence"
        }
    }
}

/// Comment colorer la partie du modèle suivi (Fable).
enum ModelColorMode: String, CaseIterable, Identifiable {
    case none, fixed, usage
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Comme le texte"
        case .fixed: return "Couleur fixe"
        case .usage: return "Selon son usage"
        }
    }
}

/// Une couleur sRGB, composantes de 0 à 1.
struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init?(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return nil }
        self.init(
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        let t = min(max(t, 0), 1)
        return RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }
}

/// Les trois couleurs qui suivent l'épuisement du quota, et les seuils où elles changent.
struct Palette: Equatable {
    var low = RGB(hex: "34C759")!
    var mid = RGB(hex: "FF9500")!
    var high = RGB(hex: "FF3B30")!
    /// Pourcentage utilisé où la couleur du milieu arrive.
    var warnAt = 60.0
    /// Pourcentage utilisé où la couleur de fin arrive.
    var dangerAt = 85.0

    struct Preset: Identifiable {
        let name: String
        let low: String
        let mid: String
        let high: String
        var id: String { name }
    }

    static let presets = [
        Preset(name: "Classique", low: "34C759", mid: "FF9500", high: "FF3B30"),
        Preset(name: "Braise", low: "FFD60A", mid: "FF9F0A", high: "FF453A"),
        Preset(name: "Océan", low: "5AC8FA", mid: "5E5CE6", high: "FF375F"),
        Preset(name: "Aurore", low: "30D158", mid: "64D2FF", high: "BF5AF2"),
    ]

    /// Couleur pour un pourcentage utilisé : par paliers, ou fondue d'une couleur à l'autre.
    func color(forUsage percent: Double, gradient: Bool) -> RGB {
        let warn = min(warnAt, dangerAt - 1)
        if !gradient {
            return percent >= dangerAt ? high : percent >= warn ? mid : low
        }
        if percent <= 0 { return low }
        if percent < warn { return low.mixed(with: mid, percent / max(warn, 1)) }
        if percent < dangerAt { return mid.mixed(with: high, (percent - warn) / max(dangerAt - warn, 1)) }
        return high
    }

    func color(for status: PaceStatus) -> RGB {
        switch status {
        case .onTrack: return low
        case .tight: return mid
        case .over: return high
        }
    }
}

/// Tout ce qui décide de l'apparence dans la barre de menus.
struct DisplayOptions: Equatable {
    var iconStyle: IconStyle = .dial
    var metric: Metric = .both
    var barText: BarText = .percent
    var colorMode: ColorMode = .mono
    var palette = Palette()
    /// Donne au modèle suivi (Fable) sa propre couleur, pour le distinguer de l'hebdo.
    var modelColorMode: ModelColorMode = .fixed
    var modelFixed = RGB(hex: "8A80E8")!
    var showPace = true
    var showRemaining = false
}

@MainActor
final class Settings: ObservableObject {
    @Published var iconStyle: IconStyle { didSet { defaults.set(iconStyle.rawValue, forKey: "iconStyle") } }
    @Published var metric: Metric { didSet { defaults.set(metric.rawValue, forKey: "metric") } }
    @Published var barText: BarText { didSet { defaults.set(barText.rawValue, forKey: "barText") } }
    @Published var colorMode: ColorMode { didSet { defaults.set(colorMode.rawValue, forKey: "colorMode") } }
    @Published var modelColorMode: ModelColorMode { didSet { defaults.set(modelColorMode.rawValue, forKey: "modelColorMode") } }
    @Published var modelFixed: RGB { didSet { defaults.set(modelFixed.hex, forKey: "modelFixed") } }
    @Published var palette: Palette {
        didSet {
            defaults.set(palette.low.hex, forKey: "paletteLow")
            defaults.set(palette.mid.hex, forKey: "paletteMid")
            defaults.set(palette.high.hex, forKey: "paletteHigh")
            defaults.set(palette.warnAt, forKey: "paletteWarnAt")
            defaults.set(palette.dangerAt, forKey: "paletteDangerAt")
        }
    }
    @Published var showPace: Bool { didSet { defaults.set(showPace, forKey: "showPace") } }
    @Published var showRemaining: Bool { didSet { defaults.set(showRemaining, forKey: "showRemaining") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        let base = DisplayOptions()
        iconStyle = d.string(forKey: "iconStyle").flatMap(IconStyle.init(rawValue:)) ?? base.iconStyle
        metric = d.string(forKey: "metric").flatMap(Metric.init(rawValue:)) ?? base.metric
        barText = d.string(forKey: "barText").flatMap(BarText.init(rawValue:)) ?? base.barText
        colorMode = d.string(forKey: "colorMode").flatMap(ColorMode.init(rawValue:)) ?? base.colorMode
        if let saved = d.string(forKey: "modelColorMode").flatMap(ModelColorMode.init(rawValue:)) {
            modelColorMode = saved
        } else if let old = d.object(forKey: "modelColor") as? Bool {
            // Ancien réglage « Fable en couleur », oui ou non.
            modelColorMode = old ? .fixed : .none
        } else {
            modelColorMode = base.modelColorMode
        }
        modelFixed = d.string(forKey: "modelFixed").flatMap(RGB.init(hex:)) ?? base.modelFixed

        var colors = Palette()
        if let c = d.string(forKey: "paletteLow").flatMap(RGB.init(hex:)) { colors.low = c }
        if let c = d.string(forKey: "paletteMid").flatMap(RGB.init(hex:)) { colors.mid = c }
        if let c = d.string(forKey: "paletteHigh").flatMap(RGB.init(hex:)) { colors.high = c }
        if let v = d.object(forKey: "paletteWarnAt") as? Double { colors.warnAt = v }
        if let v = d.object(forKey: "paletteDangerAt") as? Double { colors.dangerAt = v }
        palette = colors

        showPace = d.object(forKey: "showPace") as? Bool ?? base.showPace
        showRemaining = d.object(forKey: "showRemaining") as? Bool ?? base.showRemaining
        let minutes = d.integer(forKey: "refreshMinutes")
        // Le service refuse les demandes trop rapprochées : jamais plus souvent qu'aux 5 minutes.
        refreshMinutes = minutes >= 5 ? minutes : 15
    }

    var options: DisplayOptions {
        DisplayOptions(
            iconStyle: iconStyle, metric: metric, barText: barText, colorMode: colorMode,
            palette: palette, modelColorMode: modelColorMode, modelFixed: modelFixed,
            showPace: showPace, showRemaining: showRemaining
        )
    }
}

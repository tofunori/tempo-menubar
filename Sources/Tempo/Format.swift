import Foundation

enum Fmt {
    /// La région du système si elle parle la langue choisie, sinon une région par défaut.
    static var locale: Locale {
        let french = Lang.isFrench
        let current = Locale.current
        if (current.language.languageCode?.identifier == "fr") == french { return current }
        return Locale(identifier: french ? "fr_CA" : "en_US")
    }

    /// « 56 % » en français, « 56% » en anglais.
    static func pct(_ value: Double) -> String {
        let n = Int(value.rounded())
        return Lang.isFrench ? "\(n) %" : "\(n)%"
    }

    static func points(_ value: Double) -> String {
        let n = Int(abs(value).rounded())
        return "\(n) \(n == 1 ? "pt" : "pts")"
    }

    /// « 2 j 7 h », « 3 h 12 min », « 8 min » ; en anglais « 2d 7h », « 3h 12m », « 8 min ».
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if Lang.isFrench {
            if d > 0 { return "\(d) j \(h) h" }
            if h > 0 { return "\(h) h \(m) min" }
        } else {
            if d > 0 { return "\(d)d \(h)h" }
            if h > 0 { return "\(h)h \(m)m" }
        }
        return "\(max(m, 1)) min"
    }

    /// « jeu. 14 h » : assez court pour la barre de menus.
    static func dayHour(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated).hour())
    }

    /// « jeu. 14 h 05 ».
    static func dayTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated).hour().minute())
    }

    /// « jeu. »
    static func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated))
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return tr("à l'instant", "just now") }
        return tr("il y a \(duration(s))", "\(duration(s)) ago")
    }
}

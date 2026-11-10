import Foundation

enum Fmt {
    static let locale = Locale(identifier: "fr_CA")

    static func pct(_ value: Double) -> String { "\(Int(value.rounded())) %" }

    static func points(_ value: Double) -> String {
        let n = Int(abs(value).rounded())
        return "\(n) \(n == 1 ? "pt" : "pts")"
    }

    /// « 2 j 7 h », « 3 h 12 min », « 8 min ».
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) j \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
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
        return s < 60 ? "à l'instant" : "il y a \(duration(s))"
    }
}

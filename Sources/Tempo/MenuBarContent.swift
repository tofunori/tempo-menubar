import AppKit

/// Ce qu'une icône de la barre de menus affiche pour des données et des réglages donnés.
struct MenuBarContent {
    let image: NSImage?
    let title: NSAttributedString
    let tooltip: String

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)

    /// - Parameter zoom: 1 = taille de la barre de menus ; plus grand pour les aperçus des réglages.
    static func make(data: UsageData, options: DisplayOptions, now: Date, zoom: CGFloat = 1) -> MenuBarContent {
        let style = options.iconStyle

        // Les deux valeurs de l'icône. La deuxième est ignorée si elle répète la première.
        let first = data.insight(options.primary, now: now)
        let secondKey = options.secondary == options.primary ? nil : options.secondary
        let second = secondKey.flatMap { data.insight($0, now: now) }

        guard let first else {
            // Pas encore de données pour la valeur choisie : icône vide.
            let input = IconInput(primary: 0, secondary: style.isDual && secondKey != nil ? 0 : nil, elapsed: nil)
            let image = IconRenderer.image(style: style, input: input, zoom: zoom)
            return MenuBarContent(
                image: image,
                title: NSAttributedString(string: image == nil ? "–" : "", attributes: [.font: font]),
                tooltip: tr("Tempo : en attente des données", "Tempo: waiting for data")
            )
        }

        // Le dessin montre la deuxième valeur seulement pour les styles doubles et les classiques.
        let drawsSecond = second != nil && style.group != .single
        let secondTint: NSColor? = second.flatMap { Tint.model(options, $0) }
        let colored = options.colorMode != .mono || (secondTint != nil && drawsSecond)

        let input = IconInput(
            primary: first.limit.percent,
            secondary: second?.limit.percent,
            elapsed: first.forecast?.elapsedFraction,
            showPace: options.showPace,
            remaining: options.showRemaining,
            primaryTint: Tint.primary(options, first),
            secondaryTint: secondTint,
            days: style == .week ? Pace.dailyUsage(for: first, samples: data.samples, now: now) : [],
            template: !colored
        )
        let image = IconRenderer.image(style: style, input: input, zoom: zoom)

        var mode = options.barText
        if image == nil, mode == .none { mode = .percent }
        // « Deux lignes » porte déjà ses chiffres.
        if style == .lines, mode == .percent { mode = .none }

        func shown(_ insight: LimitInsight) -> Double {
            options.showRemaining ? 100 - insight.limit.percent : insight.limit.percent
        }
        func deltaText(_ forecast: Forecast, arrows: Bool) -> String {
            let n = Int(forecast.paceDelta.rounded())
            if arrows { return (n > 0 ? "↑" : "↓") + "\(abs(n))" }
            return n == 0 ? "±0 pt" : (n > 0 ? "+" : "−") + Fmt.points(Double(n))
        }

        let title = NSMutableAttributedString()
        func add(_ string: String, color: NSColor? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let color { attributes[.foregroundColor] = color }
            title.append(NSAttributedString(string: string, attributes: attributes))
        }

        switch mode {
        case .none:
            break
        case .percent, .percentDelta:
            add(Fmt.pct(shown(first)))
            if mode == .percentDelta, let forecast = first.forecast {
                add(" " + deltaText(forecast, arrows: true))
            }
            if let second, let secondKey {
                add(" · ")
                add(secondKey.tag(modelName: data.modelName) + " " + Fmt.pct(shown(second)), color: secondTint)
            }
        case .delta:
            add(first.forecast.map { deltaText($0, arrows: false) } ?? "–")
        case .forecast:
            if let date = first.forecast?.exhaustionDate {
                add(Fmt.dayHour(date))
            } else if let end = first.forecast?.projectedEnd {
                add("→ " + Fmt.pct(end))
            } else {
                add("–")
            }
        }

        return MenuBarContent(image: image, title: title, tooltip: tooltip(data))
    }

    /// Toutes les limites connues, un service par bloc.
    private static func tooltip(_ data: UsageData) -> String {
        Provider.allCases.compactMap { provider -> String? in
            guard let snapshot = data.snapshot(provider), !snapshot.limits.isEmpty else { return nil }
            let lines = snapshot.limits.map { "  \($0.label) \(Fmt.pct($0.percent))" }
            return ([provider.label] + lines).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

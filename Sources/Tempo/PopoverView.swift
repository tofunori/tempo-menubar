import SwiftUI

// La palette des réglages descend dans tout le panneau par l'environnement.
private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette()
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension Palette {
    func swiftColor(_ status: PaceStatus) -> Color {
        let c = color(for: status)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }
}

/// Le panneau, branché sur les données vivantes et rafraîchi chaque minute.
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: Settings
    /// La valeur principale de l'icône sur laquelle on a cliqué.
    let focus: MetricKey
    let openSettings: () -> Void
    @AppStorage("chartView") private var chartView = "cum"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            PanelContent(
                data: store.data, focus: focus, state: store.state,
                now: context.date, chartView: $chartView,
                onRefresh: { Task { await store.refresh() } },
                onSettings: openSettings
            )
            .environment(\.palette, settings.palette)
        }
        .padding(16)
        .frame(width: 348)
    }
}

/// Le contenu du panneau, sans dépendance à l'app : on peut le dessiner hors écran pour le vérifier.
struct PanelContent: View {
    let data: UsageData
    let focus: MetricKey
    let state: UsageStore.State
    let now: Date
    @Binding var chartView: String
    let onRefresh: () -> Void
    let onSettings: () -> Void
    /// Pour les images hors écran : remplace les contrôles AppKit (boutons, sélecteur),
    /// qui ne se dessinent pas hors d'une fenêtre, par des équivalents SwiftUI inertes.
    var decorative = false
    @Environment(\.palette) private var palette

    /// Vrai quand les deux services ont des données : on nomme alors chaque bloc.
    private var showsBoth: Bool { data.claude != nil && data.chatgpt != nil }

    /// La valeur mise en avant : celle de l'icône cliquée si elle a une prévision, sinon la première qui en a une.
    private var hero: LimitInsight? {
        if let chosen = data.insight(focus, now: now), chosen.forecast != nil { return chosen }
        return MetricKey.allCases.lazy
            .compactMap { data.insight($0, now: now) }
            .first { $0.forecast != nil }
    }

    /// Le graphique demande une fenêtre de plusieurs jours.
    private func charted(_ hero: LimitInsight?) -> LimitInsight? {
        if let hero, hero.limit.isWeekly { return hero }
        return [MetricKey.claudeWeekly, .chatgptWeekly].lazy
            .compactMap { data.insight($0, now: now) }
            .first { $0.forecast != nil }
    }

    var body: some View {
        let hero = self.hero
        let chart = charted(hero)

        VStack(alignment: .leading, spacing: 0) {
            header(hero)

            if let hero, let forecast = hero.forecast {
                VStack(alignment: .leading, spacing: 2) {
                    if showsBoth, let key = hero.limit.key {
                        Text(key.label(modelName: data.modelName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HeroText(insight: hero, forecast: forecast, now: now)
                    if hero.limit.isWeekly, let recent = hero.recent {
                        RecentLine(insight: hero, recent: recent)
                            .padding(.top, 8)
                    }
                }
                .padding(.top, 14)
            }

            ForEach(Provider.allCases) { provider in
                let rows = data.insights(provider, now: now)
                if !rows.isEmpty {
                    section(provider, rows, first: provider == Provider.allCases.first { data.snapshot($0) != nil })
                }
            }

            if let chart {
                Divider().padding(.top, 16)
                HStack(spacing: 6) {
                    Text(tr("Ta semaine", "Your week")).font(.callout).fontWeight(.medium)
                    if showsBoth, let key = chart.limit.key {
                        Text(key.label(modelName: data.modelName)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if decorative {
                        HStack(spacing: 0) {
                            ForEach([("cum", tr("Cumul", "Cumulative")), ("day", tr("Par jour", "Per day"))], id: \.0) { tag, label in
                                Text(label)
                                    .font(.system(size: 11, weight: chartView == tag ? .medium : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(chartView == tag ? Color.primary.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        .padding(2)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    } else {
                        Picker(tr("Vue", "View"), selection: $chartView) {
                            Text(tr("Cumul", "Cumulative")).tag("cum")
                            Text(tr("Par jour", "Per day")).tag("day")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                .padding(.top, 12)

                if chartView == "day" {
                    DayChart(insight: chart, samples: data.samples, now: now).padding(.top, 8)
                } else {
                    CumulativeChart(insight: chart, samples: data.samples, now: now).padding(.top, 8)
                }
            }

            if data.claude == nil, data.chatgpt == nil, state == .loading || state == .idle {
                Text(tr("Lecture de l'usage…", "Reading usage…")).foregroundStyle(.secondary).padding(.top, 12)
            }

            if let rows = data.claude?.breakdown, !rows.isEmpty {
                Text(rows.map { "\($0.name) \(Fmt.pct($0.percent))" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }

            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Divider().padding(.top, 12)
            HStack {
                if decorative { fakeButton(tr("Réglages…", "Settings…")) } else { Button(tr("Réglages…", "Settings…"), action: onSettings) }
                Spacer()
                if let snapshot = data.claude {
                    Text(tr("Relevé \(Fmt.ago(snapshot.fetchedAt, now: now))", "Updated \(Fmt.ago(snapshot.fetchedAt, now: now))"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if decorative { fakeButton(tr("Quitter", "Quit")) } else { Button(tr("Quitter", "Quit")) { NSApp.terminate(nil) } }
            }
            .controlSize(.small)
            .padding(.top, 10)
        }
    }

    /// Les limites d'un service. Le nom du service n'apparaît que s'il y en a deux.
    private func section(_ provider: Provider, _ rows: [LimitInsight], first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBoth {
                HStack {
                    Text(provider.label)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Les chiffres de Codex viennent de sa dernière utilisation sur ce Mac.
                    if provider == .chatgpt, let read = data.chatgpt?.fetchedAt, now.timeIntervalSince(read) > 3600 {
                        Text(tr("relevé \(Fmt.ago(read, now: now))", "read \(Fmt.ago(read, now: now))"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.bottom, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.limit.id) { index, insight in
                CadenceBar(insight: insight, showPaceLabel: first && index == 0)
                    .padding(.top, index == 0 ? 0 : 14)
            }
        }
        .padding(.top, 16)
    }

    private func header(_ hero: LimitInsight?) -> some View {
        HStack(spacing: 8) {
            Text("Tempo").font(.headline)
            if let hero, hero.forecast != nil {
                Text(hero.status.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(palette.swiftColor(hero.status).opacity(0.18), in: Capsule())
                    .foregroundStyle(palette.swiftColor(hero.status))
            }
            Spacer()
            if let reset = hero?.limit.resetsAt {
                Text(tr("réinit. dans \(Fmt.duration(reset.timeIntervalSince(now)))", "resets in \(Fmt.duration(reset.timeIntervalSince(now)))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if decorative {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state == .loading)
                .help(tr("Actualiser", "Refresh"))
            }
        }
    }

    private func fakeButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - La réponse d'abord

/// La prévision au rythme des dernières heures, à côté de celle au rythme moyen.
/// Discrète quand les deux s'accordent, en couleur quand elles divergent.
private struct RecentLine: View {
    let insight: LimitInsight
    let recent: RecentRate
    @Environment(\.palette) private var palette

    private var hours: Int { max(1, Int(recent.spanHours.rounded())) }
    private var span: String { tr("\(hours) h", "\(hours)h") }

    var body: some View {
        let diverges = insight.recentDiverges
        let color: Color = diverges
            ? palette.swiftColor(PaceStatus(projectedEnd: recent.projectedEnd ?? 0))
            : .secondary
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, diverges ? 8 : 0)
        .padding(.vertical, diverges ? 5 : 0)
        .background(diverges ? color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        guard insight.recentDiverges, let divergence = insight.recentDivergence else { return "clock.arrow.circlepath" }
        return divergence > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    private var outcome: String {
        if let date = recent.exhaustionDate {
            return tr("À ce rythme, quota épuisé \(Fmt.dayTime(date)).", "At this rate, empty \(Fmt.dayTime(date)).")
        }
        if let end = recent.projectedEnd {
            return tr("À ce rythme, fin à \(Fmt.pct(end)).", "At this rate, you'll end at \(Fmt.pct(end)).")
        }
        return ""
    }

    private var message: String {
        let gained = "+\(Fmt.points(recent.gained))"
        guard insight.recentDiverges, let divergence = insight.recentDivergence else {
            return tr("Dernières \(span) : \(gained), même tendance.", "Last \(span): \(gained), same trend.")
        }
        if divergence > 0 {
            return tr("Tu accélères : \(gained) sur les dernières \(span). ", "You're speeding up: \(gained) over the last \(span). ") + outcome
        }
        return tr("Tu ralentis : \(gained) sur les dernières \(span). ", "You're slowing down: \(gained) over the last \(span). ") + outcome
    }
}

private struct HeroText: View {
    let insight: LimitInsight
    let forecast: Forecast
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline)
                .font(.system(size: 19, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        if insight.limit.percent >= 100 { return tr("Quota épuisé", "Quota used up") }
        if let date = forecast.exhaustionDate { return tr("Quota épuisé \(Fmt.dayTime(date))", "Quota runs out \(Fmt.dayTime(date))") }
        if let end = forecast.projectedEnd {
            return insight.limit.isWeekly
                ? tr("Tu finis la semaine à \(Fmt.pct(end))", "You'll finish the week at \(Fmt.pct(end))")
                : tr("Tu finis la fenêtre à \(Fmt.pct(end))", "You'll finish the window at \(Fmt.pct(end))")
        }
        return tr("Trop tôt pour prévoir", "Too early to forecast")
    }

    private var detail: String {
        let left = 100 - insight.limit.percent
        let remaining = forecast.reset.timeIntervalSince(now)
        if insight.limit.percent >= 100 {
            return tr("Retour \(Fmt.dayTime(forecast.reset)).", "Back \(Fmt.dayTime(forecast.reset)).")
        }
        let budget = remaining < 86400
            ? tr("Il reste \(Fmt.points(left)) pour les \(Fmt.duration(remaining)) restantes.", "\(Fmt.points(left)) left for the remaining \(Fmt.duration(remaining)).")
            : nil
        if forecast.exhaustionDate != nil {
            return tr("\(Fmt.points(forecast.paceDelta)) au-dessus du rythme. ", "\(Fmt.points(forecast.paceDelta)) over pace. ")
                + (budget ?? tr("Limite-toi à \(Fmt.points(forecast.dailyBudget)) par jour pour tenir.", "Keep to \(Fmt.points(forecast.dailyBudget)) a day to make it."))
        }
        if forecast.projectedEnd != nil {
            return tr("\(Fmt.points(forecast.paceDelta)) de marge. ", "\(Fmt.points(forecast.paceDelta)) of headroom. ")
                + (budget ?? tr("Tu peux utiliser \(Fmt.points(forecast.dailyBudget)) par jour.", "You can use \(Fmt.points(forecast.dailyBudget)) a day."))
        }
        return insight.limit.isWeekly
            ? tr("La semaine vient de commencer.", "The week has just started.")
            : tr("La fenêtre vient de commencer.", "The window has just started.")
    }
}

// MARK: - Une barre qui montre aussi la cadence

/// Partie pleine : utilisé. Partie pâle : où on sera à la réinitialisation. Trait : rythme régulier.
private struct CadenceBar: View {
    let insight: LimitInsight
    let showPaceLabel: Bool
    @Environment(\.palette) private var palette

    private var color: Color { insight.forecast == nil ? .primary : palette.swiftColor(insight.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(insight.limit.label).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.pct(insight.limit.percent)).fontWeight(.medium).monospacedDigit()
            }
            .font(.callout)

            GeometryReader { geo in
                let width = geo.size.width
                let used = min(max(insight.limit.percent / 100, 0), 1)
                let projected = min(max((insight.forecast?.projectedEnd ?? insight.limit.percent) / 100, used), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color.opacity(0.3))
                        .frame(width: projected > 0 ? max(projected * width, 10) : 0)
                    Capsule().fill(color)
                        .frame(width: used > 0 ? max(used * width, 10) : 0)
                    if let pace = insight.forecast?.elapsedFraction {
                        RoundedRectangle(cornerRadius: 1).fill(.primary)
                            .frame(width: 2, height: 18)
                            .offset(x: min(max(pace, 0), 1) * width - 1)
                    }
                }
            }
            .frame(height: 10)
            .padding(.top, 9)

            if showPaceLabel, let pace = insight.forecast?.elapsedFraction {
                GeometryReader { geo in
                    Text(tr("rythme", "pace"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: min(max(pace * geo.size.width, 20), geo.size.width - 20), y: 7)
                }
                .frame(height: 14)
                .padding(.top, 7)
            } else {
                Spacer().frame(height: 8)
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(insight.forecast == nil ? Color.secondary : color)
            }
        }
    }

    private var message: String? {
        guard let forecast = insight.forecast else {
            return insight.limit.resetsAt == nil ? tr("Aucune fenêtre en cours", "No active window") : nil
        }
        if insight.limit.percent >= 100 {
            return tr("Quota épuisé · retour \(Fmt.dayTime(forecast.reset))", "Quota used up · back \(Fmt.dayTime(forecast.reset))")
        }
        if let date = forecast.exhaustionDate {
            return tr("\(Fmt.points(forecast.paceDelta)) de trop · à sec \(Fmt.dayTime(date))", "\(Fmt.points(forecast.paceDelta)) over · empty \(Fmt.dayTime(date))")
        }
        if let end = forecast.projectedEnd {
            return tr("\(Fmt.points(forecast.paceDelta)) de marge · fin prévue \(Fmt.pct(end))", "\(Fmt.points(forecast.paceDelta)) of headroom · ends at \(Fmt.pct(end))")
        }
        return nil
    }
}

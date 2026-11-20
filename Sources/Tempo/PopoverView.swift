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

// MARK: - Règles pures de mise en page (repli, micro-barre, limites inactives)

enum PanelLayout {
    /// Vrai pour une limite à 0 % dont la fenêtre n'a pas encore démarré (aucune prévision exploitable).
    static func isInactiveZero(_ insight: LimitInsight) -> Bool {
        insight.limit.percent <= 0 && insight.forecast?.projectedEnd == nil
    }

    /// Sépare les limites actives des limites à 0 % inactives.
    /// Si tout est inactif, on garde les barres normales pour ne pas vider la section.
    static func partitionLimits(_ rows: [LimitInsight]) -> (active: [LimitInsight], inactiveZero: [LimitInsight]) {
        let active = rows.filter { !isInactiveZero($0) }
        let inactive = rows.filter { isInactiveZero($0) }
        guard !active.isEmpty else { return (rows, []) }
        return (active, inactive)
    }

    /// Résumé sur une ligne pour les limites inactives d'un même service (ex. « Claude/GPT · 5 h · Hebdo »).
    static func inactiveSummaryLabel(for rows: [LimitInsight]) -> String {
        let modelNames: [String?] = rows.map { insight in
            switch insight.limit.kind {
            case .sessionModel(let name), .weeklyModel(let name): return name
            default: return nil
            }
        }
        if rows.count > 1, let first = modelNames.first ?? nil, modelNames.allSatisfy({ $0 == first }) {
            let windows = rows.map { $0.limit.isWeekly ? tr("Hebdo", "Weekly") : "5 h" }
            return "\(first) · \(windows.joined(separator: " · "))"
        }
        return rows.map(\.limit.label).joined(separator: " · ")
    }

    /// Limite représentative affichée en micro-barre quand un service est replié.
    /// Privilégie la limite hebdomadaire globale active, puis l'hebdomadaire la plus utilisée, puis la plus active.
    static func primarySummary(for provider: Provider, rows: [LimitInsight]) -> LimitInsight? {
        guard !rows.isEmpty else { return nil }
        let active = rows.filter { !isInactiveZero($0) }
        if let weeklyAll = active.first(where: { $0.limit.kind == .weeklyAll }) {
            return weeklyAll
        }
        let activeWeekly = active.filter { $0.limit.isWeekly }
        if let topWeekly = activeWeekly.max(by: { $0.limit.percent < $1.limit.percent }) {
            return topWeekly
        }
        if let topActive = active.max(by: { $0.limit.percent < $1.limit.percent }) {
            return topActive
        }
        return rows.first(where: { $0.limit.isWeekly }) ?? rows.first
    }

    /// Prévision courte placée directement sur la ligne de titre d'une barre (« → 32 % » ou « → mar. 10 h 20 »).
    static func inlineForecast(for insight: LimitInsight) -> String? {
        guard let forecast = insight.forecast else {
            return insight.limit.resetsAt == nil ? tr("inactif", "inactive") : nil
        }
        if insight.limit.percent >= 100 {
            return tr("épuisé", "used up")
        }
        if let date = forecast.exhaustionDate {
            return "→ \(Fmt.dayTime(date))"
        }
        if let end = forecast.projectedEnd {
            return "→ \(Fmt.pct(end))"
        }
        return nil
    }

    /// Valeur mise en avant lorsqu'on sélectionne un service depuis le panneau.
    static func preferredFocus(for provider: Provider, in data: UsageData, now: Date) -> MetricKey? {
        let rows = data.insights(provider, now: now)
        if let weekly = rows.first(where: { $0.limit.isWeekly && $0.forecast != nil })?.limit.key {
            return weekly
        }
        if let anyForecast = rows.first(where: { $0.forecast != nil })?.limit.key {
            return anyForecast
        }
        return rows.compactMap(\.limit.key).first
    }

    /// Relevé dont l'âge est affiché au pied du panneau : celui du service affiché en tête, sinon le premier disponible.
    static func footerSnapshot(for hero: LimitInsight?, in data: UsageData) -> (provider: Provider, snapshot: UsageSnapshot)? {
        if let provider = hero?.limit.provider, let snap = data.snapshot(provider) {
            return (provider, snap)
        }
        for provider in [Provider.claude, .antigravity, .chatgpt] {
            if let snap = data.snapshot(provider) { return (provider, snap) }
        }
        return nil
    }
}

// MARK: - Mesure des zones pour dimensionner le ScrollView au plus juste dans NSPopover

private struct TopHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MiddleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct BottomHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Le panneau, branché sur les données vivantes et rafraîchi chaque minute.
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: Settings
    /// La valeur principale de l'icône sur laquelle on a cliqué.
    let focus: MetricKey
    /// Hauteur maximale disponible à l'écran pour éviter que macOS ne rogne le haut du panneau.
    var maxHeight: CGFloat? = nil
    let openSettings: () -> Void
    @AppStorage("chartView") private var chartView = "cum"
    @State private var overrideFocus: MetricKey? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let activeFocus = overrideFocus ?? focus
            PanelContent(
                data: store.data, focus: activeFocus, state: store.state,
                isRefreshing: store.isRefreshing || store.state == .loading,
                now: now, chartView: $chartView,
                onRefresh: { Task { await store.refresh() } },
                onSettings: openSettings,
                collapsedProviders: settings.collapsedProviders,
                onToggleProvider: { settings.toggleCollapsed($0) },
                onSelectProvider: { provider in
                    if provider == focus.provider {
                        overrideFocus = nil
                    } else if let key = PanelLayout.preferredFocus(for: provider, in: store.data, now: now) {
                        overrideFocus = key
                    }
                },
                onSelectMetric: { key in
                    overrideFocus = (key == focus) ? nil : key
                },
                maxHeight: maxHeight.map { max(360, $0 - 28) }
            )
            .environment(\.palette, settings.palette)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 348)
    }
}

/// Le contenu du panneau, sans dépendance à l'app : on peut le dessiner hors écran pour le vérifier.
struct PanelContent: View {
    let data: UsageData
    let focus: MetricKey
    let state: UsageStore.State
    var isRefreshing = false
    let now: Date
    @Binding var chartView: String
    let onRefresh: () -> Void
    let onSettings: () -> Void
    var collapsedProviders: Set<Provider> = []
    var onToggleProvider: ((Provider) -> Void)? = nil
    var onSelectProvider: ((Provider) -> Void)? = nil
    var onSelectMetric: ((MetricKey) -> Void)? = nil
    /// Plafond interne (hors marges extérieures). Nil = rendu à plat sans ScrollView (images hors écran).
    var maxHeight: CGFloat? = nil
    /// Pour les images hors écran : remplace les contrôles AppKit (boutons, sélecteur),
    /// qui ne se dessinent pas hors d'une fenêtre, par des équivalents SwiftUI inertes.
    var decorative = false
    @Environment(\.palette) private var palette

    @State private var topHeight: CGFloat = 0
    @State private var middleHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0

    private var visibleProviders: [Provider] {
        Provider.allCases.filter { !data.insights($0, now: now).isEmpty }
    }

    /// Vrai quand plusieurs services ont des données : on nomme alors chaque bloc.
    private var showsProviders: Bool {
        visibleProviders.count > 1
    }

    /// Vrai quand l'utilisateur peut replier/déplier les blocs de services.
    private var allowsCollapse: Bool {
        showsProviders && (onToggleProvider != nil || !collapsedProviders.isEmpty)
    }

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
        if let provider = hero?.limit.provider {
            let sameProvider = data.insights(provider, now: now).first { $0.limit.isWeekly && $0.forecast != nil }
            if let sameProvider { return sameProvider }
        }
        return [
            MetricKey.claudeWeekly, .chatgptWeekly,
            .antigravityGeminiWeekly, .antigravityClaudeWeekly,
        ].lazy
            .compactMap { data.insight($0, now: now) }
            .first { $0.forecast != nil }
    }

    /// Nombre de services disposant d'une prévision pour basculer la courbe au clic.
    private var forecastableProviderCount: Int {
        visibleProviders.filter { provider in
            data.insights(provider, now: now).contains { $0.forecast != nil }
        }.count
    }

    private func availableMiddleHeight(for cap: CGFloat) -> CGFloat {
        let reservedTop = topHeight > 0 ? topHeight : 108
        let reservedBottom = bottomHeight > 0 ? bottomHeight : 34
        return max(160, cap - reservedTop - reservedBottom)
    }

    var body: some View {
        let hero = self.hero
        let chart = charted(hero)
        let canSwitchChart = showsProviders && onSelectProvider != nil && forecastableProviderCount > 1

        if let maxHeight {
            let available = availableMiddleHeight(for: maxHeight)
            let viewportHeight = middleHeight > 0 ? min(middleHeight, available) : min(420, available)

            VStack(alignment: .leading, spacing: 0) {
                pinnedTop(hero)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { Color.clear.preference(key: TopHeightKey.self, value: $0.size.height) })

                ScrollView(.vertical, showsIndicators: true) {
                    middleBody(hero: hero, chart: chart, canSwitchChart: canSwitchChart)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { Color.clear.preference(key: MiddleHeightKey.self, value: $0.size.height) })
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: viewportHeight)

                pinnedBottom(hero: hero)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { Color.clear.preference(key: BottomHeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(TopHeightKey.self) { h in
                let rounded = ceil(h)
                if abs(topHeight - rounded) > 0.5 { topHeight = rounded }
            }
            .onPreferenceChange(MiddleHeightKey.self) { h in
                let rounded = ceil(h)
                if abs(middleHeight - rounded) > 0.5 { middleHeight = rounded }
            }
            .onPreferenceChange(BottomHeightKey.self) { h in
                let rounded = ceil(h)
                if abs(bottomHeight - rounded) > 0.5 { bottomHeight = rounded }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                pinnedTop(hero)
                middleBody(hero: hero, chart: chart, canSwitchChart: canSwitchChart)
                    .padding(.bottom, 8)
                pinnedBottom(hero: hero)
            }
        }
    }

    // MARK: - En-tête Chiffre-roi (fixe)

    @ViewBuilder
    private func pinnedTop(_ hero: LimitInsight?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let hero {
                    let title = showsProviders
                        ? (hero.limit.key?.label(modelName: data.modelName) ?? hero.limit.label)
                        : "Tempo"
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Tempo").font(.headline)
                }

                Spacer(minLength: 4)

                if let reset = hero?.limit.resetsAt {
                    let duration = Fmt.duration(reset.timeIntervalSince(now))
                    Text(duration)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(tr("Réinitialisation dans \(duration)", "Resets in \(duration)"))
                }

                if decorative {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    RefreshIconButton(isRefreshing: isRefreshing, action: onRefresh)
                }
            }

            if let hero, let forecast = hero.forecast {
                BigNumberHero(insight: hero, forecast: forecast, now: now)
                    .padding(.top, 9)

                if hero.limit.isWeekly, let recent = hero.recent, hero.recentDiverges {
                    Divider()
                        .opacity(0.55)
                        .padding(.top, 10)
                    QuietRecentLine(insight: hero, recent: recent)
                        .padding(.top, 7)
                }
            }

            Divider()
                .opacity(0.75)
                .padding(.top, 12)
        }
    }

    // MARK: - Corps défilable (services + courbe)

    @ViewBuilder
    private func middleBody(
        hero: LimitInsight?,
        chart: LimitInsight?,
        canSwitchChart: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleProviders.enumerated()), id: \.element.id) { index, provider in
                let rows = data.insights(provider, now: now)
                let collapsed = allowsCollapse && collapsedProviders.contains(provider)
                if index > 0 {
                    Divider().opacity(0.5)
                }
                section(
                    provider, rows,
                    heroLimitID: hero?.limit.id,
                    isCollapsed: collapsed,
                    isSelected: hero?.limit.provider == provider,
                    canSwitchChart: canSwitchChart
                )
            }

            if let chart {
                Divider().opacity(0.65)
                HStack(spacing: 6) {
                    Text(tr("Semaine", "Week"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if decorative {
                        HStack(spacing: 0) {
                            ForEach([("cum", tr("Cumul", "Cumulative")), ("day", tr("Par jour", "Per day"))], id: \.0) { tag, label in
                                Text(label)
                                    .font(.system(size: 11, weight: chartView == tag ? .medium : .regular))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(chartView == tag ? Color.primary.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        .padding(2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
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
                .padding(.top, 11)

                if chartView == "day" {
                    DayChart(insight: chart, samples: data.samples, now: now).padding(.top, 6)
                } else {
                    CumulativeChart(insight: chart, samples: data.samples, now: now).padding(.top, 6)
                }
            }

            if visibleProviders.isEmpty, state == .loading || state == .idle {
                Text(tr("Lecture de l'usage…", "Reading usage…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
    }

    // MARK: - Pied de page silencieux (fixe)

    @ViewBuilder
    private func pinnedBottom(hero: LimitInsight?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }

            Divider().opacity(0.75)

            HStack {
                if decorative {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape").font(.system(size: 11))
                        Text(tr("Réglages", "Settings")).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    QuietFooterButton(
                        title: tr("Réglages", "Settings"),
                        systemImage: "gearshape",
                        shortcut: ",",
                        action: onSettings
                    )
                }

                Spacer()

                if let entry = PanelLayout.footerSnapshot(for: hero, in: data) {
                    let ago = Fmt.ago(entry.snapshot.fetchedAt, now: now)
                    Text(ago)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(tr("\(entry.provider.label) · relevé \(ago)", "\(entry.provider.label) · updated \(ago)"))
                }

                Spacer()

                if decorative {
                    Text(tr("Quitter", "Quit"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    QuietFooterButton(
                        title: tr("Quitter", "Quit"),
                        systemImage: nil,
                        shortcut: "q",
                        action: { NSApp.terminate(nil) }
                    )
                }
            }
            .padding(.top, 9)
        }
    }

    // MARK: - Bloc par service (micro-barre si replié, barres fines si déplié)

    private func section(
        _ provider: Provider,
        _ rows: [LimitInsight],
        heroLimitID: String?,
        isCollapsed: Bool,
        isSelected: Bool,
        canSwitchChart: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsProviders {
                if isCollapsed {
                    CollapsedProviderRow(
                        provider: provider,
                        rows: rows,
                        decorative: decorative,
                        onToggle: onToggleProvider.map { toggle in { toggle(provider) } }
                    )
                } else {
                    expandedHeader(provider, rows, isSelected: isSelected, canSwitchChart: canSwitchChart)
                        .padding(.top, 9)
                        .padding(.bottom, 8)
                }
            }

            if !isCollapsed {
                let parts = PanelLayout.partitionLimits(rows)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(parts.active, id: \.limit.id) { insight in
                        let selectAction: (() -> Void)? = (!decorative && insight.forecast != nil)
                            ? insight.limit.key.flatMap { key in onSelectMetric.map { select in { select(key) } } }
                            : nil
                        SlimCadenceBar(
                            insight: insight,
                            isFocused: !decorative && heroLimitID == insight.limit.id && (showsProviders || parts.active.count > 1),
                            onSelect: selectAction
                        )
                    }
                    if !parts.inactiveZero.isEmpty {
                        inactiveRow(parts.inactiveZero)
                    }
                    if provider == .claude, let breakdown = data.claude?.breakdown, !breakdown.isEmpty {
                        Text(breakdown.map { "\($0.name) \(Fmt.pct($0.percent))" }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, showsProviders ? 0 : 10)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func expandedHeader(
        _ provider: Provider,
        _ rows: [LimitInsight],
        isSelected: Bool,
        canSwitchChart: Bool
    ) -> some View {
        HStack(spacing: 6) {
            let titleContent = HStack(spacing: 5) {
                if allowsCollapse {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 9)
                }
                Text(provider.label)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary.opacity(0.88))
            }
            .contentShape(Rectangle())

            if let toggle = onToggleProvider, allowsCollapse, !decorative {
                Button { toggle(provider) } label: { titleContent }
                    .buttonStyle(.plain)
                    .help(tr("Replier \(provider.label)", "Collapse \(provider.label)"))
            } else {
                titleContent
            }

            Spacer(minLength: 4)

            // Les chiffres locaux (Codex, Antigravity en cache) peuvent dater de la dernière utilisation.
            if provider != .claude, let read = data.snapshot(provider)?.fetchedAt, now.timeIntervalSince(read) > 3600 {
                Text(Fmt.ago(read, now: now))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if canSwitchChart, !decorative, let select = onSelectProvider, rows.contains(where: { $0.forecast != nil }) {
                Button { select(provider) } label: {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.42))
                        .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
                .help(tr("Afficher la courbe de \(provider.label)", "Show \(provider.label) chart"))
            }
        }
    }

    /// Ligne sobre (sans cadre) pour les limites à 0 % inactives.
    private func inactiveRow(_ rows: [LimitInsight]) -> some View {
        HStack(spacing: 6) {
            Text(PanelLayout.inactiveSummaryLabel(for: rows))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Fmt.pct(0))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Contrôles discrets avec retour au survol et raccourcis clavier

private struct RefreshIconButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var spinning = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11.5))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    isRefreshing ? .linear(duration: 0.85).repeatForever(autoreverses: false) : .default,
                    value: spinning
                )
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .keyboardShortcut("r", modifiers: .command)
        .onHover { hovering = $0 }
        .onAppear { spinning = isRefreshing }
        .onChange(of: isRefreshing) { _, loading in spinning = loading }
        .help(tr("Actualiser (⌘R)", "Refresh (⌘R)"))
    }
}

private struct QuietFooterButton: View {
    let title: String
    let systemImage: String?
    let shortcut: KeyEquivalent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11))
                }
                Text(title).font(.caption)
            }
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .onHover { hovering = $0 }
    }
}

private struct CollapsedProviderRow: View {
    let provider: Provider
    let rows: [LimitInsight]
    let decorative: Bool
    let onToggle: (() -> Void)?
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        let primary = PanelLayout.primarySummary(for: provider, rows: rows)
        let tooltip = rows.map { "\($0.limit.label) : \(Fmt.pct($0.limit.percent))" }.joined(separator: " · ")

        let content = HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? Color.secondary : Color.secondary.opacity(0.55))
                .frame(width: 9)
            Text(provider.label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let primary {
                MicroBar(insight: primary)
                Text(Fmt.pct(primary.limit.percent))
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(primary.status == .over ? palette.swiftColor(.over) : Color.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())

        if let onToggle, !decorative {
            Button(action: onToggle) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(tooltip)
        } else {
            content
        }
    }
}

// MARK: - En-tête Chiffre-roi & tendance récente

private struct BigNumberHero: View {
    let insight: LimitInsight
    let forecast: Forecast
    let now: Date
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(Fmt.pct(insight.limit.percent))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.swiftColor(insight.status))
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 14.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        if insight.limit.percent >= 100 { return tr("Quota épuisé", "Quota used up") }
        if let date = forecast.exhaustionDate { return tr("À sec \(Fmt.dayTime(date))", "Runs out \(Fmt.dayTime(date))") }
        if let end = forecast.projectedEnd { return tr("Fin prévue à \(Fmt.pct(end))", "Ends at \(Fmt.pct(end))") }
        return tr("Trop tôt pour prévoir", "Too early to forecast")
    }

    private var detail: String {
        let left = 100 - insight.limit.percent
        let remaining = forecast.reset.timeIntervalSince(now)
        if insight.limit.percent >= 100 {
            return tr("Retour \(Fmt.dayTime(forecast.reset))", "Back \(Fmt.dayTime(forecast.reset))")
        }
        if remaining < 86400 {
            return tr("\(Fmt.points(left)) restants · \(Fmt.duration(remaining))", "\(Fmt.points(left)) left · \(Fmt.duration(remaining))")
        }
        if forecast.exhaustionDate != nil {
            return tr(
                "Max \(Fmt.points(forecast.dailyBudget))/j · +\(Fmt.points(forecast.paceDelta))",
                "Keep to \(Fmt.points(forecast.dailyBudget))/day · +\(Fmt.points(forecast.paceDelta))"
            )
        }
        if forecast.projectedEnd != nil {
            return tr(
                "\(Fmt.points(forecast.dailyBudget))/j · \(Fmt.points(forecast.paceDelta)) de marge",
                "\(Fmt.points(forecast.dailyBudget))/day · \(Fmt.points(forecast.paceDelta)) headroom"
            )
        }
        return insight.limit.isWeekly
            ? tr("Début de semaine", "Week just started")
            : tr("Début de fenêtre", "Window just started")
    }
}

/// Une seule ligne fine et discrète quand le rythme récent diverge franchement de la moyenne.
private struct QuietRecentLine: View {
    let insight: LimitInsight
    let recent: RecentRate
    @Environment(\.palette) private var palette

    private var hours: Int { max(1, Int(recent.spanHours.rounded())) }
    private var span: String { tr("\(hours) h", "\(hours)h") }
    private var speedingUp: Bool { (insight.recentDivergence ?? 0) > 0 }

    private var outcome: String {
        if let date = recent.exhaustionDate { return Fmt.dayTime(date) }
        if let end = recent.projectedEnd { return tr("fin \(Fmt.pct(end))", "ends \(Fmt.pct(end))") }
        return ""
    }

    var body: some View {
        let color = palette.swiftColor(PaceStatus(projectedEnd: recent.projectedEnd ?? 0))
        HStack(spacing: 5) {
            Image(systemName: speedingUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
            Text(speedingUp ? tr("Accélération (\(span))", "\(span) speed-up") : tr("Ralentissement (\(span))", "\(span) slow-down"))
            Spacer(minLength: 6)
            Text(outcome)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(color.opacity(0.92))
        .help(tr("+\(Fmt.points(recent.gained)) sur les dernières \(span)", "+\(Fmt.points(recent.gained)) over the last \(span)"))
    }
}

// MARK: - Barres fines (6 pt) et micro-barres (56 × 5 pt)

/// Micro-jauge pour un service replié : usage, projection pâle et trait de rythme en 56 pt.
private struct MicroBar: View {
    let insight: LimitInsight
    @Environment(\.palette) private var palette

    private var color: Color {
        PanelLayout.isInactiveZero(insight) ? .secondary : palette.swiftColor(insight.status)
    }

    var body: some View {
        let width: CGFloat = 56
        let used = min(max(insight.limit.percent / 100, 0), 1)
        let projected = min(max((insight.forecast?.projectedEnd ?? insight.limit.percent) / 100, used), 1)

        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            if projected > 0 {
                Capsule().fill(color.opacity(0.26))
                    .frame(width: max(projected * width, 4))
            }
            if used > 0 {
                Capsule().fill(color)
                    .frame(width: max(used * width, 4))
            }
            if let pace = insight.forecast?.elapsedFraction, !PanelLayout.isInactiveZero(insight) {
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(.primary.opacity(0.75))
                    .frame(width: 1.5, height: 9)
                    .offset(x: min(max(pace, 0), 1) * width - 0.75)
            }
        }
        .frame(width: width, height: 5)
    }
}

/// Barre fine : titre et prévision courte sur la même ligne, sans phrase en dessous.
/// Cliquable pour afficher cette limite dans l'en-tête et la courbe hebdomadaire.
private struct SlimCadenceBar: View {
    let insight: LimitInsight
    var isFocused = false
    var onSelect: (() -> Void)? = nil
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var color: Color { insight.forecast == nil ? .primary : palette.swiftColor(insight.status) }

    var body: some View {
        let projection = PanelLayout.inlineForecast(for: insight)

        let barContent = VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(insight.limit.label)
                    .foregroundStyle(isFocused || hovering ? Color.primary.opacity(0.9) : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.pct(insight.limit.percent))
                    .fontWeight(.medium)
                    .monospacedDigit()
                if let projection {
                    Text(projection)
                        .monospacedDigit()
                        .foregroundStyle(insight.status == .over ? color : Color.secondary.opacity(0.85))
                }
            }
            .font(.caption)

            GeometryReader { geo in
                let width = geo.size.width
                let used = min(max(insight.limit.percent / 100, 0), 1)
                let projected = min(max((insight.forecast?.projectedEnd ?? insight.limit.percent) / 100, used), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if projected > 0 {
                        Capsule().fill(color.opacity(0.25))
                            .frame(width: max(projected * width, 6))
                    }
                    if used > 0 {
                        Capsule().fill(color)
                            .frame(width: max(used * width, 6))
                    }
                    if let pace = insight.forecast?.elapsedFraction {
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(.primary.opacity(0.85))
                            .frame(width: 1.5, height: 12)
                            .offset(x: min(max(pace, 0), 1) * width - 0.75)
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())

        if let onSelect {
            Button(action: onSelect) { barContent }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(tooltip)
        } else {
            barContent.help(tooltip)
        }
    }

    private var tooltip: String {
        guard let forecast = insight.forecast else { return insight.limit.label }
        if insight.limit.percent >= 100 {
            return tr("Quota épuisé · retour \(Fmt.dayTime(forecast.reset))", "Quota used up · back \(Fmt.dayTime(forecast.reset))")
        }
        if let date = forecast.exhaustionDate {
            return tr("\(Fmt.points(forecast.paceDelta)) de trop · à sec \(Fmt.dayTime(date))", "\(Fmt.points(forecast.paceDelta)) over pace · empty \(Fmt.dayTime(date))")
        }
        if let end = forecast.projectedEnd {
            return tr("\(Fmt.points(forecast.paceDelta)) de marge · fin prévue \(Fmt.pct(end))", "\(Fmt.points(forecast.paceDelta)) of headroom · ends at \(Fmt.pct(end))")
        }
        return insight.limit.label
    }
}

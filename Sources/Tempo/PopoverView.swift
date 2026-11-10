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
    let openSettings: () -> Void
    @AppStorage("chartView") private var chartView = "cum"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            PanelContent(
                snapshot: store.snapshot, samples: store.samples, state: store.state,
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
    let snapshot: UsageSnapshot?
    let samples: [Sample]
    let state: UsageStore.State
    let now: Date
    @Binding var chartView: String
    let onRefresh: () -> Void
    let onSettings: () -> Void
    /// Pour les images hors écran : remplace les contrôles AppKit (boutons, sélecteur),
    /// qui ne se dessinent pas hors d'une fenêtre, par des équivalents SwiftUI inertes.
    var decorative = false
    @Environment(\.palette) private var palette

    private var insights: [LimitInsight] {
        guard let snapshot else { return [] }
        return snapshot.limits.map { Pace.insight(for: $0, in: snapshot, samples: samples, now: now) }
    }

    var body: some View {
        let all = insights
        let weekly = all.first { $0.limit.kind == .weeklyAll }

        VStack(alignment: .leading, spacing: 0) {
            header(weekly)

            if let weekly, let forecast = weekly.forecast {
                HeroText(insight: weekly, forecast: forecast, now: now)
                    .padding(.top, 14)
            }

            ForEach(Array(all.enumerated()), id: \.element.limit.id) { index, insight in
                CadenceBar(insight: insight, showPaceLabel: index == 0)
                    .padding(.top, 16)
            }

            if let weekly, weekly.forecast != nil {
                Divider().padding(.top, 16)
                HStack {
                    Text(tr("Ta semaine", "Your week")).font(.callout).fontWeight(.medium)
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
                    DayChart(insight: weekly, samples: samples, now: now).padding(.top, 8)
                } else {
                    CumulativeChart(insight: weekly, samples: samples, now: now).padding(.top, 8)
                }
            }

            if snapshot == nil, state == .loading || state == .idle {
                Text(tr("Lecture de l'usage…", "Reading usage…")).foregroundStyle(.secondary).padding(.top, 12)
            }

            if let rows = snapshot?.breakdown, !rows.isEmpty {
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
                if let snapshot {
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

    private func header(_ weekly: LimitInsight?) -> some View {
        HStack(spacing: 8) {
            Text("Tempo").font(.headline)
            if let weekly, weekly.forecast != nil {
                Text(weekly.status.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(palette.swiftColor(weekly.status).opacity(0.18), in: Capsule())
                    .foregroundStyle(palette.swiftColor(weekly.status))
            }
            Spacer()
            if let reset = weekly?.limit.resetsAt {
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
        if let end = forecast.projectedEnd { return tr("Tu finis la semaine à \(Fmt.pct(end))", "You'll finish the week at \(Fmt.pct(end))") }
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
        return tr("La semaine vient de commencer.", "The week has just started.")
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
                Text(message).font(.caption).foregroundStyle(color)
            }
        }
    }

    private var message: String? {
        guard let forecast = insight.forecast else { return nil }
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

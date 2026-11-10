import SwiftUI

private let labelFont = Font.system(size: 10)

private struct LegendItem: View {
    enum Mark { case solid, dotted, dashed, square }
    let mark: Mark
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                let y = size.height / 2
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                switch mark {
                case .solid:
                    context.stroke(line, with: .color(color), lineWidth: 2)
                case .dotted:
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 3]))
                case .dashed:
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                case .square:
                    let side = min(size.height, 8)
                    let box = CGRect(x: 0, y: y - side / 2, width: side, height: side)
                    context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(color))
                }
            }
            .frame(width: mark == .square ? 8 : 14, height: 10)
            Text(text).font(labelFont).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cumul

/// Usage réel (trait plein), rythme régulier (pointillé) et prévision (tirets) sur la semaine.
struct CumulativeChart: View {
    let insight: LimitInsight
    let samples: [Sample]
    let now: Date
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in draw(&context, size) }
                .frame(height: 150)
                .accessibilityLabel(tr("Usage cumulé de la semaine, rythme régulier et prévision", "Cumulative usage for the week, steady pace and forecast"))
            HStack(spacing: 12) {
                LegendItem(mark: .solid, color: .primary, text: tr("réel", "actual"))
                LegendItem(mark: .dotted, color: .secondary, text: tr("rythme régulier", "steady pace"))
                LegendItem(mark: .dashed, color: palette.swiftColor(insight.status), text: tr("prévision", "forecast"))
                if insight.recentDiverges, let end = insight.recent?.projectedEnd {
                    LegendItem(mark: .dotted, color: palette.swiftColor(PaceStatus(projectedEnd: end)), text: tr("rythme 24 h", "24h pace"))
                }
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let start = insight.start, let forecast = insight.forecast else { return }
        let total = forecast.reset.timeIntervalSince(start)
        guard total > 0 else { return }

        let x0: CGFloat = 26, x1 = size.width - 2, y1: CGFloat = 20, y0 = size.height - 18
        func X(_ u: Double) -> CGFloat { x0 + (x1 - x0) * min(max(u, 0), 1) }
        func Y(_ v: Double) -> CGFloat { y0 - (y0 - y1) * min(max(v, 0), 100) / 100 }
        func U(_ date: Date) -> Double { date.timeIntervalSince(start) / total }

        let color = palette.swiftColor(insight.status)
        let percent = insight.limit.percent
        let nowU = forecast.elapsedFraction
        let dayCount = max(1, Int((total / 86400).rounded(.up)))
        let todayIndex = min(dayCount - 1, Int(now.timeIntervalSince(start) / 86400))

        // Colonnes des jours
        for d in 0..<dayCount {
            let day = start.addingTimeInterval(Double(d) * 86400)
            if d > 0 {
                var separator = Path()
                separator.move(to: CGPoint(x: X(Double(d) / Double(dayCount)), y: y1))
                separator.addLine(to: CGPoint(x: X(Double(d) / Double(dayCount)), y: y0))
                context.stroke(separator, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)
            }
            context.draw(
                Text(Fmt.weekday(day)).font(labelFont)
                    .foregroundColor(d == todayIndex ? .primary : .secondary.opacity(0.8)),
                at: CGPoint(x: X((Double(d) + 0.5) / Double(dayCount)), y: y0 + 10)
            )
        }

        // Graduations 0, 50, 100 ; la limite en rouge
        for v in [0.0, 50, 100] {
            var grid = Path()
            grid.move(to: CGPoint(x: x0, y: Y(v)))
            grid.addLine(to: CGPoint(x: x1, y: Y(v)))
            if v == 100 {
                context.stroke(grid, with: .color(.red.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                context.stroke(grid, with: .color(.primary.opacity(0.15)), lineWidth: 0.5)
            }
            context.draw(
                Text("\(Int(v))").font(labelFont).foregroundColor(.secondary.opacity(0.8)),
                at: CGPoint(x: x0 - 5, y: Y(v)), anchor: .trailing
            )
        }

        // Zone « à sec » entre l'épuisement et la réinitialisation
        let exhaustU = percent < 100 ? forecast.exhaustionDate.map(U) : nil
        if let exhaustU {
            let zone = CGRect(x: X(exhaustU), y: y1, width: x1 - X(exhaustU), height: y0 - y1)
            context.fill(Path(zone), with: .color(.red.opacity(0.12)))
        }

        // Rythme régulier
        var ideal = Path()
        ideal.move(to: CGPoint(x: x0, y: y0))
        ideal.addLine(to: CGPoint(x: x1, y: y1))
        context.stroke(ideal, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1, 4]))

        // Usage réel
        let curve = Pace.curve(for: insight, samples: samples, now: now)
        var actual = Path()
        for (i, point) in curve.enumerated() {
            let p = CGPoint(x: X(U(point.t)), y: Y(point.v))
            if i == 0 { actual.move(to: p) } else { actual.addLine(to: p) }
        }
        var area = actual
        area.addLine(to: CGPoint(x: X(nowU), y: y0))
        area.addLine(to: CGPoint(x: x0, y: y0))
        area.closeSubpath()
        context.fill(area, with: .color(.primary.opacity(0.08)))
        context.stroke(actual, with: .color(.primary), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

        // Prévision
        let nowPoint = CGPoint(x: X(nowU), y: Y(percent))
        if percent < 100, nowU < 0.995, let end = forecast.projectedEnd {
            var projection = Path()
            projection.move(to: nowPoint)
            if let exhaustU {
                projection.addLine(to: CGPoint(x: X(exhaustU), y: Y(100)))
            } else {
                projection.addLine(to: CGPoint(x: x1, y: Y(end)))
            }
            context.stroke(projection, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
        }

        // Prévision au rythme récent, quand elle s'écarte assez de la moyenne pour changer la réponse
        if insight.recentDiverges, let recent = insight.recent, let end = recent.projectedEnd, percent < 100, nowU < 0.995 {
            var quick = Path()
            quick.move(to: nowPoint)
            if let date = recent.exhaustionDate {
                quick.addLine(to: CGPoint(x: X(U(date)), y: Y(100)))
            } else {
                quick.addLine(to: CGPoint(x: x1, y: Y(end)))
            }
            context.stroke(
                quick, with: .color(palette.swiftColor(PaceStatus(projectedEnd: end))),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 4])
            )
        }

        // Écart au rythme, à l'instant présent
        var gap = Path()
        gap.move(to: nowPoint)
        gap.addLine(to: CGPoint(x: X(nowU), y: Y(nowU * 100)))
        context.stroke(gap, with: .color(color.opacity(0.4)), lineWidth: 5)

        var nowLine = Path()
        nowLine.move(to: CGPoint(x: X(nowU), y: y1))
        nowLine.addLine(to: CGPoint(x: X(nowU), y: y0))
        context.stroke(nowLine, with: .color(.secondary), lineWidth: 0.75)
        context.fill(
            Path(ellipseIn: CGRect(x: nowPoint.x - 4, y: nowPoint.y - 4, width: 8, height: 8)),
            with: .color(.primary)
        )

        // Étiquettes, placées là où le graphique est vide
        context.draw(
            Text(tr("maintenant · \(Fmt.pct(percent))", "now · \(Fmt.pct(percent))")).font(.system(size: 11, weight: .medium)),
            at: CGPoint(x: min(max(X(nowU), x0 + 52), x1 - 52), y: 8)
        )
        if let date = forecast.exhaustionDate, percent < 100 {
            context.draw(
                Text(tr("à sec \(Fmt.dayTime(date))", "empty \(Fmt.dayTime(date))")).font(.system(size: 11, weight: .medium)).foregroundColor(.red),
                at: CGPoint(x: x1 - 3, y: y0 - 9), anchor: .trailing
            )
        } else if percent < 100, nowU < 0.9, let end = forecast.projectedEnd {
            // Sous la ligne de prévision : on descend d'autant que la ligne monte sur la largeur du texte.
            let slope = (nowPoint.y - Y(end)) / max(x1 - nowPoint.x, 1)
            context.draw(
                Text(tr("fin : \(Fmt.pct(end))", "end: \(Fmt.pct(end))")).font(.system(size: 11, weight: .medium)).foregroundColor(color),
                at: CGPoint(x: x1 - 3, y: min(Y(end) + slope * 66 + 10, y0 - 9)), anchor: .trailing
            )
        }
    }
}

// MARK: - Par jour

/// Points utilisés chaque jour, et ce qui reste possible chaque jour à venir sans dépasser.
struct DayChart: View {
    let insight: LimitInsight
    let samples: [Sample]
    let now: Date
    @Environment(\.palette) private var palette

    private var days: [DayUsage] { Pace.dailyUsage(for: insight, samples: samples, now: now) }

    var body: some View {
        let days = self.days
        let even = days.isEmpty ? 0 : 100 / Double(days.count)
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in draw(&context, size, days, even) }
                .frame(height: 150)
                .accessibilityLabel(tr("Points utilisés par jour et budget possible pour les jours restants", "Points used per day and the budget still available for the remaining days"))
            HStack(spacing: 12) {
                LegendItem(mark: .square, color: .primary, text: tr("utilisé", "used"))
                LegendItem(mark: .square, color: palette.swiftColor(insight.status).opacity(0.35), text: tr("encore possible", "still available"))
                LegendItem(mark: .dotted, color: .secondary, text: tr("régulier, \(Fmt.points(even)) par jour", "steady, \(Fmt.points(even)) a day"))
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ days: [DayUsage], _ even: Double) {
        guard !days.isEmpty else { return }
        let x0: CGFloat = 2, x1 = size.width - 2, y1: CGFloat = 20, y0 = size.height - 18
        let peak = max(even, days.map { $0.used + $0.possible }.max() ?? 0) * 1.2
        guard peak > 0 else { return }
        func Y(_ v: Double) -> CGFloat { y0 - (y0 - y1) * min(v, peak) / peak }

        let column = (x1 - x0) / CGFloat(days.count)
        let barWidth = column * 0.52
        let color = palette.swiftColor(insight.status)

        for (i, day) in days.enumerated() {
            let x = x0 + CGFloat(i) * column + (column - barWidth) / 2
            let total = day.used + day.possible
            if day.possible > 0.05 {
                let rect = CGRect(x: x, y: Y(total), width: barWidth, height: y0 - Y(total))
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.35)))
            }
            if day.used > 0.05 {
                let rect = CGRect(x: x, y: Y(day.used), width: barWidth, height: y0 - Y(day.used))
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.primary))
            }
            let value = day.kind == .future ? day.possible : day.used
            context.draw(
                Text("\(Int(value.rounded()))").font(.system(size: 10, weight: .medium))
                    .foregroundColor(day.kind == .future ? color : .primary),
                at: CGPoint(x: x + barWidth / 2, y: Y(total) - 8)
            )
            context.draw(
                Text(Fmt.weekday(day.start)).font(labelFont)
                    .foregroundColor(day.kind == .today ? .primary : .secondary.opacity(0.8)),
                at: CGPoint(x: x + barWidth / 2, y: y0 + 10)
            )
        }

        var base = Path()
        base.move(to: CGPoint(x: x0, y: y0))
        base.addLine(to: CGPoint(x: x1, y: y0))
        context.stroke(base, with: .color(.primary.opacity(0.2)), lineWidth: 0.5)

        var regular = Path()
        regular.move(to: CGPoint(x: x0, y: Y(even)))
        regular.addLine(to: CGPoint(x: x1, y: Y(even)))
        context.stroke(regular, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1, 4]))
    }
}

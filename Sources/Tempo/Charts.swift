import SwiftUI

private let labelFont = Font.system(size: 10)

// MARK: - Cumul

/// Usage réel (trait plein), rythme régulier (pointillé) et prévision (tirets) sur la semaine.
struct CumulativeChart: View {
    let insight: LimitInsight
    let samples: [Sample]
    let now: Date
    @Environment(\.palette) private var palette

    var body: some View {
        Canvas { context, size in draw(&context, size) }
            .frame(height: 118)
            .accessibilityLabel(tr("Usage cumulé de la semaine, rythme régulier et prévision", "Cumulative usage for the week, steady pace and forecast"))
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let start = insight.start, let forecast = insight.forecast else { return }
        let total = forecast.reset.timeIntervalSince(start)
        guard total > 0 else { return }

        let x0: CGFloat = 24, x1 = size.width - 2, y1: CGFloat = 18, y0 = size.height - 16
        func X(_ u: Double) -> CGFloat { x0 + (x1 - x0) * min(max(u, 0), 1) }
        func Y(_ v: Double) -> CGFloat { y0 - (y0 - y1) * min(max(v, 0), 100) / 100 }
        func U(_ date: Date) -> Double { date.timeIntervalSince(start) / total }

        let color = palette.swiftColor(insight.status)
        let percent = insight.limit.percent
        let nowU = forecast.elapsedFraction
        let dayCount = max(1, Int((total / 86400).rounded(.up)))
        let todayIndex = min(dayCount - 1, Int(now.timeIntervalSince(start) / 86400))

        // Étiquettes des jours (sans quadrillage vertical)
        for d in 0..<dayCount {
            let day = start.addingTimeInterval(Double(d) * 86400)
            context.draw(
                Text(Fmt.weekday(day)).font(labelFont)
                    .foregroundColor(d == todayIndex ? .primary : .secondary.opacity(0.65)),
                at: CGPoint(x: X((Double(d) + 0.5) / Double(dayCount)), y: y0 + 10)
            )
        }

        // Ligne de base 0 et plafond 100 uniquement
        for v in [0.0, 100] {
            var grid = Path()
            grid.move(to: CGPoint(x: x0, y: Y(v)))
            grid.addLine(to: CGPoint(x: x1, y: Y(v)))
            if v == 100 {
                let capColor: Color = insight.status == .over ? color.opacity(0.45) : .primary.opacity(0.14)
                context.stroke(grid, with: .color(capColor), style: StrokeStyle(lineWidth: 0.9, dash: [2, 3]))
            } else {
                context.stroke(grid, with: .color(.primary.opacity(0.12)), lineWidth: 0.6)
            }
            context.draw(
                Text("\(Int(v))").font(labelFont).foregroundColor(.secondary.opacity(0.6)),
                at: CGPoint(x: x0 - 5, y: Y(v)), anchor: .trailing
            )
        }

        // Zone « à sec » entre l'épuisement et la réinitialisation
        let exhaustU = percent < 100 ? forecast.exhaustionDate.map(U) : nil
        if let exhaustU {
            let zone = CGRect(x: X(exhaustU), y: y1, width: x1 - X(exhaustU), height: y0 - y1)
            context.fill(Path(zone), with: .color(color.opacity(0.1)))
        }

        // Rythme régulier
        var ideal = Path()
        ideal.move(to: CGPoint(x: x0, y: y0))
        ideal.addLine(to: CGPoint(x: x1, y: y1))
        context.stroke(ideal, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 3.5]))

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
        context.fill(area, with: .color(.primary.opacity(0.06)))
        context.stroke(actual, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

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
            context.stroke(projection, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 3.5]))
        }

        // Prévision au rythme récent, quand elle diverge nettement de la moyenne
        if insight.recentDiverges, let recent = insight.recent, let end = recent.projectedEnd, percent < 100, nowU < 0.995 {
            var quick = Path()
            quick.move(to: nowPoint)
            if let date = recent.exhaustionDate {
                quick.addLine(to: CGPoint(x: X(U(date)), y: Y(100)))
            } else {
                quick.addLine(to: CGPoint(x: x1, y: Y(end)))
            }
            context.stroke(
                quick, with: .color(palette.swiftColor(PaceStatus(projectedEnd: end)).opacity(0.65)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [1, 3.5])
            )
        }

        // Repère présent
        var nowLine = Path()
        nowLine.move(to: CGPoint(x: X(nowU), y: y1))
        nowLine.addLine(to: CGPoint(x: X(nowU), y: y0))
        context.stroke(nowLine, with: .color(.secondary.opacity(0.28)), lineWidth: 0.7)
        context.fill(
            Path(ellipseIn: CGRect(x: nowPoint.x - 3.5, y: nowPoint.y - 3.5, width: 7, height: 7)),
            with: .color(.primary)
        )

        // Étiquette présente et issue en fin de courbe
        context.draw(
            Text(Fmt.pct(percent)).font(.system(size: 10.5, weight: .semibold)),
            at: CGPoint(x: min(max(X(nowU), x0 + 22), x1 - 22), y: 7)
        )
        if let date = forecast.exhaustionDate, percent < 100 {
            context.draw(
                Text(Fmt.dayTime(date)).font(.system(size: 10.5, weight: .medium)).foregroundColor(color),
                at: CGPoint(x: x1 - 2, y: y0 - 8), anchor: .trailing
            )
        } else if percent < 100, nowU < 0.9, let end = forecast.projectedEnd {
            let slope = (nowPoint.y - Y(end)) / max(x1 - nowPoint.x, 1)
            context.draw(
                Text(Fmt.pct(end)).font(.system(size: 10.5, weight: .medium)).foregroundColor(color),
                at: CGPoint(x: x1 - 2, y: min(Y(end) + slope * 48 + 10, y0 - 8)), anchor: .trailing
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
        Canvas { context, size in draw(&context, size, days, even) }
            .frame(height: 118)
            .accessibilityLabel(tr("Points utilisés par jour et budget possible pour les jours restants", "Points used per day and the budget still available for the remaining days"))
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, _ days: [DayUsage], _ even: Double) {
        guard !days.isEmpty else { return }
        let x0: CGFloat = 2, x1 = size.width - 2, y1: CGFloat = 18, y0 = size.height - 16
        let peak = max(even, days.map { $0.used + $0.possible }.max() ?? 0) * 1.2
        guard peak > 0 else { return }
        func Y(_ v: Double) -> CGFloat { y0 - (y0 - y1) * min(v, peak) / peak }

        let column = (x1 - x0) / CGFloat(days.count)
        let barWidth = column * 0.48
        let color = palette.swiftColor(insight.status)

        for (i, day) in days.enumerated() {
            let x = x0 + CGFloat(i) * column + (column - barWidth) / 2
            let total = day.used + day.possible
            if day.possible > 0.05 {
                let rect = CGRect(x: x, y: Y(total), width: barWidth, height: y0 - Y(total))
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(color.opacity(0.24)))
            }
            if day.used > 0.05 {
                let rect = CGRect(x: x, y: Y(day.used), width: barWidth, height: y0 - Y(day.used))
                let fill: Color = day.kind == .today ? color : .primary.opacity(0.7)
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(fill))
            }
            let value = day.kind == .future ? day.possible : day.used
            context.draw(
                Text("\(Int(value.rounded()))").font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(day.kind == .future ? color.opacity(0.85) : .primary.opacity(0.85)),
                at: CGPoint(x: x + barWidth / 2, y: Y(total) - 7)
            )
            context.draw(
                Text(Fmt.weekday(day.start)).font(labelFont)
                    .foregroundColor(day.kind == .today ? .primary : .secondary.opacity(0.65)),
                at: CGPoint(x: x + barWidth / 2, y: y0 + 10)
            )
        }

        var base = Path()
        base.move(to: CGPoint(x: x0, y: y0))
        base.addLine(to: CGPoint(x: x1, y: y0))
        context.stroke(base, with: .color(.primary.opacity(0.14)), lineWidth: 0.6)

        var regular = Path()
        regular.move(to: CGPoint(x: x0, y: Y(even)))
        regular.addLine(to: CGPoint(x: x1, y: Y(even)))
        context.stroke(regular, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 3.5]))
    }
}

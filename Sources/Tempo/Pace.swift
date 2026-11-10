import Foundation

/// Prévision au rythme moyen depuis le début de la fenêtre.
struct Forecast: Equatable {
    /// Part de la fenêtre déjà écoulée, de 0 à 1.
    let elapsedFraction: Double
    /// Écart au rythme régulier, en points. Positif = en avance sur le quota.
    let paceDelta: Double
    /// Pourcentage atteint à la réinitialisation si le rythme moyen continue. Nil si trop tôt pour le dire.
    let projectedEnd: Double?
    /// Moment où le quota tombe à zéro, s'il arrive avant la réinitialisation.
    let exhaustionDate: Date?
    /// Points par jour encore disponibles pour finir exactement à 100 %.
    let dailyBudget: Double
    let reset: Date
}

/// Rythme mesuré sur les dernières heures, à partir de l'historique local.
struct RecentRate: Equatable {
    let gained: Double
    let spanHours: Double
    let pointsPerHour: Double
    let exhaustionDate: Date?
}

enum PaceStatus {
    case onTrack, tight, over

    var label: String {
        switch self {
        case .onTrack: return tr("Dans le rythme", "On pace")
        case .tight: return tr("Serré", "Tight")
        case .over: return tr("Trop vite", "Too fast")
        }
    }
}

/// L'usage d'une journée de la fenêtre : ce qui est pris, et ce qui reste possible sans dépasser.
struct DayUsage: Equatable {
    enum Kind { case past, today, future }
    let start: Date
    let kind: Kind
    let used: Double
    let possible: Double
}

struct LimitInsight {
    let limit: UsageLimit
    let start: Date?
    let forecast: Forecast?
    let recent: RecentRate?

    /// Vrai si, au rythme moyen, le quota s'épuise avant la réinitialisation.
    var willExhaust: Bool { forecast?.exhaustionDate != nil }

    var status: PaceStatus {
        guard let end = forecast?.projectedEnd else { return .onTrack }
        return end > 100 ? .over : end > 90 ? .tight : .onTrack
    }
}

enum Pace {
    /// En dessous de cette part de fenêtre écoulée, une extrapolation ne veut rien dire.
    static let minimumElapsed = 0.02

    static func forecast(percent: Double, start: Date, reset: Date, now: Date) -> Forecast? {
        let total = reset.timeIntervalSince(start)
        guard total > 0 else { return nil }
        let elapsed = min(max(now.timeIntervalSince(start), 0), total)
        let remaining = total - elapsed
        let fraction = elapsed / total

        var projected: Double?
        var exhaustion: Date?
        if percent >= 100 {
            projected = 100
            exhaustion = now
        } else if fraction >= minimumElapsed {
            let end = percent / fraction
            projected = end
            if end > 100, percent > 0 {
                exhaustion = start.addingTimeInterval(elapsed * 100 / percent)
            }
        }

        let remainingDays = max(remaining / 86400, 1.0 / 24)
        return Forecast(
            elapsedFraction: fraction,
            paceDelta: percent - fraction * 100,
            projectedEnd: projected,
            exhaustionDate: exhaustion,
            dailyBudget: max(0, 100 - percent) / remainingDays,
            reset: reset
        )
    }

    static func recent(
        points: [(t: Date, v: Double)],
        current: Double,
        windowStart: Date?,
        reset: Date?,
        now: Date,
        lookback: TimeInterval = 24 * 3600
    ) -> RecentRate? {
        let floor = max(now.addingTimeInterval(-lookback), windowStart ?? .distantPast)
        guard let first = points.first(where: { $0.t >= floor }) else { return nil }
        let span = now.timeIntervalSince(first.t)
        guard span >= 30 * 60 else { return nil }

        let gained = current - first.v
        guard gained >= 0 else { return nil }
        let rate = gained / (span / 3600)

        var exhaustion: Date?
        if rate > 0.01, current < 100 {
            let date = now.addingTimeInterval((100 - current) / rate * 3600)
            if let reset, date < reset { exhaustion = date }
        }
        return RecentRate(gained: gained, spanHours: span / 3600, pointsPerHour: rate, exhaustionDate: exhaustion)
    }

    /// Courbe d'usage cumulé depuis le début de la fenêtre : (début, 0), les relevés, puis (maintenant, valeur).
    /// Avant le premier relevé, la montée est une droite : on ne connaît pas le détail.
    static func curve(for insight: LimitInsight, samples: [Sample], now: Date) -> [(t: Date, v: Double)] {
        guard let start = insight.start else { return [] }
        let current = insight.limit.percent
        var points: [(t: Date, v: Double)] = [(start, 0)]
        for sample in samples where sample.t > start && sample.t < now {
            let value = insight.limit.key.flatMap(sample.value(for:))
            if let value, value <= current, value >= (points.last?.v ?? 0) {
                points.append((sample.t, value))
            }
        }
        points.append((now, current))
        return points
    }

    static func value(on curve: [(t: Date, v: Double)], at date: Date) -> Double {
        guard let first = curve.first, let last = curve.last else { return 0 }
        if date <= first.t { return first.v }
        if date >= last.t { return last.v }
        for i in 1..<curve.count where curve[i].t >= date {
            let a = curve[i - 1], b = curve[i]
            let span = b.t.timeIntervalSince(a.t)
            guard span > 0 else { return b.v }
            return a.v + (b.v - a.v) * date.timeIntervalSince(a.t) / span
        }
        return last.v
    }

    /// Découpe la fenêtre en journées de 24 h à partir de son début.
    static func dailyUsage(for insight: LimitInsight, samples: [Sample], now: Date) -> [DayUsage] {
        guard let start = insight.start, let forecast = insight.forecast else { return [] }
        let total = forecast.reset.timeIntervalSince(start)
        let count = Int((total / 86400).rounded(.up))
        guard count > 0, count <= 31 else { return [] }

        let curve = Pace.curve(for: insight, samples: samples, now: now)
        let budget = insight.limit.percent >= 100 ? 0 : forecast.dailyBudget
        var days: [DayUsage] = []
        for index in 0..<count {
            let dayStart = start.addingTimeInterval(Double(index) * 86400)
            let dayEnd = min(dayStart.addingTimeInterval(86400), forecast.reset)
            if dayEnd <= now {
                let used = value(on: curve, at: dayEnd) - value(on: curve, at: dayStart)
                days.append(DayUsage(start: dayStart, kind: .past, used: max(0, used), possible: 0))
            } else if dayStart <= now {
                let used = insight.limit.percent - value(on: curve, at: dayStart)
                let left = dayEnd.timeIntervalSince(now) / 86400
                days.append(DayUsage(start: dayStart, kind: .today, used: max(0, used), possible: budget * left))
            } else {
                let length = dayEnd.timeIntervalSince(dayStart) / 86400
                days.append(DayUsage(start: dayStart, kind: .future, used: 0, possible: budget * length))
            }
        }
        return days
    }

    static func insight(
        for limit: UsageLimit,
        in snapshot: UsageSnapshot,
        samples: [Sample],
        now: Date
    ) -> LimitInsight {
        let start = snapshot.windowStart(for: limit)
        var forecast: Forecast?
        if let start, let reset = limit.resetsAt {
            forecast = Pace.forecast(percent: limit.percent, start: start, reset: reset, now: now)
        }

        let points: [(t: Date, v: Double)] = samples.compactMap { s in
            limit.key.flatMap(s.value(for:)).map { (s.t, $0) }
        }
        let recent = Pace.recent(
            points: points, current: limit.percent,
            windowStart: start, reset: limit.resetsAt, now: now
        )
        return LimitInsight(limit: limit, start: start, forecast: forecast, recent: recent)
    }
}

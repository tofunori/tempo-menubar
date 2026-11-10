import Foundation

/// Une limite du forfait, telle que le service d'usage la décrit.
struct UsageLimit: Identifiable, Equatable {
    enum Kind: Equatable {
        case weeklyAll
        case weeklyModel(String)
        case session
        case other(String)
    }

    let kind: Kind
    let percent: Double
    let resetsAt: Date?

    var id: String {
        switch kind {
        case .weeklyAll: return "weekly_all"
        case .weeklyModel(let name): return "weekly_model_\(name)"
        case .session: return "session"
        case .other(let raw): return "other_\(raw)"
        }
    }

    var label: String {
        switch kind {
        case .weeklyAll: return "Hebdo · tous modèles"
        case .weeklyModel(let name): return "Hebdo · \(name)"
        case .session: return "Session 5 h"
        case .other(let raw): return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Durée de la fenêtre, pour retrouver son début quand le service ne le donne pas.
    var windowLength: TimeInterval {
        switch kind {
        case .session: return 5 * 3600
        default: return 7 * 86400
        }
    }
}

struct BreakdownRow: Equatable, Identifiable {
    let name: String
    let percent: Double
    var id: String { name }
}

struct UsageSnapshot: Equatable {
    var limits: [UsageLimit]
    var weeklyWindowStart: Date?
    var breakdown: [BreakdownRow]
    var fetchedAt: Date

    var weekly: UsageLimit? { limits.first { $0.kind == .weeklyAll } }

    var model: UsageLimit? {
        limits.first {
            if case .weeklyModel = $0.kind { return true }
            return false
        }
    }

    var modelName: String? {
        if case .weeklyModel(let name)? = model?.kind { return name }
        return nil
    }

    /// Relevé fictif, pour les aperçus et les vérifications hors ligne.
    static func sample(weekly: Double, model: Double, elapsed: Double, now: Date) -> UsageSnapshot {
        let reset = now.addingTimeInterval((1 - elapsed) * 7 * 86400)
        return UsageSnapshot(
            limits: [
                UsageLimit(kind: .weeklyAll, percent: weekly, resetsAt: reset),
                UsageLimit(kind: .weeklyModel("Fable"), percent: model, resetsAt: reset),
            ],
            weeklyWindowStart: reset.addingTimeInterval(-7 * 86400),
            breakdown: [], fetchedAt: now
        )
    }

    func windowStart(for limit: UsageLimit) -> Date? {
        if limit.kind != .session, let start = weeklyWindowStart { return start }
        return limit.resetsAt.map { $0.addingTimeInterval(-limit.windowLength) }
    }
}

// MARK: - Réponse brute du service

/// Décodage tolérant : un champ absent ou d'un type inattendu devient nil
/// plutôt que de faire échouer toute la lecture.
struct APIUsage: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let display_name: String? }
            let model: Model?
        }
        let kind: String?
        let group: String?
        let percent: Double?
        let resets_at: String?
        let scope: Scope?
    }

    struct Breakdown: Decodable {
        struct Row: Decodable {
            let display_name: String?
            let percent: Double?
        }
        let window_started_at: String?
        let rows: [Row]?
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let limits: [Limit]?
    let breakdown: Breakdown?

    private enum Keys: String, CodingKey {
        case five_hour, seven_day, limits, seven_day_breakdown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        fiveHour = (try? c.decodeIfPresent(Window.self, forKey: .five_hour)) ?? nil
        sevenDay = (try? c.decodeIfPresent(Window.self, forKey: .seven_day)) ?? nil
        limits = (try? c.decodeIfPresent([Limit].self, forKey: .limits)) ?? nil
        breakdown = (try? c.decodeIfPresent(Breakdown.self, forKey: .seven_day_breakdown)) ?? nil
    }

    func snapshot(now: Date = Date()) -> UsageSnapshot {
        var out: [UsageLimit] = []

        for l in limits ?? [] {
            guard let kind = l.kind, let percent = l.percent else { continue }
            let reset = parseISODate(l.resets_at)
            switch kind {
            case "weekly_all":
                out.append(UsageLimit(kind: .weeklyAll, percent: percent, resetsAt: reset))
            case "weekly_scoped":
                let name = l.scope?.model?.display_name ?? "Modèle"
                out.append(UsageLimit(kind: .weeklyModel(name), percent: percent, resetsAt: reset))
            default:
                if l.group == "session" || kind.contains("session") || kind.contains("five_hour") {
                    out.append(UsageLimit(kind: .session, percent: percent, resetsAt: reset))
                } else {
                    out.append(UsageLimit(kind: .other(kind), percent: percent, resetsAt: reset))
                }
            }
        }

        // Repli sur les anciens champs si la liste `limits` ne couvre pas tout.
        if !out.contains(where: { $0.kind == .weeklyAll }), let w = sevenDay, let p = w.utilization {
            out.insert(UsageLimit(kind: .weeklyAll, percent: p, resetsAt: parseISODate(w.resets_at)), at: 0)
        }
        if !out.contains(where: { $0.kind == .session }), let s = fiveHour, let p = s.utilization {
            out.insert(UsageLimit(kind: .session, percent: p, resetsAt: parseISODate(s.resets_at)), at: 0)
        }

        let rows = (breakdown?.rows ?? []).compactMap { r -> BreakdownRow? in
            guard let name = r.display_name, let p = r.percent, p > 0 else { return nil }
            return BreakdownRow(name: name, percent: p)
        }

        return UsageSnapshot(
            limits: out,
            weeklyWindowStart: parseISODate(breakdown?.window_started_at),
            breakdown: rows,
            fetchedAt: now
        )
    }
}

/// Le service renvoie des microsecondes (« 07:00:00.651333+00:00 ») ; on les retire avant l'analyse.
func parseISODate(_ string: String?) -> Date? {
    guard var s = string else { return nil }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
    return ISO8601DateFormatter().date(from: s)
}

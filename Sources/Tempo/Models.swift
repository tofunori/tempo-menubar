import Foundation

/// Les services que Tempo suit.
enum Provider: String, CaseIterable, Identifiable {
    case claude, chatgpt
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT · Codex"
        }
    }
}

/// Les valeurs qu'une icône peut montrer, tous services confondus.
enum MetricKey: String, CaseIterable, Identifiable {
    case claudeWeekly = "claude.weekly"
    case claudeModel = "claude.model"
    case claudeSession = "claude.session"
    case chatgptSession = "chatgpt.session"
    case chatgptWeekly = "chatgpt.weekly"

    var id: String { rawValue }

    var provider: Provider {
        switch self {
        case .claudeWeekly, .claudeModel, .claudeSession: return .claude
        case .chatgptSession, .chatgptWeekly: return .chatgpt
        }
    }

    /// - Parameter modelName: nom du modèle que Claude limite à part (« Fable »).
    func label(modelName: String) -> String {
        switch self {
        case .claudeWeekly: return tr("Claude · hebdo", "Claude · weekly")
        case .claudeModel: return "Claude · \(modelName)"
        case .claudeSession: return tr("Claude · 5 h", "Claude · 5 h")
        case .chatgptSession: return tr("ChatGPT · 5 h", "ChatGPT · 5 h")
        case .chatgptWeekly: return tr("ChatGPT · hebdo", "ChatGPT · weekly")
        }
    }

    /// Repère court devant la deuxième valeur dans la barre de menus (« 56 % · G 10 % »).
    func tag(modelName: String) -> String {
        switch self {
        case .claudeWeekly: return "C"
        case .claudeModel: return modelName.first.map(String.init) ?? "M"
        case .claudeSession: return "C5"
        case .chatgptSession: return "G5"
        case .chatgptWeekly: return "G"
        }
    }
}

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
    var provider: Provider = .claude
    /// Durée de la fenêtre en secondes, quand le service la donne.
    var length: TimeInterval?

    var id: String {
        switch kind {
        case .weeklyAll: return "\(provider.rawValue).weekly_all"
        case .weeklyModel(let name): return "\(provider.rawValue).weekly_model_\(name)"
        case .session: return "\(provider.rawValue).session"
        case .other(let raw): return "\(provider.rawValue).other_\(raw)"
        }
    }

    /// La valeur d'icône que cette limite alimente, s'il y en a une.
    var key: MetricKey? {
        switch (provider, kind) {
        case (.claude, .weeklyAll): return .claudeWeekly
        case (.claude, .weeklyModel): return .claudeModel
        case (.claude, .session): return .claudeSession
        case (.chatgpt, .weeklyAll): return .chatgptWeekly
        case (.chatgpt, .session): return .chatgptSession
        default: return nil
        }
    }

    /// Vrai pour une fenêtre d'au moins deux jours : on peut alors parler de semaine et de budget par jour.
    var isWeekly: Bool { windowLength >= 2 * 86400 }

    var label: String {
        switch kind {
        case .weeklyAll where provider == .chatgpt: return tr("Hebdo", "Weekly")
        case .weeklyAll: return tr("Hebdo · tous modèles", "Weekly · all models")
        case .weeklyModel(let name): return tr("Hebdo · \(name)", "Weekly · \(name)")
        case .session: return tr("Session 5 h", "5-hour session")
        case .other(let raw): return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Durée de la fenêtre, pour retrouver son début quand le service ne le donne pas.
    var windowLength: TimeInterval {
        if let length { return length }
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

    /// Relevé fictif de Codex : une fenêtre de 5 heures à moitié écoulée, et l'hebdo.
    static func sampleChatGPT(session: Double, weekly: Double, elapsed: Double, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            limits: [
                UsageLimit(
                    kind: .session, percent: session, resetsAt: now.addingTimeInterval(2.5 * 3600),
                    provider: .chatgpt, length: 5 * 3600
                ),
                UsageLimit(
                    kind: .weeklyAll, percent: weekly, resetsAt: now.addingTimeInterval((1 - elapsed) * 7 * 86400),
                    provider: .chatgpt, length: 7 * 86400
                ),
            ],
            weeklyWindowStart: nil, breakdown: [], fetchedAt: now
        )
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
        if limit.kind != .session, limit.length == nil, let start = weeklyWindowStart { return start }
        return limit.resetsAt.map { $0.addingTimeInterval(-limit.windowLength) }
    }
}

/// Tout ce que Tempo sait à un instant donné, tous services confondus.
struct UsageData {
    var claude: UsageSnapshot?
    var chatgpt: UsageSnapshot?
    var samples: [Sample] = []

    var modelName: String { claude?.modelName ?? "Fable" }

    func snapshot(_ provider: Provider) -> UsageSnapshot? {
        provider == .claude ? claude : chatgpt
    }

    func limit(_ key: MetricKey) -> UsageLimit? {
        snapshot(key.provider)?.limits.first { $0.key == key }
    }

    func insight(_ key: MetricKey, now: Date) -> LimitInsight? {
        guard let snapshot = snapshot(key.provider), let limit = limit(key) else { return nil }
        return Pace.insight(for: limit, in: snapshot, samples: samples, now: now)
    }

    /// Les limites d'un service, avec leur cadence, dans l'ordre du relevé.
    func insights(_ provider: Provider, now: Date) -> [LimitInsight] {
        guard let snapshot = snapshot(provider) else { return [] }
        return snapshot.limits.map { Pace.insight(for: $0, in: snapshot, samples: samples, now: now) }
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
                let name = l.scope?.model?.display_name ?? tr("Modèle", "Model")
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

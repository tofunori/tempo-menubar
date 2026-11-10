import Foundation

/// Un relevé d'usage. Claude : hebdo tous modèles (w), modèle suivi (m), session (s).
/// ChatGPT : session de 5 heures (gs), hebdo (gw).
struct Sample: Codable, Equatable {
    let t: Date
    var w: Double?
    var m: Double?
    var s: Double?
    var gs: Double?
    var gw: Double?

    func value(for key: MetricKey) -> Double? {
        switch key {
        case .claudeWeekly: return w
        case .claudeModel: return m
        case .claudeSession: return s
        case .chatgptSession: return gs
        case .chatgptWeekly: return gw
        }
    }
}

/// Historique local des relevés. Il sert à mesurer le rythme récent et à tracer la courbe.
final class HistoryStore {
    private(set) var samples: [Sample] = []
    private let url: URL
    private let retention: TimeInterval = 8 * 86400

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tempo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        samples = (try? decoder.decode([Sample].self, from: data)) ?? []
    }

    func record(_ data: UsageData, at now: Date) {
        let sample = Sample(
            t: now,
            w: data.limit(.claudeWeekly)?.percent, m: data.limit(.claudeModel)?.percent,
            s: data.limit(.claudeSession)?.percent,
            gs: data.limit(.chatgptSession)?.percent, gw: data.limit(.chatgptWeekly)?.percent
        )
        if let last = samples.last,
           last.w == sample.w, last.m == sample.m, last.s == sample.s,
           last.gs == sample.gs, last.gw == sample.gw,
           sample.t.timeIntervalSince(last.t) < 30 * 60 {
            return
        }
        samples.append(sample)
        let cutoff = now.addingTimeInterval(-retention)
        samples.removeAll { $0.t < cutoff }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

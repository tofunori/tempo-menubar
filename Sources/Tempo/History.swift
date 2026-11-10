import Foundation

/// Un relevé d'usage : hebdo tous modèles (w) et hebdo du modèle suivi (m).
struct Sample: Codable, Equatable {
    let t: Date
    let w: Double?
    let m: Double?
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

    func record(_ snapshot: UsageSnapshot) {
        let sample = Sample(t: snapshot.fetchedAt, w: snapshot.weekly?.percent, m: snapshot.model?.percent)
        if let last = samples.last,
           last.w == sample.w, last.m == sample.m,
           sample.t.timeIntervalSince(last.t) < 30 * 60 {
            return
        }
        samples.append(sample)
        let cutoff = snapshot.fetchedAt.addingTimeInterval(-retention)
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

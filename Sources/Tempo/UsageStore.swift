import Foundation

/// Tient les derniers relevés des deux services, l'historique, et relance la lecture à intervalle fixe.
@MainActor
final class UsageStore: ObservableObject {
    enum State: Equatable {
        case idle, loading, ok
        case failed(String)
    }

    /// Dernier relevé de Claude.
    @Published private(set) var snapshot: UsageSnapshot?
    /// Dernier relevé de ChatGPT (Codex), lu dans les fichiers locaux. Nil si Codex n'a jamais tourné ici.
    @Published private(set) var chatgpt: UsageSnapshot?
    @Published private(set) var state: State = .idle
    @Published private(set) var samples: [Sample] = []

    private let client = UsageClient()
    private let history = HistoryStore()
    private var timer: Timer?
    private var interval: TimeInterval = 300

    /// Après un refus du service, on espace les essais automatiques.
    private var backoff: TimeInterval = 0
    private var retryAfter: Date?

    init() {
        samples = history.samples
        snapshot = UsageCache.load()
        // L'attente imposée par un refus survit à un relancement de l'app.
        let saved = UserDefaults.standard.double(forKey: "retryAfter")
        if saved > Date().timeIntervalSince1970 {
            retryAfter = Date(timeIntervalSince1970: saved)
            backoff = UserDefaults.standard.double(forKey: "backoff")
        }
    }

    var data: UsageData {
        UsageData(claude: snapshot, chatgpt: chatgpt, samples: samples)
    }

    /// Vrai quand le relevé de Claude est trop vieux pour qu'on s'y fie.
    var isStale: Bool {
        guard let snapshot else { return true }
        return Date().timeIntervalSince(snapshot.fetchedAt) > max(interval * 3, 900)
    }

    func start(every seconds: TimeInterval) {
        interval = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(automatic: true) }
        }
        timer?.tolerance = seconds * 0.1
        Task { await refreshLocal() }
        // Le service limite les demandes : au lancement, on réutilise un relevé encore frais.
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < seconds { return }
        Task { await refresh(automatic: true) }
    }

    /// Relit les fichiers de Codex. Aucun appel réseau, donc on peut le faire souvent.
    func refreshLocal() async {
        let fresh = await Task.detached { CodexUsage.loadLocal() }.value
        guard fresh != chatgpt else { return }
        chatgpt = fresh
        record()
    }

    /// - Parameter automatic: vrai pour les essais du minuteur, qui respectent l'espacement
    ///   après un refus. Le bouton Actualiser essaie toujours.
    func refresh(automatic: Bool = false) async {
        await refreshLocal()
        guard state != .loading else { return }
        if automatic, let retryAfter, Date() < retryAfter { return }
        state = .loading
        let client = self.client
        do {
            let fresh = try await Task.detached { try await client.fetch() }.value
            snapshot = fresh
            record()
            state = .ok
            backoff = 0
            retryAfter = nil
            UserDefaults.standard.removeObject(forKey: "retryAfter")
        } catch {
            if (error as? UsageError) == .rateLimited {
                backoff = min(max(backoff * 2, max(interval, 600)), 3600)
                let until = Date().addingTimeInterval(backoff)
                retryAfter = until
                UserDefaults.standard.set(until.timeIntervalSince1970, forKey: "retryAfter")
                UserDefaults.standard.set(backoff, forKey: "backoff")
            }
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func record() {
        history.record(data, at: Date())
        samples = history.samples
    }
}

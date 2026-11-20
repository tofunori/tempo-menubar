import Foundation

/// Tient les derniers relevés des services, l'historique, et relance la lecture à intervalle fixe.
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
    /// Dernier relevé d'Antigravity (serveur local ou CLI `agy`). Nil si Antigravity n'est pas utilisé ici.
    @Published private(set) var antigravity: UsageSnapshot?
    @Published private(set) var state: State = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var samples: [Sample] = []

    private let client = UsageClient()
    private let history = HistoryStore()
    private var timer: Timer?
    private var interval: TimeInterval = 300
    private var antigravityLoading = false

    /// Après un refus du service, on espace les essais automatiques.
    private var backoff: TimeInterval = 0
    private var retryAfter: Date?

    init() {
        samples = history.samples
        snapshot = UsageCache.load()
        antigravity = AntigravityCache.load()
        // L'attente imposée par un refus survit à un relancement de l'app.
        let saved = UserDefaults.standard.double(forKey: "retryAfter")
        if saved > Date().timeIntervalSince1970 {
            retryAfter = Date(timeIntervalSince1970: saved)
            backoff = UserDefaults.standard.double(forKey: "backoff")
        }
    }

    var data: UsageData {
        UsageData(claude: snapshot, chatgpt: chatgpt, antigravity: antigravity, samples: samples)
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
        // Le service de Claude limite les demandes : au lancement, on réutilise un relevé encore frais.
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < seconds {
            Task {
                await refreshCodex()
                let fresh = antigravity.map { Date().timeIntervalSince($0.fetchedAt) < seconds } ?? false
                await refreshAntigravity(allowCLI: !fresh, forceRefresh: !fresh)
            }
            return
        }
        Task { await refresh(automatic: true) }
    }

    /// Relit les sources locales rapides : fichiers de Codex et serveur local d'Antigravity s'il tourne déjà.
    func refreshLocal() async {
        async let cx: Void = refreshCodex()
        async let ag: Void = refreshAntigravity(allowCLI: false, forceRefresh: false)
        _ = await (cx, ag)
    }

    /// - Parameter automatic: vrai pour les essais du minuteur, qui respectent l'espacement
    ///   après un refus. Le bouton Actualiser essaie toujours.
    func refresh(automatic: Bool = false) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshCodex()
        async let ag: Void = refreshAntigravity(allowCLI: true, forceRefresh: true)
        async let cl: Void = refreshClaude(automatic: automatic)
        _ = await (ag, cl)
    }

    private func refreshCodex() async {
        let fresh = await Task.detached { CodexUsage.loadLocal() }.value
        guard fresh != chatgpt else { return }
        chatgpt = fresh
        record()
    }

    private func refreshAntigravity(allowCLI: Bool, forceRefresh: Bool) async {
        guard !antigravityLoading else { return }
        antigravityLoading = true
        defer { antigravityLoading = false }

        let fetched = await Task.detached {
            await AntigravityUsage.fetch(allowCLI: allowCLI, forceRefresh: forceRefresh)
        }.value

        let now = Date()
        if let fetched {
            let merged = allowCLI ? fetched : AntigravityUsage.merge(fresh: fetched, existing: antigravity, now: now)
            AntigravityCache.save(merged)
            guard merged != antigravity else { return }
            antigravity = merged
            record()
        } else if let current = antigravity {
            let pruned = AntigravityCache.pruneExpired(current, now: now)
            if pruned != current {
                antigravity = pruned
                if let pruned { AntigravityCache.save(pruned) }
                record()
            }
        }
    }

    private func refreshClaude(automatic: Bool) async {
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

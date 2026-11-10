import Foundation

/// Lit les limites de Codex (forfait ChatGPT) dans les fichiers de session que Codex écrit sur ce Mac.
/// Aucun appel réseau : le relevé a l'âge de la dernière utilisation de Codex ici.
enum CodexUsage {
    /// Les limites trouvées dans un fichier de session, avec l'heure où Codex les a notées.
    private struct Reading {
        let stamp: Date
        let windows: [[String: Any]]
    }

    private static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    // Un fichier inchangé n'est pas relu : on garde ce qu'on y avait trouvé.
    private static var cache: [String: (modified: Date, reading: Reading?)] = [:]
    private static let lock = NSLock()

    /// Le relevé le plus récent, ou nil si Codex n'a pas tourné sur ce Mac dans les huit derniers jours.
    /// - Parameter root: le dossier des sessions ; celui de Codex par défaut, un autre pour les tests.
    static func loadLocal(now: Date = Date(), root: URL? = nil) -> UsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        let files = recentSessionFiles(in: root ?? sessionsRoot, since: now.addingTimeInterval(-8 * 86400), limit: 80)
        var best: Reading?
        for file in files {
            let reading: Reading?
            if let hit = cache[file.url.path], hit.modified == file.modified {
                reading = hit.reading
            } else {
                reading = read(file.url)
                cache[file.url.path] = (file.modified, reading)
            }
            // Plusieurs sessions peuvent être modifiées en même temps : c'est l'heure du relevé qui compte.
            if let reading, reading.stamp > (best?.stamp ?? .distantPast) { best = reading }
        }
        if root == nil {
            let known = Set(files.map(\.url.path))
            cache = cache.filter { known.contains($0.key) }
        }

        guard let best else { return nil }
        let limits = best.windows.compactMap { limit(from: $0, readAt: best.stamp, now: now) }
        guard !limits.isEmpty else { return nil }
        return UsageSnapshot(limits: limits, weeklyWindowStart: nil, breakdown: [], fetchedAt: best.stamp)
    }

    private static func recentSessionFiles(in root: URL, since: Date, limit: Int) -> [(url: URL, modified: Date)] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified >= since { files.append((url, modified)) }
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Cherche, en partant de la fin du fichier, la dernière ligne qui porte des limites.
    private static func read(_ file: URL) -> Reading? {
        guard let text = tail(of: file, bytes: 2_000_000) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let limits = findRateLimits(in: object),
                let stamp = parseISODate(object["timestamp"] as? String)
            else { continue }
            let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
            if !windows.isEmpty { return Reading(stamp: stamp, windows: windows) }
        }
        return nil
    }

    private static func tail(of file: URL, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func findRateLimits(in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let limits = dict["rate_limits"] as? [String: Any] { return limits }
            for child in dict.values {
                if let found = findRateLimits(in: child) { return found }
            }
        } else if let list = value as? [Any] {
            for child in list {
                if let found = findRateLimits(in: child) { return found }
            }
        }
        return nil
    }

    private static func limit(from raw: [String: Any], readAt stamp: Date, now: Date) -> UsageLimit? {
        guard let used = (raw["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (raw["window_minutes"] as? NSNumber)?.doubleValue ?? 300

        var reset: Date?
        if let epoch = (raw["resets_at"] as? NSNumber)?.doubleValue {
            reset = Date(timeIntervalSince1970: epoch)
        } else if let seconds = (raw["resets_in_seconds"] as? NSNumber)?.doubleValue {
            reset = stamp.addingTimeInterval(seconds)
        }

        // Une fenêtre déjà réinitialisée depuis le relevé repart de zéro.
        let expired = reset.map { $0 <= now } ?? false
        return UsageLimit(
            kind: minutes >= 1440 ? .weeklyAll : .session,
            percent: expired ? 0 : used,
            resetsAt: expired ? nil : reset,
            provider: .chatgpt,
            length: minutes * 60
        )
    }
}

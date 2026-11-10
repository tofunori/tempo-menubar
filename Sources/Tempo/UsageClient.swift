import Foundation

enum UsageError: LocalizedError, Equatable {
    case noCredentials
    case tokenExpired
    case rateLimited
    case http(Int)
    case network(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "Connexion Claude Code introuvable dans le Trousseau."
        case .tokenExpired: return "Connexion expirée. Ouvre Claude Code pour la renouveler."
        case .rateLimited: return "Le service limite les demandes. Tempo espace ses essais et garde le dernier relevé."
        case .http(let code): return "Le service d'usage a répondu \(code)."
        case .network(let message): return "Réseau : \(message)"
        case .decode: return "Réponse du service illisible."
        }
    }
}

struct Credentials {
    let accessToken: String
    let expiresAt: Date?
}

/// Lit la connexion que Claude Code garde dans le Trousseau.
/// On passe par `/usr/bin/security`, comme Claude Code lui-même : l'entrée
/// l'autorise déjà, donc macOS ne redemande pas la permission à chaque compilation.
enum ClaudeCredentials {
    static let service = "Claude Code-credentials"

    static func load() throws -> Credentials {
        if let data = try? readKeychain(), let creds = parse(data) { return creds }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let creds = parse(data) { return creds }
        throw UsageError.noCredentials
    }

    private static func readKeychain() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UsageError.noCredentials }
        return data
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return Credentials(accessToken: token, expiresAt: expires)
    }
}

/// Interroge le même service que la commande `/usage` de Claude Code.
/// Ce point d'accès n'est pas documenté publiquement : il peut changer.
struct UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch() async throws -> UsageSnapshot {
        let creds = try ClaudeCredentials.load()
        if let expires = creds.expiresAt, expires < Date() { throw UsageError.tokenExpired }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tempo/0.1", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401, 403: throw UsageError.tokenExpired
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(code)
        }

        guard let api = try? JSONDecoder().decode(APIUsage.self, from: data) else {
            throw UsageError.decode
        }
        let snapshot = api.snapshot()
        guard !snapshot.limits.isEmpty else { throw UsageError.decode }
        UsageCache.save(data)
        return snapshot
    }
}

/// Garde la dernière réponse du service sur disque : l'app repart avec des chiffres
/// connus même si le service refuse momentanément de répondre.
enum UsageCache {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tempo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("last-usage.json")
    }

    static func save(_ data: Data) {
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> UsageSnapshot? {
        guard
            let data = try? Data(contentsOf: url),
            let api = try? JSONDecoder().decode(APIUsage.self, from: data),
            let saved = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        let snapshot = api.snapshot(now: saved)
        // Un relevé d'une fenêtre déjà réinitialisée ne veut plus rien dire.
        if let reset = snapshot.weekly?.resetsAt, reset < Date() { return nil }
        return snapshot.limits.isEmpty ? nil : snapshot
    }
}

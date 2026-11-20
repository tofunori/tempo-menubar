import Foundation

/// Lit les limites d'Antigravity (Gemini et Claude/GPT, fenêtres de 5 h et hebdo)
/// sans écran de connexion, en réutilisant ce qui tourne déjà sur ce Mac :
///   1. le serveur local de l'app Antigravity ou d'une session `agy` en cours,
///   2. la commande `agy -p /usage --output-format json` (si `agy` >= 1.1.11 est installé),
///   3. le serveur local de l'IDE Antigravity (fenêtres de 5 h seulement).
/// Les protocoles locaux et la sortie du CLI ne sont pas documentés publiquement et peuvent changer.
enum AntigravityUsage {
    enum ProcessKind: Equatable, Sendable {
        case app
        case cli
        case ide

        fileprivate var priority: Int {
            switch self {
            case .app: return 0
            case .cli: return 1
            case .ide: return 2
            }
        }
    }

    struct ProcessEntry: Equatable, Sendable {
        let pid: Int
        let kind: ProcessKind
        let csrfToken: String
        let extensionPort: Int?
        let extensionCSRFToken: String?
    }

    struct Endpoint: Equatable, Sendable {
        let scheme: String
        let port: Int
        let csrfToken: String
        let requiresCSRF: Bool
    }

    private static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let getUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelConfigsPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"

    private static let sessionAliases: Set<String> = ["session", "5h", "5-hour", "five hour", "five-hour"]
    private static let weeklyAliases: Set<String> = ["weekly", "7d", "7-day", "seven day", "seven-day"]

    private static let loopbackDelegate = LoopbackSessionDelegate()
    private static let loopbackSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: loopbackDelegate, delegateQueue: nil)
    }()

    private static let versionCache = VersionCache()

    // MARK: - Lecture complète

    /// Interroge Antigravity sur ce Mac. Retourne nil si Antigravity n'est ni ouvert ni installé.
    /// - Parameters:
    ///   - allowCLI: vrai pour lancer `agy -p /usage` si aucun serveur local n'a donné de résumé.
    ///   - forceRefresh: demande au serveur local d'actualiser son relevé auprès du service.
    static func fetch(allowCLI: Bool = true, forceRefresh: Bool = true, now: Date = Date()) async -> UsageSnapshot? {
        let processes = discoverProcesses()
        let summaryProcs = processes.filter { $0.kind == .app || $0.kind == .cli }
        let ideProcs = processes.filter { $0.kind == .ide }

        var fallback: UsageSnapshot?

        for proc in summaryProcs {
            let candidates = endpoints(for: proc)
            guard !candidates.isEmpty else { continue }
            if let summary = await probeQuotaSummary(on: candidates, forceRefresh: forceRefresh, now: now) {
                return summary
            }
            if fallback == nil {
                fallback = await probeModelQuotas(on: candidates, now: now)
            }
        }

        if allowCLI, let cliSnapshot = fetchViaCLI(now: now) {
            return cliSnapshot
        }

        if fallback == nil {
            for proc in ideProcs {
                let candidates = endpoints(for: proc)
                guard !candidates.isEmpty else { continue }
                if let summary = await probeQuotaSummary(on: candidates, forceRefresh: forceRefresh, now: now) {
                    return summary
                }
                if let legacy = await probeModelQuotas(on: candidates, now: now) {
                    return legacy
                }
            }
        }

        return fallback
    }

    /// Conserve les limites hebdo encore valides d'un relevé précédent quand une lecture rapide
    /// (par exemple celle de l'IDE) ne renvoie que les fenêtres de 5 heures.
    static func merge(fresh: UsageSnapshot, existing: UsageSnapshot?, now: Date = Date()) -> UsageSnapshot {
        guard !fresh.limits.contains(where: \.isWeekly), let existing else { return fresh }
        guard now.timeIntervalSince(existing.fetchedAt) < 2 * 3600 else { return fresh }
        let existingWeekly = existing.limits.filter { limit in
            guard limit.isWeekly else { return false }
            if let reset = limit.resetsAt, reset <= now { return false }
            return !fresh.limits.contains(where: { $0.id == limit.id })
        }
        guard !existingWeekly.isEmpty else { return fresh }
        var combined = fresh
        combined.limits = sortLimits(fresh.limits + existingWeekly)
        return combined
    }

    // MARK: - Découverte des processus et ports

    private static func discoverProcesses() -> [ProcessEntry] {
        guard let result = runProcess(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            timeout: 3
        ), result.status == 0 else { return [] }
        return parseProcessList(String(decoding: result.stdout, as: UTF8.self))
    }

    static func parseProcessList(_ output: String) -> [ProcessEntry] {
        var entries: [ProcessEntry] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let command = String(parts[1])
            guard let kind = classifyProcess(command) else { continue }

            let token = extractFlag("--csrf_token", from: command)
            // Les serveurs de l'app et de l'IDE exigent un jeton CSRF ; on ignore ceux qui n'en ont pas.
            if kind != .cli, token == nil { continue }

            let extPort = extractFlag("--extension_server_port", from: command).flatMap(Int.init)
            let extToken = extractFlag("--extension_server_csrf_token", from: command)
            entries.append(ProcessEntry(
                pid: pid,
                kind: kind,
                csrfToken: token ?? "",
                extensionPort: extPort,
                extensionCSRFToken: extToken
            ))
        }
        return entries.sorted { lhs, rhs in
            if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority < rhs.kind.priority }
            return lhs.pid < rhs.pid
        }
    }

    static func classifyProcess(_ command: String) -> ProcessKind? {
        let lower = command.lowercased()
        let isLanguageServer = lower.range(
            of: #"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)"#,
            options: .regularExpression
        ) != nil

        if isLanguageServer, isAntigravityCommand(lower) {
            return isIDECommand(lower) ? .ide : .app
        }
        if isCLICommand(lower) {
            return .cli
        }
        return nil
    }

    private static func isAntigravityCommand(_ lower: String) -> Bool {
        if lower.contains("--app_data_dir") && lower.contains("antigravity") { return true }
        if lower.contains("antigravity.app/") || lower.contains("antigravity.app\\") { return true }
        if lower.contains("/gemini.app/") || lower.contains("\\gemini.app\\") { return true }
        if lower.contains("antigravity ide.app/") || lower.contains("antigravity ide.app\\") { return true }
        if lower.contains("/antigravity/") || lower.contains("\\antigravity\\") { return true }
        return false
    }

    private static func isIDECommand(_ lower: String) -> Bool {
        let markers = [
            "antigravity ide.app/",
            "antigravity ide.app\\",
            "--app_data_dir antigravity-ide",
            "--app_data_dir=antigravity-ide",
            "/extensions/antigravity/bin/language_server",
            "\\extensions\\antigravity\\bin\\language_server",
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func isCLICommand(_ lower: String) -> Bool {
        if lower.range(of: #"(^|[/\\])(antigravity-cli|antigravity_cli)([\s/\\]|$)"#, options: .regularExpression) != nil {
            return true
        }
        return lower.range(of: #"(^|[/\\])agy(\s|$)"#, options: .regularExpression) != nil
    }

    static func extractFlag(_ flag: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard
            let match = regex.firstMatch(in: command, options: [], range: range),
            let valueRange = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[valueRange])
    }

    private static func endpoints(for process: ProcessEntry) -> [Endpoint] {
        let ports = listeningPorts(pid: process.pid)
        return buildEndpoints(for: process, listeningPorts: ports)
    }

    static func buildEndpoints(for process: ProcessEntry, listeningPorts: [Int]) -> [Endpoint] {
        var list: [Endpoint] = []
        func appendUnique(_ endpoint: Endpoint) {
            if !list.contains(endpoint) { list.append(endpoint) }
        }

        let needsCSRF = process.kind != .cli || !process.csrfToken.isEmpty
        for port in listeningPorts {
            appendUnique(Endpoint(scheme: "https", port: port, csrfToken: process.csrfToken, requiresCSRF: needsCSRF))
        }

        if let extPort = process.extensionPort, (1...65535).contains(extPort) {
            if let extToken = process.extensionCSRFToken, !extToken.isEmpty {
                appendUnique(Endpoint(scheme: "http", port: extPort, csrfToken: extToken, requiresCSRF: true))
            }
            if !process.csrfToken.isEmpty {
                appendUnique(Endpoint(scheme: "http", port: extPort, csrfToken: process.csrfToken, requiresCSRF: true))
            }
        }
        return list
    }

    private static func listeningPorts(pid: Int) -> [Int] {
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let lsof else { return [] }
        guard let result = runProcess(
            executable: lsof,
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            timeout: 3
        ) else { return [] }
        return parseListeningPorts(String(decoding: result.stdout, as: UTF8.self))
    }

    static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports: Set<Int> = []
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard
                let match,
                let portRange = Range(match.range(at: 1), in: output),
                let port = Int(output[portRange]),
                (1...65535).contains(port)
            else { return }
            ports.insert(port)
        }
        return ports.sorted()
    }

    // MARK: - Requêtes locales (Connect RPC sur 127.0.0.1)

    private static func probeQuotaSummary(
        on endpoints: [Endpoint], forceRefresh: Bool, now: Date
    ) async -> UsageSnapshot? {
        let body = Data((forceRefresh ? #"{"forceRefresh":true}"# : "{}").utf8)
        for endpoint in endpoints {
            guard let data = await post(path: quotaSummaryPath, body: body, endpoint: endpoint, timeout: 3) else { continue }
            if let snapshot = parseQuotaSummary(data, now: now) { return snapshot }
        }
        return nil
    }

    private static func probeModelQuotas(on endpoints: [Endpoint], now: Date) async -> UsageSnapshot? {
        let body = Data(
            #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8
        )
        for endpoint in endpoints {
            if let data = await post(path: getUserStatusPath, body: body, endpoint: endpoint, timeout: 3),
               let snapshot = parseUserStatus(data, now: now) {
                return snapshot
            }
        }
        for endpoint in endpoints {
            if let data = await post(path: commandModelConfigsPath, body: body, endpoint: endpoint, timeout: 3),
               let snapshot = parseCommandModelConfigs(data, now: now) {
                return snapshot
            }
        }
        return nil
    }

    private static func post(
        path: String, body: Data, endpoint: Endpoint, timeout: TimeInterval
    ) async -> Data? {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if endpoint.requiresCSRF, !endpoint.csrfToken.isEmpty {
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }

        do {
            let (data, response) = try await loopbackSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Repli via le CLI `agy`

    static func resolveBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override = env["ANTIGRAVITY_CLI_PATH"] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && isExecutable(trimmed) ? trimmed : nil
        }

        var candidates: [String] = []
        if let path = env["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                candidates.append(String(dir) + "/agy")
            }
        }
        candidates.append(contentsOf: [
            "\(home)/.local/bin/agy",
            "\(home)/.antigravity/antigravity/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ])

        var seen: Set<String> = []
        for path in candidates where seen.insert(path).inserted {
            if isExecutable(path) { return path }
        }
        return nil
    }

    static func parseVersion(_ output: String) -> (Int, Int, Int)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let parts = trimmed.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    private static func agyVersion(at binary: String) -> (Int, Int, Int)? {
        if let cached = versionCache.get(for: binary) { return cached }
        guard let result = runProcess(executable: binary, arguments: ["--version"], timeout: 3),
              result.status == 0
        else { return nil }
        let parsed = parseVersion(String(decoding: result.stdout, as: UTF8.self))
        if let parsed { versionCache.set(parsed, for: binary) }
        return parsed
    }

    private static func fetchViaCLI(now: Date) -> UsageSnapshot? {
        guard let binary = resolveBinary() else { return nil }
        // Avant 1.1.11, `-p /usage` pouvait être envoyé comme prompt au modèle.
        guard let version = agyVersion(at: binary), version >= (1, 1, 11) else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-agy-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: tempDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Empêche `agy` d'ouvrir un onglet de navigateur en arrière-plan si la session a expiré.
        for tool in ["open", "xdg-open"] {
            let stub = tempDir.appendingPathComponent(tool).path
            guard FileManager.default.createFile(
                atPath: stub,
                contents: Data("#!/bin/sh\nexit 1\n".utf8),
                attributes: [.posixPermissions: 0o700]
            ) else { return nil }
        }

        var env = ProcessInfo.processInfo.environment
        let basePath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(tempDir.path):\(basePath):/opt/homebrew/bin:/usr/local/bin"
        env["BROWSER"] = tempDir.appendingPathComponent("open").path

        guard let result = runProcess(
            executable: binary,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "30s"],
            environment: env,
            directory: tempDir,
            timeout: 35
        ), result.status == 0 else { return nil }

        return parseCLIUsageReport(result.stdout, now: now)
    }

    // MARK: - Analyse des réponses

    static func parseQuotaSummary(_ data: Data, now: Date = Date()) -> UsageSnapshot? {
        guard let response = try? JSONDecoder().decode(QuotaSummaryResponse.self, from: data) else { return nil }
        if let code = response.code, !code.isOK { return nil }
        guard let groups = response.resolvedGroups, !groups.isEmpty else { return nil }
        return snapshot(from: groups, now: now)
    }

    static func parseCLIUsageReport(_ data: Data, now: Date = Date()) -> UsageSnapshot? {
        let payloadData = extractJSONObject(from: data) ?? data
        guard
            let report = try? JSONDecoder().decode(CLIUsageReport.self, from: payloadData),
            report.status?.uppercased() == "SUCCESS",
            report.command?.name == "usage",
            let groups = report.command?.data?.groups,
            !groups.isEmpty
        else { return nil }
        return snapshot(from: groups, now: now)
    }

    static func parseUserStatus(_ data: Data, now: Date = Date()) -> UsageSnapshot? {
        guard let response = try? JSONDecoder().decode(UserStatusResponse.self, from: data) else { return nil }
        if let code = response.code, !code.isOK { return nil }
        guard let configs = response.userStatus?.cascadeModelConfigData?.clientModelConfigs else { return nil }
        return snapshot(fromModelConfigs: configs, now: now)
    }

    static func parseCommandModelConfigs(_ data: Data, now: Date = Date()) -> UsageSnapshot? {
        guard let response = try? JSONDecoder().decode(CommandModelConfigsResponse.self, from: data) else { return nil }
        if let code = response.code, !code.isOK { return nil }
        guard let configs = response.clientModelConfigs else { return nil }
        return snapshot(fromModelConfigs: configs, now: now)
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let iso = parseISODate(raw) { return iso }
        if let seconds = Double(raw), seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        return nil
    }

    private static func extractJSONObject(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let first = text.firstIndex(of: "{"),
              let last = text.lastIndex(of: "}"),
              first <= last
        else { return nil }
        return Data(text[first...last].utf8)
    }

    private enum Cadence {
        case session, weekly, other
    }

    private enum Family {
        case gemini
        case claudeGPT
        case extra(String)
    }

    private static func snapshot(from groups: [QuotaGroup], now: Date) -> UsageSnapshot? {
        var limits: [UsageLimit] = []

        for group in groups {
            let groupName = group.resolvedName
            for bucket in group.buckets ?? [] {
                if bucket.disabled == true { continue }
                guard let remaining = bucket.resolvedRemainingFraction, remaining.isFinite else { continue }

                let used = min(max((1 - remaining) * 100, 0), 100)
                let reset = parseDate(bucket.resolvedResetTime)
                let expired = reset.map { $0 <= now } ?? false
                let cadence = resolveCadence(bucket)
                let family = resolveFamily(groupName: groupName, bucketID: bucket.resolvedID)

                let limit: UsageLimit
                switch (family, cadence) {
                case (.gemini, .session):
                    limit = UsageLimit(
                        kind: .sessionModel("Gemini"),
                        percent: expired ? 0 : used,
                        resetsAt: expired ? nil : reset,
                        provider: .antigravity,
                        length: 5 * 3600
                    )
                case (.gemini, .weekly):
                    limit = UsageLimit(
                        kind: .weeklyModel("Gemini"),
                        percent: expired ? 0 : used,
                        resetsAt: expired ? nil : reset,
                        provider: .antigravity,
                        length: 7 * 86400
                    )
                case (.claudeGPT, .session):
                    limit = UsageLimit(
                        kind: .sessionModel("Claude/GPT"),
                        percent: expired ? 0 : used,
                        resetsAt: expired ? nil : reset,
                        provider: .antigravity,
                        length: 5 * 3600
                    )
                case (.claudeGPT, .weekly):
                    limit = UsageLimit(
                        kind: .weeklyModel("Claude/GPT"),
                        percent: expired ? 0 : used,
                        resetsAt: expired ? nil : reset,
                        provider: .antigravity,
                        length: 7 * 86400
                    )
                case (.extra(let title), .weekly):
                    limit = UsageLimit(
                        kind: .weeklyModel(title),
                        percent: expired ? 0 : used,
                        resetsAt: expired ? nil : reset,
                        provider: .antigravity,
                        length: 7 * 86400
                    )
                case (.extra(let title), .session):
                    limit = UsageLimit(
                        kind: .sessionModel(title),
                        percent: expired ? 0 : used,
                        resetsAt: expired ? nil : reset,
                        provider: .antigravity,
                        length: 5 * 3600
                    )
                default:
                    let prefix: String
                    switch family {
                    case .gemini: prefix = "Gemini"
                    case .claudeGPT: prefix = "Claude/GPT"
                    case .extra(let title): prefix = title
                    }
                    let suffix = bucket.resolvedName ?? bucket.resolvedID ?? "Quota"
                    let length: TimeInterval? = cadence == .weekly ? 7 * 86400 : cadence == .session ? 5 * 3600 : nil
                    limit = UsageLimit(
                        kind: .other("\(prefix) · \(suffix)"),
                        percent: expired ? 0 : used,
                        resetsAt: expired ? nil : reset,
                        provider: .antigravity,
                        length: length
                    )
                }
                limits.append(limit)
            }
        }

        let unique = deduplicateAndSort(limits)
        guard !unique.isEmpty else { return nil }
        return UsageSnapshot(limits: unique, weeklyWindowStart: nil, breakdown: [], fetchedAt: now)
    }

    private static func snapshot(fromModelConfigs configs: [ModelConfig], now: Date) -> UsageSnapshot? {
        struct Candidate {
            let used: Double
            let reset: Date?
        }

        var gemini: [Candidate] = []
        var claudeGPT: [Candidate] = []

        for config in configs {
            guard let remaining = config.quotaInfo?.remainingFraction, remaining.isFinite else { continue }
            let modelID = (config.modelOrAlias?.model ?? "").lowercased()
            let label = (config.label ?? "").lowercased()
            let combined = "\(modelID) \(label)"

            // On écarte les modèles cachés ou auxiliaires qui ne représentent pas le quota principal.
            if combined.contains("lite") || combined.contains("autocomplete")
                || combined.contains("image") || modelID.hasPrefix("tab_") {
                continue
            }

            let candidate = Candidate(
                used: min(max((1 - remaining) * 100, 0), 100),
                reset: parseDate(config.quotaInfo?.resetTime?.raw)
            )
            if combined.contains("gemini") {
                gemini.append(candidate)
            } else if combined.contains("claude") || combined.contains("opus")
                || combined.contains("sonnet") || combined.contains("haiku") || combined.contains("gpt") {
                claudeGPT.append(candidate)
            }
        }

        func pick(_ pool: [Candidate], name: String) -> UsageLimit? {
            guard let worst = pool.max(by: { lhs, rhs in
                if lhs.used != rhs.used { return lhs.used < rhs.used }
                switch (lhs.reset, rhs.reset) {
                case let (.some(a), .some(b)): return a > b
                case (.none, .some): return true
                default: return false
                }
            }) else { return nil }

            let expired = worst.reset.map { $0 <= now } ?? false
            let isWeekly = worst.reset.map { !expired && $0.timeIntervalSince(now) > 24 * 3600 } ?? false
            return UsageLimit(
                kind: isWeekly ? .weeklyModel(name) : .sessionModel(name),
                percent: expired ? 0 : worst.used,
                resetsAt: expired ? nil : worst.reset,
                provider: .antigravity,
                length: isWeekly ? 7 * 86400 : 5 * 3600
            )
        }

        let limits = sortLimits([pick(gemini, name: "Gemini"), pick(claudeGPT, name: "Claude/GPT")].compactMap { $0 })
        guard !limits.isEmpty else { return nil }
        return UsageSnapshot(limits: limits, weeklyWindowStart: nil, breakdown: [], fetchedAt: now)
    }

    private static func resolveCadence(_ bucket: QuotaBucket) -> Cadence {
        let explicit = bucket.window?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources: [String]
        if let explicit, !explicit.isEmpty {
            sources = [explicit]
        } else {
            sources = [bucket.resolvedID, bucket.resolvedName].compactMap { $0 }
        }

        var tokens: Set<String> = []
        for raw in sources {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty else { continue }
            var variants = [normalized]
            if normalized.hasSuffix(" limit") {
                variants.append(String(normalized.dropLast(" limit".count)))
            }
            if normalized.hasSuffix(" limit remaining") {
                variants.append(String(normalized.dropLast(" limit remaining".count)))
            }
            for variant in variants {
                tokens.insert(variant)
                for alias in sessionAliases.union(weeklyAliases) {
                    if variant.hasSuffix("-\(alias)") || variant.hasPrefix("\(alias)-")
                        || variant.contains(" \(alias)") || variant.contains("\(alias) ") {
                        tokens.insert(alias)
                    }
                }
            }
        }

        if !tokens.isDisjoint(with: sessionAliases) { return .session }
        if !tokens.isDisjoint(with: weeklyAliases) { return .weekly }
        return .other
    }

    private static func resolveFamily(groupName: String?, bucketID: String?) -> Family {
        var rawID = (bucketID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        for suffix in ["-limit", " limit"] where rawID.hasSuffix(suffix) {
            rawID.removeLast(suffix.count)
        }
        let title = (groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTitle = title.lowercased()

        // Les compartiments ordinaires Gemini ont un identifiant de la forme `gemini-5h` ou `gemini-weekly`.
        let ordinaryGeminiIDs = Set(sessionAliases.union(weeklyAliases).map { "gemini-\($0)" })
        if ordinaryGeminiIDs.contains(rawID) { return .gemini }

        if rawID.contains("3p") || rawID.contains("third-party") || rawID.contains("claude") || rawID.contains("gpt") {
            return .claudeGPT
        }

        // Un groupe versionné (par exemple « Gemini 4 Argon ») garde son propre nom à part.
        if lowerTitle.contains("gemini") {
            if title.contains(where: \.isNumber) { return .extra(title) }
            return .gemini
        }
        if lowerTitle.contains("claude") || lowerTitle.contains("gpt") {
            return .claudeGPT
        }
        if rawID.contains("gemini") {
            return title.isEmpty ? .gemini : .extra(title)
        }
        return .extra(title.isEmpty ? "Quota" : title)
    }

    private static func deduplicateAndSort(_ limits: [UsageLimit]) -> [UsageLimit] {
        var byID: [String: UsageLimit] = [:]
        for limit in limits {
            if let existing = byID[limit.id] {
                if limit.percent > existing.percent
                    || (limit.percent == existing.percent && (limit.resetsAt ?? .distantFuture) < (existing.resetsAt ?? .distantFuture)) {
                    byID[limit.id] = limit
                }
            } else {
                byID[limit.id] = limit
            }
        }
        return sortLimits(Array(byID.values))
    }

    private static func sortLimits(_ limits: [UsageLimit]) -> [UsageLimit] {
        func rank(_ limit: UsageLimit) -> Int {
            switch limit.key {
            case .antigravityGeminiSession: return 0
            case .antigravityGeminiWeekly: return 1
            case .antigravityClaudeSession: return 2
            case .antigravityClaudeWeekly: return 3
            default: return 4
            }
        }
        return limits.sorted { lhs, rhs in
            let a = rank(lhs), b = rank(rhs)
            if a != b { return a < b }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Sous-processus avec délai limite

    private static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        timeout: TimeInterval
    ) -> (status: Int32, stdout: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }

        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let guardState = ProcessTimeoutGuard(process: process)
        let deadline = DispatchWorkItem { guardState.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

        do {
            try process.run()
        } catch {
            deadline.cancel()
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        guard !guardState.timedOut else { return nil }
        return (process.terminationStatus, data)
    }

    // MARK: - Modèles de décodage tolérants

    private enum StatusCode: Decodable {
        case int(Int)
        case string(String)

        var isOK: Bool {
            switch self {
            case .int(let n): return n == 0
            case .string(let s): return ["ok", "success", "0"].contains(s.lowercased())
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .int(n); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            throw DecodingError.typeMismatch(
                StatusCode.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "code")
            )
        }
    }

    private struct FlexibleDate: Decodable {
        let raw: String

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { raw = s; return }
            if let n = try? c.decode(Double.self) { raw = String(n); return }
            throw DecodingError.typeMismatch(
                FlexibleDate.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "date")
            )
        }
    }

    private struct QuotaRemaining: Decodable {
        let fraction: Double?

        private enum Keys: String, CodingKey {
            case remainingFraction, remaining_fraction, oneofCase = "case", value
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if let v = (try? c.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil {
                fraction = v
                return
            }
            if let v = (try? c.decodeIfPresent(Double.self, forKey: .remaining_fraction)) ?? nil {
                fraction = v
                return
            }
            let kind = (try? c.decodeIfPresent(String.self, forKey: .oneofCase)) ?? nil
            if kind == "remainingFraction" || kind == "remaining_fraction" {
                fraction = (try? c.decodeIfPresent(Double.self, forKey: .value)) ?? nil
            } else {
                fraction = nil
            }
        }
    }

    private struct QuotaBucket: Decodable {
        let bucketId: String?
        let bucket_id: String?
        let id: String?
        let displayName: String?
        let display_name: String?
        let name: String?
        let remainingFraction: Double?
        let remaining_fraction: Double?
        let remaining: QuotaRemaining?
        let resetTime: FlexibleDate?
        let reset_time: FlexibleDate?
        let disabled: Bool?
        let window: String?

        var resolvedID: String? { bucketId ?? bucket_id ?? id }
        var resolvedName: String? { displayName ?? display_name ?? name }
        var resolvedRemainingFraction: Double? { remainingFraction ?? remaining_fraction ?? remaining?.fraction }
        var resolvedResetTime: String? { resetTime?.raw ?? reset_time?.raw }

        private enum Keys: String, CodingKey {
            case bucketId, bucket_id, id, displayName, display_name, name
            case remainingFraction, remaining_fraction, remaining, resetTime, reset_time, disabled, window
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            bucketId = (try? c.decodeIfPresent(String.self, forKey: .bucketId)) ?? nil
            bucket_id = (try? c.decodeIfPresent(String.self, forKey: .bucket_id)) ?? nil
            id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
            displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
            display_name = (try? c.decodeIfPresent(String.self, forKey: .display_name)) ?? nil
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
            remainingFraction = (try? c.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil
            remaining_fraction = (try? c.decodeIfPresent(Double.self, forKey: .remaining_fraction)) ?? nil
            remaining = (try? c.decodeIfPresent(QuotaRemaining.self, forKey: .remaining)) ?? nil
            resetTime = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .resetTime)) ?? nil
            reset_time = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .reset_time)) ?? nil
            disabled = (try? c.decodeIfPresent(Bool.self, forKey: .disabled)) ?? nil
            window = (try? c.decodeIfPresent(String.self, forKey: .window)) ?? nil
        }
    }

    private struct QuotaGroup: Decodable {
        let displayName: String?
        let display_name: String?
        let name: String?
        let buckets: [QuotaBucket]?

        var resolvedName: String? { displayName ?? display_name ?? name }

        private enum Keys: String, CodingKey {
            case displayName, display_name, name, buckets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
            display_name = (try? c.decodeIfPresent(String.self, forKey: .display_name)) ?? nil
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
            buckets = (try? c.decodeIfPresent([QuotaBucket].self, forKey: .buckets)) ?? nil
        }
    }

    private struct QuotaSummaryPayload: Decodable {
        let groups: [QuotaGroup]?

        private enum Keys: String, CodingKey { case groups }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            groups = (try? c.decodeIfPresent([QuotaGroup].self, forKey: .groups)) ?? nil
        }
    }

    private struct QuotaSummaryResponse: Decodable {
        let code: StatusCode?
        let response: QuotaSummaryPayload?
        let summary: QuotaSummaryPayload?
        let groups: [QuotaGroup]?

        var resolvedGroups: [QuotaGroup]? { response?.groups ?? summary?.groups ?? groups }

        private enum Keys: String, CodingKey { case code, response, summary, groups }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            code = (try? c.decodeIfPresent(StatusCode.self, forKey: .code)) ?? nil
            response = (try? c.decodeIfPresent(QuotaSummaryPayload.self, forKey: .response)) ?? nil
            summary = (try? c.decodeIfPresent(QuotaSummaryPayload.self, forKey: .summary)) ?? nil
            groups = (try? c.decodeIfPresent([QuotaGroup].self, forKey: .groups)) ?? nil
        }
    }

    private struct CLIUsageReport: Decodable {
        struct Command: Decodable {
            let name: String?
            let data: QuotaSummaryPayload?
        }

        let status: String?
        let command: Command?

        private enum Keys: String, CodingKey { case status, command }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
            command = (try? c.decodeIfPresent(Command.self, forKey: .command)) ?? nil
        }
    }

    private struct ModelConfig: Decodable {
        struct Alias: Decodable { let model: String? }
        struct QuotaInfo: Decodable {
            let remainingFraction: Double?
            let resetTime: FlexibleDate?

            private enum Keys: String, CodingKey { case remainingFraction, resetTime }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                remainingFraction = (try? c.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil
                resetTime = (try? c.decodeIfPresent(FlexibleDate.self, forKey: .resetTime)) ?? nil
            }
        }

        let label: String?
        let modelOrAlias: Alias?
        let quotaInfo: QuotaInfo?

        private enum Keys: String, CodingKey { case label, modelOrAlias, quotaInfo }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
            modelOrAlias = (try? c.decodeIfPresent(Alias.self, forKey: .modelOrAlias)) ?? nil
            quotaInfo = (try? c.decodeIfPresent(QuotaInfo.self, forKey: .quotaInfo)) ?? nil
        }
    }

    private struct UserStatusResponse: Decodable {
        struct UserStatus: Decodable {
            struct ModelConfigData: Decodable { let clientModelConfigs: [ModelConfig]? }
            let cascadeModelConfigData: ModelConfigData?
        }

        let code: StatusCode?
        let userStatus: UserStatus?

        private enum Keys: String, CodingKey { case code, userStatus }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            code = (try? c.decodeIfPresent(StatusCode.self, forKey: .code)) ?? nil
            userStatus = (try? c.decodeIfPresent(UserStatus.self, forKey: .userStatus)) ?? nil
        }
    }

    private struct CommandModelConfigsResponse: Decodable {
        let code: StatusCode?
        let clientModelConfigs: [ModelConfig]?

        private enum Keys: String, CodingKey { case code, clientModelConfigs }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            code = (try? c.decodeIfPresent(StatusCode.self, forKey: .code)) ?? nil
            clientModelConfigs = (try? c.decodeIfPresent([ModelConfig].self, forKey: .clientModelConfigs)) ?? nil
        }
    }

    // MARK: - Helpers internes sûrs pour la concurrence

    /// Accepte le certificat auto-signé du serveur local d'Antigravity, uniquement sur 127.0.0.1 / localhost.
    private final class LoopbackSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        private func decide(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            let space = challenge.protectionSpace
            let host = space.host.lowercased()
            guard
                space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                host == "127.0.0.1" || host == "localhost",
                let trust = space.serverTrust
            else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }

        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            decide(challenge)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            decide(challenge)
        }
    }

    private final class ProcessTimeoutGuard: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var didTimeOut = false

        init(process: Process) { self.process = process }

        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didTimeOut
        }

        func expire() {
            lock.lock()
            didTimeOut = true
            let running = process.isRunning
            lock.unlock()
            if running { process.terminate() }
        }
    }

    private final class VersionCache: @unchecked Sendable {
        private struct Entry {
            let path: String
            let modified: Date?
            let size: UInt64?
            let version: (Int, Int, Int)
        }

        private let lock = NSLock()
        private var entry: Entry?

        func get(for path: String) -> (Int, Int, Int)? {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = attrs?[.modificationDate] as? Date
            let size = (attrs?[.size] as? NSNumber)?.uint64Value
            lock.lock()
            defer { lock.unlock() }
            guard let entry, entry.path == path, entry.modified == modified, entry.size == size else { return nil }
            return entry.version
        }

        func set(_ version: (Int, Int, Int), for path: String) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = attrs?[.modificationDate] as? Date
            let size = (attrs?[.size] as? NSNumber)?.uint64Value
            lock.lock()
            defer { lock.unlock() }
            entry = Entry(path: path, modified: modified, size: size, version: version)
        }
    }
}

/// Garde le dernier relevé d'Antigravity sur disque : Tempo continue d'afficher
/// les chiffres connus même après la fermeture de l'app Antigravity.
enum AntigravityCache {
    private struct StoredLimit: Codable {
        let kind: String
        let name: String
        let percent: Double
        let resetsAt: Date?
        let length: TimeInterval?
    }

    private struct StoredSnapshot: Codable {
        let fetchedAt: Date
        let limits: [StoredLimit]
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tempo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("last-antigravity.json")
    }

    static func save(_ snapshot: UsageSnapshot, to url: URL? = nil) {
        let stored = StoredSnapshot(
            fetchedAt: snapshot.fetchedAt,
            limits: snapshot.limits.map { limit in
                switch limit.kind {
                case .sessionModel(let name):
                    return StoredLimit(kind: "session_model", name: name, percent: limit.percent, resetsAt: limit.resetsAt, length: limit.length)
                case .weeklyModel(let name):
                    return StoredLimit(kind: "weekly_model", name: name, percent: limit.percent, resetsAt: limit.resetsAt, length: limit.length)
                case .session:
                    return StoredLimit(kind: "session", name: "", percent: limit.percent, resetsAt: limit.resetsAt, length: limit.length)
                case .weeklyAll:
                    return StoredLimit(kind: "weekly_all", name: "", percent: limit.percent, resetsAt: limit.resetsAt, length: limit.length)
                case .other(let raw):
                    return StoredLimit(kind: "other", name: raw, percent: limit.percent, resetsAt: limit.resetsAt, length: limit.length)
                }
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: url ?? defaultURL, options: .atomic)
    }

    static func load(now: Date = Date(), from url: URL? = nil) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url ?? defaultURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let stored = try? decoder.decode(StoredSnapshot.self, from: data) else { return nil }
        guard now.timeIntervalSince(stored.fetchedAt) <= 8 * 86400 else { return nil }

        let rawLimits: [UsageLimit] = stored.limits.map { item in
            let kind: UsageLimit.Kind
            switch item.kind {
            case "session_model": kind = .sessionModel(item.name)
            case "weekly_model": kind = .weeklyModel(item.name)
            case "session": kind = .session
            case "weekly_all": kind = .weeklyAll
            default: kind = .other(item.name)
            }
            return UsageLimit(
                kind: kind, percent: item.percent, resetsAt: item.resetsAt,
                provider: .antigravity, length: item.length
            )
        }
        return pruneExpired(
            UsageSnapshot(limits: rawLimits, weeklyWindowStart: nil, breakdown: [], fetchedAt: stored.fetchedAt),
            now: now
        )
    }

    /// Remet à zéro les fenêtres déjà réinitialisées. Retourne nil si toutes les fenêtres datées ont expiré.
    static func pruneExpired(_ snapshot: UsageSnapshot, now: Date = Date()) -> UsageSnapshot? {
        guard !snapshot.limits.isEmpty else { return nil }
        let dated = snapshot.limits.filter { $0.resetsAt != nil }
        if !dated.isEmpty, dated.allSatisfy({ ($0.resetsAt ?? .distantPast) <= now }) {
            return nil
        }
        let updated = snapshot.limits.map { limit -> UsageLimit in
            guard let reset = limit.resetsAt, reset <= now else { return limit }
            return UsageLimit(
                kind: limit.kind, percent: 0, resetsAt: nil,
                provider: limit.provider, length: limit.length
            )
        }
        return UsageSnapshot(
            limits: updated,
            weeklyWindowStart: snapshot.weeklyWindowStart,
            breakdown: snapshot.breakdown,
            fetchedAt: snapshot.fetchedAt
        )
    }
}

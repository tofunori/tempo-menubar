import XCTest
@testable import Tempo

final class ParsingTests: XCTestCase {
    // MARK: - Service de Claude

    func testDatesWithMicroseconds() throws {
        let date = try XCTUnwrap(parseISODate("2026-11-12T07:00:00.651333+00:00"))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-12T07:00:00Z"))
        XCTAssertEqual(date, expected)
        XCTAssertNil(parseISODate("pas une date"))
        XCTAssertNil(parseISODate(nil))
    }

    func testClaudeUsageResponse() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": {"utilization": 55.0, "resets_at": "2026-11-12T07:00:00.651333+00:00"},
          "seven_day_opus": null,
          "some_new_field": {"anything": [1, 2, 3]},
          "limits": [
            {"kind": "weekly_all", "group": "weekly", "percent": 55,
             "resets_at": "2026-11-12T07:00:00.651333+00:00", "scope": null},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 8,
             "resets_at": "2026-11-12T07:00:00.651469+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
          ],
          "seven_day_breakdown": {
            "window_started_at": "2026-11-05T07:00:00.651333+00:00",
            "rows": [
              {"key": "claude_code", "display_name": "Claude Code", "percent": 91},
              {"key": "other", "display_name": "Other", "percent": 0}
            ]
          }
        }
        """
        let api = try JSONDecoder().decode(APIUsage.self, from: Data(json.utf8))
        let snapshot = api.snapshot()

        XCTAssertEqual(snapshot.limits.count, 2)
        XCTAssertEqual(snapshot.weekly?.percent, 55)
        XCTAssertEqual(snapshot.model?.percent, 8)
        XCTAssertEqual(snapshot.modelName, "Fable")
        XCTAssertEqual(snapshot.weekly?.key, .claudeWeekly)
        XCTAssertEqual(snapshot.model?.key, .claudeModel)
        XCTAssertNotNil(snapshot.weeklyWindowStart)
        XCTAssertEqual(snapshot.breakdown.map(\.name), ["Claude Code"], "Les lignes à 0 % sont écartées")
    }

    func testClaudeResponseWithoutTheLimitsList() throws {
        let json = #"{"seven_day": {"utilization": 41.2, "resets_at": "2026-11-12T07:00:00+00:00"}}"#
        let snapshot = try JSONDecoder().decode(APIUsage.self, from: Data(json.utf8)).snapshot()
        XCTAssertEqual(snapshot.weekly?.percent, 41.2)
        XCTAssertNil(snapshot.model)
    }

    // MARK: - Fichiers de Codex

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func line(stamp: Date, session: Double, weekly: Double, sessionReset: Date, weeklyReset: Date) -> String {
        """
        {"timestamp":"\(iso(stamp))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex",\
        "primary":{"used_percent":\(session),"window_minutes":300,"resets_at":\(Int(sessionReset.timeIntervalSince1970))},\
        "secondary":{"used_percent":\(weekly),"window_minutes":10080,"resets_at":\(Int(weeklyReset.timeIntervalSince1970))}}}}
        """
    }

    private func write(_ name: String, lines: [String], modified: Date) throws {
        let url = folder.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testCodexPicksTheNewestReadingNotTheNewestFile() throws {
        let now = Date()
        let soon = now.addingTimeInterval(3 * 3600), later = now.addingTimeInterval(3 * 86400)
        // Fichier modifié en dernier, mais avec un relevé plus ancien.
        try write("a.jsonl", lines: [
            #"{"timestamp":"x","type":"session_meta"}"#,
            line(stamp: now.addingTimeInterval(-2 * 3600), session: 5, weekly: 1, sessionReset: soon, weeklyReset: later),
        ], modified: now.addingTimeInterval(-60))
        try write("b.jsonl", lines: [
            line(stamp: now.addingTimeInterval(-4 * 3600), session: 1, weekly: 0, sessionReset: soon, weeklyReset: later),
            line(stamp: now.addingTimeInterval(-1 * 3600), session: 30, weekly: 10, sessionReset: soon, weeklyReset: later),
        ], modified: now.addingTimeInterval(-600))

        let snapshot = try XCTUnwrap(CodexUsage.loadLocal(now: now, root: folder))
        let session = try XCTUnwrap(snapshot.limits.first { $0.key == .chatgptSession })
        let weekly = try XCTUnwrap(snapshot.limits.first { $0.key == .chatgptWeekly })
        XCTAssertEqual(session.percent, 30)
        XCTAssertEqual(weekly.percent, 10)
        XCTAssertEqual(weekly.windowLength, 7 * 86400)
        XCTAssertEqual(snapshot.fetchedAt.timeIntervalSince(now), -3600, accuracy: 1)
    }

    func testCodexWindowThatHasAlreadyResetStartsFromZero() throws {
        let now = Date()
        try write("c.jsonl", lines: [
            line(stamp: now.addingTimeInterval(-6 * 3600), session: 70, weekly: 12,
                 sessionReset: now.addingTimeInterval(-3600), weeklyReset: now.addingTimeInterval(86400)),
        ], modified: now)
        let snapshot = try XCTUnwrap(CodexUsage.loadLocal(now: now, root: folder))
        let session = try XCTUnwrap(snapshot.limits.first { $0.key == .chatgptSession })
        XCTAssertEqual(session.percent, 0)
        XCTAssertNil(session.resetsAt)
        XCTAssertEqual(snapshot.limits.first { $0.key == .chatgptWeekly }?.percent, 12)
    }

    func testCodexWithoutAnyReading() throws {
        try write("d.jsonl", lines: [#"{"timestamp":"x","type":"session_meta"}"#], modified: Date())
        XCTAssertNil(CodexUsage.loadLocal(now: Date(), root: folder))
        XCTAssertNil(CodexUsage.loadLocal(now: Date(), root: folder.appendingPathComponent("absent")))
    }

    // MARK: - Antigravity

    func testAntigravityQuotaSummaryResponse() throws {
        let now = try XCTUnwrap(parseISODate("2026-06-15T08:00:00Z"))
        let json = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {
                    "bucketId": "gemini-weekly",
                    "displayName": "Weekly Limit",
                    "remaining": { "remainingFraction": 0.82 },
                    "resetTime": "2026-06-19T08:45:39Z"
                  },
                  {
                    "bucketId": "gemini-5h",
                    "displayName": "Five Hour Limit",
                    "remaining": { "remainingFraction": 0.91 },
                    "resetTime": "2026-06-15T11:39:34Z"
                  }
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  {
                    "bucketId": "3p-weekly",
                    "displayName": "Weekly Limit",
                    "remaining": { "remainingFraction": 0.64 },
                    "resetTime": "2026-06-20T00:39:54Z"
                  },
                  {
                    "bucketId": "3p-5h",
                    "displayName": "Five Hour Limit",
                    "remaining": { "remainingFraction": 0.73 },
                    "resetTime": "2026-06-15T12:52:10Z"
                  }
                ]
              }
            ]
          }
        }
        """

        let snapshot = try XCTUnwrap(AntigravityUsage.parseQuotaSummary(Data(json.utf8), now: now))
        XCTAssertEqual(snapshot.limits.map(\.key), [
            .antigravityGeminiSession,
            .antigravityGeminiWeekly,
            .antigravityClaudeSession,
            .antigravityClaudeWeekly,
        ])
        XCTAssertEqual(snapshot.limits[0].percent, 9, accuracy: 1e-6)
        XCTAssertEqual(snapshot.limits[1].percent, 18, accuracy: 1e-6)
        XCTAssertEqual(snapshot.limits[2].percent, 27, accuracy: 1e-6)
        XCTAssertEqual(snapshot.limits[3].percent, 36, accuracy: 1e-6)
        XCTAssertEqual(snapshot.limits[0].windowLength, 5 * 3600)
        XCTAssertEqual(snapshot.limits[1].windowLength, 7 * 86400)
        XCTAssertEqual(snapshot.limits[1].resetsAt, parseISODate("2026-06-19T08:45:39Z"))
    }

    func testAntigravityQuotaSummaryOneOfDisabledAndVersionedGroup() throws {
        let now = try XCTUnwrap(parseISODate("2026-06-15T08:00:00Z"))
        let json = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit",
                  "remaining": { "case": "remainingFraction", "value": 0.5 },
                  "resetTime": "2026-06-19T08:45:39Z"
                },
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit",
                  "disabled": true,
                  "remaining": { "remainingFraction": 0.2 }
                }
              ]
            },
            {
              "displayName": "Gemini 4 Argon",
              "buckets": [
                {
                  "bucketId": "gemini-argon-weekly",
                  "displayName": "Weekly Limit",
                  "remaining": { "remainingFraction": 0.8 },
                  "resetTime": "2026-06-19T08:45:39Z"
                }
              ]
            }
          ]
        }
        """

        let snapshot = try XCTUnwrap(AntigravityUsage.parseQuotaSummary(Data(json.utf8), now: now))
        XCTAssertEqual(snapshot.limits.count, 2)
        XCTAssertEqual(snapshot.limits[0].key, .antigravityGeminiWeekly)
        XCTAssertEqual(snapshot.limits[0].percent, 50, accuracy: 1e-6)
        XCTAssertNil(snapshot.limits[1].key, "Un groupe versionné ne doit pas écraser le quota Gemini ordinaire")
        XCTAssertEqual(snapshot.limits[1].kind, .weeklyModel("Gemini 4 Argon"))
        XCTAssertEqual(snapshot.limits[1].percent, 20, accuracy: 1e-6)
    }

    func testAntigravityCLIUsageReport() throws {
        let now = try XCTUnwrap(parseISODate("2026-09-12T22:00:00Z"))
        let json = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.86,
                      "reset_time": "2026-09-17T18:40:27Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.95,
                      "reset_time": "2026-09-13T03:48:04Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.89,
                      "reset_time": "2026-09-17T02:38:46Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(AntigravityUsage.parseCLIUsageReport(Data(json.utf8), now: now))
        XCTAssertEqual(snapshot.limits.map(\.key), [
            .antigravityGeminiSession,
            .antigravityGeminiWeekly,
            .antigravityClaudeWeekly,
        ])
        XCTAssertEqual(snapshot.limits[0].percent, 5, accuracy: 1e-6)
        XCTAssertEqual(snapshot.limits[1].percent, 14, accuracy: 1e-6)
        XCTAssertEqual(snapshot.limits[2].percent, 11, accuracy: 1e-6)

        let failed = #"{"status":"ERROR","command":{"name":"usage","data":{"groups":[]}}}"#
        XCTAssertNil(AntigravityUsage.parseCLIUsageReport(Data(failed.utf8), now: now))
    }

    func testAntigravityUserStatusAndCommandConfigsFallback() throws {
        let now = try XCTUnwrap(parseISODate("2026-06-15T08:00:00Z"))
        let userStatus = """
        {
          "code": 0,
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 3.8 Flash",
                  "modelOrAlias": { "model": "gemini-3.8-flash" },
                  "quotaInfo": { "remainingFraction": 0.9, "resetTime": "2026-06-15T12:00:00Z" }
                },
                {
                  "label": "Gemini 3.1 Pro",
                  "modelOrAlias": { "model": "gemini-3.1-pro" },
                  "quotaInfo": { "remainingFraction": 0.75, "resetTime": "2026-06-15T11:30:00Z" }
                },
                {
                  "label": "Gemini Lite",
                  "modelOrAlias": { "model": "gemini-lite" },
                  "quotaInfo": { "remainingFraction": 0.1, "resetTime": "2026-06-15T11:00:00Z" }
                },
                {
                  "label": "Claude Sonnet",
                  "modelOrAlias": { "model": "claude-sonnet" },
                  "quotaInfo": { "remainingFraction": 0.6, "resetTime": "2026-06-15T12:30:00Z" }
                },
                {
                  "label": "Claude Opus",
                  "modelOrAlias": { "model": "claude-opus" },
                  "quotaInfo": { "resetTime": "2026-06-15T12:30:00Z" }
                }
              ]
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(AntigravityUsage.parseUserStatus(Data(userStatus.utf8), now: now))
        XCTAssertEqual(snapshot.limits.map(\.key), [.antigravityGeminiSession, .antigravityClaudeSession])
        XCTAssertEqual(snapshot.limits[0].percent, 25, accuracy: 1e-6, "Le modèle Gemini le plus contraint, hors Lite")
        XCTAssertEqual(snapshot.limits[1].percent, 40, accuracy: 1e-6)

        let configs = """
        {
          "clientModelConfigs": [
            {
              "label": "Gemini 3 Pro",
              "modelOrAlias": { "model": "gemini-3-pro" },
              "quotaInfo": { "remainingFraction": 0.5, "resetTime": "2026-06-20T08:00:00Z" }
            }
          ]
        }
        """
        let weeklyFallback = try XCTUnwrap(AntigravityUsage.parseCommandModelConfigs(Data(configs.utf8), now: now))
        XCTAssertEqual(weeklyFallback.limits.first?.key, .antigravityGeminiWeekly)
        XCTAssertEqual(weeklyFallback.limits.first?.percent, 50, accuracy: 1e-6)
    }

    func testAntigravityProcessPortAndVersionParsing() {
        let ps = """
          100 /usr/libexec/some_daemon
          201 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --app_data_dir antigravity-ide --csrf_token ide-tok --extension_server_port 51001
          202 /Applications/Antigravity.app/Contents/MacOS/language_server_macos_arm --app_data_dir antigravity
          203 /Applications/Antigravity.app/Contents/MacOS/language_server_macos_arm --app_data_dir antigravity --csrf_token app-tok --extension_server_port 52000 --extension_server_csrf_token ext-tok
          204 /opt/homebrew/bin/agy
        """
        let procs = AntigravityUsage.parseProcessList(ps)
        XCTAssertEqual(procs.map(\.pid), [203, 204, 201], "App d'abord, puis CLI, puis IDE ; un serveur d'app sans jeton est ignoré")
        XCTAssertEqual(procs[0].csrfToken, "app-tok")
        XCTAssertEqual(procs[0].extensionPort, 52000)
        XCTAssertEqual(procs[0].extensionCSRFToken, "ext-tok")
        XCTAssertEqual(procs[1].kind, .cli)
        XCTAssertEqual(procs[1].csrfToken, "")
        XCTAssertEqual(procs[2].kind, .ide)

        let lsof = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language_ 203 user   10u  IPv4 0x1234      0t0  TCP 127.0.0.1:52002 (LISTEN)
        language_ 203 user   11u  IPv4 0x1235      0t0  TCP 127.0.0.1:52001 (LISTEN)
        """
        XCTAssertEqual(AntigravityUsage.parseListeningPorts(lsof), [52001, 52002])

        let endpoints = AntigravityUsage.buildEndpoints(for: procs[0], listeningPorts: [52001])
        XCTAssertEqual(endpoints.count, 3)
        XCTAssertEqual(endpoints[0].scheme, "https")
        XCTAssertEqual(endpoints[0].port, 52001)
        XCTAssertEqual(endpoints[1].scheme, "http")
        XCTAssertEqual(endpoints[1].port, 52000)
        XCTAssertEqual(endpoints[1].csrfToken, "ext-tok")

        XCTAssertEqual(AntigravityUsage.parseVersion("1.2.2\n")?.0, 1)
        XCTAssertEqual(AntigravityUsage.parseVersion("1.2.2\n")?.1, 2)
        XCTAssertEqual(AntigravityUsage.parseVersion("1.2.2\n")?.2, 2)
        XCTAssertNil(AntigravityUsage.parseVersion("agy 1.2.2"))
    }

    func testAntigravityMergeAndCache() throws {
        let now = Date()
        let full = UsageSnapshot.sampleAntigravity(
            geminiSession: 10, geminiWeekly: 40, claudeSession: 5, claudeWeekly: 25,
            elapsed: 0.5, now: now.addingTimeInterval(-300)
        )
        let ideOnly = UsageSnapshot(
            limits: [
                UsageLimit(
                    kind: .sessionModel("Gemini"), percent: 22, resetsAt: now.addingTimeInterval(3 * 3600),
                    provider: .antigravity, length: 5 * 3600
                ),
            ],
            weeklyWindowStart: nil, breakdown: [], fetchedAt: now
        )

        let merged = AntigravityUsage.merge(fresh: ideOnly, existing: full, now: now)
        XCTAssertEqual(merged.limits.first { $0.key == .antigravityGeminiSession }?.percent, 22)
        XCTAssertEqual(merged.limits.first { $0.key == .antigravityGeminiWeekly }?.percent, 40)
        XCTAssertEqual(merged.limits.first { $0.key == .antigravityClaudeWeekly }?.percent, 25)

        let cacheFile = folder.appendingPathComponent("last-antigravity.json")
        AntigravityCache.save(full, to: cacheFile)
        let loaded = try XCTUnwrap(AntigravityCache.load(now: now, from: cacheFile))
        XCTAssertEqual(loaded.limits.count, 4)
        XCTAssertEqual(loaded.limits.first { $0.key == .antigravityGeminiWeekly }?.percent, 40)

        // Après expiration de la fenêtre de 5 h mais avant l'hebdo, la 5 h repart de zéro.
        let later = now.addingTimeInterval(4 * 3600)
        let partiallyExpired = try XCTUnwrap(AntigravityCache.load(now: later, from: cacheFile))
        let gem5 = try XCTUnwrap(partiallyExpired.limits.first { $0.key == .antigravityGeminiSession })
        XCTAssertEqual(gem5.percent, 0)
        XCTAssertNil(gem5.resetsAt)
        XCTAssertEqual(partiallyExpired.limits.first { $0.key == .antigravityGeminiWeekly }?.percent, 40)

        // Une fois toutes les fenêtres expirées, le cache ne renvoie plus rien.
        let nextWeek = now.addingTimeInterval(5 * 86400)
        XCTAssertNil(AntigravityCache.load(now: nextWeek, from: cacheFile))
    }
}

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
}

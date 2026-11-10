import XCTest
@testable import Tempo

final class PaceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var reset: Date { start.addingTimeInterval(7 * 86400) }
    private func at(_ days: Double) -> Date { start.addingTimeInterval(days * 86400) }

    override func setUp() {
        Lang.setting = .en
    }

    // MARK: - Prévision au rythme moyen

    func testOnPaceForecast() throws {
        let f = try XCTUnwrap(Pace.forecast(percent: 40, start: start, reset: reset, now: at(3.5)))
        XCTAssertEqual(f.elapsedFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.paceDelta, -10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(f.projectedEnd), 80, accuracy: 1e-9)
        XCTAssertNil(f.exhaustionDate)
        XCTAssertEqual(f.dailyBudget, 60 / 3.5, accuracy: 1e-9)
    }

    func testTooFastForecastGivesTheRunOutDate() throws {
        let f = try XCTUnwrap(Pace.forecast(percent: 60, start: start, reset: reset, now: at(3.5)))
        XCTAssertEqual(try XCTUnwrap(f.projectedEnd), 120, accuracy: 1e-9)
        // 60 % en 3,5 jours : 100 % au bout de 3,5 × 100 / 60 jours.
        let expected = at(3.5 * 100 / 60)
        XCTAssertEqual(try XCTUnwrap(f.exhaustionDate).timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testNoProjectionTooEarlyInTheWindow() throws {
        let f = try XCTUnwrap(Pace.forecast(percent: 5, start: start, reset: reset, now: at(0.07)))
        XCTAssertLessThan(f.elapsedFraction, Pace.minimumElapsed)
        XCTAssertNil(f.projectedEnd)
        XCTAssertNil(f.exhaustionDate)
    }

    func testUsedUpQuota() throws {
        let now = at(5)
        let f = try XCTUnwrap(Pace.forecast(percent: 100, start: start, reset: reset, now: now))
        XCTAssertEqual(f.projectedEnd, 100)
        XCTAssertEqual(f.exhaustionDate, now)
        XCTAssertEqual(f.dailyBudget, 0)
    }

    func testStatusFollowsTheProjectedEnd() {
        XCTAssertEqual(PaceStatus(projectedEnd: 80), .onTrack)
        XCTAssertEqual(PaceStatus(projectedEnd: 95), .tight)
        XCTAssertEqual(PaceStatus(projectedEnd: 101), .over)
    }

    // MARK: - Rythme récent

    func testRecentRateAndItsProjection() throws {
        let now = at(5)
        let points = [(t: now.addingTimeInterval(-10 * 3600), v: 30.0)]
        let r = try XCTUnwrap(Pace.recent(
            points: points, current: 40, windowStart: start, reset: now.addingTimeInterval(48 * 3600), now: now
        ))
        XCTAssertEqual(r.gained, 10, accuracy: 1e-9)
        XCTAssertEqual(r.pointsPerHour, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.projectedEnd), 88, accuracy: 1e-9)
        XCTAssertNil(r.exhaustionDate, "60 heures pour finir, la réinitialisation arrive dans 48")
    }

    func testRecentRunOutBeforeTheReset() throws {
        let now = at(3)
        let points = [(t: now.addingTimeInterval(-10 * 3600), v: 30.0)]
        let r = try XCTUnwrap(Pace.recent(
            points: points, current: 40, windowStart: start, reset: now.addingTimeInterval(100 * 3600), now: now
        ))
        XCTAssertEqual(try XCTUnwrap(r.exhaustionDate).timeIntervalSince(now), 60 * 3600, accuracy: 1)
    }

    func testRecentNeedsAtLeastHalfAnHour() {
        let now = at(3)
        let points = [(t: now.addingTimeInterval(-10 * 60), v: 30.0)]
        XCTAssertNil(Pace.recent(points: points, current: 35, windowStart: start, reset: reset, now: now))
    }

    func testRecentIgnoresReadingsFromBeforeTheWindow() {
        let now = at(0.5)
        // Un relevé de la semaine précédente, plus haut que l'usage actuel : on ne doit pas s'en servir.
        let points = [(t: start.addingTimeInterval(-3600), v: 90.0)]
        XCTAssertNil(Pace.recent(points: points, current: 5, windowStart: start, reset: reset, now: now))
    }

    func testDivergenceBetweenTheTwoForecasts() {
        let limit = UsageLimit(kind: .weeklyAll, percent: 50, resetsAt: reset)
        let average = Pace.forecast(percent: 50, start: start, reset: reset, now: at(4.2))
        let recent = RecentRate(gained: 20, spanHours: 24, pointsPerHour: 0.83, exhaustionDate: nil, projectedEnd: 95)
        let insight = LimitInsight(limit: limit, start: start, forecast: average, recent: recent)
        XCTAssertEqual(try XCTUnwrap(insight.recentDivergence), 95 - 50 / 0.6, accuracy: 1e-6)
        XCTAssertTrue(insight.recentDiverges)

        let close = RecentRate(gained: 10, spanHours: 24, pointsPerHour: 0.4, exhaustionDate: nil, projectedEnd: 85)
        XCTAssertFalse(LimitInsight(limit: limit, start: start, forecast: average, recent: close).recentDiverges)
    }

    // MARK: - Par jour

    func testDailyUsageAddsUpToTheCurrentPercent() throws {
        let now = at(4.69)
        let snapshot = UsageSnapshot.sample(weekly: 56, model: 10, elapsed: 0.67, now: now)
        let samples = DebugTools.fakeSamples(weekly: 56, model: 10, elapsed: 0.67, now: now)
        let limit = try XCTUnwrap(snapshot.weekly)
        let insight = Pace.insight(for: limit, in: snapshot, samples: samples, now: now)
        let days = Pace.dailyUsage(for: insight, samples: samples, now: now)

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map(\.used).reduce(0, +), 56, accuracy: 0.5)
        XCTAssertEqual(days.filter { $0.kind == .today }.count, 1)

        let budget = try XCTUnwrap(insight.forecast).dailyBudget
        for day in days where day.kind == .future {
            XCTAssertEqual(day.possible, budget, accuracy: 0.01)
        }
    }
}

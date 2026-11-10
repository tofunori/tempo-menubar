import XCTest
@testable import Tempo

final class AlertRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        Lang.setting = .en
    }

    private func claude(weekly: Double, model: Double = 10, elapsed: Double = 0.5) -> UsageData {
        UsageData(claude: .sample(weekly: weekly, model: model, elapsed: elapsed, now: now), chatgpt: nil)
    }

    func testThresholdAndRunOutFireOnce() {
        let settings = AlertSettings()
        let first = AlertRules.due(data: claude(weekly: 85), settings: settings, sent: [], now: now)
        XCTAssertEqual(first.count, 2, "Le seuil de 80 % et la prévision d'épuisement")
        XCTAssertTrue(first.contains { $0.title == "Claude · weekly: 85%" })
        XCTAssertTrue(first.contains { $0.title == "Claude · weekly: too fast" })

        let sent = Set(first.flatMap(\.ids))
        XCTAssertTrue(AlertRules.due(data: claude(weekly: 85), settings: settings, sent: sent, now: now).isEmpty)
    }

    func testHigherThresholdFiresOnceAndCoversLowerOnes() throws {
        let settings = AlertSettings()
        let first = AlertRules.due(data: claude(weekly: 85), settings: settings, sent: [], now: now)
        let sent = Set(first.flatMap(\.ids))

        let next = AlertRules.due(data: claude(weekly: 96), settings: settings, sent: sent, now: now)
        let alert = try XCTUnwrap(next.first)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(alert.title, "Claude · weekly: 96%")
        XCTAssertEqual(alert.ids.count, 2, "80 % et 95 %")
    }

    func testUsedUpQuotaSkipsTheRunOutAlert() {
        let alerts = AlertRules.due(data: claude(weekly: 100), settings: AlertSettings(), sent: [], now: now)
        XCTAssertEqual(alerts.map(\.title), ["Claude · weekly: quota used up"])
    }

    func testNoRunOutAlertTooEarlyInTheWindow() {
        // 30 % après 5 % de la semaine : la prévision dit 600 %, mais c'est trop tôt pour déranger.
        let alerts = AlertRules.due(data: claude(weekly: 30, elapsed: 0.05), settings: AlertSettings(), sent: [], now: now)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testDisabledAndUnwatched() {
        var settings = AlertSettings()
        settings.enabled = false
        XCTAssertTrue(AlertRules.due(data: claude(weekly: 99), settings: settings, sent: [], now: now).isEmpty)

        settings = AlertSettings()
        settings.watched = [.claudeModel]
        XCTAssertTrue(AlertRules.due(data: claude(weekly: 99), settings: settings, sent: [], now: now).isEmpty)
    }

    func testEachAlertKindCanBeTurnedOff() {
        var settings = AlertSettings()
        settings.runOut = false
        XCTAssertEqual(AlertRules.due(data: claude(weekly: 85), settings: settings, sent: [], now: now).count, 1)

        settings = AlertSettings()
        settings.thresholdsOn = false
        let alerts = AlertRules.due(data: claude(weekly: 85), settings: settings, sent: [], now: now)
        XCTAssertEqual(alerts.map(\.title), ["Claude · weekly: too fast"])
    }

    func testWindowIdentityIgnoresSmallResetJitter() {
        let reset = now.addingTimeInterval(3 * 86400)
        XCTAssertEqual(
            AlertRules.windowID(.claudeWeekly, reset: reset),
            AlertRules.windowID(.claudeWeekly, reset: reset.addingTimeInterval(0.4))
        )
        XCTAssertNotEqual(
            AlertRules.windowID(.claudeWeekly, reset: reset),
            AlertRules.windowID(.claudeWeekly, reset: reset.addingTimeInterval(7 * 86400))
        )
    }

    func testChatGPTValuesAreWatchedToo() {
        let data = UsageData(
            claude: nil,
            chatgpt: .sampleChatGPT(session: 20, weekly: 82, elapsed: 0.9, now: now)
        )
        let alerts = AlertRules.due(data: data, settings: AlertSettings(), sent: [], now: now)
        XCTAssertEqual(alerts.map(\.title), ["ChatGPT · weekly: 82%"])
    }
}

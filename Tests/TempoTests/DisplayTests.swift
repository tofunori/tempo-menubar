import XCTest
@testable import Tempo

final class DisplayTests: XCTestCase {
    override func tearDown() {
        Lang.setting = .en
    }

    // MARK: - Langue et formats

    func testPercentagesAndDurationsFollowTheLanguage() {
        Lang.setting = .fr
        XCTAssertEqual(Fmt.pct(56.4), "56 %")
        XCTAssertEqual(Fmt.duration(2 * 86400 + 7 * 3600 + 100), "2 j 7 h")
        XCTAssertEqual(tr("bonjour", "hello"), "bonjour")

        Lang.setting = .en
        XCTAssertEqual(Fmt.pct(56.6), "57%")
        XCTAssertEqual(Fmt.duration(2 * 86400 + 7 * 3600 + 100), "2d 7h")
        XCTAssertEqual(Fmt.duration(3 * 3600 + 12 * 60), "3h 12m")
        XCTAssertEqual(tr("bonjour", "hello"), "hello")
    }

    func testPoints() {
        XCTAssertEqual(Fmt.points(1), "1 pt")
        XCTAssertEqual(Fmt.points(-11.4), "11 pts")
    }

    // MARK: - Couleurs

    func testHexRoundTrip() throws {
        XCTAssertEqual(try XCTUnwrap(RGB(hex: "#34C759")).hex, "34C759")
        XCTAssertNil(RGB(hex: "12345"))
        XCTAssertNil(RGB(hex: "GGGGGG"))
    }

    func testThresholdColors() {
        let p = Palette()
        XCTAssertEqual(p.color(forUsage: 50, gradient: false), p.low)
        XCTAssertEqual(p.color(forUsage: 60, gradient: false), p.mid)
        XCTAssertEqual(p.color(forUsage: 85, gradient: false), p.high)
    }

    func testGradientBlendsBetweenStops() {
        let p = Palette()
        let halfway = p.color(forUsage: 30, gradient: true)
        let expected = p.low.mixed(with: p.mid, 0.5)
        XCTAssertEqual(halfway.r, expected.r, accuracy: 1e-9)
        XCTAssertEqual(halfway.g, expected.g, accuracy: 1e-9)
        XCTAssertEqual(p.color(forUsage: 0, gradient: true), p.low)
        XCTAssertEqual(p.color(forUsage: 100, gradient: true), p.high)
    }

    // MARK: - Texte de la barre

    private func data(now: Date) -> UsageData {
        UsageData(
            claude: .sample(weekly: 59, model: 16, elapsed: 0.68, now: now),
            chatgpt: .sampleChatGPT(session: 0, weekly: 10, elapsed: 0.27, now: now),
            antigravity: .sampleAntigravity(
                geminiSession: 12, geminiWeekly: 42, claudeSession: 5, claudeWeekly: 28,
                elapsed: 0.5, now: now
            )
        )
    }

    private func title(_ primary: MetricKey, _ secondary: MetricKey?, style: IconStyle = .arcs) -> String {
        Lang.setting = .en
        let now = Date()
        var options = DisplayOptions()
        options.iconStyle = style
        options.primary = primary
        options.secondary = secondary
        return MenuBarContent.make(data: data(now: now), options: options, now: now).title.string
    }

    func testMenuBarTextForCombinations() {
        XCTAssertEqual(title(.claudeWeekly, .claudeModel), "59% · F 16%")
        XCTAssertEqual(title(.claudeWeekly, .chatgptWeekly), "59% · G 10%")
        XCTAssertEqual(title(.chatgptSession, .claudeWeekly), "0% · C 59%")
        XCTAssertEqual(title(.claudeWeekly, .antigravityGeminiWeekly), "59% · AG 42%")
        XCTAssertEqual(title(.antigravityGeminiWeekly, .antigravityClaudeWeekly), "42% · AC 28%")
        XCTAssertEqual(title(.antigravityGeminiWeekly, .antigravityGeminiSession), "42% · AG5 12%")
        XCTAssertEqual(title(.claudeWeekly, nil), "59%")
        XCTAssertEqual(title(.claudeWeekly, .claudeWeekly), "59%", "Une valeur répétée n'est montrée qu'une fois")
        XCTAssertEqual(title(.claudeWeekly, .chatgptWeekly, style: .lines), "", "Deux lignes porte ses chiffres dans le dessin")
    }

    func testMissingValueKeepsAnEmptyIcon() {
        let now = Date()
        var options = DisplayOptions()
        options.iconStyle = .arcs
        options.primary = .claudeSession
        let content = MenuBarContent.make(data: data(now: now), options: options, now: now)
        XCTAssertNotNil(content.image)
        XCTAssertEqual(content.title.string, "")
    }

    func testSizeIsCappedByTheMenuBarHeight() throws {
        let now = Date()
        var options = DisplayOptions()
        options.iconStyle = .dial
        options.scale = 1.3
        let free = try XCTUnwrap(MenuBarContent.make(data: data(now: now), options: options, now: now).image)
        let capped = try XCTUnwrap(MenuBarContent.make(data: data(now: now), options: options, now: now, maxHeight: 22).image)
        XCTAssertGreaterThan(free.size.height, 22)
        XCTAssertLessThanOrEqual(capped.size.height, 22)

        options.scale = 0.7
        let small = try XCTUnwrap(MenuBarContent.make(data: data(now: now), options: options, now: now, maxHeight: 22).image)
        XCTAssertLessThan(small.size.height, capped.size.height)
    }

    // MARK: - Mise en page du panneau (repli et limites à 0 % inactives)

    func testPanelLayoutPartitionsInactiveZeroLimitsAndGroupsSameModel() {
        Lang.setting = .en
        let now = Date()
        let snapshot = UsageSnapshot(
            limits: [
                UsageLimit(kind: .sessionModel("Gemini"), percent: 9, resetsAt: now.addingTimeInterval(3 * 3600), provider: .antigravity, length: 5 * 3600),
                UsageLimit(kind: .weeklyModel("Gemini"), percent: 41, resetsAt: now.addingTimeInterval(4 * 86400), provider: .antigravity, length: 7 * 86400),
                UsageLimit(kind: .sessionModel("Claude/GPT"), percent: 0, resetsAt: now.addingTimeInterval(5 * 3600), provider: .antigravity, length: 5 * 3600),
                UsageLimit(kind: .weeklyModel("Claude/GPT"), percent: 0, resetsAt: now.addingTimeInterval(7 * 86400), provider: .antigravity, length: 7 * 86400),
            ],
            weeklyWindowStart: nil, breakdown: [], fetchedAt: now
        )
        let usage = UsageData(antigravity: snapshot)
        let rows = usage.insights(.antigravity, now: now)

        let parts = PanelLayout.partitionLimits(rows)
        XCTAssertEqual(parts.active.map(\.limit.key), [.antigravityGeminiSession, .antigravityGeminiWeekly])
        XCTAssertEqual(parts.inactiveZero.map(\.limit.key), [.antigravityClaudeSession, .antigravityClaudeWeekly])
        XCTAssertEqual(PanelLayout.inactiveSummaryLabel(for: parts.inactiveZero), "Claude/GPT · 5 h · Weekly")

        Lang.setting = .fr
        XCTAssertEqual(PanelLayout.inactiveSummaryLabel(for: parts.inactiveZero), "Claude/GPT · 5 h · Hebdo")
    }

    func testPanelLayoutKeepsAllBarsWhenEveryLimitIsInactive() {
        let now = Date()
        let snapshot = UsageSnapshot(
            limits: [
                UsageLimit(kind: .sessionModel("Claude/GPT"), percent: 0, resetsAt: now.addingTimeInterval(5 * 3600), provider: .antigravity, length: 5 * 3600),
                UsageLimit(kind: .weeklyModel("Claude/GPT"), percent: 0, resetsAt: now.addingTimeInterval(7 * 86400), provider: .antigravity, length: 7 * 86400),
            ],
            weeklyWindowStart: nil, breakdown: [], fetchedAt: now
        )
        let rows = UsageData(antigravity: snapshot).insights(.antigravity, now: now)
        let parts = PanelLayout.partitionLimits(rows)
        XCTAssertEqual(parts.active.count, 2)
        XCTAssertTrue(parts.inactiveZero.isEmpty)
    }

    func testPanelLayoutPrimarySummaryInlineForecastAndFocus() throws {
        Lang.setting = .en
        let now = Date()
        let usage = data(now: now)

        let agPrimary = try XCTUnwrap(PanelLayout.primarySummary(for: .antigravity, rows: usage.insights(.antigravity, now: now)))
        XCTAssertEqual(agPrimary.limit.key, .antigravityGeminiWeekly, "Retient la limite hebdo la plus utilisée pour la micro-barre")
        XCTAssertEqual(PanelLayout.inlineForecast(for: agPrimary), "→ 84%")

        let claudePrimary = try XCTUnwrap(PanelLayout.primarySummary(for: .claude, rows: usage.insights(.claude, now: now)))
        XCTAssertEqual(claudePrimary.limit.key, .claudeWeekly)
        XCTAssertEqual(PanelLayout.inlineForecast(for: claudePrimary), "→ 87%")

        let gptPrimary = try XCTUnwrap(PanelLayout.primarySummary(for: .chatgpt, rows: usage.insights(.chatgpt, now: now)))
        XCTAssertEqual(gptPrimary.limit.key, .chatgptWeekly)

        XCTAssertEqual(PanelLayout.preferredFocus(for: .claude, in: usage, now: now), .claudeWeekly)
        XCTAssertEqual(PanelLayout.preferredFocus(for: .chatgpt, in: usage, now: now), .chatgptWeekly)
        XCTAssertEqual(PanelLayout.preferredFocus(for: .antigravity, in: usage, now: now), .antigravityGeminiWeekly)

        let agHero = usage.insight(.antigravityGeminiWeekly, now: now)
        XCTAssertEqual(PanelLayout.footerSnapshot(for: agHero, in: usage)?.provider, .antigravity)
        let gptHero = usage.insight(.chatgptWeekly, now: now)
        XCTAssertEqual(PanelLayout.footerSnapshot(for: gptHero, in: usage)?.provider, .chatgpt)
    }
}

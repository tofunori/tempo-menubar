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
            chatgpt: .sampleChatGPT(session: 0, weekly: 10, elapsed: 0.27, now: now)
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
}

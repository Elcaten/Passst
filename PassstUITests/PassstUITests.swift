import XCTest

final class PassstUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--show-panel"]
        app.launch()

        XCTAssertTrue(
            app.textFields["Search history"].waitForExistence(timeout: 4),
            "The Passst panel did not become ready."
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testSearchAcceptsAccentedText() {
        let search = app.textFields["Search history"]
        search.typeText("café")

        let accentedResult = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] %@", "Café search")
        ).firstMatch
        XCTAssertTrue(accentedResult.waitForExistence(timeout: 2))

        search.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(
            (search.value as? String ?? "").localizedCaseInsensitiveContains("café")
        )
    }

    func testCommandASelectsAllSearchText() {
        let search = app.textFields["Search history"]
        search.typeText("café")
        search.typeKey("a", modifierFlags: [.command])
        search.typeText("swiftui")

        XCTAssertEqual(search.value as? String, "swiftui")
    }

    func testReturnLeavesSearchOpenWithoutPasting() {
        let search = app.textFields["Search history"]
        search.typeText("café")
        search.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(search.waitForExistence(timeout: 0.5))
        XCTAssertEqual(search.value as? String, "café")
    }

    func testPreviewOpensAndClosesFromKeyboard() {
        let search = app.textFields["Search history"]
        search.typeKey(.tab, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])

        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["←  →"].exists)

        app.typeKey(.space, modifierFlags: [])
        XCTAssertFalse(app.buttons["Close"].waitForExistence(timeout: 0.5))
    }

    func testShiftArrowCreatesOrderedRange() {
        let search = app.textFields["Search history"]
        search.typeKey(.tab, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [.shift])
        app.typeKey(.rightArrow, modifierFlags: [.shift])

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Ordered multi-selection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPanelScreenshotLight() {
        app.terminate()
        app.launchArguments = [
            "--ui-testing",
            "--show-panel",
            "-appearance",
            "light"
        ]
        app.launch()
        XCTAssertTrue(app.textFields["Search history"].waitForExistence(timeout: 4))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Panel Light"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testPanelScreenshotDark() {
        app.terminate()
        app.launchArguments = [
            "--ui-testing",
            "--show-panel",
            "-appearance",
            "dark"
        ]
        app.launch()
        XCTAssertTrue(app.textFields["Search history"].waitForExistence(timeout: 4))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Panel Dark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

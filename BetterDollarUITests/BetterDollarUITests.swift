import XCTest

/// End-to-end journeys on an in-memory store (`-BDDemo` sample household or `-BDEmpty`).
@MainActor final class BetterDollarUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-trayExpanded", "YES", "-appLock", "NO", "-coachEngine", ""]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func trayTitle(_ app: XCUIApplication) -> String { element(app, "tray-toggle").label }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.label == label { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    /// Scrolls the budget until `target` sits fully above the tray.
    private func reveal(_ target: XCUIElement, above trayTop: CGFloat, in app: XCUIApplication) {
        for _ in 0..<12 {
            if target.exists && target.frame.minY > 180 && target.frame.maxY < trayTop - 16 { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let delta: CGFloat = target.exists && target.frame.maxY < trayTop ? 120 : -160
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
        }
        XCTFail("Couldn't scroll \(target) into view")
    }

    func testPlanFirstMonthFromTemplate() {
        let app = launch(["-BDEmpty", "-budgetColumn", "Planned"])
        element(app, "start-template").tap()
        let paycheck = app.textFields["planned-Paycheck 1"]
        XCTAssertTrue(paycheck.waitForExistence(timeout: 5))
        paycheck.tap()
        paycheck.typeText("4000")
        app.toolbars.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(element(app, "leftToBudget").label.contains("$4,000.00"), true, element(app, "leftToBudget").label)

        let rent = app.textFields["planned-Mortgage/Rent"]
        rent.tap()
        rent.typeText("1500.50")
        app.toolbars.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(element(app, "leftToBudget").label.contains("$2,499.50"), element(app, "leftToBudget").label)
    }

    func testDragTransactionOntoBudgetItem() {
        let app = launch(["-BDDemo", "-budgetColumn", "Spent"])
        let slip = element(app, "slip-City Water Utility")
        XCTAssertTrue(slip.waitForExistence(timeout: 10))
        XCTAssertEqual(trayTitle(app), "4 new transactions")
        let water = element(app, "item-Water")
        reveal(water, above: element(app, "tray-toggle").frame.minY, in: app)
        slip.press(forDuration: 1.2, thenDragTo: water)
        XCTAssertTrue(waitForLabel(element(app, "tray-toggle"), "3 new transactions"), trayTitle(app))
        XCTAssertFalse(element(app, "slip-City Water Utility").exists)
    }

    func testTapToAssignWithSuggestion() {
        let app = launch(["-BDDemo"])
        let slip = element(app, "slip-Netflix")
        XCTAssertTrue(slip.waitForExistence(timeout: 10))
        slip.tap()
        // Netflix went to Subscriptions last month, so it is suggested first.
        XCTAssertTrue(app.staticTexts["Last time"].waitForExistence(timeout: 5) || app.otherElements["Last time"].exists)
        element(app, "assign-Subscriptions").tap()
        XCTAssertTrue(waitForLabel(element(app, "tray-toggle"), "3 new transactions"), trayTitle(app))
    }

    func testSplitTransaction() {
        let app = launch(["-BDDemo"])
        let slip = element(app, "slip-Whole Foods Market")
        XCTAssertTrue(slip.waitForExistence(timeout: 10))
        let screenWidth = app.windows.firstMatch.frame.maxX
        for _ in 0..<4 where slip.frame.maxX > screenWidth {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: screenWidth * 0.8, dy: slip.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -220, dy: 0)))
        }
        slip.tap()
        element(app, "split").tap()

        let menus = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose a budget item"))
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: 5))
        menus.firstMatch.tap()
        app.buttons["Groceries"].firstMatch.tap()
        let amounts = app.textFields.matching(identifier: "Amount")
        let first = amounts.element(boundBy: 0)
        first.tap()
        first.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        first.typeText(XCUIKeyboardKey.delete.rawValue + "80")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose a budget item")).firstMatch.tap()
        app.buttons["Restaurants"].firstMatch.tap()
        let second = amounts.element(boundBy: 1)
        second.tap()
        second.typeText("27.01")
        XCTAssertTrue(app.staticTexts["Splits add up to $107.01."].waitForExistence(timeout: 3))
        app.navigationBars.buttons["Save"].tap()

        app.tabBars.buttons["Transactions"].tap()
        app.buttons["Tracked (82)"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Split: Groceries, Restaurants")).firstMatch
            .waitForExistence(timeout: 5))
    }

    func testAddManualTransactionLandsInTray() {
        let app = launch(["-BDDemo", "-BDTab", "transactions"])
        XCTAssertTrue(app.buttons["New (4)"].waitForExistence(timeout: 10))
        element(app, "add-transaction").tap()
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("12.34")
        let merchant = app.textFields["merchant"]
        merchant.tap()
        merchant.typeText("Farmers Market")
        element(app, "save-transaction").tap()
        XCTAssertTrue(app.buttons["New (5)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Farmers Market"].exists)
    }

    /// Runs Apple's on-device model when the simulator has Apple Intelligence; skipped otherwise.
    func testCoachAnswersWithAppleIntelligence() throws {
        let app = launch(["-BDDemo", "-BDTab", "coach"])
        let starter = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "How am I doing this month?")).firstMatch
        XCTAssertTrue(starter.waitForExistence(timeout: 10))
        guard starter.isEnabled else { throw XCTSkip("Apple Intelligence isn't available on this simulator.") }
        starter.tap()
        let footnote = app.staticTexts["Written on this iPhone by Apple Intelligence"]
        XCTAssertTrue(footnote.waitForExistence(timeout: 180), "No answer from Apple Intelligence")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Captures the screens the journeys don't visit, for design review.
    func testScreenTour() {
        let app = launch(["-BDDemo", "-budgetColumn", "Remaining"])
        func snap(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let groceries = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Groceries")).firstMatch
        reveal(groceries, above: element(app, "tray-toggle").frame.minY, in: app)
        groceries.tap()
        XCTAssertTrue(app.navigationBars["Food"].waitForExistence(timeout: 5))
        snap("item-detail")
        app.navigationBars.buttons["Done"].tap()

        app.tabBars.buttons["Settings"].tap()
        element(app, "setup-plaid").tap()
        XCTAssertTrue(app.navigationBars["Plaid"].waitForExistence(timeout: 5))
        snap("plaid-setup")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["On-device AI models"].tap()
        XCTAssertTrue(app.navigationBars["On-device AI"].waitForExistence(timeout: 5))
        snap("models")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Back up and restore"].tap()
        XCTAssertTrue(app.navigationBars["Back up and restore"].waitForExistence(timeout: 5))
        snap("backup")
    }
}

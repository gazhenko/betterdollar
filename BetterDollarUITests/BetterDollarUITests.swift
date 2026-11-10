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

    /// Scrolls the tray sideways until the slip is on screen; its place depends on the day's charges.
    private func revealSlip(_ slip: XCUIElement, in app: XCUIApplication) {
        let screenWidth = app.windows.firstMatch.frame.maxX
        for _ in 0..<4 where slip.frame.maxX > screenWidth {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: screenWidth * 0.8, dy: slip.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -220, dy: 0)))
        }
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

    func testRemoveSampleData() {
        let app = launch(["-BDDemo", "-BDTab", "settings"])
        let remove = element(app, "remove-sample-data")
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        remove.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Remove sample data", "remove-sample-data")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))

        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(element(app, "start-template").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "sample-data").exists, "with no months left, the sample can be explored again")
    }

    func testDragTransactionOntoBudgetItem() {
        let app = launch(["-BDDemo", "-budgetColumn", "Spent"])
        let slip = element(app, "slip-City Water Utility")
        XCTAssertTrue(slip.waitForExistence(timeout: 10))
        XCTAssertEqual(trayTitle(app), "4 new transactions")
        let water = element(app, "item-Water")
        reveal(water, above: element(app, "tray-toggle").frame.minY, in: app)
        revealSlip(slip, in: app)
        slip.press(forDuration: 1.2, thenDragTo: water)
        XCTAssertTrue(waitForLabel(element(app, "tray-toggle"), "3 new transactions"), trayTitle(app))
        XCTAssertTrue(element(app, "slip-City Water Utility").waitForNonExistence(timeout: 3))
    }

    func testTapToAssignWithSuggestion() {
        let app = launch(["-BDDemo"])
        let slip = element(app, "slip-Netflix")
        XCTAssertTrue(slip.waitForExistence(timeout: 10))
        revealSlip(slip, in: app)
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
        revealSlip(slip, in: app)
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
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tracked (")).firstMatch.tap()
        // Newest first, so later sample charges this month can push it down the list.
        let split = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Split: Groceries, Restaurants")).firstMatch
        for _ in 0..<8 where !split.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(split.exists)
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
    /// The three cash flow tabs with a warning line high enough that the sample household dips below it, then the review sheet.
    func testCashFlowTabsAndReview() {
        // Tabs are picked by tapping: a launch argument would pin the stored setting for the whole run.
        let app = launch(["-BDDemo", "-BDTab", "insights", "-cashFlowCushion", "500000"])
        func snap(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        element(app, "cash-flow-tab").buttons["Summary"].tap()
        XCTAssertTrue(element(app, "cash-flow-plate").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "cash-flow-plate").label.contains("drops below $5,000"), element(app, "cash-flow-plate").label)
        XCTAssertFalse(element(app, "runway-chart").exists)
        snap("cashflow-summary-1")
        app.swipeUp()
        XCTAssertTrue(element(app, "cash-flow-suggestions").exists)
        snap("cashflow-summary-2")

        app.swipeDown(); app.swipeDown()
        element(app, "cash-flow-tab").buttons["Runway"].tap()
        XCTAssertTrue(element(app, "runway-chart").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "cash-flow-plate").exists)
        snap("cashflow-runway-1")
        app.swipeUp()
        snap("cashflow-runway-2")

        app.swipeDown(); app.swipeDown()
        element(app, "cash-flow-tab").buttons["Calendar"].tap()
        XCTAssertTrue(element(app, "cash-flow-calendar").waitForExistence(timeout: 5))
        snap("cashflow-calendar-1")
        app.swipeUp()
        snap("cashflow-calendar-2")

        app.swipeDown(); app.swipeDown(); app.swipeDown()
        element(app, "cash-flow-tab").buttons["Summary"].tap()
        XCTAssertTrue(element(app, "review-found").waitForExistence(timeout: 5))
        element(app, "cash-flow-review").tap()
        XCTAssertTrue(app.navigationBars["Paychecks and bills"].waitForExistence(timeout: 5))
        snap("cashflow-review")

        // A one-time paycheck asks for its payday, not the next one.
        app.buttons["Add a paycheck"].firstMatch.tap()
        let often = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "How often")).firstMatch
        XCTAssertTrue(often.waitForExistence(timeout: 5))
        often.tap()
        app.buttons["Just once"].tap()
        XCTAssertTrue(app.staticTexts["Payday"].waitForExistence(timeout: 5))
        snap("cashflow-paycheck-once")
        app.navigationBars["Add a paycheck"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Paychecks and bills"].waitForExistence(timeout: 5))
        // Bills are in date order, so where rent sits depends on today's date.
        let rent = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Oak Street Apartments")).firstMatch
        for _ in 0..<4 where !(rent.exists && rent.isHittable) { app.swipeUp() }
        XCTAssertTrue(rent.waitForExistence(timeout: 5))
        rent.tap()
        let toggle = app.switches["Count in the forecast"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        snap("cashflow-bill-detail")
        toggle.switches.firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Turned off")).firstMatch.waitForExistence(timeout: 5))

        // A card: how it's paid, and what that puts in the forecast.
        let card = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Rewards Card")).firstMatch
        for _ in 0..<4 where !(card.exists && card.isHittable) { app.swipeUp() }
        card.tap()
        XCTAssertTrue(element(app, "card-pay-mode").waitForExistence(timeout: 5))
        snap("cashflow-card")
        // Food is paid with the card, so it leaves checking with the card payment.
        let food = app.switches["Food"]
        for _ in 0..<4 where !(food.exists && food.isHittable) { app.swipeUp() }
        food.switches.firstMatch.tap()
        let includes = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "of budget spending")).firstMatch
        for _ in 0..<3 where !includes.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(includes.exists)
        snap("cashflow-card-groups")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        element(app, "card-pay-mode").tap()
        app.buttons["Minimum payment"].tap()
        XCTAssertTrue(app.staticTexts["Minimum due"].waitForExistence(timeout: 5))
        snap("cashflow-card-minimum")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Minimum payment")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars["Paychecks and bills"].buttons["Done"].tap()
        XCTAssertTrue(element(app, "cash-flow-plate").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "review-found").exists, "reviewing clears the prompt")
    }

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
        // Everyday items mark how far through the month it is, so spending can be read against an even pace.
        XCTAssertTrue((element(app, "item-Groceries").value as? String ?? "").contains("of the month gone"))
        snap("budget-pace")
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

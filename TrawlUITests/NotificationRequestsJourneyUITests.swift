//
//  NotificationRequestsJourneyUITests.swift
//  TrawlUITests
//
//  The notification sheet's Requests tab against the loopback Seerr fixture. Only
//  the Seerr profile and session cookie are seeded; the bar, the sheet, the undo
//  window and every decision go through production code to the fixture.
//

import XCTest

final class NotificationRequestsJourneyUITests: XCTestCase {
    private var fixtureServer: SeerrUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    /// A waiting request leads the bar, and a tap on it opens Requests. Approve and
    /// Decline are on the row and wait out an undo window before anything is sent.
    ///
    /// The undo is proven by ordering, not by waiting: the series is declined and
    /// undone, then the movie is approved. The approval is sent a full undo window
    /// after the decline would have been, so when the approval reaches the fixture,
    /// a decline that Undo failed to cancel would already be there too.
    @MainActor
    func testWaitingRequestsLeadTheBarAndDecisionsCanBeUndone() async throws {
        let server = try await SeerrUIFixtureServer(includesRequests: true)
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = server.baseURL
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))

        let bar = app.buttons["Notifications"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15))
        let leadsWithRequests = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@", "awaiting approval"),
            object: bar
        )
        await fulfillment(of: [leadsWithRequests], timeout: 20)
        XCTAssertTrue(tapWhenHittable(bar, in: app, timeout: 5))

        let requestsTab = app.tabBars.buttons["Requests"]
        XCTAssertTrue(requestsTab.waitForExistence(timeout: 10), "With Seerr set up, the sheet has a Requests tab.")
        XCTAssertTrue(requestsTab.isSelected, "A tap on a waiting request opens the sheet on Requests.")
        XCTAssertTrue(app.navigationBars["Requests"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Requested Movie"].waitForExistence(in: app, timeout: 15))
        XCTAssertTrue(app.staticTexts["Fixture Requested Series"].exists)
        capture(app, "requests-waiting")

        let declineSeries = app.buttons["request-decline-802"]
        XCTAssertTrue(tapWhenHittable(declineSeries, in: app, timeout: 5))
        let undoSeries = app.buttons["request-undo-802"]
        XCTAssertTrue(undoSeries.waitForExistence(timeout: 5), "A decision shows Undo before it is sent.")
        capture(app, "request-decision-undo-window")
        XCTAssertTrue(tapWhenHittable(undoSeries, in: app, timeout: 5))
        XCTAssertTrue(
            app.buttons["request-approve-802"].waitForExistence(timeout: 5),
            "Undo puts both answers back."
        )

        XCTAssertTrue(tapWhenHittable(app.buttons["request-approve-801"], in: app, timeout: 5))
        let approved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/request/801/approve" }.count == 1
        }, object: nil)
        await fulfillment(of: [approved], timeout: 15)
        XCTAssertEqual(
            server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/request/802/decline" }.count,
            0,
            "An undone decision must never reach Seerr."
        )
        XCTAssertTrue(
            app.buttons["request-approve-801"].waitForNonExistence(timeout: 10),
            "An approved request stops waiting on the user."
        )
        XCTAssertTrue(
            app.staticTexts["Fixture Requested Movie"].waitForExistence(in: app, timeout: 10),
            "An approved request moves to On the Way rather than vanishing."
        )

        XCTAssertTrue(tapWhenHittable(app.buttons["request-decline-802"], in: app, timeout: 5))
        let declined = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/request/802/decline" }.count == 1
        }, object: nil)
        await fulfillment(of: [declined], timeout: 15)
        XCTAssertTrue(
            app.staticTexts["Fixture Requested Series"].waitForNonExistence(timeout: 10),
            "A declined request leaves the queue."
        )
        XCTAssertTrue(
            server.requests.contains {
                $0.method == "GET" && $0.path == "/api/v1/request"
                    && SeerrUIFixtureServer.queryValue("filter", in: $0.query) == "processing"
            },
            "On the Way is read from Seerr's processing filter."
        )
        capture(app, "requests-after-decisions")
    }

    @discardableResult
    @MainActor
    private func tapWhenHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

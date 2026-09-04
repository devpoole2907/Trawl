//
//  ServiceSetupEditJourneyUITests.swift
//  TrawlUITests
//
//  Exercises the two saved-download-client edit forms that had only navigation
//  coverage: qBittorrent's username/password sheet and SABnzbd's full-API-key sheet.
//  Each journey starts with a real seeded profile, makes a deliberately rejected
//  connection attempt against a second server, then corrects the form and proves the
//  real production client performed the expected handshake before persistence.
//

import XCTest

final class ServiceSetupEditJourneyUITests: XCTestCase {
    private var servers: [ServiceSetupEditUIFixtureServer] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        servers.forEach { $0.stop() }
        servers = []
    }

    /// Regressions this catches: the qBittorrent Settings → Servers → edit route no
    /// longer reaching the real `OnboardingSheet`; existing host/username values not
    /// pre-filling; a rejected login dismissing or clearing the form; the retried
    /// `AuthService` login not carrying the edited credentials; or a successful
    /// validation failing to persist the edited host/name.
    @MainActor
    func testEditingQBittorrentKeepsTheFormOpenAfterRejectedCredentialsThenPersistsRetry() async throws {
        let original = try await ServiceSetupEditUIFixtureServer(
            service: .qbittorrent(username: "uitest-username", password: "uitest-password")
        )
        let replacementUsername = "fixture-updated-user"
        let replacementPassword = "fixture-updated-password"
        let replacement = try await ServiceSetupEditUIFixtureServer(
            service: .qbittorrent(username: replacementUsername, password: replacementPassword)
        )
        servers = [original, replacement]

        let app = launchApp(qbittorrent: original.baseURL, sabnzbd: nil)
        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A seeded qBittorrent profile should reach Trawl's app chrome.")

        navigateToQBittorrentServerEditor(in: app)

        let editTitle = app.navigationBars["Edit Server"]
        XCTAssertTrue(editTitle.waitForExistence(timeout: 10), "Selecting the active qBittorrent server should present the real OnboardingSheet in edit mode.")

        let host = app.textFields["Server address"]
        let username = app.textFields["Username"]
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(host.waitForExistence(timeout: 10), "The edit sheet should expose its Server address field.")
        waitForValue(host, expected: original.baseURL, timeout: 10)
        replace(replacement.baseURL, in: host, deleting: original.baseURL.count, in: app)

        XCTAssertTrue(username.waitForExistence(in: app, timeout: 10), "The edit sheet should expose its Username field.")
        waitForValue(username, expected: "uitest-username", timeout: 10)
        replace(replacementUsername, in: username, deleting: "uitest-username".count, in: app)

        XCTAssertTrue(password.waitForExistence(in: app, timeout: 10), "The edit sheet should expose its Password field.")
        replace("not-the-password", in: password, deleting: "uitest-password".count, in: app)

        let connect = app.buttons["Connect"]
        XCTAssertTrue(tap(connect, in: app, timeout: 5), "The populated qBittorrent edit form should enable Connect.")
        XCTAssertTrue(
            waitForCondition(in: app, timeout: 10) {
                replacement.hasReceivedQBittorrentLogin(username: replacementUsername, password: "not-the-password")
            },
            "The rejected edit must issue POST /api/v2/auth/login to the edited host with the new username and the attempted password."
        )

        let rejectedCopy = app.staticTexts["Authentication failed. Check your credentials."]
        XCTAssertTrue(rejectedCopy.waitForExistence(timeout: 10), "A rejected qBittorrent login must be surfaced in the edit sheet instead of dismissing it.")
        XCTAssertTrue(editTitle.exists, "A failed validation must retain the edit sheet so the user can correct credentials.")
        XCTAssertEqual(host.value as? String, replacement.baseURL, "The rejected attempt must preserve the edited host instead of restoring or clearing it.")
        XCTAssertEqual(username.value as? String, replacementUsername, "The rejected attempt must preserve the edited username instead of restoring it silently.")

        replace(replacementPassword, in: password, deleting: "not-the-password".count, in: app)
        XCTAssertTrue(tap(connect, in: app, timeout: 5), "Correcting the password should allow a second real validation attempt.")
        XCTAssertTrue(
            waitForCondition(in: app, timeout: 10) {
                replacement.hasReceivedQBittorrentLogin(username: replacementUsername, password: replacementPassword)
            },
            "The successful retry must send the corrected form credentials to the edited qBittorrent host."
        )
        XCTAssertTrue(
            waitForCondition(in: app, timeout: 10) {
                replacement.requests.contains { $0.method == "GET" && $0.path == "/api/v2/app/version" }
            },
            "OnboardingViewModel must validate a successful qBittorrent login with GET /api/v2/app/version before saving the profile."
        )

        waitForDisappearance(of: editTitle, timeout: 15)
        XCTAssertFalse(editTitle.exists, "A successful validation should dismiss OnboardingSheet.")
        XCTAssertTrue(
            firstElement(containing: replacement.baseURL, in: app).waitForExistence(timeout: 10),
            "After the real validation succeeds, ServerListView should repaint from SwiftData with the edited qBittorrent host."
        )
    }

    /// Regressions this catches: the Settings → SABnzbd edit route losing its prefilled
    /// Full API Key; a 401 from `mode=auth` not keeping the form editable; an edited
    /// key/host not being passed to every setup handshake request; or a successful save
    /// failing to trigger SABnzbdServiceManager's real reconnect to the new profile.
    @MainActor
    func testEditingSABnzbdRejectsWrongFullKeyThenReconnectsUsingTheSavedHost() async throws {
        let original = try await ServiceSetupEditUIFixtureServer(service: .sabnzbd(apiKey: "uitest-api-key"))
        let replacementKey = "fixture-updated-full-api-key"
        let replacement = try await ServiceSetupEditUIFixtureServer(service: .sabnzbd(apiKey: replacementKey))
        servers = [original, replacement]

        let app = launchApp(qbittorrent: nil, sabnzbd: original.baseURL)
        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A seeded SABnzbd profile should reach Trawl's app chrome.")

        navigateToSABnzbdEditor(in: app)

        let editTitle = app.navigationBars["Edit SABnzbd"]
        XCTAssertTrue(editTitle.waitForExistence(timeout: 10), "SABnzbd Settings should present SABnzbdSetupSheet in edit mode.")
        let host = app.textFields["SABnzbd URL (e.g. http://192.168.1.50:8080)"]
        let key = app.secureTextFields["Full API Key"]
        XCTAssertTrue(host.waitForExistence(timeout: 10), "The SABnzbd edit sheet should expose the configured host field.")
        XCTAssertTrue(key.waitForExistence(timeout: 10), "The SABnzbd edit sheet should expose the full API-key field.")
        waitForValue(host, expected: original.baseURL, timeout: 10)

        replace(replacement.baseURL, in: host, deleting: original.baseURL.count, in: app)
        replace("wrong-full-api-key", in: key, deleting: "uitest-api-key".count, in: app)

        let save = app.buttons["Save Connection"]
        XCTAssertTrue(tap(save, in: app, timeout: 5), "A nonempty SABnzbd host/key form should enable Save Connection.")
        XCTAssertTrue(
            waitForCondition(in: app, timeout: 10) {
                replacement.hasReceivedSABnzbdRequest(mode: "auth", apiKey: "wrong-full-api-key", extraKey: "wrong-full-api-key")
            },
            "The failed validation must send mode=auth with the edited key in both SABnzbd's apikey and key query parameters."
        )

        let invalidKeyCopy = app.staticTexts["The SABnzbd API key is missing or no longer valid."]
        XCTAssertTrue(invalidKeyCopy.waitForExistence(timeout: 10), "A 401 during SABnzbd setup must be visible while retaining the sheet for correction.")
        XCTAssertTrue(editTitle.exists, "A wrong SABnzbd full key must not dismiss the setup sheet.")
        XCTAssertEqual(host.value as? String, replacement.baseURL, "A failed SABnzbd validation must retain the newly entered host.")

        replace(replacementKey, in: key, deleting: "wrong-full-api-key".count, in: app)
        XCTAssertTrue(tap(save, in: app, timeout: 5), "Correcting the SABnzbd key should allow a second save attempt.")
        XCTAssertTrue(
            waitForCondition(in: app, timeout: 10) {
                replacement.hasReceivedSABnzbdRequest(mode: "auth", apiKey: replacementKey, extraKey: replacementKey) &&
                    replacement.hasReceivedSABnzbdRequest(mode: "version", apiKey: replacementKey) &&
                    replacement.hasReceivedSABnzbdRequest(mode: "queue", apiKey: replacementKey)
            },
            "A successful SABnzbd setup must authenticate, read version, and probe queue using the corrected key before persistence."
        )

        waitForDisappearance(of: editTitle, timeout: 15)
        XCTAssertFalse(editTitle.exists, "A successful SABnzbd setup should dismiss the edit sheet.")
        XCTAssertTrue(
            waitForCondition(in: app, timeout: 15) {
                replacement.hasReceivedSABnzbdRequest(mode: "history", apiKey: replacementKey)
            },
            "The completion callback must reinitialize SABnzbdServiceManager from the saved profile; its real reconnect fetches history, which the setup probe itself never does."
        )
        XCTAssertTrue(
            firstElement(containing: replacement.baseURL, in: app).waitForExistence(timeout: 10),
            "SABnzbd Settings should repaint with the persisted replacement host after the successful reconnect."
        )
    }

    // MARK: - Real navigation

    @MainActor
    private func launchApp(qbittorrent: String?, sabnzbd: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        if let qbittorrent {
            app.launchEnvironment["TRAWL_UITEST_QBITTORRENT_BASE_URL"] = qbittorrent
        }
        if let sabnzbd {
            app.launchEnvironment["TRAWL_UITEST_SABNZBD_BASE_URL"] = sabnzbd
        }
        app.launch()
        return app
    }

    @MainActor
    private func navigateToQBittorrentServerEditor(in app: XCUIApplication) {
        XCTAssertTrue(openDestination(.settings, in: app), "Settings should be open before selecting qBittorrent.")
        XCTAssertTrue(tap(firstButton(containing: "Fixture qBittorrent", in: app), in: app, timeout: 10), "Settings should show the seeded qBittorrent service row.")
        XCTAssertTrue(app.navigationBars["qBittorrent"].waitForExistence(timeout: 10), "The qBittorrent service row should route to qBittorrent Settings.")
        XCTAssertTrue(
            tap(app.staticTexts["Servers"], in: app, timeout: 10),
            "qBittorrent Settings should expose the real Servers destination."
        )
        XCTAssertTrue(app.navigationBars["qBittorrent Server"].waitForExistence(timeout: 10), "Servers should push ServerListView.")
        XCTAssertTrue(tap(firstButton(containing: "Fixture qBittorrent", in: app), in: app, timeout: 10), "Tapping the active server should open its actual edit form.")
    }

    @MainActor
    private func navigateToSABnzbdEditor(in app: XCUIApplication) {
        XCTAssertTrue(openDestination(.settings, in: app), "Settings should be open before selecting SABnzbd.")
        XCTAssertTrue(tap(firstButton(containing: "Fixture SABnzbd", in: app), in: app, timeout: 10), "Settings should show the seeded SABnzbd service row.")
        XCTAssertTrue(app.navigationBars["SABnzbd Settings"].waitForExistence(timeout: 10), "The SABnzbd service row should route to SABnzbd Settings.")
        XCTAssertTrue(tap(app.buttons["Edit Server"], in: app, timeout: 10), "SABnzbd Settings should expose Edit Server for a configured profile.")
    }

    // MARK: - UI helpers

    @MainActor
    private func firstButton(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func firstElement(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @discardableResult
    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            let scroller = app.scroller(for: element)
            // Direction follows the target: SwiftUI may restore a Form at its
            // previous bottom offset, so always pushing upward can move an
            // already-passed control further away.
            if element.frame.midY < app.frame.midY {
                scroller.swipeDown()
            } else {
                scroller.swipeUp()
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    @MainActor
    private func replace(_ value: String, in field: XCUIElement, deleting characterCount: Int, in app: XCUIApplication) {
        focus(field, in: app)
        if characterCount > 0 {
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: characterCount))
        }
        app.typeText(value)
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, expected: String, timeout: TimeInterval) {
        let expectation = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "Expected field to be prefilled with \(expected).")
    }

    @MainActor
    private func waitForCondition(in app: XCUIApplication, timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            _ = app.staticTexts["__service_setup_edit_tick__"].waitForExistence(timeout: 0.25)
        }
        return condition()
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while element.exists && Date.now < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }
}

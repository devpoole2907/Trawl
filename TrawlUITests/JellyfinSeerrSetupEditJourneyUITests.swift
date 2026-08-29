//
//  JellyfinSeerrSetupEditJourneyUITests.swift
//  TrawlUITests
//
//  The Jellyfin and Seerr editors had unit coverage of their view models
//  (`TrawlTests/JellyfinSetupViewModelTests.swift`) and journey coverage of the screens
//  *behind* a working connection (`JellyfinJourneyUITests`, `SeerrJourneyUITests`), but
//  nothing exercised the edit path itself: reaching the editor through the real More →
//  Settings → service route, correcting a rejected credential without losing the form,
//  and proving the service manager afterwards talks to the new server instead of the
//  old one.
//
//  Both journeys follow the same shape as `ServiceSetupEditJourneyUITests`:
//
//  1. Launch seeded against fixture A (`-TrawlUITestInMemoryStore` plus the DEBUG-only
//     profile/Keychain hook in `Trawl/TrawlApp.swift`), and confirm from the screen
//     that the real manager is connected to A.
//  2. Navigate the production UI to the editor and check A's values are pre-filled.
//  3. Repoint the host at fixture B with a deliberately wrong credential, and let B
//     issue a real 401.
//  4. Assert the exact user-visible production error, that the editor stays open, and
//     that the edited values survive.
//  5. Correct the credential, assert the exact request B received at the socket, and
//     assert the editor dismisses only then.
//  6. Assert the new host is visibly persisted and that the manager reconnected to B.
//
//  ## Proving the reconnect without depending on timing
//
//  Step 6's "reconnected to B, not still talking to A" is asserted two ways, neither of
//  which races a background refresh:
//
//  * B must have received the manager-only part of the handshake *more than once* -
//    for Jellyfin, a second authenticated `GET /System/Info` and `GET /Users` beyond
//    the single pair `JellyfinSetupViewModel.authenticate` performs; for Seerr,
//    `GET /api/v1/auth/me`, which `SeerrSetupViewModel.login` never calls at all.
//  * A must never have received a request bearing the *replacement* credential. After a
//    successful save that credential is the only one production holds, so any client
//    still aimed at A would show up there whenever it next fired - including the
//    notification accessory's 60-second Seerr poll.
//

import XCTest

final class JellyfinSeerrSetupEditJourneyUITests: XCTestCase {
    private var servers: [JellyfinSeerrSetupEditUIFixtureServer] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        servers.forEach { $0.stop() }
        servers = []
    }

    // MARK: - Jellyfin

    /// Regressions this catches: the More → Settings → Jellyfin → Edit Server route no
    /// longer presenting the real `JellyfinSetupSheet` in edit mode;
    /// `JellyfinSetupViewModel.seed(from:)` failing to pre-fill the saved display name
    /// and host; a rejected API key dismissing the sheet or reverting the edited host;
    /// the probe/authenticated split of `authenticate(normalizedURL:)` collapsing so the
    /// public probe stops being unauthenticated or the token stops being sent; a
    /// successful save not persisting the new host; and `JellyfinServiceManager` staying
    /// pointed at the previous server after the profile is repointed.
    @MainActor
    func testEditingJellyfinRejectsAWrongAPIKeyThenRepointsTheManagerToTheNewServer() async throws {
        let originalKey = "uitest-api-key"
        let replacementKey = "fixture-replacement-api-key"
        let original = try await JellyfinSeerrSetupEditUIFixtureServer(
            role: .jellyfin(apiKey: originalKey, serverName: "Fixture Jellyfin Server", version: "10.11.11")
        )
        let replacement = try await JellyfinSeerrSetupEditUIFixtureServer(
            role: .jellyfin(apiKey: replacementKey, serverName: "Replacement Jellyfin Server", version: "10.12.99")
        )
        servers = [original, replacement]

        let app = launchApp(environment: ["TRAWL_UITEST_JELLYFIN_BASE_URL": original.baseURL])
        XCTAssertTrue(
            app.tabBars.buttons["More"].waitForExistence(timeout: 15),
            "A seeded Jellyfin profile should clear the welcome gate and reach the real tab UI."
        )

        navigateToServiceSettings(named: "Fixture Jellyfin", navigationBar: "Jellyfin", in: app)

        // The System Info section is rendered from JellyfinServiceManager.cachedSystemInfo,
        // which only exists once the real manager has completed GET /System/Info. Seeing
        // the original server's name here is the baseline the repoint is measured against.
        XCTAssertTrue(
            staticText("Server, Fixture Jellyfin Server", in: app).waitForExistence(in: app, timeout: 15),
            "Jellyfin Settings should show the originally connected server's name before any edit - if this fails, the baseline connect is broken, not the repoint."
        )

        XCTAssertTrue(tap(app.buttons["Edit Server"], in: app, timeout: 10), "A configured Jellyfin profile should offer Edit Server.")
        let editTitle = app.navigationBars["Edit Jellyfin"]
        XCTAssertTrue(
            editTitle.waitForExistence(timeout: 10),
            "Edit Server should present the real JellyfinSetupSheet in edit mode rather than an Add flow."
        )
        expandSheet(titled: "Edit Jellyfin", in: app)

        // MARK: Pre-fill

        let displayName = textField(placeholder: "Display Name", in: app)
        let host = textField(placeholder: "Jellyfin URL (e.g. http://192.168.1.50:8096)", in: app)
        XCTAssertTrue(displayName.waitForExistence(timeout: 10), "The Jellyfin editor should expose its Display Name field.")
        XCTAssertTrue(host.waitForExistence(timeout: 10), "The Jellyfin editor should expose its host field.")
        waitForValue(displayName, expected: "Fixture Jellyfin", timeout: 10)
        waitForValue(host, expected: original.baseURL, timeout: 10)

        // MARK: Repoint at the replacement with a wrong key

        replace(replacement.baseURL, into: host, in: app, deleting: original.baseURL.count)
        let apiKey = secureField(placeholder: "API Key", in: app)
        XCTAssertTrue(apiKey.waitForExistence(timeout: 10), "API-key mode should expose the API Key field.")
        // `seed(from:)` deliberately leaves the key blank on edit - the stored token is
        // never read back into the form - so there is nothing to delete first.
        replace("wrong-api-key", into: apiKey, in: app, deleting: 0)

        let save = app.buttons["Save Connection"]
        XCTAssertTrue(
            tapInEditor(save, in: app, timeout: 15),
            "A populated Jellyfin edit form should enable its submit button."
        )

        XCTAssertTrue(
            waitForCondition(in: app, timeout: 15) {
                replacement.hasReceivedJellyfinRequestWithClientIdentity(method: "GET", path: "/System/Info/Public") &&
                    replacement.hasReceivedJellyfinRequest(method: "GET", path: "/System/Info/Public", token: nil)
            },
            "JellyfinSetupViewModel must probe the edited host with an unauthenticated GET /System/Info/Public that still carries the MediaBrowser client identity but no Token field."
        )
        XCTAssertTrue(
            waitForCondition(in: app, timeout: 15) {
                replacement.hasReceivedJellyfinRequest(method: "GET", path: "/System/Info", token: "wrong-api-key")
            },
            "The rejected attempt must send the typed API key to the edited host as Authorization: MediaBrowser … Token=\"wrong-api-key\"."
        )

        // MARK: The rejection must be visible and non-destructive

        let rejectedCopy = staticText("Your Jellyfin credentials are no longer valid. Please sign in again.", in: app)
        XCTAssertTrue(
            rejectedCopy.waitForExistence(timeout: 15),
            "A 401 from Jellyfin must surface JellyfinAPIError.unauthorized's copy in the editor's ValidationErrorSection."
        )
        XCTAssertTrue(editTitle.exists, "A rejected API key must keep the Jellyfin editor open for correction.")
        // Scroll the host field back into view before reading it: surfacing the error
        // section can move it, and a row SwiftUI has unloaded reports no value at all,
        // which would fail for a reason unrelated to the behavior under test.
        XCTAssertTrue(
            waitUntilHittable(host, timeout: 10),
            "The host field must still be present and editable after a rejected validation."
        )
        XCTAssertEqual(
            host.value as? String,
            replacement.baseURL,
            "The rejected attempt must preserve the edited host instead of restoring the previously saved one."
        )
        XCTAssertFalse(
            replacement.hasReceivedJellyfinRequest(method: "GET", path: "/Users", token: "wrong-api-key"),
            "A failed system-info check must abort the handshake rather than continuing on to the user prefetch."
        )

        // MARK: Correct the key

        replace(replacementKey, into: apiKey, in: app, deleting: "wrong-api-key".count)
        XCTAssertTrue(
            tapInEditor(save, in: app, timeout: 15),
            "Correcting the API key should allow a second real validation attempt."
        )

        XCTAssertTrue(
            waitForCondition(in: app, timeout: 20) {
                replacement.hasReceivedJellyfinRequest(method: "GET", path: "/System/Info", token: replacementKey) &&
                    replacement.hasReceivedJellyfinRequest(method: "GET", path: "/Users", token: replacementKey)
            },
            "A successful Jellyfin save must read system info and users from the edited host using the corrected key before persisting."
        )

        waitForDisappearance(of: editTitle, timeout: 20)
        XCTAssertFalse(editTitle.exists, "The Jellyfin editor should dismiss only once the real validation succeeds.")

        // MARK: Persisted, and the manager followed

        XCTAssertTrue(
            staticText(replacement.baseURL, in: app).waitForExistence(in: app, timeout: 15),
            "Jellyfin Settings should repaint from SwiftData with the persisted replacement host."
        )
        XCTAssertTrue(
            staticText("Server, Replacement Jellyfin Server", in: app).waitForExistence(in: app, timeout: 20),
            "The System Info section should show the replacement server's name, which only reaches the screen through JellyfinServiceManager's cachedSystemInfo after a real reconnect."
        )

        XCTAssertTrue(
            waitForCondition(in: app, timeout: 20) {
                replacement.jellyfinRequestCount(method: "GET", path: "/System/Info", token: replacementKey) >= 2 &&
                    replacement.jellyfinRequestCount(method: "GET", path: "/Users", token: replacementKey) >= 2
            },
            "JellyfinSetupViewModel performs exactly one authenticated /System/Info + /Users pair per attempt, so a second pair proves JellyfinServiceManager reconnected to the replacement rather than reusing its existing client."
        )
        XCTAssertFalse(
            original.hasReceivedRequestCarrying(jellyfinToken: replacementKey),
            "The original Jellyfin fixture must never see the replacement API key - receiving it means a client or manager is still aimed at the old host after the repoint."
        )

        assertNoUnexpectedRoutes(original, replacement, service: "Jellyfin")
    }

    // MARK: - Seerr

    /// Regressions this catches: the More → Settings → Seerr → Edit Server route no
    /// longer presenting `SeerrSetupSheet` in edit mode; the editor's `onAppear`
    /// pre-fill of the saved host regressing; a rejected sign-in dismissing the sheet or
    /// discarding the edited host; `SeerrAPIClient.loginJellyfin` changing the shape of
    /// its real POST; the session cookie issued by the new server not being captured
    /// from `Set-Cookie` and persisted; and `SeerrServiceManager` continuing to use the
    /// old host or the old cookie afterwards.
    @MainActor
    func testEditingSeerrRejectsWrongCredentialsThenReconnectsWithTheNewSessionCookie() async throws {
        let originalCookie = "uitest-session"
        let replacementCookie = "fixture-replacement-session"
        let username = "fixture-admin"
        let password = "fixture-admin-password"
        let original = try await JellyfinSeerrSetupEditUIFixtureServer(
            role: .seerr(
                username: username,
                password: password,
                sessionCookie: originalCookie,
                applicationTitle: "Fixture Seerr Instance"
            )
        )
        let replacement = try await JellyfinSeerrSetupEditUIFixtureServer(
            role: .seerr(
                username: username,
                password: password,
                sessionCookie: replacementCookie,
                applicationTitle: "Replacement Seerr Instance"
            )
        )
        servers = [original, replacement]

        let app = launchApp(environment: ["TRAWL_UITEST_SEERR_BASE_URL": original.baseURL])
        XCTAssertTrue(
            app.tabBars.buttons["More"].waitForExistence(timeout: 15),
            "A seeded Seerr profile should clear the welcome gate and reach the real tab UI."
        )

        navigateToServiceSettings(named: "Fixture Seerr", navigationBar: "Seerr", in: app)

        // System Status is rendered from SeerrSettingsView.loadPublicSettings(), which
        // runs against SeerrServiceManager's active client. Seeing the original
        // instance's title proves the baseline connection before the repoint.
        XCTAssertTrue(
            staticText("Instance, Fixture Seerr Instance", in: app).waitForExistence(in: app, timeout: 15),
            "Seerr Settings should show the originally connected instance's title before any edit."
        )

        XCTAssertTrue(tap(app.buttons["Edit Server"], in: app, timeout: 10), "A configured Seerr profile should offer Edit Server.")
        let editTitle = app.navigationBars["Edit Seerr"]
        XCTAssertTrue(
            editTitle.waitForExistence(timeout: 10),
            "Edit Server should present the real SeerrSetupSheet in edit mode rather than an Add flow."
        )

        // MARK: Pre-fill

        let host = textField(placeholder: "Seerr URL (e.g. http://192.168.1.50:5055)", in: app)
        XCTAssertTrue(host.waitForExistence(timeout: 10), "The Seerr editor should expose its host field.")
        waitForValue(host, expected: original.baseURL, timeout: 10)

        // MARK: Repoint at the replacement with a wrong password

        replace(replacement.baseURL, into: host, in: app, deleting: original.baseURL.count)

        let usernameField = textField(placeholder: "Jellyfin Username", in: app)
        let passwordField = secureField(placeholder: "Jellyfin Password", in: app)
        XCTAssertTrue(usernameField.waitForExistence(timeout: 10), "The Seerr editor should expose its username field.")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "The Seerr editor should expose its password field.")
        // Seerr exchanges these credentials for a session cookie and never stores them,
        // so an edit legitimately starts with both fields empty.
        replace(username, into: usernameField, in: app, deleting: 0)
        replace("wrong-password", into: passwordField, in: app, deleting: 0)

        let signIn = app.buttons["Sign In"]
        XCTAssertTrue(
            tapInEditor(signIn, in: app, timeout: 15),
            "A fully populated Seerr edit form should enable Sign In and keep it reachable: the editor presents at .large precisely so this button is on screen without scrolling."
        )

        XCTAssertTrue(
            waitForCondition(in: app, timeout: 15) {
                replacement.hasReceivedSeerrLogin(username: username, password: "wrong-password")
            },
            "The rejected attempt must POST /api/v1/auth/jellyfin to the edited host as application/json with exactly the typed username and password."
        )

        // MARK: The rejection must be visible and non-destructive

        let rejectedCopy = staticText("Your Seerr session has expired. Please sign in again.", in: app)
        XCTAssertTrue(
            rejectedCopy.waitForExistence(timeout: 15),
            "A 401 from Seerr's sign-in must surface SeerrAPIError.unauthorized's copy inside the editor."
        )
        XCTAssertTrue(editTitle.exists, "A rejected Seerr sign-in must keep the editor open for correction.")
        // Same reason as the Jellyfin journey: read the field only once it is back on
        // screen, so an unloaded row can't be mistaken for a discarded edit.
        XCTAssertTrue(
            waitUntilHittable(host, timeout: 10),
            "The host field must still be present and editable after a rejected sign-in."
        )
        XCTAssertEqual(
            host.value as? String,
            replacement.baseURL,
            "The rejected attempt must preserve the edited host instead of restoring the previously saved one."
        )
        XCTAssertFalse(
            replacement.hasReceivedSeerrRequest(method: "GET", path: "/api/v1/auth/me", cookie: replacementCookie),
            "A failed sign-in must not connect the manager to the edited host."
        )

        // MARK: Correct the password

        replace(password, into: passwordField, in: app, deleting: "wrong-password".count)
        XCTAssertTrue(
            tapInEditor(signIn, in: app, timeout: 15),
            "Correcting the password should allow a second real sign-in attempt."
        )

        XCTAssertTrue(
            waitForCondition(in: app, timeout: 20) {
                replacement.hasReceivedSeerrLogin(username: username, password: password)
            },
            "The successful retry must send the corrected credentials to the edited Seerr host."
        )

        waitForDisappearance(of: editTitle, timeout: 20)
        XCTAssertFalse(editTitle.exists, "The Seerr editor should dismiss only once the real sign-in succeeds.")

        // MARK: Persisted, and the manager followed

        XCTAssertTrue(
            staticText(replacement.baseURL, in: app).waitForExistence(in: app, timeout: 15),
            "Seerr Settings should repaint from SwiftData with the persisted replacement host."
        )
        XCTAssertTrue(
            staticText("Instance, Replacement Seerr Instance", in: app).waitForExistence(in: app, timeout: 20),
            "System Status should show the replacement instance's title, which only arrives via GET /api/v1/settings/public through the manager's reconnected client."
        )

        XCTAssertTrue(
            waitForCondition(in: app, timeout: 20) {
                replacement.hasReceivedSeerrRequest(method: "GET", path: "/api/v1/auth/me", cookie: replacementCookie)
            },
            "SeerrSetupViewModel never calls /api/v1/auth/me, so receiving it with the newly issued cookie proves SeerrServiceManager reconnected using the cookie captured from the replacement's Set-Cookie header."
        )
        XCTAssertTrue(
            waitForCondition(in: app, timeout: 20) {
                replacement.hasReceivedSeerrRequest(
                    method: "GET",
                    path: "/api/v1/settings/public",
                    queryItems: [:],
                    cookie: replacementCookie
                )
            },
            "SeerrSettingsView's System Status must be loaded from the replacement host with the new cookie, not served from state cached against the old one."
        )
        XCTAssertFalse(
            original.hasReceivedRequestCarrying(seerrCookie: replacementCookie),
            "The original Seerr fixture must never see the replacement session cookie - receiving it means a client or manager is still aimed at the old host after the repoint."
        )

        assertNoUnexpectedRoutes(original, replacement, service: "Seerr")
    }

    // MARK: - Launch & navigation

    @MainActor
    private func launchApp(environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// More → Settings → the seeded service row, exactly as `SettingsView`'s Services
    /// section wires it (each row is a `Button` labelled with the profile's display
    /// name and host URL).
    @MainActor
    private func navigateToServiceSettings(named name: String, navigationBar: String, in app: XCUIApplication) {
        XCTAssertTrue(tap(app.tabBars.buttons["More"], in: app, timeout: 10), "The More tab should be reachable.")
        XCTAssertTrue(tap(firstButton(containing: "Settings", in: app), in: app, timeout: 10), "More should route to Settings.")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings should be pushed before selecting \(name).")
        XCTAssertTrue(tap(firstButton(containing: name, in: app), in: app, timeout: 10), "Settings should list the seeded \(name) service row.")
        XCTAssertTrue(
            app.navigationBars[navigationBar].waitForExistence(timeout: 10),
            "The \(name) row should push its real \(navigationBar) settings screen."
        )
    }

    @MainActor
    private func assertNoUnexpectedRoutes(
        _ fixtures: JellyfinSeerrSetupEditUIFixtureServer...,
        service: String
    ) {
        for server in fixtures {
            let unexpected = server.unexpectedRequests.map { "\($0.method) \($0.path)" }
            XCTAssertTrue(
                unexpected.isEmpty,
                "\(service) production code called routes this journey never traced: \(unexpected.joined(separator: ", ")). The fixture answered 404 rather than inventing a success - extend the traced route set deliberately."
            )
        }
    }

    // MARK: - UI helpers

    @MainActor
    private func firstButton(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Matched by exact label and reduced to `firstMatch`. Two things make this the
    /// right query: `LabeledContent` publishes one merged element whose label is
    /// `"<label>, <value>"` (so asserting `"Server, Replacement Jellyfin Server"` pins
    /// the row *and* its value, not a loose string anywhere on screen), and
    /// `SeerrSettingsView` renders the instance title in two sections, where a
    /// multiple-match query would fail on access rather than on the behavior.
    @MainActor
    private func staticText(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// SwiftUI `TextField`/`SecureField` inside a `Form` publish their title as the
    /// element's *placeholder*, not its accessibility label - a probe of the real
    /// hierarchy shows `label` empty on every field in both editors. Matching on
    /// `placeholderValue` is therefore the identity that actually exists, and it stays
    /// stable once the field holds a value.
    @MainActor
    private func textField(placeholder: String, in app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    @MainActor
    private func secureField(placeholder: String, in app: XCUIApplication) -> XCUIElement {
        app.secureTextFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
    }

    // MARK: Working inside a presented editor
    //
    // Everything below exists to keep the editor's layout *static* while the journey
    // drives it, which is what makes these forms addressable at all. Probing the real
    // hierarchy showed two ways the naive approach fails:
    //
    // * Jellyfin supports a medium detent, so the test expands it before interaction.
    //   Seerr deliberately presents at `.large`: at medium its form is too short to
    //   scroll while "Sign In" sits below an iPhone 17 Pro screen.
    // * Scrolling a presented sheet is not addressable: the sheet's Form and the
    //   settings list behind it are both in the tree, so `collectionViews.firstMatch`
    //   resolves to either, and scrolling far enough unloads the very lazily-rendered
    //   row being reached for.
    //
    // Keeping each editor at the large detent, and dropping the keyboard after every
    // entry, removes both problems without in-sheet scrolling.

    /// Drags the presented editor up to its large detent - what a user does with a
    /// cramped sheet. A no-op once the sheet is already large.
    @MainActor
    private func expandSheet(titled title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        guard bar.waitForExistence(timeout: 10) else { return }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            )
        _ = app.staticTexts["__jellyfin_seerr_setup_edit_tick__"].waitForExistence(timeout: 1)
    }

    /// Types into a field of the presented editor, then drops the keyboard so the next
    /// element is looked at against a settled layout.
    @MainActor
    private func replace(
        _ value: String,
        into field: XCUIElement,
        in app: XCUIApplication,
        deleting characterCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntilHittable(field, timeout: 10),
            "The field should be on screen and interactable before typing into it.",
            file: file,
            line: line
        )
        if field.elementType == .secureTextField {
            // SecureField exposes a compact text-input element; tapping it directly is
            // what gives it keyboard focus.
            field.tap()
        } else {
            // SwiftUI aligns URL fields toward their trailing edge, so tapping there
            // puts the caret after the existing text rather than in front of it.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        if characterCount > 0 {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: characterCount))
        }
        field.typeText(value)
        resignKeyboard(in: app)
    }

    /// Taps a control inside the presented editor. No scrolling: the sheet has been
    /// expanded and the keyboard dropped, so the control is either on screen or the
    /// journey has found a real problem.
    @discardableResult
    @MainActor
    private func tapInEditor(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        resignKeyboard(in: app)
        guard waitUntilHittable(element, timeout: timeout) else { return false }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    /// Dismisses the software keyboard by pressing its submit key. The label differs by
    /// keyboard type (the host fields use `.URL`), so the known variants are tried in
    /// turn.
    @MainActor
    private func resignKeyboard(in app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        for label in ["return", "Return", "Go", "go", "Done", "done"] {
            let key = app.keyboards.buttons[label]
            guard key.exists, key.isHittable else { continue }
            key.tap()
            break
        }
        let deadline = Date.now.addingTimeInterval(5)
        while app.keyboards.element.exists && Date.now < deadline {
            _ = app.staticTexts["__jellyfin_seerr_setup_edit_tick__"].waitForExistence(timeout: 0.25)
        }
    }

    /// Bounded poll on `isHittable`, built only from `waitForExistence`, so it never
    /// sleeps and never manufactures a result.
    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.exists && element.isHittable { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.exists && element.isHittable
    }

    // MARK: Working in the pushed settings lists

    /// Taps a row in a normal pushed list, scrolling toward it when SwiftUI has not
    /// rendered it yet. Only used where no sheet is presented, so the scroll container
    /// is unambiguous.
    @discardableResult
    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            let scroller = app.collectionViews.firstMatch.exists
                ? app.collectionViews.firstMatch
                : app.scrollViews.firstMatch
            if scroller.exists {
                // A destination Form can be restored at its previous offset, so move
                // toward the off-screen element instead of always scrolling one way.
                if element.frame.midY < app.frame.midY {
                    scroller.swipeDown()
                } else {
                    scroller.swipeUp()
                }
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, expected: String, timeout: TimeInterval) {
        let expectation = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout),
            .completed,
            "Expected the editor to be pre-filled with \(expected), but it held \(String(describing: element.value))."
        )
    }

    /// Bounded poll over fixture state. Built only from `waitForExistence` on a query
    /// that never matches, so it yields to the runner without sleeping.
    @MainActor
    private func waitForCondition(in app: XCUIApplication, timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            _ = app.staticTexts["__jellyfin_seerr_setup_edit_tick__"].waitForExistence(timeout: 0.25)
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

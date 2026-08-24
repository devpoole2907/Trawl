//
//  ArrRemotePathMappingJourneyUITests.swift
//  TrawlUITests
//
//  End-to-end coverage for More → Automation & Clients → Remote Path Mappings.
//  The app owns startup seeding, SwiftData, Keychain, navigation, state, sheets,
//  confirmation dialogs, and ArrAPIClient. The loopback fixture is solely the
//  external Sonarr server the production client speaks to.
//

import XCTest

final class ArrRemotePathMappingJourneyUITests: XCTestCase {
    private var server: ArrRemotePathMappingUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// Regression coverage for the full remote-path-mapping administration flow:
    /// a mapping returned by Sonarr must render; Add, Edit, and the destructive
    /// confirmation must each call their real /api/v3 endpoint with the exact
    /// entered model; and the list must reflect the server's returned mutation.
    @MainActor
    func testSonarrRemotePathMappingsLoadThenAddEditAndDeleteThroughTheRealUI() async throws {
        let server = try await ArrRemotePathMappingUIFixtureServer()
        self.server = server
        let app = launchApp(using: server)

        openMappings(in: app)

        XCTAssertTrue(
            app.staticTexts[ArrRemotePathMappingUIFixtureServer.originalRemotePath].waitForExistence(in: app, timeout: 15),
            "The mapping list should render the remote path decoded from Sonarr's GET /api/v3/remotepathmapping response."
        )
        XCTAssertTrue(
            app.staticTexts[ArrRemotePathMappingUIFixtureServer.originalLocalPath].waitForExistence(in: app, timeout: 10),
            "The mapping list should also render the decoded local path, proving this is a real server result rather than a title-only navigation smoke test."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v3/remotepathmapping"),
            "The rendered mapping must originate from SonarrAPIClient.getRemotePathMappings() over real HTTP."
        )

        // Add a second mapping. With only one seeded Arr service, the editor has no
        // service picker and correctly defaults to Sonarr; Any Host (*) is likewise
        // the production default when no qBittorrent profile exists.
        let addMapping = app.buttons["Add Mapping"]
        XCTAssertTrue(addMapping.waitForExistence(timeout: 10), "A connected Sonarr profile should expose the Add Mapping toolbar action.")
        addMapping.tap()
        XCTAssertTrue(app.navigationBars["Add Mapping"].waitForExistence(timeout: 10), "Add Mapping should present the real editor sheet.")

        let remoteField = app.textFields["/downloads/"]
        let localField = app.textFields["/media/downloads/"]
        XCTAssertTrue(remoteField.waitForExistence(in: app, timeout: 10), "The editor should expose its Remote Path input.")
        XCTAssertTrue(localField.waitForExistence(in: app, timeout: 10), "The editor should expose its Local Path input.")
        remoteField.tap()
        remoteField.typeText(ArrRemotePathMappingUIFixtureServer.addedRemotePath)
        localField.tap()
        localField.typeText(ArrRemotePathMappingUIFixtureServer.addedLocalPath)

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "The editor should expose Save after both required paths are supplied.")
        XCTAssertTrue(save.isEnabled, "Save must enable only after the production form receives both entered paths.")
        save.tap()

        XCTAssertTrue(
            app.staticTexts[ArrRemotePathMappingUIFixtureServer.addedRemotePath].waitForExistence(in: app, timeout: 15),
            "Saving should append the mapping returned from Sonarr, not just leave the sheet dismissed."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(
                method: "POST",
                path: "/api/v3/remotepathmapping",
                bodyMatching: [
                    "id": 0,
                    "host": "*",
                    "remotePath": ArrRemotePathMappingUIFixtureServer.addedRemotePath,
                    "localPath": ArrRemotePathMappingUIFixtureServer.addedLocalPath,
                ]
            ),
            "Add Mapping must send the exact entered ArrRemotePathMapping model to Sonarr's POST endpoint."
        )

        // Tap the newly returned row to exercise the editor's populated edit path.
        let addedRow = firstButton(containing: ArrRemotePathMappingUIFixtureServer.addedRemotePath, in: app)
        XCTAssertTrue(addedRow.waitForExistence(in: app, timeout: 10), "The newly-added mapping row should be a tappable edit entry point.")
        addedRow.tap()
        XCTAssertTrue(app.navigationBars["Edit Mapping"].waitForExistence(timeout: 10), "Tapping a mapping should present its real edit sheet.")

        let existingRemote = app.textFields["/downloads/"]
        let existingLocal = app.textFields["/media/downloads/"]
        XCTAssertEqual(existingRemote.value as? String, ArrRemotePathMappingUIFixtureServer.addedRemotePath, "Edit should pre-fill the server-returned remote path.")
        XCTAssertEqual(existingLocal.value as? String, ArrRemotePathMappingUIFixtureServer.addedLocalPath, "Edit should pre-fill the server-returned local path.")
        replaceText(in: existingRemote, with: ArrRemotePathMappingUIFixtureServer.editedRemotePath)
        replaceText(in: existingLocal, with: ArrRemotePathMappingUIFixtureServer.editedLocalPath)

        let update = app.buttons["Update"]
        XCTAssertTrue(update.waitForExistence(timeout: 5), "The edit sheet should expose Update.")
        XCTAssertTrue(update.isEnabled, "Update should remain enabled after both edited paths are present.")
        update.tap()

        XCTAssertTrue(
            waitForRequest(
                on: server,
                method: "PUT",
                path: "/api/v3/remotepathmapping/42",
                bodyMatching: [
                    "id": 42,
                    "host": "*",
                    "remotePath": ArrRemotePathMappingUIFixtureServer.editedRemotePath,
                    "localPath": ArrRemotePathMappingUIFixtureServer.editedLocalPath,
                ],
                in: app,
                timeout: 10
            ),
            "Update must send the edited mapping, including the server-assigned ID, to Sonarr's exact PUT route. Recorded requests: \(server.requests)"
        )
        waitForDisappearance(of: app.navigationBars["Edit Mapping"], timeout: 10)
        XCTAssertFalse(
            app.navigationBars["Edit Mapping"].exists,
            "A successful PUT should dismiss the edit sheet before the updated list is asserted."
        )
        XCTAssertTrue(
            app.staticTexts[ArrRemotePathMappingUIFixtureServer.editedRemotePath].waitForExistence(in: app, timeout: 15),
            "Updating should replace the row with the mapping returned by Sonarr's PUT response."
        )
        XCTAssertFalse(
            app.staticTexts[ArrRemotePathMappingUIFixtureServer.addedRemotePath].exists,
            "The old remote path should not remain visible after a successful server-backed update."
        )
        // Delete goes through the row's explicit destructive swipe action, which
        // must present the confirmation before DELETE is permitted.
        let editedRow = firstButton(containing: ArrRemotePathMappingUIFixtureServer.editedRemotePath, in: app)
        XCTAssertTrue(editedRow.waitForExistence(in: app, timeout: 10), "The updated row should remain available for deletion.")
        editedRow.swipeLeft()
        let deleteAction = app.buttons["Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 10), "Swiping a mapping should reveal the explicit Delete action, not delete immediately.")
        deleteAction.tap()

        XCTAssertTrue(
            app.staticTexts["Delete Mapping?"].waitForExistence(timeout: 10),
            "Delete should present the production confirmation dialog before an HTTP mutation is issued."
        )
        XCTAssertFalse(
            server.hasReceivedRequest(method: "DELETE", path: "/api/v3/remotepathmapping/42"),
            "Opening the destructive confirmation must not issue DELETE before the user explicitly confirms it."
        )
        let confirmDelete = app.buttons["Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5), "The confirmation dialog should offer its destructive Delete choice.")
        confirmDelete.tap()

        waitForDisappearance(of: app.staticTexts[ArrRemotePathMappingUIFixtureServer.editedRemotePath], timeout: 15)
        XCTAssertFalse(
            app.staticTexts[ArrRemotePathMappingUIFixtureServer.editedRemotePath].exists,
            "Confirming deletion should remove the mapping from the visible list only after Sonarr accepts the DELETE."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "DELETE", path: "/api/v3/remotepathmapping/42"),
            "The confirmed destructive action must issue DELETE to the exact Sonarr mapping ID selected in the UI."
        )
        XCTAssertTrue(
            app.staticTexts[ArrRemotePathMappingUIFixtureServer.originalRemotePath].exists,
            "Deleting the edited mapping must preserve the independently decoded original mapping."
        )
    }

    // MARK: - Launch, navigation, and interaction helpers

    @MainActor
    private func launchApp(using server: ArrRemotePathMappingUIFixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        app.launch()
        return app
    }

    @MainActor
    private func openMappings(in app: XCUIApplication) {
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(tapWhenHittable(more, in: app, timeout: 15), "A seeded Sonarr profile should bring the app to its tab UI so More is reachable.")

        let automation = firstButton(containing: "Automation & Clients", in: app)
        XCTAssertTrue(tapWhenHittable(automation, in: app, timeout: 10), "More should expose Automation & Clients.")
        XCTAssertTrue(app.navigationBars["Automation & Clients"].waitForExistence(timeout: 10), "Automation & Clients should push its real hub.")

        let remoteMappings = firstButton(containing: "Remote Path Mappings", in: app)
        XCTAssertTrue(tapWhenHittable(remoteMappings, in: app, timeout: 10), "The Automation & Clients hub should expose Remote Path Mappings.")
        XCTAssertTrue(app.navigationBars["Remote Path Mappings"].waitForExistence(timeout: 10), "Remote Path Mappings should push ArrRemotePathMappingListView.")
    }

    @MainActor
    private func firstButton(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable {
                element.tap()
                return true
            }
            let scroller = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            scroller.swipeUp()
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        let existing = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, element.exists {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }

    @MainActor
    private func waitForRequest(
        on server: ArrRemotePathMappingUIFixtureServer,
        method: String,
        path: String,
        bodyMatching: [String: AnyHashable],
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let tick = app.otherElements["trawl-tests-only-request-wait-tick"]
        while Date() < deadline {
            if server.hasReceivedRequest(method: method, path: path, bodyMatching: bodyMatching) {
                return true
            }
            _ = tick.waitForExistence(timeout: 0.25)
        }
        return server.hasReceivedRequest(method: method, path: path, bodyMatching: bodyMatching)
    }
}

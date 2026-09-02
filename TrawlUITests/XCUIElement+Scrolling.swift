import XCTest

extension XCUIElement {
    /// Waits for this element, scrolling the enclosing scroll view if it does not
    /// appear straight away.
    ///
    /// SwiftUI renders `Form`/`List` rows lazily, so a control that is simply below
    /// the fold is absent from the accessibility tree entirely - `waitForExistence`
    /// reports it missing even though a user could reach it by scrolling. That makes
    /// a plain wait fail for reasons that have nothing to do with the behavior under
    /// test.
    ///
    /// Scrolls a bounded number of times and never sleeps: each attempt is another
    /// short `waitForExistence`.
    func waitForExistence(
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        maxScrolls: Int = 8
    ) -> Bool {
        if waitForExistence(timeout: timeout) { return true }

        let scroller = Self.contentScroller(in: app)
        for _ in 0..<maxScrolls {
            scroller.swipeUp()
            if waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    /// The scrollable view holding the screen under test.
    ///
    /// Scrolls the form/list itself rather than the whole app: a swipe on a sheet's
    /// backdrop drags the sheet instead of its content.
    ///
    /// The iPad sidebar makes the obvious `collectionViews.firstMatch` wrong. The
    /// sidebar is a `List`, so it *is* a collection view, and being the leading column
    /// it is the first one in the hierarchy - so the naive query scrolled the sidebar
    /// eight times while the screen under test never moved, and the element below the
    /// fold was duly reported missing. The failure reads as "this screen stopped
    /// rendering its content", which is the wrong screen and the wrong bug.
    ///
    /// So candidates that are the sidebar are skipped. Identification is by the
    /// `nav.<case>` rows only the sidebar holds, rather than by position or width,
    /// because those change with orientation and column sizing while the rows do not.
    private static func contentScroller(in app: XCUIApplication) -> XCUIElement {
        for query in [app.collectionViews, app.tables, app.scrollViews] {
            guard query.firstMatch.exists else { continue }
            if let content = query.allElementsBoundByIndex.first(where: { !isSidebar($0) }) {
                return content
            }
        }
        return app
    }

    /// Whether this scrollable view is the iPad sidebar.
    ///
    /// Deliberately `cells.containing` rather than `descendants(matching: .any)`:
    /// the broad form walks the entire tree on every call, and on these screens it
    /// pushed later queries past their limit - a run died with "Failed to get matching
    /// snapshots: Timed out while evaluating UI query" several steps after the query
    /// that actually caused it.
    private static func isSidebar(_ element: XCUIElement) -> Bool {
        element.cells
            .containing(NSPredicate(format: "identifier BEGINSWITH %@", "nav."))
            .firstMatch
            .exists
    }
}

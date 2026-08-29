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

        // Scroll the form/list itself rather than the whole app: a swipe on a sheet's
        // backdrop drags the sheet instead of its content.
        let scroller: XCUIElement
        if app.collectionViews.firstMatch.exists {
            scroller = app.collectionViews.firstMatch
        } else if app.tables.firstMatch.exists {
            scroller = app.tables.firstMatch
        } else if app.scrollViews.firstMatch.exists {
            scroller = app.scrollViews.firstMatch
        } else {
            scroller = app
        }

        for _ in 0..<maxScrolls {
            scroller.swipeUp()
            if waitForExistence(timeout: 1) { return true }
        }
        return false
    }
}

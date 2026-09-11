import XCTest

extension XCUIApplication {
    /// The scrollable view a swipe should move in order to bring `element` into view.
    ///
    /// Not `collectionViews.firstMatch`, and not simply the last one either. On iPad
    /// three scrollable things are routinely on screen at once - the sidebar, the
    /// content column, and a presented sheet's own form - plus the keyboard, which is
    /// a collection view hosted out of process. Swiping the wrong one moves something
    /// the test is not looking at while the screen under test stays exactly where it
    /// was, and the control below the fold is reported unreachable: the failure names
    /// the wrong screen and the wrong bug.
    ///
    /// Two filters settle it. The keyboard is excluded by frame - swiping it produced
    /// four rounds of "Wait for com.apple.springboard to idle" while a setup sheet sat
    /// still. And the remaining candidates are narrowed to the one the control is
    /// horizontally inside, which is what tells a form sheet's list apart from the
    /// sidebar beside it. With no frame to go on - the control is below the fold, so
    /// it is not in the tree at all - the largest candidate that is not the sidebar
    /// wins instead.
    ///
    /// Every property read here is an IPC round trip, so this is deliberately frugal:
    /// the sidebar is recognised by its accessibility label rather than by inspecting
    /// its rows, and the three query types are tried in turn rather than all at once.
    /// An earlier version that checked each candidate's cells took a journey from
    /// forty seconds to twelve minutes.
    func scroller(for element: XCUIElement) -> XCUIElement {
        let keyboard = keyboards.firstMatch
        let keyboardFrame = keyboard.exists ? keyboard.frame : .null
        // `frame` on an element that is not in the tree throws "Failed to get matching
        // snapshot", which surfaces as an error in this helper rather than as the
        // caller's own assertion about the element it was looking for.
        let midX: CGFloat? = element.exists ? element.frame.midX : nil

        func pick(_ query: XCUIElementQuery) -> XCUIElement? {
            let candidates = query.allElementsBoundByIndex.filter { !keyboardFrame.contains($0.frame) }
            guard !candidates.isEmpty else { return nil }
            let content = candidates.filter { $0.label != "Sidebar" }
            let pool = content.isEmpty ? candidates : content
            guard let midX else {
                return pool.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            }
            return pool.last { $0.frame.minX <= midX && midX <= $0.frame.maxX } ?? pool.last
        }
        if let match = pick(collectionViews) { return match }
        if let match = pick(tables) { return match }
        if let match = pick(scrollViews) { return match }
        return self
    }
}

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
    /// short `waitForExistence`. The scroller is chosen **once**, before the loop.
    /// Re-choosing it per attempt is the obvious thing and it is far too expensive -
    /// every candidate's frame is an IPC round trip - and this helper is called from
    /// almost every assertion in the target.
    func waitForExistence(
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        maxScrolls: Int = 8
    ) -> Bool {
        if waitForExistence(timeout: timeout) { return true }

        // Alternates between the candidate columns, within one shared budget. A
        // three-column iPad screen has two scrollable columns that are not the sidebar
        // and the element can be in either, so both get swiped - but `maxScrolls` is
        // the total, not a budget each. Spending it per candidate doubled the swipes
        // on every lookup that was going to fail anyway, which showed up as whole
        // suites running 20-50% slower.
        let scrollers = Self.contentScrollers(in: app)
        // One column keeps exactly the budget it always had, so a phone - where there
        // is only ever one - pays nothing for any of this. Two columns share half as
        // much again rather than a full budget each, so neither is starved and the
        // worst case grows by half rather than doubling.
        let budget = scrollers.count == 1 ? maxScrolls : maxScrolls + maxScrolls / 2
        for attempt in 0..<budget {
            scrollers[attempt % scrollers.count].swipeUp()
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
    /// Ordered right-most first, because the detail pane is the right-most column and
    /// is where a pushed or selected screen's own content lives.
    ///
    /// This used to return the *first* non-sidebar scroller, which is correct on a
    /// phone and on a two-column layout but wrong on three: the first one is the
    /// content column - the list - while the screen under test is in the detail pane
    /// beside it. Prowlarr's indexer detail failed exactly that way, reporting its
    /// "Test Indexer" action missing after eight swipes that scrolled the indexer
    /// list instead. Same shape as the sidebar bug above, one column further right.
    private static func contentScrollers(in app: XCUIApplication) -> [XCUIElement] {
        for query in [app.collectionViews, app.tables, app.scrollViews] {
            guard query.firstMatch.exists else { continue }

            // The cheap path first, and it is the one nearly every call takes: the
            // leading non-sidebar scroller, found by short-circuit exactly as this
            // did before there was a second candidate.
            let all = query.allElementsBoundByIndex
            guard let leading = all.first(where: { !isSidebar($0) }) else { continue }

            // A second candidate is only worth paying for when the screen actually
            // has more than one non-sidebar column, and the check is capped because
            // both `isSidebar` and `.frame` are IPC round trips per element. Filtering
            // and sorting *every* collection view on the screen is what the warning
            // above is about: doing it turned a 55-second test failure into a
            // 43-minute one, because this runs on almost every assertion in the
            // target.
            let inspected = all.prefix(Self.maxInspectedScrollers)
            let candidates = inspected.filter { !isSidebar($0) }
            guard candidates.count > 1 else { return [leading] }

            // Right-most first: the detail pane is where a selected screen's own
            // content lives, so it is the likelier home of the element under test.
            // Sorted by frame rather than by query order, which is not screen order.
            return candidates.sorted { $0.frame.minX > $1.frame.minX }
        }
        return [app]
    }

    /// How many scrollable views are worth inspecting to find a second column.
    /// A split view has one sidebar plus at most two scrollable columns, so anything
    /// past the first few is a nested list rather than a column, and paying an IPC
    /// round trip each to rule them out costs more than the second candidate is worth.
    private static let maxInspectedScrollers = 4

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

extension XCUIApplication {
    /// A screen's name belongs to its native navigation bar on both chromes.
    func showsScreen(named name: String, timeout: TimeInterval = 10) -> Bool {
        navigationBars[name].waitForExistence(timeout: timeout)
    }
}

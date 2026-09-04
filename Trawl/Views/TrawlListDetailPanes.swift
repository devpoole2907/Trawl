//
//  TrawlListDetailPanes.swift
//  Trawl
//
//  A list beside its detail, for a screen that is already inside a navigation column.
//

import SwiftUI

/// Two panes side by side at regular width, and just the list at compact width.
///
/// Deliberately a *layout* rather than a `NavigationSplitView`. These screens are
/// pushed inside the iPad chrome's own split view, and nesting one split view in
/// another was tried and abandoned - every level brought its own navigation bar and
/// safe area, which showed as a band of empty space above the inner column. An
/// `HStack` of two panes has none of that: the column's bar stays the only bar, and
/// the pane on the right is content rather than a destination.
///
/// The screen's title belongs to *this* view, not to either pane, which is why it is
/// a parameter rather than something a caller attaches to its list.
///
/// Both panes sit inside one navigation column and there is only ever one bar. A
/// `navigationTitle` written by either pane propagates up to that bar, and the detail
/// is the later sibling, so it wins: selecting a row blanked the screen's name and
/// replaced it with the selection's, dragging the selection's subtitle and buttons
/// along with it.
///
/// Two fixes were tried and neither worked. Giving the detail pane a `NavigationStack`
/// of its own looks like it should contain the pane's title, and does not - the pane's
/// title and subtitle still reached the column's bar, and a dump of the accessibility
/// tree showed no second bar had been created at all. Worse, it made the obvious
/// remedy fail too: with a navigation container somewhere inside, a `navigationTitle`
/// applied *around* both panes attaches to that inner container rather than to the
/// column, so the bar went empty instead of merely wrong.
///
/// So there is no inner stack, and the title is applied here, above both panes. A
/// parent's `navigationTitle` replaces whatever its children wrote, which is exactly
/// the "the screen names itself, its panes do not" rule this needs. The detail's
/// *toolbar* still reaches the column's bar, which is wanted: a pane's actions belong
/// to the screen showing it.
///
/// Panes that push still work - the column's own stack receives the push, as before,
/// and no pane uses a value-based `NavigationLink` that would need a
/// `navigationDestination` of its own.
///
/// Rows still push rather than select at compact width, where the list *is* the whole
/// window.
struct TrawlListDetailPanes<ListContent: View, DetailContent: View>: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// How wide the list pane is allowed to be. The default matches the chrome's own
    /// content column, so a screen with two panes reads as part of the same app
    /// rather than as its own arrangement.
    var listWidth: ClosedRange<CGFloat> = 320...420

    /// The screen's own name, shown in the column's bar whichever pane is active.
    var title: String
    /// The server or scope the screen is showing, where it has one.
    var subtitle: String?

    @ViewBuilder var list: ListContent
    @ViewBuilder var detail: DetailContent

    private var showsBothPanes: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }

    var body: some View {
        Group {
            if showsBothPanes {
                HStack(spacing: 0) {
                    list
                        .frame(minWidth: listWidth.lowerBound, idealWidth: listWidth.lowerBound, maxWidth: listWidth.upperBound)
                    Divider()
                    detail
                        .environment(\.isDetailPane, true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Artwork backgrounds may scale and blur beyond their layout
                        // bounds. Keep that rendering inside the detail column, away
                        // from the list.
                        .clipped()
                }
            } else {
                list
            }
        }
        // Above both panes, so it replaces anything either of them writes.
        .navigationTitle(title)
        .navigationSubtitle(subtitle ?? "")
    }
}

extension View {
    /// The right-hand pane's placeholder, in the one shape every screen uses.
    func listDetailPlaceholder(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IsDetailPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the view is being shown as `TrawlListDetailPanes`' right-hand pane
    /// rather than as a screen of its own.
    var isDetailPane: Bool {
        get { self[IsDetailPaneKey.self] }
        set { self[IsDetailPaneKey.self] = newValue }
    }
}

extension View {
    /// Names the screen - unless this view is currently somebody's detail pane, in
    /// which case it names nothing and lets the screen around it do the naming.
    ///
    /// Views like the Prowlarr indexer detail and the Arr download-client list are
    /// both destinations in their own right *and* panes inside a bigger screen. As
    /// destinations they must title themselves; as panes they must not, because both
    /// panes share the column's one navigation bar and whatever the detail writes
    /// there displaces the screen's own name.
    ///
    /// Suppressing it at the source rather than trying to out-rank it from the
    /// parent, because the parent does not reliably win: applying the screen's title
    /// above both panes fixed the download-client screen and left the indexer screen
    /// still showing the selected indexer's name, so "the outer `navigationTitle`
    /// wins" is not a rule that can be leaned on here.
    func paneAwareNavigationTitle(_ title: String, subtitle: String? = nil) -> some View {
        modifier(PaneAwareNavigationTitle(title: title, subtitle: subtitle))
    }
}

private struct PaneAwareNavigationTitle: ViewModifier {
    @Environment(\.isDetailPane) private var isDetailPane
    let title: String
    let subtitle: String?

    func body(content: Content) -> some View {
        if isDetailPane {
            content
        } else {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle ?? "")
        }
    }
}

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
/// The detail pane *does* get a `NavigationStack`, and it has to. Without one, the
/// pane's own `navigationTitle`, `navigationSubtitle` and `toolbar` are written into
/// the column's bar - the same bar the screen titles - and being the later sibling
/// they win. Selecting a row therefore blanked the screen's title and replaced it
/// with the selection's, so the list sat under a bar naming the thing beside it and
/// carrying its buttons. Setting the title on the panes' parent does not help: this
/// is not a parent-versus-child contest, it is two siblings writing one preference.
///
/// A stack of its own gives the pane somewhere to put all three, and gives a push
/// from inside the pane somewhere to land - which is what a detail that drills down
/// wants anyway. It is safe here because no pane's content uses a value-based
/// `NavigationLink`; every one of them either pushes a view directly or acts through
/// an environment action, and neither needs a `navigationDestination` from an outer
/// stack.
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
        if showsBothPanes {
            HStack(spacing: 0) {
                list
                    .frame(minWidth: listWidth.lowerBound, idealWidth: listWidth.lowerBound, maxWidth: listWidth.upperBound)
                Divider()
                NavigationStack {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            list
        }
    }
}

extension View {
    /// The right-hand pane's placeholder, in the one shape every screen uses.
    func listDetailPlaceholder(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

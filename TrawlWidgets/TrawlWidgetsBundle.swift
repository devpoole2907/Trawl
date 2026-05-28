import WidgetKit
import SwiftUI

@main
struct TrawlWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SpeedWidget()
        ActiveTorrentsWidget()
        CalendarWidget()
        LibraryHealthWidget()
        SeerrPendingRequestsWidget()
        SeerrOpenIssuesWidget()
    }
}

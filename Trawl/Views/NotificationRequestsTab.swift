import SwiftUI

/// The notification sheet's Requests tab: the request *queue*, not the archive.
///
/// It holds what is in flight between "someone asked" and "it's in the library" -
/// decisions waiting on the user, approved requests on their way, and titles that
/// arrived in the last day. Everything else about requests (history, every user,
/// filters) is a place, and stays under More; the footer links there.
struct NotificationRequestsTab: View {
    @Environment(SeerrServiceManager.self) private var seerrServiceManager

    @State private var detailRoute: RequestRoute?

    private var pending: [SeerrMediaRequest] { seerrServiceManager.pendingRequests }
    private var inFlight: [SeerrMediaRequest] { seerrServiceManager.inFlightRequests }
    private var recentlyAvailable: [SeerrMediaRequest] { seerrServiceManager.recentlyAvailableRequests }

    private var isEmpty: Bool { pending.isEmpty && inFlight.isEmpty && recentlyAvailable.isEmpty }

    /// Which request sits in which section. Animating on this, rather than wrapping
    /// each mutation in `withAnimation`, also covers changes that arrive from Seerr:
    /// an approval sliding from Waiting on You to On the Way, a decline leaving, or a
    /// refresh landing. Titles and progress are left out so they don't re-animate rows.
    private var queueLayout: [[Int]] { [pending.map(\.id), inFlight.map(\.id), recentlyAvailable.map(\.id)] }

    var body: some View {
        Group {
            if isEmpty {
                ContentUnavailableView {
                    Label("No Open Requests", systemImage: "film.stack")
                } description: {
                    Text("New requests to approve, and approved ones on their way, will show up here.")
                } actions: {
                    NavigationLink("Browse All Requests") {
                        SeerrDashboardView()
                    }
                }
                .scrollableUnavailableState()
            } else {
                List {
                    if !pending.isEmpty {
                        Section("Waiting on You") {
                            ForEach(pending) { request in
                                SeerrPendingRequestRow(request: request) {
                                    detailRoute = RequestRoute(id: request.id)
                                }
                            }
                        }
                    }
                    if !inFlight.isEmpty {
                        Section("On the Way") {
                            ForEach(inFlight) { request in
                                inFlightRow(request)
                            }
                        }
                    }
                    if !recentlyAvailable.isEmpty {
                        Section("Recently Available") {
                            ForEach(recentlyAvailable) { request in
                                availableRow(request)
                            }
                        }
                    }
                    Section {
                        NavigationLink {
                            SeerrDashboardView()
                        } label: {
                            Label("All Requests", systemImage: "list.bullet")
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
            }
        }
        .animation(.snappy, value: queueLayout)
        .navigationDestination(item: $detailRoute) { route in
            if let request = (pending + inFlight + recentlyAvailable).first(where: { $0.id == route.id }) {
                SeerrRequestDetailView(
                    request: request,
                    // Deciding on the detail screen is already deliberate, and it shows
                    // its own error in place, so it sends straight away.
                    onApprove: request.requestStatus == .pending ? { await seerrServiceManager.sendDecision(for: request.id, approve: true) } : nil,
                    onDecline: request.requestStatus == .pending ? { await seerrServiceManager.sendDecision(for: request.id, approve: false) } : nil
                )
            }
        }
        .task {
            await seerrServiceManager.refreshRequestQueue()
        }
        .refreshable {
            await seerrServiceManager.refreshRequestQueue()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func inFlightRow(_ request: SeerrMediaRequest) -> some View {
        let is4k = request.is4k == true
        let progress = request.media?.downloadProgress(is4k: is4k)

        Button {
            detailRoute = RequestRoute(id: request.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RequestRowHeader(request: request, detail: inFlightDetail(request), tint: .teal, showsChevron: true)
                if let progress {
                    ProgressView(value: progress)
                        .tint(.teal)
                        .padding(.leading, 50)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func availableRow(_ request: SeerrMediaRequest) -> some View {
        Button {
            detailRoute = RequestRoute(id: request.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(seerrServiceManager.displayTitle(for: request))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(requesterLine(request, prefix: "Available"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let date = SeerrServiceManager.availableDate(of: request) {
                    Text(NotificationTimeline.timeText(for: date, now: .now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func inFlightDetail(_ request: SeerrMediaRequest) -> String {
        let is4k = request.is4k == true
        if let progress = request.media?.downloadProgress(is4k: is4k) {
            let count = request.media?.downloadingCount(is4k: is4k) ?? 0
            let percent = Int((progress * 100).rounded())
            return count > 1 ? "Downloading \(count) items · \(percent)%" : "Downloading · \(percent)%"
        }
        if request.badgeStatus == .partiallyAvailable {
            return requesterLine(request, prefix: "Partly available")
        }
        return requesterLine(request, prefix: "Approved · waiting for a release")
    }

    private func requesterLine(_ request: SeerrMediaRequest, prefix: String) -> String {
        guard let requester = request.requestedBy?.displayName, !requester.isEmpty else { return prefix }
        return "\(prefix) · \(requester)"
    }
}

private struct RequestRoute: Hashable, Identifiable {
    let id: Int
}

/// A pending request with its two answers on the row.
///
/// Approve and Decline sit on the row: a pending request has exactly two answers,
/// and leaving the list to give one defeats the point of surfacing it. They are two
/// small round buttons at the trailing edge, in line with the title. A tap waits out
/// `SeerrServiceManager.decisionUndoWindow` before anything is sent; the decision
/// lives in the manager, so its Undo shows wherever this request does.
struct SeerrPendingRequestRow: View {
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    let request: SeerrMediaRequest
    let onOpen: () -> Void

    var body: some View {
        let scheduled = seerrServiceManager.scheduledDecisions[request.id]
        let isSending = seerrServiceManager.sendingDecisionIDs.contains(request.id)

        HStack(alignment: .center, spacing: 10) {
            Button(action: onOpen) {
                RequestRowHeader(
                    request: request,
                    detail: scheduled.map { $0 ? "Approving…" : "Declining…" } ?? Self.pendingDetail(request),
                    tint: ServiceIdentity.seerr.brandColor
                )
            }
            .buttonStyle(.plain)

            SeerrRequestDecisionControls(request: request)
        }
        .padding(.vertical, 2)
        // Carries the subtitle's fade to "Approving…" and back.
        .animation(.snappy, value: scheduled)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if scheduled == nil && !isSending {
                Button { schedule(approve: true) } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if scheduled == nil && !isSending {
                Button { schedule(approve: false) } label: {
                    Label("Decline", systemImage: "xmark.circle")
                }
                .tint(.orange)
            }
        }
    }

    private func schedule(approve: Bool) {
        SeerrRequestDecisionControls.schedule(
            request, approve: approve, in: seerrServiceManager, reportingTo: inAppNotificationCenter
        )
    }

    static func pendingDetail(_ request: SeerrMediaRequest) -> String {
        var parts = [request.media?.typeLabel ?? "Media"]
        if request.is4k == true { parts.append("4K") }
        if let requester = request.requestedBy?.displayName, !requester.isEmpty {
            parts.append("requested by \(requester)")
        }
        if let date = SeerrDateFormatter.date(from: request.createdAt) {
            parts.append(NotificationTimeline.timeText(for: date, now: .now))
        }
        return parts.joined(separator: " · ")
    }
}

/// A request's icon, title and one line of detail.
struct RequestRowHeader: View {
    @Environment(SeerrServiceManager.self) private var seerrServiceManager

    let request: SeerrMediaRequest
    let detail: String
    let tint: Color
    var showsChevron = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: request.media?.mediaType == "tv" ? "tv" : "film")
                    .font(.title3)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(seerrServiceManager.displayTitle(for: request))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    // "Approving…" fades in over the request's details instead of snapping.
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A pending request's two answers, or its Undo while a decision waits, or a spinner
/// while it is sent. Everything it shows is read from `SeerrServiceManager`, so the
/// same request answered in one place shows its Undo in every other.
struct SeerrRequestDecisionControls: View {
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    let request: SeerrMediaRequest

    var body: some View {
        let scheduled = seerrServiceManager.scheduledDecisions[request.id]
        let isSending = seerrServiceManager.sendingDecisionIDs.contains(request.id)
        let title = seerrServiceManager.displayTitle(for: request)

        Group {
            if scheduled != nil {
                Button("Undo") { seerrServiceManager.undoDecision(for: request.id) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel(scheduled == true ? "Undo approving \(title)" : "Undo declining \(title)")
                    .accessibilityIdentifier("request-undo-\(request.id)")
            } else if isSending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else {
                HStack(spacing: 8) {
                    decisionButton(
                        "Decline \(title)",
                        systemImage: "xmark",
                        tint: nil,
                        identifier: "request-decline-\(request.id)"
                    ) { schedule(approve: false) }
                    decisionButton(
                        "Approve \(title)",
                        systemImage: "checkmark",
                        tint: .green,
                        identifier: "request-approve-\(request.id)"
                    ) { schedule(approve: true) }
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .animation(.snappy, value: scheduled)
        .animation(.snappy, value: isSending)
    }

    private func schedule(approve: Bool) {
        Self.schedule(request, approve: approve, in: seerrServiceManager, reportingTo: inAppNotificationCenter)
    }

    /// Schedules a decision and says so if Seerr refuses it. Shared with swipe actions.
    static func schedule(
        _ request: SeerrMediaRequest,
        approve: Bool,
        in manager: SeerrServiceManager,
        reportingTo center: InAppNotificationCenter
    ) {
        manager.scheduleDecision(for: request.id, approve: approve) { message in
            center.showError(title: approve ? "Approve Failed" : "Decline Failed", message: message)
        }
    }

    private func decisionButton(
        _ title: String,
        systemImage: String,
        tint: Color?,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        // Decline is neutral, Approve is green: one answer is the expected one.
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .background(
                    tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.quaternary),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        // Plain, not borderless: borderless tints its label with the accent colour,
        // which turned Decline's grey blue.
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

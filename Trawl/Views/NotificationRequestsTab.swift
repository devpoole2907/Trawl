import SwiftUI

/// The notification sheet's Requests tab: the request *queue*, not the archive.
///
/// It holds what is in flight between "someone asked" and "it's in the library" -
/// decisions waiting on the user, approved requests on their way, and titles that
/// arrived in the last day. Everything else about requests (history, every user,
/// filters) is a place, and stays under More; the footer links there.
struct NotificationRequestsTab: View {
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    /// A decision the user made that has not been sent yet. It waits
    /// `RequestDecision.undoWindow` so a mis-tap can be taken back; the row shows
    /// what will happen and an Undo until then.
    @State private var scheduledDecisions: [Int: RequestDecision] = [:]
    /// Decisions on their way to Seerr, so the row can't be acted on twice.
    @State private var sendingIDs: Set<Int> = []
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
                                pendingRow(request)
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
                    onApprove: request.requestStatus == .pending ? { await decideNow(request, approve: true) } : nil,
                    onDecline: request.requestStatus == .pending ? { await decideNow(request, approve: false) } : nil
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

    /// Approve and Decline sit on the row: a pending request has exactly two answers,
    /// and leaving the sheet to give one defeats the point of surfacing it here. They
    /// are two small round buttons at the row's trailing edge, in line with the title,
    /// rather than a second row of pills under it.
    @ViewBuilder
    private func pendingRow(_ request: SeerrMediaRequest) -> some View {
        let scheduled = scheduledDecisions[request.id]
        let isSending = sendingIDs.contains(request.id)

        HStack(alignment: .center, spacing: 10) {
            Button {
                detailRoute = RequestRoute(id: request.id)
            } label: {
                rowHeader(
                    request,
                    detail: scheduled.map { $0.approve ? "Approving…" : "Declining…" } ?? pendingDetail(request),
                    tint: ServiceIdentity.seerr.brandColor
                )
            }
            .buttonStyle(.plain)

            Group {
                if scheduled != nil {
                    Button("Undo") { undo(request) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityIdentifier("request-undo-\(request.id)")
                } else if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                } else {
                    HStack(spacing: 8) {
                        decisionButton(
                            "Decline",
                            systemImage: "xmark",
                            tint: nil,
                            identifier: "request-decline-\(request.id)"
                        ) { schedule(request, approve: false) }
                        decisionButton(
                            "Approve",
                            systemImage: "checkmark",
                            tint: .green,
                            identifier: "request-approve-\(request.id)"
                        ) { schedule(request, approve: true) }
                    }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .padding(.vertical, 2)
        .animation(.snappy, value: scheduled?.approve)
        .animation(.snappy, value: isSending)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if scheduled == nil && !isSending {
                Button { schedule(request, approve: true) } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if scheduled == nil && !isSending {
                Button { schedule(request, approve: false) } label: {
                    Label("Decline", systemImage: "xmark.circle")
                }
                .tint(.orange)
            }
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

    @ViewBuilder
    private func inFlightRow(_ request: SeerrMediaRequest) -> some View {
        let is4k = request.is4k == true
        let progress = request.media?.downloadProgress(is4k: is4k)

        Button {
            detailRoute = RequestRoute(id: request.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                rowHeader(request, detail: inFlightDetail(request), tint: .teal, showsChevron: true)
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

    private func rowHeader(
        _ request: SeerrMediaRequest,
        detail: String,
        tint: Color,
        showsChevron: Bool = false
    ) -> some View {
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

    private func pendingDetail(_ request: SeerrMediaRequest) -> String {
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

    // MARK: - Decisions

    private func schedule(_ request: SeerrMediaRequest, approve: Bool) {
        guard scheduledDecisions[request.id] == nil, !sendingIDs.contains(request.id) else { return }
        let task = Task { @MainActor in
            try? await Task.sleep(for: RequestDecision.undoWindow)
            guard !Task.isCancelled, scheduledDecisions[request.id] != nil else { return }
            scheduledDecisions[request.id] = nil
            await send(request, approve: approve)
        }
        scheduledDecisions[request.id] = RequestDecision(approve: approve, task: task)
    }

    private func undo(_ request: SeerrMediaRequest) {
        scheduledDecisions[request.id]?.task.cancel()
        scheduledDecisions[request.id] = nil
    }

    private func send(_ request: SeerrMediaRequest, approve: Bool) async {
        sendingIDs.insert(request.id)
        defer { sendingIDs.remove(request.id) }
        if let message = await decideNow(request, approve: approve) {
            inAppNotificationCenter.showError(title: approve ? "Approve Failed" : "Decline Failed", message: message)
        }
    }

    /// Sends a decision straight away. The detail screen uses this: deciding there is
    /// already a deliberate act, and it shows its own error in place.
    private func decideNow(_ request: SeerrMediaRequest, approve: Bool) async -> String? {
        do {
            if approve {
                try await seerrServiceManager.approveRequest(id: request.id)
            } else {
                try await seerrServiceManager.declineRequest(id: request.id)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct RequestRoute: Hashable, Identifiable {
    let id: Int
}

private struct RequestDecision {
    static let undoWindow: Duration = .seconds(4)

    let approve: Bool
    let task: Task<Void, Never>
}

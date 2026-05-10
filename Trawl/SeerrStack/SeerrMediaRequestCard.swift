import SwiftUI

struct SeerrMediaRequestCard: View {
    enum Media: Sendable {
        case movie(tmdbId: Int, title: String)
        case series(tvdbId: Int, title: String)

        var title: String {
            switch self {
            case .movie(_, let title), .series(_, let title): title
            }
        }

        var mediaType: String {
            switch self {
            case .movie: "movie"
            case .series: "tv"
            }
        }

        func matches(_ request: SeerrMediaRequest) -> Bool {
            switch self {
            case .movie(let tmdbId, _):
                request.media?.mediaType == "movie" && request.media?.tmdbId == tmdbId
            case .series(let tvdbId, _):
                request.media?.mediaType == "tv" && request.media?.tvdbId == tvdbId
            }
        }
    }

    let media: Media
    @Environment(SeerrServiceManager.self) private var serviceManager
    @State private var requests: [SeerrMediaRequest] = []
    @State private var isLoading = false
    @State private var actionInFlightIDs: Set<Int> = []
    @State private var errorMessage: String?
    @State private var isExpanded = false
    @State private var didApplyInitialExpansion = false

    var body: some View {
        if serviceManager.isConnected || serviceManager.connectionError != nil {
            cardContent
                .task(id: taskID) {
                    didApplyInitialExpansion = false
                    isExpanded = false
                    requests = []
                    errorMessage = nil
                    await loadRequests()
                }
        }
    }

    private var taskID: String {
        "\(media.mediaType)-\(media.title)-\(serviceManager.activeProfileID?.uuidString ?? "none")"
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                if serviceManager.isConnecting {
                    loadingRow("Connecting to Seerr...")
                } else if let errorMessage {
                    errorRow(errorMessage)
                } else if isLoading && requests.isEmpty {
                    loadingRow("Loading requests...")
                } else if requests.isEmpty {
                    emptyRow
                } else {
                    requestRows
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(.indigo)
                Text("Requests")
                    .font(.headline)
                Spacer()
                if pendingRequestCount > 0 {
                    Text("\(pendingRequestCount) pending")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if !requests.isEmpty {
                    Text("\(requests.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var pendingRequestCount: Int {
        requests.filter { $0.requestStatus == .pending }.count
    }

    private var requestRows: some View {
        VStack(spacing: 12) {
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(request.requestedBy.map { "Requested by \($0.displayName)" } ?? "Seerr Request")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                if let date = request.createdAtRelativeText {
                                    Text(date)
                                }
                                if request.is4k == true {
                                    Text("4K")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if let status = request.requestStatus {
                            Text(status.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(statusTint(status).opacity(0.16), in: Capsule())
                                .foregroundStyle(statusTint(status))
                        }
                    }

                    actionRow(for: request)
                }
                .padding(12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func actionRow(for request: SeerrMediaRequest) -> some View {
        HStack(spacing: 8) {
            if request.requestStatus == .pending {
                Button("Approve", systemImage: "checkmark.circle.fill") {
                    Task { await approve(request) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Decline", systemImage: "xmark.circle") {
                    Task { await decline(request) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                Task { await delete(request) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .disabled(actionInFlightIDs.contains(request.id))
        .overlay(alignment: .trailing) {
            if actionInFlightIDs.contains(request.id) {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text("No Seerr requests found for \(media.title).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                Task { await loadRequests(force: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func loadRequests(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || requests.isEmpty else { return }
        guard let client = serviceManager.activeClient else {
            errorMessage = serviceManager.connectionError
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await client.getRequests(
                take: 100,
                skip: 0,
                filter: "all",
                sort: "added",
                sortDirection: "desc",
                mediaType: media.mediaType
            )
            requests = response.results.filter(media.matches)
            if !didApplyInitialExpansion {
                isExpanded = pendingRequestCount > 0
                didApplyInitialExpansion = true
            }
        } catch {
            errorMessage = error.localizedDescription
            if !didApplyInitialExpansion {
                didApplyInitialExpansion = true
            }
        }
    }

    private func approve(_ request: SeerrMediaRequest) async {
        await performAction(for: request) { client in
            let updated = try await client.approveRequest(id: request.id)
            replace(updated)
            InAppNotificationCenter.shared.showSuccess(
                title: "Request Approved",
                message: "\(media.title) was approved.",
                source: .inApp
            )
        }
    }

    private func decline(_ request: SeerrMediaRequest) async {
        await performAction(for: request) { client in
            let updated = try await client.declineRequest(id: request.id)
            replace(updated)
            InAppNotificationCenter.shared.showSuccess(
                title: "Request Declined",
                message: "\(media.title) was declined.",
                source: .inApp
            )
        }
    }

    private func delete(_ request: SeerrMediaRequest) async {
        await performAction(for: request) { client in
            try await client.deleteRequest(id: request.id)
            requests.removeAll { $0.id == request.id }
            InAppNotificationCenter.shared.showSuccess(
                title: "Request Deleted",
                message: "The Seerr request was removed.",
                source: .inApp
            )
        }
    }

    private func performAction(
        for request: SeerrMediaRequest,
        action: (SeerrAPIClient) async throws -> Void
    ) async {
        guard let client = serviceManager.activeClient else { return }
        actionInFlightIDs.insert(request.id)
        defer { actionInFlightIDs.remove(request.id) }

        do {
            try await action(client)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            InAppNotificationCenter.shared.showError(
                title: "Request Action Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }

    private func replace(_ request: SeerrMediaRequest) {
        guard media.matches(request) else {
            requests.removeAll { $0.id == request.id }
            return
        }
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
        } else {
            requests.insert(request, at: 0)
        }
    }

    private func statusTint(_ status: SeerrRequestStatus) -> Color {
        switch status {
        case .pending: .orange
        case .approved: .green
        case .declined: .red
        case .processing: .blue
        case .available: .teal
        case .failed: .red
        case .completed: .purple
        }
    }
}

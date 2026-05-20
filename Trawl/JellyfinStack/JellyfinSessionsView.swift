import SwiftUI

// MARK: - View

struct JellyfinSessionsView: View {
    let apiClient: JellyfinAPIClient

    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var viewModel: JellyfinSessionsViewModel?
    @State private var messageSession: JellyfinSession?
    @State private var playbackStopSession: JellyfinSession?

    var body: some View {
        Group {
            if let viewModel {
                sessionsContent(viewModel)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Sessions")
        .navigationSubtitle("Jellyfin")
        .task {
            let vm = JellyfinSessionsViewModel(apiClient: apiClient)
            viewModel = vm
            await vm.startPolling()
        }
        .onDisappear {
            viewModel?.stopPolling()
        }
        .sheet(item: $messageSession) { session in
            JellyfinSendMessageSheet(
                sessionId: session.id,
                sessionName: session.userName ?? session.deviceName ?? "Session",
                apiClient: apiClient
            )
        }
    }

    @ViewBuilder
    private func sessionsContent(_ viewModel: JellyfinSessionsViewModel) -> some View {
        List {
            if let error = viewModel.errorMessage, viewModel.sessions.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isLoading && viewModel.sessions.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if viewModel.sessions.isEmpty {
                ContentUnavailableView(
                    "No Active Sessions",
                    systemImage: "play.slash",
                    description: Text("No playback sessions are currently active on Jellyfin.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.sessions) { session in
                        sessionRow(session)
                            .contextMenu {
                                if session.supportsRemoteControl == true && session.nowPlayingItem != nil {
                                    Button(role: .destructive) {
                                        playbackStopSession = session
                                    } label: {
                                        Label("Stop Playback", systemImage: "stop.fill")
                                    }
                                }

                                Button {
                                    messageSession = session
                                } label: {
                                    Label("Send Message", systemImage: "message.fill")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if session.supportsRemoteControl == true && session.nowPlayingItem != nil {
                                    Button(role: .destructive) {
                                        playbackStopSession = session
                                    } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                }

                                Button {
                                    messageSession = session
                                } label: {
                                    Label("Message", systemImage: "message.fill")
                                }
                                .tint(ServiceIdentity.jellyfin.brandColor)
                            }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .refreshable {
            await viewModel.refresh()
        }
        .alert("Stop Playback?", isPresented: stopPlaybackAlertPresented) {
            Button("Cancel", role: .cancel) {
                playbackStopSession = nil
            }
            Button("Stop", role: .destructive) {
                if let session = playbackStopSession {
                    Task { await viewModel.stopPlayback(sessionId: session.id) }
                }
                playbackStopSession = nil
            }
        } message: {
            if let session = playbackStopSession {
                Text("This stops playback for \(session.userName ?? session.deviceName ?? "this session").")
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: JellyfinSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: session.isActive ? "play.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(session.isActive ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.userName ?? session.deviceName ?? "Unknown")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let client = session.client, !client.isEmpty {
                            Text(client)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let device = session.deviceName, !device.isEmpty, device != session.userName {
                            Text("· \(device)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 8)

                if let lastActivity = session.lastActivityDate {
                    Text(relativeDate(from: lastActivity))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let item = session.nowPlayingItem {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: mediaIcon(for: item.mediaType))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "Unknown")
                                .font(.subheadline)
                                .lineLimit(1)

                            if let detail = item.episodeDetail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if let seriesName = item.seriesName {
                                Text(seriesName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if !item.formattedDuration.isEmpty {
                            Text(item.formattedDuration)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if session.progressFraction > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.quaternary)
                                    .frame(height: 4)

                                Capsule()
                                    .fill(.green)
                                    .frame(width: geometry.size.width * session.progressFraction, height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.vertical, 4)
    }

    private func mediaIcon(for type: String) -> String {
        switch type.lowercased() {
        case "movie": "film"
        case "episode": "tv"
        case "audio": "music.note"
        case "book": "book"
        case "game": "gamecontroller"
        default: "play.rectangle"
        }
    }

    private func relativeDate(from raw: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = isoFormatter.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private var stopPlaybackAlertPresented: Binding<Bool> {
        Binding(
            get: { playbackStopSession != nil },
            set: { if !$0 { playbackStopSession = nil } }
        )
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class JellyfinSessionsViewModel {
    private(set) var sessions: [JellyfinSession] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let apiClient: JellyfinAPIClient
    private var pollingTask: Task<Void, Never>?

    init(apiClient: JellyfinAPIClient) {
        self.apiClient = apiClient
    }

    func startPolling() async {
        await loadSessions()
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await loadSessions(showLoading: false)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() async {
        await loadSessions(showLoading: false)
    }

    private func loadSessions(showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        errorMessage = nil

        do {
            sessions = try await apiClient.getSessions()
        } catch {
            errorMessage = error.localizedDescription
        }

        if showLoading { isLoading = false }
    }

    func stopPlayback(sessionId: String) async {
        do {
            try await apiClient.stopPlayback(sessionId: sessionId)
            await loadSessions(showLoading: false)
        } catch {
            InAppNotificationCenter.shared.showError(title: "Couldn't Stop Playback", message: error.localizedDescription)
        }
    }
}

// MARK: - Send Message Sheet

private struct JellyfinSendMessageSheet: View {
    let sessionId: String
    let sessionName: String
    let apiClient: JellyfinAPIClient

    @Environment(\.dismiss) private var dismiss
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var header = ""
    @State private var messageText = ""
    @State private var isSending = false

    var body: some View {
        AppSheetShell(
            title: "Send Message",
            confirmTitle: "Send",
            isConfirmDisabled: messageText.isEmpty,
            isConfirmLoading: isSending,
            onConfirm: { Task { await send() } },
            detents: [.medium]
        ) {
            Form {
                Section {
                    TextField("Header", text: $header)
                    TextField("Message", text: $messageText, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Send message to \(sessionName)")
                }
            }
            .presentationDragIndicator(.visible)
        }
    }

    private func send() async {
        isSending = true
        do {
            try await apiClient.sendMessage(
                sessionId: sessionId,
                header: header.isEmpty ? "Trawl" : header,
                text: messageText
            )
            inAppNotificationCenter.showSuccess(
                title: "Message Sent",
                message: "Message delivered to \(sessionName).",
                source: .inApp
            )
            dismiss()
        } catch {
            inAppNotificationCenter.showError(
                title: "Message Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
        isSending = false
    }
}

import SwiftUI

// MARK: - View

struct JellyfinSessionsView: View {
    let apiClient: JellyfinAPIClient

    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(JellyfinSessionBrowserState.self) private var sharedBrowser: JellyfinSessionBrowserState?
    @State private var localBrowser = JellyfinSessionBrowserState()
    private var browser: JellyfinSessionBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }
    private var showsDetailPane: Bool { sidebarColumn != nil }

    @State private var messageSession: JellyfinSession?
    @State private var playbackStopSession: JellyfinSession?
    #if DEBUG
    private var isPreview = false
    #endif

    init(apiClient: JellyfinAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        TrawlListDetailPanes(title: "Sessions", subtitle: "Jellyfin") {
            sessionsList
        } detail: {
            selectedSessionDetail
        }
        .task {
            #if DEBUG
            if isPreview { return }
            #endif
            guard sidebarColumn != .detail else { return }
            await browser.startPolling(apiClient: apiClient)
        }
        .onDisappear {
            guard sidebarColumn != .detail else { return }
            browser.stopPolling()
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
    private var selectedSessionDetail: some View {
        if let id = browser.selectedSessionID,
           let session = currentSession(for: id) {
            JellyfinSessionDetailView(
                session: session,
                apiClient: apiClient
            )
            .id(session.id)
        } else {
            listDetailPlaceholder("Select a Session", systemImage: "play.rectangle.on.rectangle")
        }
    }

    @ViewBuilder
    private var sessionsList: some View {
        @Bindable var browser = self.browser
        List(selection: $browser.selectedSessionID) {
            if let error = browser.errorMessage {
                ServiceErrorView(
                    title: "Sessions Unavailable",
                    message: error,
                    identity: .jellyfin,
                    hasContent: !browser.sessions.isEmpty,
                    onRetry: { await browser.refresh(apiClient: apiClient) }
                )
            }

            if browser.isLoading && browser.sessions.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if browser.sessions.isEmpty {
                if browser.errorMessage == nil {
                    ContentUnavailableView(
                        "No Active Sessions",
                        systemImage: "play.slash",
                        description: Text("No playback sessions are currently active on Jellyfin.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(browser.sessions) { session in
                        sessionLink(session)
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
            await browser.refresh(apiClient: apiClient)
        }
        .alert("Stop Playback?", isPresented: stopPlaybackAlertPresented) {
            Button("Cancel", role: .cancel) {
                playbackStopSession = nil
            }
            Button("Stop", role: .destructive) {
                if let session = playbackStopSession {
                    Task { await browser.stopPlayback(sessionId: session.id, apiClient: apiClient) }
                }
                playbackStopSession = nil
            }
        } message: {
            if let session = playbackStopSession {
                Text("This stops playback for \(session.userName ?? session.deviceName ?? "this session").")
            }
        }
        .onChange(of: browser.sessions.map(\.id)) { _, ids in
            if let id = browser.selectedSessionID, !ids.contains(id) {
                browser.selectedSessionID = nil
            }
        }
    }

    @ViewBuilder
    private func sessionLink(_ session: JellyfinSession) -> some View {
        if showsDetailPane {
            sessionRow(session)
                .tag(session.id)
        } else {
            NavigationLink {
                JellyfinSessionDetailView(
                    session: currentSession(for: session.id) ?? session,
                    apiClient: apiClient
                )
            } label: {
                sessionRow(session)
            }
        }
    }

    private func currentSession(for id: String) -> JellyfinSession? {
        browser.sessions.first(where: { $0.id == id })
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
        .macListRowStableHeight()
    }

    private var stopPlaybackAlertPresented: Binding<Bool> {
        Binding(
            get: { playbackStopSession != nil },
            set: { if !$0 { playbackStopSession = nil } }
        )
    }
}

// MARK: - Detail View

struct JellyfinSessionDetailView: View {
    let session: JellyfinSession
    let apiClient: JellyfinAPIClient

    @Environment(\.isDetailPane) private var isDetailPane
    @Environment(JellyfinSessionBrowserState.self) private var sharedBrowser: JellyfinSessionBrowserState?
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    @State private var showingStopAlert = false
    @State private var showingMessageSheet = false

    private var headerSubtitle: String? {
        var parts: [String] = []
        if let client = session.client, !client.isEmpty { parts.append(client) }
        if let device = session.deviceName, !device.isEmpty, device != session.userName { parts.append(device) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        if let playState = session.playState {
            if playState.isPaused == true {
                badges.append(ArrDetailBadge(icon: "pause.fill", label: "Paused", color: .orange))
            } else if session.isActive {
                badges.append(ArrDetailBadge(icon: "play.fill", label: "Playing", color: .green))
            } else {
                badges.append(ArrDetailBadge(icon: "moon.fill", label: "Idle", color: .secondary))
            }
        } else if session.isActive {
            badges.append(ArrDetailBadge(icon: "play.fill", label: "Playing", color: .green))
        } else {
            badges.append(ArrDetailBadge(icon: "moon.fill", label: "Idle", color: .secondary))
        }

        if let transcode = session.transcodingInfo {
            if transcode.isDirectPlay {
                badges.append(ArrDetailBadge(icon: "bolt.fill", label: "Direct Play", color: .green))
            } else {
                badges.append(ArrDetailBadge(icon: "arrow.triangle.2.circlepath", label: "Transcode", color: .orange))
            }
        } else if let method = session.playState?.playMethod {
            if method == "DirectPlay" {
                badges.append(ArrDetailBadge(icon: "bolt.fill", label: "Direct Play", color: .green))
            } else if method == "DirectStream" {
                badges.append(ArrDetailBadge(icon: "arrow.right.circle", label: "Direct Stream", color: .blue))
            } else if method == "Transcode" {
                badges.append(ArrDetailBadge(icon: "arrow.triangle.2.circlepath", label: "Transcode", color: .orange))
            }
        }

        if let client = session.client, !client.isEmpty {
            badges.append(ArrDetailBadge(icon: "display", label: client, color: .secondary))
        }

        return badges
    }

    var body: some View {
        Form {
            Section {
                TrawlEntityHeader(
                    title: session.userName ?? session.deviceName ?? "Session",
                    subtitle: headerSubtitle,
                    systemImage: session.isActive ? "play.circle.fill" : "person.crop.circle",
                    tint: ServiceIdentity.jellyfin.brandColor,
                    shape: .circle,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            if let item = session.nowPlayingItem {
                nowPlayingSection(item)
            }

            streamDiagnosticsSection

            clientDetailsSection

            remoteControlsSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .paneAwareNavigationTitle(
            session.userName ?? session.deviceName ?? "Session",
            subtitle: "Jellyfin Session",
            whenPane: session.userName ?? session.deviceName ?? "Session"
        )
        .alert("Stop Playback?", isPresented: $showingStopAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Stop", role: .destructive) {
                Task { await stopPlayback() }
            }
        } message: {
            Text("This stops playback for \(session.userName ?? session.deviceName ?? "this session").")
        }
        .sheet(isPresented: $showingMessageSheet) {
            JellyfinSendMessageSheet(
                sessionId: session.id,
                sessionName: session.userName ?? session.deviceName ?? "Session",
                apiClient: apiClient
            )
        }
    }

    @ViewBuilder
    private func nowPlayingSection(_ item: JellyfinNowPlayingItem) -> some View {
        Section("Now Playing") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: mediaIcon(for: item.mediaType))
                        .font(.title2)
                        .foregroundStyle(ServiceIdentity.jellyfin.brandColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Unknown Title")
                            .font(.headline)

                        if let detail = item.episodeDetail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if let seriesName = item.seriesName {
                            Text(seriesName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(.top, 2)
                }

                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.quaternary)
                                .frame(height: 6)

                            Capsule()
                                .fill(session.playState?.isPaused == true ? Color.orange : Color.green)
                                .frame(width: max(0, min(geometry.size.width * session.progressFraction, geometry.size.width)), height: 6)
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        Text(session.playState?.formattedPosition ?? "0:00")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        if session.progressFraction > 0 {
                            Text("\(Int(session.progressFraction * 100))%")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(item.formattedDuration.isEmpty ? "—" : item.formattedDuration)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)

            LabeledContent("Media Type", value: item.mediaType.capitalized)

            if let year = item.productionYear {
                LabeledContent("Year", value: "\(year)")
            }

            if let rating = item.officialRating, !rating.isEmpty {
                LabeledContent("Rating", value: rating)
            }

            if let volume = session.playState?.volumeLevel {
                LabeledContent("Volume") {
                    HStack(spacing: 4) {
                        Image(systemName: session.playState?.isMuted == true ? "speaker.slash.fill" : (volume > 50 ? "speaker.wave.3.fill" : "speaker.wave.1.fill"))
                        Text(session.playState?.isMuted == true ? "Muted" : "\(volume)%")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var streamDiagnosticsSection: some View {
        Section("Stream Diagnostics") {
            if let transcode = session.transcodingInfo {
                LabeledContent("Play Method") {
                    HStack(spacing: 6) {
                        Image(systemName: transcode.isDirectPlay ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        Text(transcode.isDirectPlay ? "Direct Play" : "Transcode")
                    }
                    .foregroundStyle(transcode.isDirectPlay ? .green : .orange)
                    .font(.subheadline.weight(.medium))
                }

                if let reasons = transcode.transcodeReasons, !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Transcode Reasons")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(reasons, id: \.self) { reason in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .padding(.top, 2)
                                Text(humanizedReason(reason))
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let videoCodec = transcode.videoCodec {
                    LabeledContent("Video Codec") {
                        HStack(spacing: 4) {
                            Text(videoCodec.uppercased())
                            if transcode.isVideoDirect == true {
                                Text("(Direct)").foregroundStyle(.green)
                            } else {
                                Text("(Transcoded)").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                    }
                }

                if let resolution = transcode.resolution {
                    LabeledContent("Resolution", value: resolution)
                }

                if let fps = transcode.framerate, fps > 0 {
                    LabeledContent("Framerate", value: String(format: "%.1f fps", fps))
                }

                if let audioCodec = transcode.audioCodec {
                    LabeledContent("Audio Codec") {
                        HStack(spacing: 4) {
                            Text(audioCodec.uppercased())
                            if transcode.isAudioDirect == true {
                                Text("(Direct)").foregroundStyle(.green)
                            } else {
                                Text("(Transcoded)").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                    }
                }

                if let channels = transcode.audioChannelsDescription {
                    LabeledContent("Audio Channels", value: channels)
                }

                if let container = transcode.container {
                    LabeledContent("Container", value: container.uppercased())
                }

                if let bitrate = transcode.formattedBitrate {
                    LabeledContent("Bitrate", value: bitrate)
                }
            } else if let method = session.playState?.playMethod {
                LabeledContent("Play Method") {
                    HStack(spacing: 6) {
                        Image(systemName: method == "DirectPlay" ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        Text(method == "DirectPlay" ? "Direct Play" : method)
                    }
                    .foregroundStyle(method == "DirectPlay" ? .green : .blue)
                    .font(.subheadline.weight(.medium))
                }
            } else {
                LabeledContent("Play Method", value: session.isActive ? "Direct Play" : "Idle")
            }
        }
    }

    @ViewBuilder
    private var clientDetailsSection: some View {
        Section("Client & Device") {
            if let user = session.userName {
                LabeledContent("User", value: user)
            }

            if let client = session.client {
                LabeledContent("Client", value: client)
            }

            if let version = session.applicationVersion {
                LabeledContent("Version", value: version)
            }

            if let device = session.deviceName {
                LabeledContent("Device", value: device)
            }

            if let endpoint = session.remoteEndPoint, !endpoint.isEmpty {
                LabeledContent("Remote Address", value: endpoint)
            }

            if let lastActivity = session.lastActivityDate {
                LabeledContent("Last Activity", value: relativeDate(from: lastActivity))
            }

            LabeledContent("Remote Control") {
                Text(session.supportsRemoteControl == true ? "Supported" : "Unsupported")
                    .foregroundStyle(session.supportsRemoteControl == true ? .green : .secondary)
            }
        }
    }

    @ViewBuilder
    private var remoteControlsSection: some View {
        Section("Actions") {
            if session.supportsRemoteControl == true && session.nowPlayingItem != nil {
                Button(role: .destructive) {
                    showingStopAlert = true
                } label: {
                    Label("Stop Playback", systemImage: "stop.fill")
                }
            }

            Button {
                showingMessageSheet = true
            } label: {
                Label("Send Message", systemImage: "message.fill")
            }
        }
    }

    private func stopPlayback() async {
        if let sharedBrowser {
            await sharedBrowser.stopPlayback(sessionId: session.id, apiClient: apiClient)
        } else {
            do {
                try await apiClient.stopPlayback(sessionId: session.id)
            } catch {
                inAppNotificationCenter.showError(
                    title: "Couldn't Stop Playback",
                    message: error.localizedDescription
                )
            }
        }
    }
}

// MARK: - Helpers

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

private func humanizedReason(_ reason: String) -> String {
    switch reason {
    case "ContainerNotSupported": "Container not supported"
    case "VideoCodecNotSupported": "Video codec not supported"
    case "AudioCodecNotSupported": "Audio codec not supported"
    case "SubtitleCodecNotSupported": "Subtitle format not supported"
    case "AudioProfileNotSupported": "Audio profile not supported"
    case "AudioChannelsNotSupported": "Audio channels not supported"
    case "VideoProfileNotSupported": "Video profile not supported"
    case "VideoLevelNotSupported": "Video level not supported"
    case "VideoResolutionNotSupported": "Resolution not supported"
    case "VideoBitrateNotSupported": "Video bitrate exceeds limit"
    case "AudioBitrateNotSupported": "Audio bitrate exceeds limit"
    case "ContainerBitrateExceedsLimit": "Container bitrate exceeds limit"
    case "DirectPlayError": "Direct play error"
    case "SecondaryAudioNotSupported": "Secondary audio not supported"
    default:
        reason.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

// MARK: - ViewModel (Compatibility)

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

#if DEBUG
extension JellyfinSessionsView {
    init(
        apiClient: JellyfinAPIClient = .preview(),
        previewBrowser: JellyfinSessionBrowserState
    ) {
        self.apiClient = apiClient
        self._localBrowser = State(initialValue: previewBrowser)
        self.isPreview = true
    }

    init(
        apiClient: JellyfinAPIClient = .preview(),
        previewViewModel: JellyfinSessionsViewModel
    ) {
        let browser = JellyfinSessionBrowserState()
        browser.sessions = previewViewModel.sessions
        browser.isLoading = previewViewModel.isLoading
        browser.errorMessage = previewViewModel.errorMessage
        self.apiClient = apiClient
        self._localBrowser = State(initialValue: browser)
        self.isPreview = true
    }
}

extension JellyfinSessionsViewModel {
    convenience init(
        previewSessions: [JellyfinSession],
        isLoading: Bool = false,
        errorMessage: String? = nil,
        apiClient: JellyfinAPIClient = .preview()
    ) {
        self.init(apiClient: apiClient)
        self.sessions = previewSessions
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

#Preview("Jellyfin Sessions - Loaded") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinSessionsView(
                previewViewModel: JellyfinSessionsViewModel(previewSessions: JellyfinSession.previewList)
            )
        }
    }
}

#Preview("Jellyfin Session Detail - Direct Play") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinSessionDetailView(
                session: JellyfinSession.previewActive,
                apiClient: .preview()
            )
        }
    }
}

#Preview("Jellyfin Session Detail - Transcoding") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinSessionDetailView(
                session: JellyfinSession.previewTranscoding,
                apiClient: .preview()
            )
        }
    }
}

#Preview("Jellyfin Sessions - Empty") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinSessionsView(
                previewViewModel: JellyfinSessionsViewModel(previewSessions: [])
            )
        }
    }
}

#Preview("Jellyfin Sessions - Loading") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connecting)) {
        NavigationStack {
            JellyfinSessionsView(
                previewViewModel: JellyfinSessionsViewModel(previewSessions: [], isLoading: true)
            )
        }
    }
}

#Preview("Jellyfin Sessions - Error") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.error("Unable to load sessions."))) {
        NavigationStack {
            JellyfinSessionsView(
                previewViewModel: JellyfinSessionsViewModel(
                    previewSessions: [],
                    errorMessage: "Jellyfin refused the session request."
                )
            )
        }
    }
}

#Preview("Jellyfin Send Message") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        JellyfinSendMessageSheet(
            sessionId: JellyfinSession.previewActive.id,
            sessionName: JellyfinSession.previewActive.userName ?? "Preview Session",
            apiClient: .preview()
        )
    }
}
#endif

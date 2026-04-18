import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
import CoreServices
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query private var servers: [ServerProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @State private var showOnboarding = false
    @State private var appServices: AppServices?
    @State private var disconnectedServices = AppServices.disconnected()
    @State private var connectionError: String?
    @State private var isConnecting = false
    @State private var isInWelcomeFlow = true
    @State private var selectedTab: RootTab = .torrents
    @State private var morePath: [MoreDestination] = []
    @State private var magnetDeepLink: MagnetDeepLink?
    @State private var pendingMagnetURL: String?  // holds URL during cold launch before services are ready
    @State private var showArrSetup = false
    @State private var showSSHDisconnectConfirm = false
    @State private var showSSHSessionSheet = false
    @State private var welcomeStep: WelcomeStep = .intro
    @State private var setupTarget: SetupTarget?
    #if os(macOS)
    @AppStorage("hasPromptedForMagnetHandler") private var hasPromptedForMagnetHandler = false
    @State private var showMagnetHandlerPrompt = false
    #endif

    @Environment(SSHSessionStore.self) private var sshSessionStore

    var body: some View {
        Group {
            if shouldShowWelcomeScreen {
                welcomeScreen
            } else {
                tabContent
            }
        }
        .overlay(alignment: .top) {
            if let banner = inAppNotificationCenter.currentBanner {
                InAppNotificationBanner(item: banner) {
                    inAppNotificationCenter.dismissCurrentBanner()
                }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: inAppNotificationCenter.currentBanner)
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet(serverProfile: activeServer, onComplete: { initializeServices() })
        }
        .sheet(item: $setupTarget) { target in
            switch target {
            case .qbittorrent:
                OnboardingSheet(serverProfile: activeServer, onComplete: { initializeServices() })
            case .sonarr:
                ArrSetupSheet(initialServiceType: .sonarr, onComplete: {})
                    .environment(arrServiceManager)
            case .radarr:
                ArrSetupSheet(initialServiceType: .radarr, onComplete: {})
                    .environment(arrServiceManager)
            }
        }
        .sheet(isPresented: $showArrSetup) {
            ArrSetupSheet(onComplete: {})
                .environment(arrServiceManager)
        }
        #if os(macOS)
        .alert("Handle Magnet Links?", isPresented: $showMagnetHandlerPrompt) {
            Button("Set as Default") { setAsDefaultMagnetHandler() }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Would you like Trawl to open magnet: links automatically?")
        }
        #endif
        .onOpenURL { url in
            switch url.scheme?.lowercased() {
            case "magnet":
                if appServices != nil {
                    magnetDeepLink = MagnetDeepLink(url: url.absoluteString)
                } else {
                    pendingMagnetURL = url.absoluteString
                }
            case "trawl":
                guard url.host?.lowercased() == "ssh-session", sshSessionStore.hasSession else { return }
                if let requestedProfileID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "profile" })?
                    .value,
                   sshSessionStore.activeProfile?.id.uuidString != requestedProfileID {
                    return
                }
                openSSHSession()
            default:
                return
            }
        }
        .task {
            if !servers.isEmpty || !arrProfiles.isEmpty {
                isInWelcomeFlow = false
            }
            if !servers.isEmpty {
                initializeServices()
            }
            await arrServiceManager.initialize(from: arrProfiles)
        }
        .onChange(of: activeServerID) { _, newValue in
            appServices?.syncService.stopPolling()
            if newValue == nil {
                appServices = nil
                connectionError = nil
                isConnecting = false
            } else {
                initializeServices()
            }
        }
        .onDisappear {
            appServices?.syncService.stopPolling()
        }
    }

    private var welcomeScreen: some View {
        Group {
            switch welcomeStep {
            case .intro:
                welcomeIntroScreen
            case .services:
                serviceSelectionScreen
            }
        }
        .padding(32)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var welcomeIntroScreen: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Welcome to Trawl")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Your home for torrents, TV, and movies.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                featureRow(icon: "arrow.down.circle.fill", color: .blue,
                           title: "qBittorrent",
                           description: "Manage and monitor your downloads")
                featureRow(icon: "tv.fill", color: .purple,
                           title: "Sonarr",
                           description: "Track and automate your TV series")
                featureRow(icon: "film.fill", color: .orange,
                           title: "Radarr",
                           description: "Discover and collect movies")
            }
            .padding(.horizontal, 8)

            Button("Get Started") {
                welcomeStep = .services
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
    }

    private var serviceSelectionScreen: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("Choose Your Services")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Set up the services you want to use, then continue into the app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                setupRow(
                    icon: "arrow.down.circle.fill",
                    color: .blue,
                    title: "qBittorrent",
                    description: "Manage and monitor your downloads",
                    isConfigured: activeServer != nil
                ) {
                    setupTarget = .qbittorrent
                }

                setupRow(
                    icon: "tv.fill",
                    color: .purple,
                    title: "Sonarr",
                    description: "Track and automate your TV series",
                    isConfigured: sonarrProfile != nil
                ) {
                    setupTarget = .sonarr
                }

                setupRow(
                    icon: "film.fill",
                    color: .orange,
                    title: "Radarr",
                    description: "Discover and collect movies",
                    isConfigured: radarrProfile != nil
                ) {
                    setupTarget = .radarr
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button("Done") {
                    if hasConfiguredAnyService {
                        isInWelcomeFlow = false
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasConfiguredAnyService)
                    .frame(maxWidth: .infinity)

                Button("Back") {
                    welcomeStep = .intro
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func setupRow(
        icon: String,
        color: Color,
        title: String,
        description: String,
        isConfigured: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isConfigured ? Color.green : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        let services = appServices ?? disconnectedServices
        let activeTorrentCount = services.syncService.sortedTorrents.filter(\.isRunningInTabBadge).count
        TabView(selection: $selectedTab) {
            Tab("Torrents", systemImage: "arrow.down.circle", value: RootTab.torrents) {
                NavigationStack {
                    if appServices != nil {
                        TorrentListView(title: activeServer?.displayName ?? "Trawl")
                            .environment(services.syncService)
                            .environment(services.torrentService)
                    } else {
                        torrentsUnavailableContent
                            .navigationTitle(activeServer?.displayName ?? "Trawl")
                    }
                }
            }
            .badge(activeTorrentCount)

            Tab("Series", systemImage: "tv", value: RootTab.series) {
                NavigationStack {
                    SonarrSeriesListView()
                }
                .environment(arrServiceManager)
                .environment(services.syncService)
                .environment(services.torrentService)
            }

            Tab("Movies", systemImage: "film", value: RootTab.movies) {
                NavigationStack {
                    RadarrMovieListView()
                }
                .environment(arrServiceManager)
                .environment(services.syncService)
                .environment(services.torrentService)
            }

            Tab(value: RootTab.search, role: .search) {
                SearchView(appServices: appServices)
                    .environment(arrServiceManager)
                    .environment(services.syncService)
                    .environment(services.torrentService)
            }

            Tab("More", systemImage: "ellipsis.circle", value: RootTab.more) {
                MoreView(
                    appServices: appServices,
                    path: $morePath,
                    openSSHSession: { openSSHSession() },
                    selectSSHProfile: { profile in
                        sshSessionStore.prepareSession(for: profile)
                        openSSHSession()
                    }
                )
                    .environment(arrServiceManager)
                    .environment(\.navigateToQbittorrentSettings) {
                        morePath.append(.qbittorrentSettings)
                    }
                    .environment(\.navigateToSonarrSettings) {
                        morePath.append(.sonarrSettings)
                    }
                    .environment(\.navigateToRadarrSettings) {
                        morePath.append(.radarrSettings)
                    }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(SSHSessionAccessoryModifier(
            isEnabled: isAccessoryVisible,
            title: sshSessionStore.sessionTitle,
            subtitle: sshSessionStore.sessionSubtitle,
            statusText: sshSessionStore.statusText,
            statusColor: sshSessionStore.statusColor,
            openSession: openSSHSession,
            closeSession: { showSSHDisconnectConfirm = true }
        ))
        #endif
        .onChange(of: selectedTab) { _, newValue in
            if newValue != .more {
                sshSessionStore.hideKeyboard()
            }
        }
        .onChange(of: morePath) { _, newValue in
            if !newValue.contains(MoreDestination.sshSession) {
                sshSessionStore.hideKeyboard()
            }
        }
        .sheet(item: $magnetDeepLink) { link in
            AddTorrentSheet(initialMagnetURL: link.url)
                .environment(services.syncService)
                .environment(services.torrentService)
        }
        #if os(iOS)
        .sheet(isPresented: $showSSHSessionSheet, onDismiss: {
            sshSessionStore.wantsKeyboard = false
        }) {
            NavigationStack {
                SSHSessionView()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        #endif
        .alert("Disconnect?", isPresented: $showSSHDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    sshSessionStore.disconnect()
                    showSSHSessionSheet = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current terminal session will be closed.")
        }
    }

    @ViewBuilder
    private var torrentsUnavailableContent: some View {
        if isConnecting {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting…")
                    .font(.headline)
                if let server = activeServer {
                    VStack(spacing: 4) {
                        Text(server.displayName)
                        Text(server.hostURL)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                }
                Button("Edit Server", systemImage: "server.rack") {
                    showOnboarding = true
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = connectionError {
            ContentUnavailableView {
                Label("Connection Failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Retry", systemImage: "arrow.clockwise") { initializeServices() }
                Button("Edit Server", systemImage: "server.rack") { showOnboarding = true }
            }
        } else {
            // qBittorrent not configured — arr-only user or setup pending
            ContentUnavailableView {
                Label("qBittorrent Not Set Up", systemImage: "arrow.down.circle")
            } description: {
                Text("Add a qBittorrent server in Settings to manage your downloads.")
            } actions: {
                Button("Add Server", systemImage: "plus") { showOnboarding = true }
            }
        }
    }

    #if os(macOS)
    private func isDefaultMagnetHandler() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = LSCopyDefaultHandlerForURLScheme("magnet" as CFString)?.takeRetainedValue() as String?
        return current == bundleID
    }

    private func setAsDefaultMagnetHandler() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        LSSetDefaultHandlerForURLScheme("magnet" as CFString, bundleID as CFString)
    }
    #endif

    private var activeServer: ServerProfile? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var activeServerID: UUID? {
        activeServer?.id
    }

    private var sonarrProfile: ArrServiceProfile? {
        arrProfiles.first(where: { $0.resolvedServiceType == .sonarr })
    }

    private var radarrProfile: ArrServiceProfile? {
        arrProfiles.first(where: { $0.resolvedServiceType == .radarr })
    }

    private var hasConfiguredAnyService: Bool {
        activeServer != nil || sonarrProfile != nil || radarrProfile != nil
    }

    private var shouldShowWelcomeScreen: Bool {
        isInWelcomeFlow || (servers.isEmpty && arrProfiles.isEmpty)
    }

    private var isShowingSSHSession: Bool {
        showSSHSessionSheet
    }

    private var isAccessoryVisible: Bool {
        sshSessionStore.hasSession && !isShowingSSHSession
    }

    private func initializeServices() {
        guard let server = activeServer else {
            return
        }

        isConnecting = true
        connectionError = nil

        Task {
            do {
                let previousServices = appServices
                let username = try await KeychainHelper.shared.read(key: server.usernameKey) ?? ""
                let password = try await KeychainHelper.shared.read(key: server.passwordKey) ?? ""

                guard !username.isEmpty, !password.isEmpty else {
                    connectionError = "Credentials not found. Please re-enter your server details."
                    isConnecting = false
                    return
                }

                let services = try await AppServices.build(from: server, username: username, password: password)
                previousServices?.syncService.stopPolling()
                await services.syncService.refreshNow()
                services.syncService.startPolling()

                // Update last connected
                server.lastConnected = .now
                try? modelContext.save()

                appServices = services
                selectedTab = .torrents
                isConnecting = false

                #if os(macOS)
                if !hasPromptedForMagnetHandler && !isDefaultMagnetHandler() {
                    hasPromptedForMagnetHandler = true
                    showMagnetHandlerPrompt = true
                }
                #endif

                if let pending = pendingMagnetURL {
                    magnetDeepLink = MagnetDeepLink(url: pending)
                    pendingMagnetURL = nil
                }
            } catch {
                connectionError = error.localizedDescription
                isConnecting = false
            }
        }
    }

    private func openSSHSession() {
        if sshSessionStore.activeProfile != nil {
            #if os(iOS)
            presentSSHSession()
            #else
            selectedTab = .more
            morePath = [.ssh, .sshSession]
            sshSessionStore.focusSession()
            #endif
        }
    }

    private func presentSSHSession() {
        sshSessionStore.focusSession()
        showSSHSessionSheet = true
    }
}

private extension Torrent {
    var isRunningInTabBadge: Bool {
        switch state {
        case .downloading, .metaDL, .forcedDL, .forcedUP, .uploading, .checkingDL, .checkingUP,
             .checkingResumeData, .allocating, .moving:
            true
        case .stalledDL, .stalledUP:
            dlspeed > 0 || upspeed > 0
        case .queuedDL, .queuedUP:
            dlspeed > 0 || upspeed > 0
        case .pausedDL, .pausedUP, .stoppedDL, .stoppedUP, .error, .missingFiles, .unknown:
            false
        }
    }
}

private struct InAppNotificationBanner: View {
    let item: InAppBannerItem
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .glassEffect(.regular.tint(.green.opacity(0.18)), in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct MagnetDeepLink: Identifiable {
    let id = UUID()
    let url: String
}

private enum RootTab: Hashable {
    case torrents
    case series
    case movies
    case search
    case more
}

private enum WelcomeStep {
    case intro
    case services
}

private enum SetupTarget: Identifiable {
    case qbittorrent
    case sonarr
    case radarr

    var id: String {
        switch self {
        case .qbittorrent: "qbittorrent"
        case .sonarr: "sonarr"
        case .radarr: "radarr"
        }
    }
}
#if os(iOS)
private struct SSHSessionAccessoryModifier: ViewModifier {
    let isEnabled: Bool
    let title: String
    let subtitle: String
    let statusText: String
    let statusColor: Color
    let openSession: () -> Void
    let closeSession: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) {
                accessoryView
            }
        } else {
            content.tabViewBottomAccessory {
                if isEnabled {
                    accessoryView
                }
            }
        }
    }

    private var accessoryView: some View {
        SSHSessionAccessoryView(
            title: title,
            subtitle: subtitle,
            statusText: statusText,
            statusColor: statusColor,
            openSession: openSession,
            closeSession: closeSession
        )
    }
}
#endif

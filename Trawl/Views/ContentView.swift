import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(AppLockController.self) private var appLockController
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
    @State private var pendingDeepLink: PendingDeepLink?  // holds deep link during welcome screen
    @State private var showArrSetup = false
    @State private var showSSHDisconnectConfirm = false
    @State private var showSSHSessionSheet = false
    @State private var welcomePath: [WelcomeStep] = []
    @State private var setupTarget: SetupTarget?
    @State private var hasAutoSelectedTorrents = false
    @State private var didEvaluateWelcomeState = false
    @State private var servicesTask: Task<Void, Never>?
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
                } onTap: {
                    inAppNotificationCenter.fireCurrentBannerAction()
                }
                .withActionAffordance(inAppNotificationCenter.currentBannerHasAction)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: inAppNotificationCenter.currentBanner)
        .sensoryFeedback(trigger: inAppNotificationCenter.currentBanner) { _, newValue in
            guard let newBanner = newValue else { return nil }
            switch newBanner.style {
            case .error: return .error
            case .success: return .success
            case .progress: return nil
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet(serverProfile: activeServer, onComplete: { initializeServices() })
        }
        .sheet(item: $setupTarget) { target in
            switch target {
            case .qbittorrent:
                OnboardingSheet(serverProfile: activeServer, onComplete: { initializeServices() })
            case .sonarr:
                ArrSetupSheet(initialServiceType: .sonarr, onComplete: refreshArrConfiguration)
                    .environment(arrServiceManager)
            case .radarr:
                ArrSetupSheet(initialServiceType: .radarr, onComplete: refreshArrConfiguration)
                    .environment(arrServiceManager)
            case .prowlarr:
                ArrSetupSheet(initialServiceType: .prowlarr, onComplete: refreshArrConfiguration)
                    .environment(arrServiceManager)
            case .bazarr:
                ArrSetupSheet(initialServiceType: .bazarr, onComplete: refreshArrConfiguration)
                    .environment(arrServiceManager)
            }
        }
        .sheet(isPresented: $showArrSetup) {
            ArrSetupSheet(onComplete: refreshArrConfiguration)
                .environment(arrServiceManager)
        }
        .overlay {
            if appLockController.isLocked {
                AppLockView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.18), value: appLockController.isLocked)
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
                if shouldShowWelcomeScreen {
                    // Store deep link to be applied after welcome screen completes
                    switch url.host?.lowercased() {
                    case "torrents":
                        pendingDeepLink = PendingDeepLink(tab: .torrents, morePath: [])
                    case "calendar":
                        pendingDeepLink = PendingDeepLink(tab: .more, morePath: [.calendar])
                    default:
                        break
                    }
                } else {
                    switch url.host?.lowercased() {
                    case "torrents":
                        selectedTab = .torrents
                    case "calendar":
                        selectedTab = .more
                        morePath = [.calendar]
                    case "ssh-session":
                        guard sshSessionStore.hasSession else { return }
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
            default:
                return
            }
        }
        .task(id: arrProfilesSyncKey) {
            if !didEvaluateWelcomeState {
                isInWelcomeFlow = !hasConfiguredAnyService
                didEvaluateWelcomeState = true
            }
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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            appLockController.handleScenePhase(newPhase, old: oldPhase)
        }
        .onChange(of: shouldShowWelcomeScreen) { _, isShowing in
            if !isShowing, let pending = pendingDeepLink {
                selectedTab = pending.tab
                morePath = pending.morePath
                pendingDeepLink = nil
            }
        }
        .onDisappear {
            appServices?.syncService.stopPolling()
        }
    }

    private var welcomeScreen: some View {
        NavigationStack(path: $welcomePath) {
            welcomeIntroScreen
                .navigationDestination(for: WelcomeStep.self) { step in
                    switch step {
                    case .services:
                        serviceSelectionScreen
                    }
                }
        }
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
                featureRow(icon: "magnifyingglass.circle.fill", color: .yellow,
                           title: "Prowlarr",
                           description: "Manage and search your indexers")
                featureRow(icon: "captions.bubble.fill", color: .teal,
                           title: "Bazarr",
                           description: "Manage subtitles for series and movies")
            }
            .padding(.horizontal, 8)

            NavigationLink(value: WelcomeStep.services) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(32)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                setupRow(
                    icon: "magnifyingglass.circle.fill",
                    color: .yellow,
                    title: "Prowlarr",
                    description: "Manage and search your indexers",
                    isConfigured: prowlarrProfile != nil
                ) {
                    setupTarget = .prowlarr
                }

                setupRow(
                    icon: "captions.bubble.fill",
                    color: .teal,
                    title: "Bazarr",
                    description: "Manage subtitles for series and movies",
                    isConfigured: bazarrProfile != nil
                ) {
                    setupTarget = .bazarr
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button("Go") {
                    if hasConfiguredAnyService {
                        isInWelcomeFlow = false
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasConfiguredAnyService)
                    .frame(maxWidth: .infinity)

                Button("Back") {
                    welcomePath.removeAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Choose Services")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        let activeTorrentCount = services.syncService.activeTorrentCount
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
                        sshSessionStore.addSession(for: profile)
                        openSSHSession()
                    }
                )
                    .environment(arrServiceManager)
                    .environment(\.navigateToSeriesTab) {
                        selectedTab = .series
                    }
                    .environment(\.navigateToMoviesTab) {
                        selectedTab = .movies
                    }
                    .environment(\.navigateToQbittorrentSettings) {
                        morePath.append(.qbittorrentSettings)
                    }
                    .environment(\.navigateToSonarrSettings) {
                        morePath.append(.sonarrSettings)
                    }
                    .environment(\.navigateToRadarrSettings) {
                        morePath.append(.radarrSettings)
                    }
                    .environment(\.navigateToProwlarrSettings) {
                        morePath.append(.prowlarrSettings)
                    }
                    .environment(\.navigateToBazarrSettings) {
                        morePath.append(.bazarrSettings)
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
                SSHSessionContainerView()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        #endif
        .alert("Disconnect?", isPresented: $showSSHDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                Task { @MainActor in
                    await sshSessionStore.disconnect()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showSSHSessionSheet = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = sshSessionStore.sessions.count
            Text(count > 1 ? "All \(count) terminal sessions will be closed." : "Your terminal session will be closed.")
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
        MagnetLinkHandler.isDefault
    }

    private func setAsDefaultMagnetHandler() {
        MagnetLinkHandler.setAsDefault()
    }
    #endif

    private var activeServer: ServerProfile? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var activeServerID: UUID? {
        activeServer?.id
    }

    private var sonarrProfile: ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: .sonarr, in: arrProfiles)
    }

    private var radarrProfile: ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: .radarr, in: arrProfiles)
    }

    private var prowlarrProfile: ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: .prowlarr, in: arrProfiles)
    }

    private var bazarrProfile: ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: .bazarr, in: arrProfiles)
    }

    private var hasConfiguredAnyService: Bool {
        activeServer != nil || sonarrProfile != nil || radarrProfile != nil || prowlarrProfile != nil || bazarrProfile != nil
    }

    private var arrProfilesSyncKey: String {
        arrProfiles
            .map { "\($0.id.uuidString):\($0.serviceType):\($0.hostURL):\($0.isEnabled)" }
            .sorted()
            .joined(separator: "|")
    }

    private var shouldShowWelcomeScreen: Bool {
        didEvaluateWelcomeState ? isInWelcomeFlow : !hasConfiguredAnyService
    }

    private var isShowingSSHSession: Bool {
        showSSHSessionSheet
    }

    private var isAccessoryVisible: Bool {
        sshSessionStore.hasSession && !isShowingSSHSession
    }

    private func initializeServices() {
        servicesTask?.cancel()

        guard let server = activeServer else {
            appServices?.syncService.stopPolling()
            appServices = nil
            connectionError = nil
            isConnecting = false
            return
        }

        let previousServices = appServices
        isConnecting = true
        connectionError = nil

        servicesTask = Task {
            do {
                let username = try await KeychainHelper.shared.read(key: server.usernameKey) ?? ""
                let password = try await KeychainHelper.shared.read(key: server.passwordKey) ?? ""

                guard !username.isEmpty, !password.isEmpty else {
                    guard !Task.isCancelled else { return }
                    previousServices?.syncService.stopPolling()
                    appServices = nil
                    connectionError = "Credentials not found. Please re-enter your server details."
                    isConnecting = false
                    return
                }

                let services = try await AppServices.build(from: server, username: username, password: password)
                guard !Task.isCancelled else {
                    services.syncService.stopPolling()
                    return
                }
                previousServices?.syncService.stopPolling()
                await services.syncService.refreshNow()
                guard !Task.isCancelled else {
                    services.syncService.stopPolling()
                    return
                }
                services.syncService.startPolling()

                // Update last connected
                server.lastConnected = .now
                do {
                    try modelContext.save()
                } catch {
                    InAppNotificationCenter.shared.showError(
                        title: "Couldn't Save Server State",
                        message: error.localizedDescription
                    )
                }

                guard !Task.isCancelled else {
                    services.syncService.stopPolling()
                    return
                }
                appServices = services
                if !hasAutoSelectedTorrents {
                    selectedTab = .torrents
                    hasAutoSelectedTorrents = true
                }
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
                guard !Task.isCancelled else { return }
                previousServices?.syncService.stopPolling()
                appServices = nil
                connectionError = error.localizedDescription
                isConnecting = false
            }
        }
    }

    private func refreshArrConfiguration() {
        Task {
            await arrServiceManager.refreshConfiguration()
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

private struct InAppNotificationBanner: View {
    let item: InAppBannerItem
    let onDismiss: () -> Void
    let onTap: () -> Void
    var hasAction = false

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if item.showsProgressView {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(item.tintColor)
                } else {
                    Image(systemName: item.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(item.tintColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(item.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if hasAction {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassEffect(.regular.tint(item.tintColor.opacity(0.18)), in: RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height < 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height < -40 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
}

private extension InAppNotificationBanner {
    func withActionAffordance(_ hasAction: Bool) -> InAppNotificationBanner {
        var copy = self
        copy.hasAction = hasAction
        return copy
    }
}

private extension InAppBannerItem {
    var tintColor: Color {
        switch style {
        case .success:
            .green
        case .error:
            .red
        case .progress:
            .blue
        }
    }
}

private struct MagnetDeepLink: Identifiable {
    let id = UUID()
    let url: String
}

private struct PendingDeepLink {
    let tab: RootTab
    let morePath: [MoreDestination]
}

private enum RootTab: Hashable {
    case torrents
    case series
    case movies
    case search
    case more
}

private enum WelcomeStep: Hashable {
    case services
}

private enum SetupTarget: Identifiable {
    case qbittorrent
    case sonarr
    case radarr
    case prowlarr
    case bazarr

    var id: String {
        switch self {
        case .qbittorrent: "qbittorrent"
        case .sonarr: "sonarr"
        case .radarr: "radarr"
        case .prowlarr: "prowlarr"
        case .bazarr: "bazarr"
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

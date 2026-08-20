import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

#if os(iOS)
private let notificationSheetTransitionID = "recent-notifications-accessory"
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Environment(AppLockController.self) private var appLockController
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query private var servers: [ServerProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var jellyfinProfiles: [JellyfinServiceProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @State private var appServices: AppServices?
    @State private var disconnectedServices = AppServices.disconnected()
    @State private var connectionError: String?
    @State private var isConnecting = false
    @State private var isInWelcomeFlow = true
    @AppStorage("startupTab") private var startupTab: String = RootTab.downloads.displayName
    @AppStorage("themeOverride") private var themeOverride: ThemeOverride = .system
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @State private var selectedTab: RootTab = .downloads
    @State private var morePath: [MoreDestination] = []
    @State private var magnetDeepLink: MagnetDeepLink?
    @State private var pendingMagnetURL: String?  // holds URL during cold launch before services are ready
    @State private var pendingDeepLink: PendingDeepLink?  // holds deep link during welcome screen
    @State private var showArrSetup = false
    @State private var setupTarget: SetupTarget?
    @State private var didEvaluateWelcomeState = false
    @State private var servicesTask: Task<Void, Never>?
    @State private var connectionRetryScheduler = ConnectionRetryScheduler()
    #if os(macOS)
    @AppStorage("hasPromptedForMagnetHandler") private var hasPromptedForMagnetHandler = false
    @State private var showMagnetHandlerPrompt = false
    #endif
    @State private var hasSetStartupTab = false
    @State private var topBannerPadding: CGFloat = 100
    #if os(iOS)
    @Namespace private var notificationTransitionNamespace
    @State private var notificationWindowPresenter = InAppNotificationWindowPresenter()
    @State private var isTabChromeHidden = false
    #endif
    #if DEBUG
    private var isPreview = false
    #endif

    var body: some View {
        Group {
            if shouldShowWelcomeScreen {
                welcomeScreen
            } else {
                tabContent
            }
        }
        .environment(connectionRetryScheduler)
        .preferredColorScheme(themeOverride.colorScheme)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { topBannerPadding = geometry.safeAreaInsets.top + 44 + 8 }
                    .onChange(of: geometry.safeAreaInsets.top) { topBannerPadding = geometry.safeAreaInsets.top + 44 + 8 }
            }
            .ignoresSafeArea()
        )
        #if os(macOS)
        .overlay(alignment: .top) {
            if let banner = inAppNotificationCenter.currentBanner {
                InAppNotificationBanner(item: banner) {
                    inAppNotificationCenter.dismissCurrentBanner()
                } onTap: {
                    if inAppNotificationCenter.currentBannerHasAction {
                        inAppNotificationCenter.fireCurrentBannerAction()
                    } else {
                        inAppNotificationCenter.showRecentNotifications()
                        inAppNotificationCenter.dismissCurrentBanner()
                    }
                }
                .withActionAffordance(inAppNotificationCenter.currentBannerHasAction)
                .padding(.top, topBannerPadding)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: inAppNotificationCenter.currentBanner)
        #endif
        .sensoryFeedback(trigger: inAppNotificationCenter.currentBanner) { _, newValue in
            guard hapticsEnabled, let newBanner = newValue else { return nil }
            switch newBanner.style {
            case .error: return .error
            case .success: return .success
            case .progress: return nil
            }
        }
        .sheet(isPresented: Binding(
            get: { inAppNotificationCenter.isPresentingRecentNotifications },
            set: { inAppNotificationCenter.isPresentingRecentNotifications = $0 }
        )) {
            #if os(iOS)
            RecentNotificationsSheet()
                .environment(inAppNotificationCenter)
                .navigationTransition(.zoom(sourceID: notificationSheetTransitionID, in: notificationTransitionNamespace))
            #else
            RecentNotificationsSheet()
                .environment(inAppNotificationCenter)
            #endif
        }
        .sheet(item: $setupTarget) { target in
            switch target {
            case .qbittorrent:
                OnboardingSheet(serverProfile: activeServer, onComplete: { initializeServices() })
            case .sabnzbd:
                SABnzbdSetupSheet {
                    Task { await sabnzbdServiceManager.initialize(from: sabnzbdProfiles) }
                }
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
            case .seerr:
                SeerrSetupSheet()
            case .jellyfin:
                JellyfinSetupSheet()
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
        .onAppear {
            evaluateInitialWelcomeStateIfNeeded()

            if startupTab == "Torrents" {
                startupTab = RootTab.downloads.displayName
            }
            if !hasSetStartupTab, let tab = RootTab.allCases.first(where: { $0.displayName == startupTab }) {
                selectedTab = tab
                hasSetStartupTab = true
            }
            #if os(iOS)
            notificationWindowPresenter.install(notificationCenter: inAppNotificationCenter)
            #endif
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, _ in
            notificationWindowPresenter.install(notificationCenter: inAppNotificationCenter)
        }
        #endif
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
                    case "torrents", "downloads":
                        pendingDeepLink = PendingDeepLink(tab: .downloads, morePath: [])
                    case "calendar":
                        pendingDeepLink = PendingDeepLink(tab: .more, morePath: [.calendar])
                    case "health":
                        pendingDeepLink = PendingDeepLink(tab: .more, morePath: [.health])
                    case "seerr-requests":
                        pendingDeepLink = PendingDeepLink(tab: .more, morePath: [.seerrAdmin])
                    case "seerr-issue":
                        pendingDeepLink = PendingDeepLink(tab: .more, morePath: [.seerrIssues])
                    default:
                        break
                    }
                } else {
                    switch url.host?.lowercased() {
                    case "torrents", "downloads":
                        selectedTab = .downloads
                    case "calendar":
                        selectedTab = .more
                        morePath = [.calendar]
                    case "health":
                        selectedTab = .more
                        morePath = [.health]
                    case "seerr-requests":
                        selectedTab = .more
                        morePath = [.seerrAdmin]
                    case "seerr-issue":
                        selectedTab = .more
                        morePath = [.seerrIssues]
                    default:
                        return
                    }
                }
            default:
                return
            }
        }
        .task(id: seerrProfilesSyncKey) {
            #if DEBUG
            guard !isPreview else { return }
            #endif
            evaluateInitialWelcomeStateIfNeeded()
            await seerrServiceManager.initialize(from: seerrProfiles)
        }
        .task(id: jellyfinProfilesSyncKey) {
            #if DEBUG
            guard !isPreview else { return }
            #endif
            evaluateInitialWelcomeStateIfNeeded()
            await jellyfinServiceManager.initialize(from: jellyfinProfiles)
        }
        .task(id: sabnzbdProfilesSyncKey) {
            #if DEBUG
            guard !isPreview else { return }
            #endif
            evaluateInitialWelcomeStateIfNeeded()
            await sabnzbdServiceManager.initialize(from: sabnzbdProfiles)
        }
        .task(id: arrProfilesSyncKey) {
            #if DEBUG
            guard !isPreview else { return }
            #endif
            evaluateInitialWelcomeStateIfNeeded()
            if !servers.isEmpty {
                initializeServices()
            }
            await arrServiceManager.initialize(from: arrProfiles)
        }
        .task(id: connectionRetryLoopKey) {
            #if DEBUG
            guard !isPreview else { return }
            #endif
            guard scenePhase == .active, !shouldShowWelcomeScreen else { return }
            await connectionRetryScheduler.start {
                await retryDisconnectedConnections()
            }
        }
        .onChange(of: activeServerID) { _, newValue in
            appServices?.syncService.stopPolling()
            if newValue == nil {
                withAnimation(.snappy) {
                    appServices = nil
                    connectionError = nil
                    isConnecting = false
                }
            } else {
                initializeServices()
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            appLockController.handleScenePhase(newPhase, old: oldPhase)
            if newPhase == .background {
                servicesTask?.cancel()
                appServices?.syncService.stopPolling()
                sabnzbdServiceManager.stopPolling()
            } else if newPhase == .active && !shouldShowWelcomeScreen {
                // iOS transitions scenePhase through .inactive in both directions
                // (.background → .inactive → .active), so checking `oldPhase == .background`
                // never matches. Restart whenever services are missing or polling died.
                let needsRestart = appServices == nil || appServices?.syncService.isPolling == false
                if needsRestart {
                    initializeServices()
                }
                // Re-attempt service managers that failed to connect (e.g. VPN was off at launch).
                // These don't reset already-connected services — only retry disconnected ones.
                if !seerrServiceManager.isConnected && !seerrServiceManager.isConnecting && !seerrProfiles.isEmpty {
                    Task { await seerrServiceManager.initialize(from: seerrProfiles) }
                }
                if !jellyfinServiceManager.isConnected && !jellyfinServiceManager.isConnecting && !jellyfinProfiles.isEmpty {
                    Task { await jellyfinServiceManager.initialize(from: jellyfinProfiles) }
                }
                if !sabnzbdServiceManager.isConnected && !sabnzbdServiceManager.isConnecting && !sabnzbdProfiles.isEmpty {
                    Task { await sabnzbdServiceManager.initialize(from: sabnzbdProfiles) }
                } else if sabnzbdServiceManager.isConnected {
                    sabnzbdServiceManager.startPolling()
                }
                Task { await arrServiceManager.retryDisconnected() }
            }
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
            sabnzbdServiceManager.stopPolling()
        }
    }

    private var welcomeScreen: some View {
        WelcomeFlowView(
            isInWelcomeFlow: $isInWelcomeFlow,
            setupTarget: $setupTarget,
            configuredServices: WelcomeServicesState(
                qbittorrent: activeServer != nil,
                sabnzbd: sabnzbdProfile != nil,
                sonarr: sonarrProfile != nil,
                radarr: radarrProfile != nil,
                prowlarr: prowlarrProfile != nil,
                bazarr: bazarrProfile != nil,
                seerr: seerrProfile != nil,
                jellyfin: jellyfinProfile != nil
            )
        )
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        let services = appServices ?? disconnectedServices
        let unifiedActiveDownloadCount = services.syncService.activeTorrentCount + sabnzbdServiceManager.activeJobs.count
        TabView(selection: $selectedTab) {
            Tab("Downloads", systemImage: "tray.and.arrow.down", value: RootTab.downloads) {
                NavigationStack {
                    DownloadsView()
                        .environment(services.syncService)
                        .environment(services.torrentService)
                        .environment(arrServiceManager)
                        .environment(sabnzbdServiceManager)
                }
            }
            .badge(unifiedActiveDownloadCount)

            Tab("Series", systemImage: ServiceIdentity.sonarr.tabSystemImage, value: RootTab.series) {
                NavigationStack {
                    SonarrSeriesListView()
                }
                .environment(arrServiceManager)
                .environment(services.syncService)
                .environment(services.torrentService)
            }

            Tab("Movies", systemImage: ServiceIdentity.radarr.tabSystemImage, value: RootTab.movies) {
                NavigationStack {
                    RadarrMovieListView()
                }
                .environment(arrServiceManager)
                .environment(services.syncService)
                .environment(services.torrentService)
            }

            Tab(value: RootTab.search, role: .search) {
                SearchView()
                    .environment(arrServiceManager)
                    .environment(services.syncService)
                    .environment(services.torrentService)
            }

            Tab("More", systemImage: "ellipsis", value: RootTab.more) {
                MoreView(
                    appServices: appServices,
                    path: $morePath,
                    isQBittorrentConnecting: isConnecting,
                    onRetryQBittorrent: { initializeServices() }
                )
                    .environment(services.syncService)
                    .environment(services.torrentService)
                    .environment(arrServiceManager)
                    .environment(sabnzbdServiceManager)
                    .environment(\.navigateToSeriesTab) {
                        selectedTab = .series
                    }
                    .environment(\.navigateToMoviesTab) {
                        selectedTab = .movies
                    }
                    .environment(\.navigateToQbittorrentSettings) {
                        morePath.append(.qbittorrentSettings)
                    }
                    .environment(\.navigateToDownloadsTab) {
                        selectedTab = .downloads
                    }
                    .environment(\.navigateToSABnzbdSettings) {
                        morePath.append(.sabnzbdSettings)
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
                    .environment(\.navigateToSeerrSettings) {
                        morePath.append(.seerrSettings)
                    }
                    .environment(\.navigateToSeerrIssues) {
                        morePath.append(.seerrIssues)
                    }
                    .environment(\.navigateToJellyfinSettings) {
                        morePath.append(.jellyfinSettings)
                    }
                    .environment(\.navigateToSettings) {
                        morePath.append(.settings)
                    }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabViewBottomAccessory(isEnabled: !isTabChromeHidden) {
            NotificationTabBarAccessory()
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .bottom) {
            if !isTabChromeHidden {
                // Source view for the notification sheet zoom transition.
                // Lives in the main view hierarchy (not inside tabViewBottomAccessory)
                // because matched transitions can't resolve views bridged through the
                // liquid-glass tab bar. The view is rendered (non-zero opacity) so
                // SwiftUI registers its frame, but visually imperceptible.
                Rectangle()
                    .fill(Color.primary.opacity(0.001))
                    .frame(width: 320, height: 56)
                    .matchedTransitionSource(id: notificationSheetTransitionID, in: notificationTransitionNamespace)
                    .padding(.bottom, 96)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .environment(\.setTabChromeHidden) { isHidden in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isTabChromeHidden = isHidden
            }
        }
        #endif
        .sheet(item: $magnetDeepLink) { link in
            AddTorrentSheet(initialMagnetURL: link.url)
                .environment(services.syncService)
                .environment(services.torrentService)
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

    private var seerrProfile: SeerrServiceProfile? {
        seerrProfiles.first(where: { $0.isEnabled }) ?? seerrProfiles.first
    }

    private var jellyfinProfile: JellyfinServiceProfile? {
        jellyfinProfiles.first(where: { $0.isEnabled }) ?? jellyfinProfiles.first
    }

    private var sabnzbdProfile: SABnzbdServiceProfile? {
        sabnzbdProfiles.first(where: { $0.isEnabled }) ?? sabnzbdProfiles.first
    }

    private var hasConfiguredAnyService: Bool {
        activeServer != nil || sabnzbdProfile != nil || sonarrProfile != nil || radarrProfile != nil || prowlarrProfile != nil || bazarrProfile != nil || seerrProfile != nil || jellyfinProfile != nil
    }

    private var arrProfilesSyncKey: String {
        arrProfiles
            .map { "\($0.id.uuidString):\($0.serviceType):\($0.hostURL):\($0.isEnabled)" }
            .sorted()
            .joined(separator: "|")
    }

    private var seerrProfilesSyncKey: String {
        seerrProfiles
            .map { "\($0.id.uuidString):\($0.hostURL):\($0.isEnabled)" }
            .sorted()
            .joined(separator: "|")
    }

    private var jellyfinProfilesSyncKey: String {
        jellyfinProfiles
            .map { "\($0.id.uuidString):\($0.hostURL):\($0.isEnabled):\($0.authModeRaw)" }
            .sorted()
            .joined(separator: "|")
    }

    private var sabnzbdProfilesSyncKey: String {
        sabnzbdProfiles
            .map { "\($0.id.uuidString):\($0.hostURL):\($0.isEnabled)" }
            .sorted()
            .joined(separator: "|")
    }

    private var connectionRetryLoopKey: String {
        [
            scenePhase == .active ? "active" : "paused",
            shouldShowWelcomeScreen ? "welcome" : "content",
            activeServerID?.uuidString ?? "no-qbittorrent",
            arrProfilesSyncKey,
            seerrProfilesSyncKey,
            jellyfinProfilesSyncKey,
            sabnzbdProfilesSyncKey
        ].joined(separator: "|")
    }

    private var shouldShowWelcomeScreen: Bool {
        didEvaluateWelcomeState ? isInWelcomeFlow : !hasConfiguredAnyService
    }

    private func evaluateInitialWelcomeStateIfNeeded() {
        guard !didEvaluateWelcomeState else { return }

        isInWelcomeFlow = !hasConfiguredAnyService
        didEvaluateWelcomeState = true
    }

    private func initializeServices() {
        servicesTask?.cancel()

        guard let server = activeServer else {
            appServices?.syncService.stopPolling()
            withAnimation(.snappy) {
                appServices = nil
                connectionError = nil
                isConnecting = false
            }
            return
        }

        let previousServices = appServices
        withAnimation(.snappy) {
            isConnecting = true
            connectionError = nil
        }

        servicesTask = Task {
            do {
                let username = try await KeychainHelper.shared.read(key: server.usernameKey) ?? ""
                let password = try await KeychainHelper.shared.read(key: server.passwordKey) ?? ""

                guard !username.isEmpty, !password.isEmpty else {
                    guard !Task.isCancelled else { return }
                    previousServices?.syncService.stopPolling()
                    withAnimation(.snappy) {
                        appServices = nil
                        connectionError = "Credentials not found. Please re-enter your server details."
                        isConnecting = false
                    }
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
                withAnimation(.snappy) {
                    appServices = services
                    isConnecting = false
                }

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
                withAnimation(.snappy) {
                    appServices = nil
                    connectionError = error.localizedDescription
                    isConnecting = false
                }
                // A magnet opened at cold launch stays queued in pendingMagnetURL and is
                // presented once a retry reconnects — let the user know it wasn't lost.
                if pendingMagnetURL != nil {
                    InAppNotificationCenter.shared.showSuccess(
                        title: "Magnet Queued",
                        message: "It will be added once Trawl reconnects to your server."
                    )
                }
            }
        }
    }

    private func retryDisconnectedConnections() async {
        guard !shouldShowWelcomeScreen else { return }

        if activeServer != nil && appServices == nil && !isConnecting {
            initializeServices()
        }

        if !seerrProfiles.isEmpty && !seerrServiceManager.isConnected && !seerrServiceManager.isConnecting {
            await seerrServiceManager.initialize(from: seerrProfiles)
        }

        if !jellyfinProfiles.isEmpty && !jellyfinServiceManager.isConnected && !jellyfinServiceManager.isConnecting {
            await jellyfinServiceManager.initialize(from: jellyfinProfiles)
        }

        if !sabnzbdProfiles.isEmpty && !sabnzbdServiceManager.isConnected && !sabnzbdServiceManager.isConnecting {
            await sabnzbdServiceManager.initialize(from: sabnzbdProfiles)
        }

        await arrServiceManager.retryDisconnected()
    }

    private func refreshArrConfiguration() {
        Task {
            await arrServiceManager.refreshConfiguration()
        }
    }
}

#if DEBUG
extension ContentView {
    init(
        previewSelectedTab: RootTab,
        previewMorePath: [MoreDestination] = [],
        previewAppServices: AppServices? = AppServices.disconnected(),
        previewIsConnecting: Bool = false,
        previewConnectionError: String? = nil,
        previewIsInWelcomeFlow: Bool = false
    ) {
        self._appServices = State(initialValue: previewAppServices)
        self._connectionError = State(initialValue: previewConnectionError)
        self._isConnecting = State(initialValue: previewIsConnecting)
        self._isInWelcomeFlow = State(initialValue: previewIsInWelcomeFlow)
        self._selectedTab = State(initialValue: previewSelectedTab)
        self._morePath = State(initialValue: previewMorePath)
        self._didEvaluateWelcomeState = State(initialValue: true)
        self._hasSetStartupTab = State(initialValue: true)
        self.isPreview = true
    }
}

#Preview("Content - More Tab") {
    PreviewHost(
        profiles: .allServices,
        arr: .preview(.allConfigured),
        appServices: AppServices.disconnected(),
        notificationCenter: InAppNotificationCenter(
            previewNotifications: [
                NotificationLogEntry(
                    title: "Download Complete",
                    message: "A Radarr movie finished importing.",
                    style: .success,
                    source: .inApp,
                    timestamp: Date().addingTimeInterval(-600)
                )
            ],
            lastReadDate: Date().addingTimeInterval(-3_600)
        )
    ) {
        ContentView(
            previewSelectedTab: .more,
            previewAppServices: AppServices.disconnected()
        )
    }
}

#Preview("Content - Welcome") {
    PreviewHost(
        profiles: .empty,
        arr: .preview(.noneConfigured),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil,
        notificationCenter: InAppNotificationCenter(previewNotifications: [])
    ) {
        ContentView(
            previewSelectedTab: .downloads,
            previewAppServices: nil,
            previewIsInWelcomeFlow: true
        )
    }
}
#endif

private struct MagnetDeepLink: Identifiable {
    let id = UUID()
    let url: String
}

private struct PendingDeepLink {
    let tab: RootTab
    let morePath: [MoreDestination]
}

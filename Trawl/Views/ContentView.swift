import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(AppLockController.self) private var appLockController
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query private var servers: [ServerProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var jellyfinProfiles: [JellyfinServiceProfile]
    @State private var showOnboarding = false
    @State private var appServices: AppServices?
    @State private var disconnectedServices = AppServices.disconnected()
    @State private var connectionError: String?
    @State private var isConnecting = false
    @State private var isInWelcomeFlow = true
    @AppStorage("startupTab") private var startupTab: String = RootTab.torrents.displayName
    @AppStorage("themeOverride") private var themeOverride: ThemeOverride = .system
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @State private var selectedTab: RootTab = .torrents
    @State private var morePath: [MoreDestination] = []
    @State private var magnetDeepLink: MagnetDeepLink?
    @State private var pendingMagnetURL: String?  // holds URL during cold launch before services are ready
    @State private var pendingDeepLink: PendingDeepLink?  // holds deep link during welcome screen
    @State private var showArrSetup = false
    @State private var welcomePath: [WelcomeStep] = []
    @State private var setupTarget: SetupTarget?
    @State private var didEvaluateWelcomeState = false
    @State private var servicesTask: Task<Void, Never>?
    #if os(macOS)
    @AppStorage("hasPromptedForMagnetHandler") private var hasPromptedForMagnetHandler = false
    @State private var showMagnetHandlerPrompt = false
    #endif
    @State private var hasSetStartupTab = false

    var body: some View {
        Group {
            if shouldShowWelcomeScreen {
                welcomeScreen
            } else {
                tabContent
            }
        }
        .preferredColorScheme(themeOverride.colorScheme)
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
            guard hapticsEnabled, let newBanner = newValue else { return nil }
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
            if !hasSetStartupTab, let tab = RootTab.allCases.first(where: { $0.displayName == startupTab }) {
                selectedTab = tab
                hasSetStartupTab = true
            }
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
                    case "seerr-issue":
                        selectedTab = .more
                        morePath = [.seerrIssues]
                        // We could deep link directly to the issue if we had a MoreDestination for it
                    default:
                        return
                    }
                }
            default:
                return
            }
        }
        .task(id: seerrProfilesSyncKey) {
            await seerrServiceManager.initialize(from: seerrProfiles)
            if !seerrProfiles.isEmpty {
                isInWelcomeFlow = false
            }
        }
        .task(id: jellyfinProfilesSyncKey) {
            await jellyfinServiceManager.initialize(from: jellyfinProfiles)
            if !jellyfinProfiles.isEmpty {
                isInWelcomeFlow = false
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
            if newPhase == .background {
                servicesTask?.cancel()
                appServices?.syncService.stopPolling()
            } else if newPhase == .active && oldPhase == .background && !shouldShowWelcomeScreen {
                initializeServices()
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
                featureRow(icon: ServiceIdentity.qbittorrent.systemImage, color: ServiceIdentity.qbittorrent.brandColor,
                           title: "qBittorrent",
                           description: "Manage and monitor your downloads")
                featureRow(icon: ServiceIdentity.sonarr.systemImage, color: ServiceIdentity.sonarr.brandColor,
                           title: "Sonarr",
                           description: "Track and automate your TV series")
                featureRow(icon: ServiceIdentity.radarr.systemImage, color: ServiceIdentity.radarr.brandColor,
                           title: "Radarr",
                           description: "Discover and collect movies")
                featureRow(icon: ServiceIdentity.prowlarr.systemImage, color: ServiceIdentity.prowlarr.brandColor,
                           title: "Prowlarr",
                           description: "Manage and search your indexers")
                featureRow(icon: ServiceIdentity.bazarr.systemImage, color: ServiceIdentity.bazarr.brandColor,
                           title: "Bazarr",
                           description: "Manage subtitles for series and movies")
                featureRow(icon: ServiceIdentity.seerr.systemImage, color: ServiceIdentity.seerr.brandColor,
                           title: "Seerr",
                           description: "Manage requests and users")
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
        .frame(maxWidth: hSizeClass == .regular ? 600 : 440)
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
                    icon: ServiceIdentity.qbittorrent.systemImage,
                    color: ServiceIdentity.qbittorrent.brandColor,
                    title: "qBittorrent",
                    description: "Manage and monitor your downloads",
                    isConfigured: activeServer != nil
                ) {
                    setupTarget = .qbittorrent
                }

                setupRow(
                    icon: ServiceIdentity.sonarr.systemImage,
                    color: ServiceIdentity.sonarr.brandColor,
                    title: "Sonarr",
                    description: "Track and automate your TV series",
                    isConfigured: sonarrProfile != nil
                ) {
                    setupTarget = .sonarr
                }

                setupRow(
                    icon: ServiceIdentity.radarr.systemImage,
                    color: ServiceIdentity.radarr.brandColor,
                    title: "Radarr",
                    description: "Discover and collect movies",
                    isConfigured: radarrProfile != nil
                ) {
                    setupTarget = .radarr
                }

                setupRow(
                    icon: ServiceIdentity.prowlarr.systemImage,
                    color: ServiceIdentity.prowlarr.brandColor,
                    title: "Prowlarr",
                    description: "Manage and search your indexers",
                    isConfigured: prowlarrProfile != nil
                ) {
                    setupTarget = .prowlarr
                }

                setupRow(
                    icon: ServiceIdentity.bazarr.systemImage,
                    color: ServiceIdentity.bazarr.brandColor,
                    title: "Bazarr",
                    description: "Manage subtitles for series and movies",
                    isConfigured: bazarrProfile != nil
                ) {
                    setupTarget = .bazarr
                }

                setupRow(
                    icon: ServiceIdentity.seerr.systemImage,
                    color: ServiceIdentity.seerr.brandColor,
                    title: "Seerr",
                    description: "Manage requests and users",
                    isConfigured: seerrProfile != nil
                ) {
                    setupTarget = .seerr
                }

                setupRow(
                    icon: ServiceIdentity.jellyfin.systemImage,
                    color: ServiceIdentity.jellyfin.brandColor,
                    title: "Jellyfin",
                    description: "Manage users, libraries, and server activity",
                    isConfigured: jellyfinProfile != nil
                ) {
                    setupTarget = .jellyfin
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
        .frame(maxWidth: hSizeClass == .regular ? 600 : 440)
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
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        let services = appServices ?? disconnectedServices
        let activeTorrentCount = services.syncService.activeTorrentCount
        TabView(selection: $selectedTab) {
            Tab("Torrents", systemImage: ServiceIdentity.qbittorrent.tabSystemImage, value: RootTab.torrents) {
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
                SearchView(appServices: appServices)
                    .environment(arrServiceManager)
                    .environment(services.syncService)
                    .environment(services.torrentService)
            }

            Tab("More", systemImage: "ellipsis", value: RootTab.more) {
                MoreView(
                    appServices: appServices,
                    path: $morePath
                )
                    .environment(services.syncService)
                    .environment(services.torrentService)
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
                    .environment(\.navigateToSeerrSettings) {
                        morePath.append(.seerrSettings)
                    }
                    .environment(\.navigateToSeerrIssues) {
                        morePath.append(.seerrIssues)
                    }
                    .environment(\.navigateToJellyfinSettings) {
                        morePath.append(.jellyfinSettings)
                    }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        .sheet(item: $magnetDeepLink) { link in
            AddTorrentSheet(initialMagnetURL: link.url)
                .environment(services.syncService)
                .environment(services.torrentService)
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
                Label("qBittorrent Not Set Up", systemImage: ServiceIdentity.qbittorrent.tabSystemImage)
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

    private var seerrProfile: SeerrServiceProfile? {
        seerrProfiles.first(where: { $0.isEnabled }) ?? seerrProfiles.first
    }

    private var jellyfinProfile: JellyfinServiceProfile? {
        jellyfinProfiles.first(where: { $0.isEnabled }) ?? jellyfinProfiles.first
    }

    private var hasConfiguredAnyService: Bool {
        activeServer != nil || sonarrProfile != nil || radarrProfile != nil || prowlarrProfile != nil || bazarrProfile != nil || seerrProfile != nil || jellyfinProfile != nil
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

    private var shouldShowWelcomeScreen: Bool {
        didEvaluateWelcomeState ? isInWelcomeFlow : !hasConfiguredAnyService
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
        .glassEffect(.regular.tint(item.tintColor.opacity(0.18)), in: RoundedRectangle(cornerRadius: 16))
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

enum RootTab: Hashable, CaseIterable {
    case torrents
    case series
    case movies
    case search
    case more

    var displayName: String {
        switch self {
        case .torrents: "Torrents"
        case .series: "Series"
        case .movies: "Movies"
        case .search: "Search"
        case .more: "More"
        }
    }
}

enum ThemeOverride: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
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
    case seerr
    case jellyfin

    var id: String {
        switch self {
        case .qbittorrent: "qbittorrent"
        case .sonarr: "sonarr"
        case .radarr: "radarr"
        case .prowlarr: "prowlarr"
        case .bazarr: "bazarr"
        case .seerr: "seerr"
        case .jellyfin: "jellyfin"
        }
    }
}

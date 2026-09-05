import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

extension Notification.Name {
    /// Posted by the Mac menu bar's Settings command. A notification rather than a
    /// binding because the command lives on the `Scene` and the selection lives in
    /// `ContentView`, and threading one into the other would mean hoisting the app's
    /// whole navigation state up a level for one menu item.
    static let trawlOpenSettings = Notification.Name("com.poole.james.Trawl.openSettings")
}

#if os(iOS)
private let notificationSheetTransitionID = "recent-notifications-accessory"
#endif

private struct SidebarListChrome: ViewModifier {
    @Binding var search: String
    let placement: SearchFieldPlacement

    func body(content: Content) -> some View {
        content
            .navigationTitle("Trawl")
            .searchable(text: $search, placement: placement, prompt: "Search Trawl")
    }
}

#if os(iOS)
private struct SidebarRowRestorationModifier: ViewModifier {
    let row: RootTab
    let detailColumn: Bool
    let state: SidebarScrollState
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            state.rowFrames[row] = frame
            if let anchor = state.takeRestoration(for: row, detailColumn: detailColumn) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(row, anchor: anchor)
                }
            }
        }
    }
}
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Environment(CleanuparrServiceManager.self) private var cleanuparrServiceManager
    @Environment(AppLockController.self) private var appLockController
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query private var servers: [ServerProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var jellyfinProfiles: [JellyfinServiceProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @Query private var cleanuparrProfiles: [CleanuparrServiceProfile]
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
    /// One navigation stack per promoted sidebar destination. They are kept apart
    /// rather than sharing `morePath` because they are separate tabs: switching from
    /// System to Settings and back should find System where you left it, exactly as
    /// switching between Series and Movies does.
    @State private var sidebarPaths: [RootTab: [MoreDestination]] = [:]
    /// Pinned open. The iPad sidebar is the app's primary navigation, not a panel to
    /// be dismissed - and a collapsed one used to take the promoted destinations with
    /// it. It still yields automatically when the window gets narrow enough to turn
    /// the size class compact, which is the case where hiding it is correct.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarSearch = ""
    @State private var sidebarScroll = SidebarScrollState()
    /// Which title the library split views have open. Owned here rather than inside
    /// the lists because the content column and the detail column are two separate
    /// closures of one split view, and both need to read it.
    /// Which download the detail column is showing, when the sidebar chrome is up.
    @State private var downloadSelection: DownloadDetailSelection?
    @State private var seriesSelection: ArrMergeKey?
    @State private var moviesSelection: ArrMergeKey?
    @State private var indexerBrowser = ProwlarrIndexerBrowserState()
    @State private var downloadClientSelection = TrawlColumnSelection<MoreDestination>()
    @State private var linkedApplicationSelection = TrawlColumnSelection<MoreDestination>()
    @State private var taskSelection = TrawlColumnSelection<MoreDestination>()
    @State private var subtitleSelection = TrawlColumnSelection<MoreDestination>()
    @State private var logSelection = TrawlColumnSelection<MoreDestination>()
    @State private var settingsSelection = TrawlColumnSelection<MoreDestination>()
    @State private var healthBrowser = ArrHealthBrowserState()
    @State private var calendarSelection = TrawlColumnSelection<ArrMediaDestination>()
    @State private var missingSelection = TrawlColumnSelection<ArrWantedDestination>()
    @State private var qualityProfileBrowser = ArrQualityProfileBrowserState()
    @State private var importLocationBrowser = ArrImportLocationBrowserState()
    @State private var requestBrowser = SeerrRequestBrowserState()
    @State private var issueBrowser = SeerrIssueBrowserState()
    @State private var userBrowser = UnifiedUserBrowserState()
    @State private var jellyfinLibraryBrowser = JellyfinLibraryBrowserState()
    @State private var magnetDeepLink: MagnetDeepLink?
    @State private var pendingMagnetURL: String?  // holds URL during cold launch before services are ready
    @State private var pendingDeepLink: PendingDeepLink?  // holds deep link during welcome screen
    @State private var nzbDeepLink: NZBDeepLink?
    @State private var nzbStatusMessage: String?
    @State private var isSendingNZB = false
    @State private var showArrSetup = false
    @State private var setupTarget: SetupTarget?
    @State private var didEvaluateWelcomeState = false
    @State private var servicesTask: Task<Void, Never>?
    @State private var connectionRetryScheduler = ConnectionRetryScheduler()
    @State private var downloadsNavigator = DownloadsNavigator()
    @State private var jellyfinCredentialHandoff = JellyfinCredentialHandoff()
    #if os(macOS)
    @AppStorage("hasPromptedForMagnetHandler") private var hasPromptedForMagnetHandler = false
    @State private var showMagnetHandlerPrompt = false
    #endif
    @State private var hasSetStartupTab = false
    @State private var topBannerPadding: CGFloat = 100
    /// Only the iPhone's tab chrome ever hides; the sidebar bar reads this too, so it
    /// lives outside the platform gate and simply stays false on iPad and the Mac.
    @State private var isTabChromeHidden = false
    #if os(iOS)
    @Namespace private var notificationTransitionNamespace
    @State private var notificationWindowPresenter = InAppNotificationWindowPresenter()
    /// The measured width of the sidebar column, so the notification bar can be held
    /// inside it rather than running the width of the window.
    #endif
    /// Which sidebar sections the user has closed. Stored rather than defaulted so
    /// the choice survives a relaunch; see `expansionBinding(for:)`. Not iOS-only:
    /// the Mac draws the same sidebar.
    ///
    /// A newline-joined string because `AppStorage` holds no `Set`. The section's
    /// raw value is its title, which never contains a newline.
    @AppStorage("collapsedSidebarSections") private var collapsedSidebarSectionsRaw: String = ""

    private var collapsedSidebarSections: Set<String> {
        get { Set(collapsedSidebarSectionsRaw.split(separator: "\n").map(String.init)) }
        nonmutating set { collapsedSidebarSectionsRaw = newValue.sorted().joined(separator: "\n") }
    }
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
        .environment(jellyfinCredentialHandoff)
        // `SyncService` and `TorrentService` are the only two service dependencies
        // not injected at the app root, because they come from `AppServices`, which
        // only exists once a qBittorrent server is configured. Every one of the 43
        // `@Environment(SyncService.self)` / `@Environment(TorrentService.self)`
        // reads in the app is non-optional, and a missing one is a *fatal* SwiftUI
        // assertion, not a degraded view - that is exactly what crashed the app in
        // N-02, four navigations deep, on a screen no test had ever opened.
        //
        // Injecting them here, with the same disconnected fallback `tabContent`
        // already uses, means no navigation path below this point can lose them.
        // The per-screen injections further down still win for their own subtrees;
        // this is the floor, not a replacement for them.
        .environment((appServices ?? disconnectedServices).syncService)
        .environment((appServices ?? disconnectedServices).torrentService)
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
                    // Same entry point as every other presentation, so the two
                    // cannot drift: an action runs it, anything else opens history.
                    inAppNotificationCenter.activateCurrentBanner()
                }
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
            // The sheet is presented at root, so the services its Needs Attention
            // section reads have to be handed to it explicitly.
            #if os(iOS)
            RecentNotificationsSheet()
                .environment(inAppNotificationCenter)
                .environment((appServices ?? disconnectedServices).syncService)
                .environment(downloadsNavigator)
                .environment(\.navigateToDownloadsTab) { selectedTab = .downloads }
                // Only on the chrome that has Setup Check to select. Read here, at
                // the root, rather than inside the sheet: a `NavigationSplitView`'s
                // columns report themselves compact on iPad, so a size-class test
                // taken further in gets the wrong answer.
                .environment(
                    \.navigateToSetupCheck,
                    hSizeClass == .compact ? nil : { selectedTab = .setupCheck }
                )
                .navigationTransition(.zoom(sourceID: notificationSheetTransitionID, in: notificationTransitionNamespace))
                // The zoom transition's vertical swipe competes with the sheet's
                // native pull-down dismissal. Keep the other zoom gestures.
                .navigationAllowDismissalGestures([
                    .swipeToGoBack,
                    .zoomEdgePanToDismiss,
                    .zoomPinchToDismiss,
                ])
            #else
            RecentNotificationsSheet()
                .environment(inAppNotificationCenter)
                .environment((appServices ?? disconnectedServices).syncService)
                .environment(downloadsNavigator)
                .environment(\.navigateToDownloadsTab) { selectedTab = .downloads }
                // Always available here: macOS has only the sidebar chrome.
                .environment(\.navigateToSetupCheck) { selectedTab = .setupCheck }
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
                SeerrSetupSheet(
                    existingProfile: seerrProfiles.first(where: { $0.isEnabled }) ?? seerrProfiles.first
                )
            case .jellyfin:
                JellyfinSetupSheet()
            case .cleanuparr:
                CleanuparrSetupSheet {
                    Task { await cleanuparrServiceManager.initialize(from: cleanuparrProfiles) }
                }
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
            handleIncomingURL(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationConstants.pushDeepLinkNotification)) { notification in
            // A tapped push routes through exactly the same handler as an external
            // link, so the two can't drift apart.
            guard let url = notification.object as? URL else { return }
            handleIncomingURL(url)
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
        .task(id: cleanuparrProfilesSyncKey) {
            #if DEBUG
            guard !isPreview else { return }
            #endif
            evaluateInitialWelcomeStateIfNeeded()
            await cleanuparrServiceManager.initialize(from: cleanuparrProfiles)
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
            // Slow app-wide poll purely so the tab-bar accessory's failure count
            // stays honest; Downloads speeds it up while that tab is on screen.
            arrServiceManager.startQueuePolling()
            // Fire-and-forget: `/series` and `/movie` are unpaged full-library
            // dumps, so this must never sit in front of the first frame. It just
            // means the Series and Movies tabs open with content instead of
            // starting the download on appear.
            arrServiceManager.prefetchLibraries()
            await arrServiceManager.refreshQueues()
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
                arrServiceManager.stopQueuePolling()
            } else if newPhase == .active && !shouldShowWelcomeScreen {
                // iOS transitions scenePhase through .inactive in both directions
                // (.background → .inactive → .active), so checking `oldPhase == .background`
                // never matches. Restart whenever services are missing or polling died.
                let needsRestart = appServices == nil || appServices?.syncService.isPolling == false
                if needsRestart {
                    initializeServices()
                }
                // Re-attempt service managers that failed to connect (e.g. VPN was off at launch).
                // These don't reset already-connected services - only retry disconnected ones.
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
                if !cleanuparrServiceManager.isConnected && !cleanuparrServiceManager.isConnecting && !cleanuparrProfiles.isEmpty {
                    Task { await cleanuparrServiceManager.initialize(from: cleanuparrProfiles) }
                }
                Task { await arrServiceManager.retryDisconnected() }
                arrServiceManager.startQueuePolling()
                // Covers returning to a tab that isn't Series or Movies - those two
                // refresh themselves on `.active`. Staleness-gated, so a quick trip
                // out of the app doesn't refetch anything.
                arrServiceManager.prefetchLibraries()
            }
        }
        .onChange(of: shouldShowWelcomeScreen) { _, isShowing in
            if !isShowing, let pending = pendingDeepLink {
                selectedTab = pending.tab
                morePath = pending.morePath
                if let section = pending.downloadsSection {
                    downloadsNavigator.show(section)
                }
                pendingDeepLink = nil
            }
        }
        .onDisappear {
            appServices?.syncService.stopPolling()
            sabnzbdServiceManager.stopPolling()
            arrServiceManager.stopQueuePolling()
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
                jellyfin: jellyfinProfile != nil,
                cleanuparr: cleanuparrProfile != nil
            )
        )
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        let services = appServices ?? disconnectedServices
        let unifiedActiveDownloadCount = services.syncService.activeTorrentCount + sabnzbdServiceManager.activeJobs.count
        Group {
            if hSizeClass == .compact {
                compactTabs(services: services, downloadBadge: unifiedActiveDownloadCount)
            } else {
                regularSidebar(services: services, downloadBadge: unifiedActiveDownloadCount)
            }
        }
        .sheet(item: $magnetDeepLink) { link in
            AddTorrentSheet(initialMagnetURL: link.url)
                .environment(services.syncService)
                .environment(services.torrentService)
        }
        .alert(
            hasSABnzbdServer ? "Send to SABnzbd?" : "SABnzbd Not Set Up",
            isPresented: Binding(get: { nzbDeepLink != nil }, set: { if !$0 { nzbDeepLink = nil } }),
            presenting: nzbDeepLink
        ) { link in
            if hasSABnzbdServer {
                Button("Add") { send(link) }
                Button("Cancel", role: .cancel) { }
            } else {
                Button("OK", role: .cancel) { }
            }
        } message: { link in
            if hasSABnzbdServer {
                Text(link.displayName)
            } else {
                Text("Add a SABnzbd server in \(MoreDestination.sabnzbdSettings.userFacingPath) before adding an NZB.")
            }
        }
        .alert(
            "NZB",
            isPresented: Binding(get: { nzbStatusMessage != nil }, set: { if !$0 { nzbStatusMessage = nil } }),
            presenting: nzbStatusMessage
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Compact chrome (iPhone, and a narrow iPad window)

    /// The five-tab bar, unchanged. This is now the *only* thing `TabView` is
    /// responsible for: the iPad sidebar is built by hand below rather than being
    /// coaxed out of `.sidebarAdaptable`, so the promoted destinations and the
    /// `defaultVisibility` calls that used to hide them from this bar are gone.
    @ViewBuilder
    private func compactTabs(services: AppServices, downloadBadge: Int) -> some View {
        TabView(selection: $selectedTab) {
            Tab("Downloads", systemImage: "tray.and.arrow.down", value: RootTab.downloads) {
                NavigationStack {
                    downloadsRoot(services: services)
                }
            }
            .badge(downloadBadge)

            Tab("Series", systemImage: ServiceIdentity.sonarr.tabSystemImage, value: RootTab.series) {
                NavigationStack {
                    SonarrSeriesListView()
                }
                .environment(arrServiceManager)
                .environment(services.syncService)
                .environment(services.torrentService)
                .environment(sabnzbdServiceManager)
            }

            Tab("Movies", systemImage: ServiceIdentity.radarr.tabSystemImage, value: RootTab.movies) {
                NavigationStack {
                    RadarrMovieListView()
                }
                .environment(arrServiceManager)
                .environment(services.syncService)
                .environment(services.torrentService)
                .environment(sabnzbdServiceManager)
            }

            if #available(iOS 27.0, macOS 27.0, *) {
                Tab(value: RootTab.search, role: .prominent) {
                    searchRoot(services: services)
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            } else {
                Tab(value: RootTab.search, role: .search) {
                    searchRoot(services: services)
                }
            }

            Tab("More", systemImage: "ellipsis", value: RootTab.more) {
                moreStack(rootedAt: nil, path: $morePath, services: services)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabViewBottomAccessory(isEnabled: !isTabChromeHidden) {
            NotificationTabBarAccessory()
                .environment(services.syncService)
                .environment(downloadsNavigator)
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
    }

    // MARK: - Regular chrome (iPad)

    /// A sidebar that is always there.
    ///
    /// `.sidebarAdaptable` was doing this job and doing it conditionally: it offers a
    /// toggle that collapses the sidebar into a floating pill, that choice persists
    /// across launches, and the pill renders only the tabs with no `defaultVisibility`
    /// of their own - so the seven promoted destinations vanished with it. There is no
    /// API to hold that style open (`TabViewStyle` has `.sidebarAdaptable` and
    /// `.tabBarOnly`, and nothing in between), so the sidebar is built here instead.
    ///
    /// The width test is `hSizeClass`, which is what actually matters: a full-screen
    /// iPad is regular and gets the sidebar; the same iPad in a narrow Split View or
    /// Slide Over turns compact and gets the phone's tab bar, which is the right
    /// answer for that width rather than a squeezed sidebar.
    /// One split view with three columns - not a split view whose detail column holds
    /// another split view. The nested arrangement worked, but every level brought its
    /// own navigation bar and safe area, which showed as a band of empty space above
    /// the middle column. `sidebar | content | detail` is the shape iPadOS actually
    /// provides, and a `NavigationLink` in the content column routes into the detail
    /// column without any of that.
    ///
    /// Portrait is left to SwiftUI. Three columns do not fit in 1032pt, so it moves
    /// the sidebar behind a "Show Sidebar" button and shows list and detail side by
    /// side - which is a better trade at that width than a permanently visible
    /// sidebar squeezing both. An earlier version special-cased portrait into two
    /// columns to keep the sidebar pinned; that is gone, and the button is fine.
    @ViewBuilder
    private func regularSidebar(services: AppServices, downloadBadge: Int) -> some View {
        Group {
            if selectedTab.wantsDetailColumn {
                threeColumnLayout(services: services, downloadBadge: downloadBadge)
            } else {
                twoColumnLayout(services: services, downloadBadge: downloadBadge)
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .trawlOpenSettings)) { _ in
            selectedTab = .settings
            sidebarPath(for: .settings).wrappedValue = []
        }
        #endif
        #if os(iOS)
        .environment(\.setTabChromeHidden) { isHidden in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isTabChromeHidden = isHidden
            }
        }
        #endif
    }

    /// Three columns, for the destinations that are a list of things you open.
    private func threeColumnLayout(services: AppServices, downloadBadge: Int) -> some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebarColumn(services: services, downloadBadge: downloadBadge)
        } content: {
            contentColumn(for: selectedTab, services: services)
                .navigationSplitViewColumnWidth(min: 360, ideal: 420, max: 560)
        } detail: {
            detailColumn(for: selectedTab, services: services)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.selectLibraryTitle, selectLibraryTitle)
        .environment(\.showsSidebarAttentionBanner, true)
    }

    /// Two columns, for the hubs.
    ///
    /// There is no way to hide a split view's detail column - `NavigationSplitView
    /// Visibility` only ever trims from the leading edge (`.all`, `.doubleColumn`,
    /// `.detailOnly`). So a destination that does not want a third column has to be
    /// a two-column split view rather than a three-column one with the third emptied.
    ///
    /// The hubs are that case. Settings, System and the rest are a screen you read,
    /// not a list you pick from, so a permanent "Nothing Selected" panel next to them
    /// is space spent on nothing. Here the hub gets the whole width and its pushes
    /// cover it, which is also where `path` keeps working: the stack is rooted at the
    /// hub itself, so `path.append(...)` from a deep link still lands somewhere real.
    private func twoColumnLayout(services: AppServices, downloadBadge: Int) -> some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebarColumn(services: services, downloadBadge: downloadBadge)
        } detail: {
            moreStack(
                rootedAt: selectedTab.moreRoot,
                path: pathBinding(for: selectedTab),
                services: services
            )
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.showsSidebarAttentionBanner, true)
    }

    /// The sidebar column, with the notification bar pinned beneath it.
    ///
    /// The inset belongs to *this column*, not to the split view around it. Attached
    /// outside, it laid the bar across the whole window: the sidebar's own scroll
    /// view never learned about it, so the last rows of the last section - System's
    /// Settings among them - sat under a bar that swallowed their taps. Attached
    /// here, UIKit insets the list's content by the bar's height, so those rows
    /// scroll clear of it, and the columns beside it keep their full height instead
    /// of being shortened by chrome that does not belong to them.
    private func sidebarColumn(services: AppServices, downloadBadge: Int) -> some View {
        sidebarList(downloadBadge: downloadBadge)
            .safeAreaInset(edge: .top) {
                sidebarAttentionBanner
            }
            .safeAreaInset(edge: .bottom) {
                sidebarNotificationBar(services: services)
            }
            .refreshesConfigurationAudit(forContextualBanner: true)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
    }

    /// The setup-attention banner, at the top of the sidebar rather than on each
    /// screen it concerns.
    ///
    /// This chrome has somewhere better to put it than the compact one does. On
    /// iPhone the banner has to live on the screen the finding is about, because that
    /// screen is the whole window and there is nowhere else; here the sidebar is
    /// always on show, so one banner covers the app and is visible from wherever the
    /// user happens to be. It takes no topic for the same reason - it speaks for
    /// every finding, not for whichever screen is open.
    ///
    /// Tapping selects Setup Check rather than presenting the wizard as a sheet. The
    /// sidebar already has Setup Check as a destination, and a sheet covering the
    /// screen the user is reading, to show something they can also just navigate to,
    /// is the compact chrome's compromise rather than this one's.
    ///
    /// It occupies no height when the audit is clear - the banner renders nothing at
    /// all in that case, so the inset costs nothing.
    private var sidebarAttentionBanner: some View {
        ConfigurationAttentionBanner(topic: nil) {
            selectedTab = .setupCheck
        }
    }

    /// The notification bar, as the sidebar's own footer.
    ///
    /// The tab bar's bottom accessory has no equivalent in this chrome, and the
    /// notification bar is how the app surfaces failures app-wide - dropping it on
    /// iPad or Mac would quietly remove that.
    @ViewBuilder
    private func sidebarNotificationBar(services: AppServices) -> some View {
        if !isTabChromeHidden {
            #if os(macOS)
            NotificationTabBarAccessory()
                .environment(services.syncService)
                .environment(downloadsNavigator)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            #else
            NotificationTabBarAccessory()
                .environment(services.syncService)
                .environment(downloadsNavigator)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                // Glass, because here the bar floats over a column rather than
                // sitting in a tab bar that already has a material behind it - what
                // `tabViewBottomAccessory` gives the compact chrome for free.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            #endif
        }
    }

    /// The sidebar's own list. Searchable, which is the point: it replaces More's
    /// search field, and it filters destinations by name rather than making the user
    /// remember which hub a screen lives under.
    private func sidebarList(downloadBadge: Int) -> some View {
        // `List`'s single-selection initialiser takes an *optional* binding on iOS,
        // while `selectedTab` is never nil - the app always has a destination open.
        // The setter ignores a nil write rather than inventing an "SwiftUI selects
        // nothing" state the rest of the app has no representation for.
        let selection = Binding<RootTab?>(
            get: { selectedTab },
            set: {
                if let newValue = $0 {
                    sidebarScroll.capture(newValue, replacingColumns: selectedTab.wantsDetailColumn != newValue.wantsDetailColumn)
                    selectedTab = newValue
                }
            }
        )

        #if os(macOS)
        // A Mac sidebar is already a native, continuously scrollable outline-style
        // list. Wrapping it in ScrollViewReader makes SwiftUI install a second
        // scrolling coordinator around the NSScrollView; after clicking a row that
        // coordinator can retain the wheel/trackpad gesture and the list appears
        // frozen. Mac never needs the restoration below because changing a
        // destination does not replace its split-view shape the way iPad does.
        return sidebarListContent(selection: selection, downloadBadge: downloadBadge)
            .modifier(SidebarListChrome(search: $sidebarSearch, placement: sidebarSearchPlacement))
        #else
        let detailColumn = selectedTab.wantsDetailColumn
        return ScrollViewReader { proxy in
            sidebarListContent(selection: selection, downloadBadge: downloadBadge) { row in
                SidebarRowRestorationModifier(
                    row: row,
                    detailColumn: detailColumn,
                    state: sidebarScroll,
                    proxy: proxy
                )
            }
            .modifier(SidebarListChrome(search: $sidebarSearch, placement: sidebarSearchPlacement))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                sidebarScroll.viewportFrame = $0
            }
        }
        #endif
    }

    @ViewBuilder
    private func sidebarListContent<RowModifier: ViewModifier>(
        selection: Binding<RootTab?>,
        downloadBadge: Int,
        rowModifier: @escaping (RootTab) -> RowModifier
    ) -> some View {
        List(selection: selection) {
            if isSearchingSidebar {
                sidebarSearchResults
            } else {
                ForEach(SidebarSection.allCases) { section in
                    Section(isExpanded: expansionBinding(for: section)) {
                        ForEach(section.rows, id: \.self) { row in
                            sidebarRow(row, badge: row == .downloads ? downloadBadge : 0)
                                .modifier(rowModifier(row))
                        }
                    } header: {
                        Text(section.title)
                    }
                }
            }
        }
    }

    private func sidebarListContent(
        selection: Binding<RootTab?>,
        downloadBadge: Int
    ) -> some View {
        sidebarListContent(
            selection: selection,
            downloadBadge: downloadBadge,
            rowModifier: { _ in EmptyModifier() }
        )
    }

    private var sidebarSearchPlacement: SearchFieldPlacement {
        #if os(macOS)
        .sidebar
        #else
        .navigationBarDrawer(displayMode: .always)
        #endif
    }

    /// Whether a section is open, remembered across launches.
    ///
    /// Thirty rows is a lot to re-collapse every launch, and a section someone has
    /// closed is a statement about what they use rather than transient view state.
    /// Stored as the set of *collapsed* sections so the default - a fresh install,
    /// with nothing stored - is everything open.
    private func expansionBinding(for section: SidebarSection) -> Binding<Bool> {
        Binding(
            get: { !collapsedSidebarSections.contains(section.rawValue) },
            set: { isExpanded in
                var collapsed = collapsedSidebarSections
                if isExpanded {
                    collapsed.remove(section.rawValue)
                } else {
                    collapsed.insert(section.rawValue)
                }
                collapsedSidebarSections = collapsed
            }
        )
    }

    private var isSearchingSidebar: Bool {
        !sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The sidebar's search results.
    ///
    /// Deliberately the *same* index More searches, rather than a filter over the
    /// eleven sidebar rows. On iPad the sidebar's field is the only search there is -
    /// More, which used to own one, is not in this chrome - so narrowing it to
    /// destination names would have lost every screen that is not itself a sidebar
    /// row: quality profiles, root folders, remote path mappings, news servers. The
    /// whole point of searching is to reach those without knowing which hub they
    /// live under.
    @ViewBuilder
    private var sidebarSearchResults: some View {
        let query = sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = MoreSearchIndex.results(for: query)

        if results.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("No settings or features match \"\(query)\".")
            )
        } else {
            Section("Results") {
                ForEach(results) { entry in
                    Button {
                        open(entry)
                    } label: {
                        MoreSearchResultRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Opens a search result on the hub that owns it.
    ///
    /// The push goes onto that hub's own stack, so the screen arrives with the hub
    /// behind it and a working way back - the same place it would have been reached
    /// from by hand.
    private func open(_ entry: MoreSearchIndexEntry) {
        sidebarSearch = ""

        guard let destination = entry.destination else {
            // Index entries with no destination are Downloads-tab routes. Queue the
            // route first; DownloadsView applies it on arrival, exactly as More's own
            // results do.
            if let route = entry.downloadsRoute {
                downloadsNavigator.show(route)
            }
            selectedTab = .downloads
            return
        }

        let owner = RootTab.owningSidebarDestination(for: destination, category: entry.category)
        selectedTab = owner
        // A row that *is* the destination roots its own stack at it, so pushing it
        // again would show the same screen twice with a Back button between them.
        pathBinding(for: owner).wrappedValue = owner.moreRoot == destination ? [] : [destination]
    }

    /// A sidebar row, or nothing when the search field excludes it.
    @ViewBuilder
    private func sidebarRow(_ destination: RootTab, badge: Int = 0) -> some View {
        if sidebarSearchMatches(destination) {
            Label(destination.displayName, systemImage: destination.systemImage)
                .badge(badge)
                .tag(destination)
                .id(destination)
                .accessibilityIdentifier(destination.navigationIdentifier)
        }
    }

    private func sidebarSearchMatches(_ destination: RootTab) -> Bool {
        let query = sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return destination.displayName.localizedCaseInsensitiveContains(query)
    }

    /// The middle column: the list for whichever destination is selected.
    ///
    /// Each of these registers its own `navigationDestination`, and that is fine
    /// here - a link tapped in this column is routed by the split view into the
    /// detail column beside it.
    @ViewBuilder
    private func contentColumn(for destination: RootTab, services: AppServices) -> some View {
        switch destination {
        case .downloads:
            downloadsRoot(services: services, detailSelection: $downloadSelection)
        case .series:
            SonarrSeriesListView(detailSelection: $seriesSelection)
                .environment(arrServiceManager)
                .environment(services.syncService)
                .environment(services.torrentService)
                .environment(sabnzbdServiceManager)
        case .movies:
            RadarrMovieListView(detailSelection: $moviesSelection)
                .environment(arrServiceManager)
                .environment(services.syncService)
                .environment(services.torrentService)
                .environment(sabnzbdServiceManager)
        case .indexers:
            moreStack(
                rootedAt: .prowlarrIndexers,
                path: pathBinding(for: .indexers),
                services: services,
                presentation: .contentColumn
            )
            .environment(indexerBrowser)
        case .downloadClients, .linkedApplications, .qualityProfiles, .tasks, .requests,
             .issues, .calendar, .missing, .users, .jellyfinLibraries, .libraryImport,
             .subtitles, .logs, .settings, .health:
            nativeSidebarColumn(for: destination, services: services, column: .content)
        case .search:
            // `.contentColumn`, because this column *is* inside the split view's
            // navigation container. SearchView's own `NavigationStack` nested here
            // took its search field with it - `.searchable` puts the field in its
            // container's bar, and the nested stack's bar is not the one this column
            // draws, so Search had no field at all on iPad.
            searchRoot(services: services, presentation: .contentColumn)
        default:
            moreStack(
                rootedAt: destination.moreRoot,
                path: pathBinding(for: destination),
                services: services,
                presentation: .contentColumn
            )
        }
    }

    /// Opens a title in the library column's detail pane.
    ///
    /// Installed only on the three-column layout, which is the only place a detail
    /// pane exists. A cast sheet that offers "and they were also in this" has to land
    /// somewhere: on iPhone it pushes, because the screen you are on is the whole
    /// window; here the list is still beside you, so the right move is to change what
    /// the pane is showing rather than to stack a third title on top of the second.
    private var selectLibraryTitle: ((ArrMergeKey) -> Void)? {
        { key in
            switch key.serviceType {
            case .sonarr:
                seriesSelection = key
                selectedTab = .series
            case .radarr:
                moviesSelection = key
                selectedTab = .movies
            case .prowlarr, .bazarr:
                break
            }
        }
    }

    /// The detail column: what a selection from the middle column opens into.
    ///
    /// The library destinations put a placeholder here and let their own pushes fill
    /// it. The More-derived screens need a real `NavigationStack` bound to their
    /// path, because they are also navigated to programmatically - by the
    /// `navigateToX` environment actions and by deep links - and an `append` only
    /// arrives somewhere if a stack is driving that path.
    @ViewBuilder
    private func detailColumn(for destination: RootTab, services: AppServices) -> some View {
        switch destination {
        case .downloads:
            // Rendered as this column's *root*, keyed by the selection - never pushed
            // into it. A push from the content column survives a change of sidebar
            // destination, so a download opened here used to still be sitting on top
            // of the detail column after switching to Series or Search.
            switch downloadSelection {
            case .torrent(let hash):
                TorrentDetailView(torrentHash: hash)
                    .id(hash)
                    .environment(services.syncService)
                    .environment(services.torrentService)
            case .sabJob(let id, let name):
                SABnzbdJobDetailView(jobID: id, fallbackName: name)
                    .id(id)
                    .environment(sabnzbdServiceManager)
            case nil:
                ContentUnavailableView("Select a download", systemImage: "tray.and.arrow.down")
            }
        case .series:
            // A detail view builds its own view model from the service manager -
            // the same thing `arrMediaNavigationDestinations` does for every pushed
            // Arr detail - so the detail column does not need a handle on the list's.
            if let seriesSelection {
                SonarrSeriesDetailView(
                    mergeKey: seriesSelection,
                    viewModel: SonarrViewModel(
                        serviceManager: arrServiceManager,
                        // Seeded from the app-wide library cache, exactly as
                        // `arrMediaNavigationDestinations` seeds every pushed Arr
                        // detail. A bare view model starts with an empty library, so
                        // the detail cannot resolve its merge key and renders
                        // "Series Not Found" until its own fetch lands.
                        preloadedSeries: arrServiceManager.calendarViewModel?.sonarrSeries ?? [],
                        jellyfinManager: jellyfinServiceManager
                    )
                )
                .id(seriesSelection)
                .environment(services.syncService)
            } else {
                ContentUnavailableView("Select a series", systemImage: ServiceIdentity.sonarr.tabSystemImage)
            }
        case .movies:
            if let moviesSelection {
                RadarrMovieDetailView(
                    mergeKey: moviesSelection,
                    viewModel: RadarrViewModel(
                        serviceManager: arrServiceManager,
                        preloadedMovies: arrServiceManager.calendarViewModel?.radarrMovies ?? [],
                        jellyfinManager: jellyfinServiceManager
                    )
                )
                .id(moviesSelection)
                .environment(services.syncService)
            } else {
                ContentUnavailableView("Select a movie", systemImage: ServiceIdentity.radarr.tabSystemImage)
            }
        case .indexers:
            ProwlarrIndexerListView(showsSelectedIndexer: true)
                .environment(indexerBrowser)
                .environment(arrServiceManager)
        case .downloadClients, .linkedApplications, .qualityProfiles, .tasks, .requests,
             .issues, .calendar, .missing, .users, .jellyfinLibraries, .libraryImport,
             .subtitles, .logs, .settings, .health:
            nativeSidebarColumn(for: destination, services: services, column: .detail)
        case .search:
            ContentUnavailableView("Search Trawl", systemImage: "magnifyingglass")
        default:
            moreStack(
                rootedAt: destination.moreRoot,
                path: pathBinding(for: destination),
                services: services,
                presentation: .detailColumn
            )
        }
    }

    /// Each affected screen is instantiated once per native column, with only its
    /// selection (and any shared live model) owned above the split view.
    private func nativeSidebarColumn(
        for destination: RootTab,
        services: AppServices,
        column: NavigationSplitViewColumn
    ) -> some View {
        moreStack(
            rootedAt: destination.moreRoot,
            path: pathBinding(for: destination),
            services: services,
            presentation: column == .detail ? .stack : .contentColumn
        )
        .environment(\.sidebarNavigationColumn, column)
        .environment(\.hasDetailPane, column == .content)
        .environment(moreColumnSelection(for: destination))
        .environment(calendarSelection)
        .environment(missingSelection)
        .environment(qualityProfileBrowser)
        .environment(importLocationBrowser)
        .environment(healthBrowser)
        .environment(requestBrowser)
        .environment(issueBrowser)
        .environment(userBrowser)
        .environment(jellyfinLibraryBrowser)
        .id(destination)
    }

    private func moreColumnSelection(for destination: RootTab) -> TrawlColumnSelection<MoreDestination>? {
        switch destination {
        case .downloadClients: downloadClientSelection
        case .linkedApplications: linkedApplicationSelection
        case .tasks: taskSelection
        case .subtitles: subtitleSelection
        case .logs: logSelection
        case .settings: settingsSelection
        default: nil
        }
    }

    /// One path per destination. `.more` keeps `morePath` so the compact chrome and
    /// any deep link that targets it stay pointed at the same array.
    private func pathBinding(for destination: RootTab) -> Binding<[MoreDestination]> {
        destination == .more ? $morePath : sidebarPath(for: destination)
    }

    private func downloadsRoot(
        services: AppServices,
        detailSelection: Binding<DownloadDetailSelection?>? = nil
    ) -> some View {
        DownloadsView(detailSelection: detailSelection)
            .environment(services)
            .environment(services.syncService)
            .environment(services.torrentService)
            .environment(arrServiceManager)
            .environment(sabnzbdServiceManager)
            .environment(downloadsNavigator)
    }

    /// Shared by the compact Search tab and the regular chrome's middle column, which
    /// need different navigation containers - hence the parameter. The tab is the root
    /// of its own stack; the column is already inside the split view's.
    private func searchRoot(
        services: AppServices,
        presentation: SearchView.Presentation = .stack
    ) -> some View {
        SearchView(presentation: presentation)
            .environment(arrServiceManager)
            .environment(services.syncService)
            .environment(services.torrentService)
    }


    private func sidebarPath(for destination: RootTab) -> Binding<[MoreDestination]> {
        Binding(
            get: { sidebarPaths[destination] ?? [] },
            set: { sidebarPaths[destination] = $0 }
        )
    }

    /// One `MoreView` stack, wired identically wherever it is rooted.
    ///
    /// The tab bar's More and each of the sidebar's promoted destinations are the
    /// same view with a different root, so the long environment chain below is
    /// written once. It used to sit inline on the More tab; duplicating it seven
    /// times for the sidebar would have been seven chances for one screen to be
    /// missing an injection nothing catches until someone navigates into it.
    @ViewBuilder
    private func moreStack(
        rootedAt root: MoreDestination?,
        path: Binding<[MoreDestination]>,
        services: AppServices,
        presentation: MoreView.Presentation = .stack
    ) -> some View {
        MoreView(
            appServices: appServices,
            path: path,
            isQBittorrentConnecting: isConnecting,
            onRetryQBittorrent: { initializeServices() },
            root: root,
            presentation: presentation
        )
            // `AppServices` itself, not just the services hanging off it. The
            // qBittorrent RSS screens read it out of the environment, and reaching
            // them through here - the sidebar's qBittorrent row, or More on iPhone -
            // used to trap on a missing observable, because only `downloadsRoot`
            // was injecting it.
            .environment(services)
            .environment(services.syncService)
            .environment(services.torrentService)
            .environment(arrServiceManager)
            .environment(sabnzbdServiceManager)
            .environment(cleanuparrServiceManager)
            .environment(downloadsNavigator)
            .environment(\.navigateToSeriesTab) { selectedTab = .series }
            .environment(\.navigateToMoviesTab) { selectedTab = .movies }
            .environment(\.navigateToDownloadsTab) { selectedTab = .downloads }
            // Settings destinations route by chrome - see `openSettings`.
            .environment(\.navigateToQbittorrentSettings) { openSettings(.qbittorrentSettings, from: path) }
            .environment(\.navigateToSABnzbdSettings) { openSettings(.sabnzbdSettings, from: path) }
            .environment(\.navigateToSonarrSettings) { openSettings(.sonarrSettings, from: path) }
            .environment(\.navigateToRadarrSettings) { openSettings(.radarrSettings, from: path) }
            .environment(\.navigateToProwlarrSettings) { openSettings(.prowlarrSettings, from: path) }
            .environment(\.navigateToBazarrSettings) { openSettings(.bazarrSettings, from: path) }
            .environment(\.navigateToSeerrSettings) { openSettings(.seerrSettings, from: path) }
            .environment(\.navigateToSeerrIssues) { path.wrappedValue.append(.seerrIssues) }
            .environment(\.navigateToJellyfinSettings) { openSettings(.jellyfinSettings, from: path) }
            .environment(\.navigateToCleanuparrSettings) { openSettings(.cleanuparrSettings, from: path) }
            .environment(\.navigateToSettings) { openSettings(nil, from: path) }
    }

    /// Takes the user to a settings screen, by whichever route the chrome provides.
    ///
    /// On the tab chrome this pushes onto `path` - the stack this copy is driving,
    /// and deliberately not `morePath`, because on iPad those are different arrays
    /// and a push onto the wrong one lands on a stack nobody is looking at.
    ///
    /// On the sidebar chrome pushing is wrong twice over. Settings is a destination
    /// of its own there, so pushing it inside Media Server buried a second copy of it
    /// under a screen it has nothing to do with. And the service-specific
    /// destinations were being appended to stacks that register no
    /// `navigationDestination` for them - Library Management → Jellyfin Libraries →
    /// "Open Settings" appended `.jellyfinSettings` to Library Management's path and
    /// nothing happened at all. So the sidebar route changes destination instead, and
    /// puts the requested screen on Settings' own stack.
    private func openSettings(_ destination: MoreDestination?, from path: Binding<[MoreDestination]>) {
        #if os(iOS)
        guard hSizeClass == .regular else {
            path.wrappedValue.append(destination ?? .settings)
            return
        }
        showSettings(destination)
        #else
        showSettings(destination)
        #endif
    }

    /// Puts the sidebar chrome on Settings, showing the requested service in its
    /// detail pane.
    ///
    /// Settings is a native split view here, so the service screens are a *selection*
    /// rather than a push: appending to Settings' stack would have pushed the screen
    /// over the list column beside the pane it belongs in.
    private func showSettings(_ destination: MoreDestination?) {
        sidebarPath(for: .settings).wrappedValue = []
        settingsSelection.selection = destination
        selectedTab = .settings
    }

    /// Single entry point for every URL that reaches the app - external links,
    /// opened files, and tapped push notifications.
    private func handleIncomingURL(_ url: URL) {
        // NZBs arrive as a file the system hands us ("Open in Trawl" from Files
        // or Safari's download tray), or as an http(s) link to a .nzb. Neither
        // has a scheme of its own, so they're matched before the switch.
        if let nzb = NZBDeepLink(openedURL: url) ?? NZBDeepLink(trawlURL: url) {
            nzbDeepLink = nzb
            return
        }

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
                    pendingDeepLink = PendingDeepLink(
                        tab: .downloads,
                        morePath: [],
                        downloadsSection: Self.downloadsSection(from: url)
                    )
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
                    if let section = Self.downloadsSection(from: url) {
                        downloadsNavigator.show(section)
                    }
                case "calendar":
                    selectedTab = .more
                    morePath = [.calendar]
                case "health":
                    selectedTab = .more
                    morePath = [.health]
                case "seerr-requests":
                    // A pending-request push exists to get a decision, so it opens
                    // the notification sheet's Pending Approval section rather than
                    // the management list three levels into More. Browsing every
                    // request is a different intent and still lives there.
                    inAppNotificationCenter.showRecentNotifications()
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

    // MARK: - NZB deep links

    private var hasSABnzbdServer: Bool { !sabnzbdProfiles.isEmpty }

    /// Hands an incoming NZB straight to SABnzbd. There's no torrent-style staging
    /// sheet for Usenet deep links - SABnzbd's own defaults cover category and
    /// priority, so a confirm-and-send is the whole flow.
    private func send(_ link: NZBDeepLink) {
        guard !isSendingNZB else { return }
        isSendingNZB = true

        Task {
            defer { isSendingNZB = false }

            if !sabnzbdServiceManager.isConnected {
                await sabnzbdServiceManager.initialize(from: sabnzbdProfiles)
            }

            guard sabnzbdServiceManager.isConnected else {
                nzbStatusMessage = sabnzbdServiceManager.connectionError
                    ?? "Couldn't reach SABnzbd. Check the server in \(MoreDestination.sabnzbdSettings.userFacingPath)."
                return
            }

            do {
                switch link.payload {
                case .url(let url):
                    try await sabnzbdServiceManager.addURL(url)
                case .file(let data, let name):
                    try await sabnzbdServiceManager.addNZB(data: data, filename: name)
                }
                nzbStatusMessage = "Sent \(link.displayName) to SABnzbd."
                selectedTab = .downloads
            } catch {
                nzbStatusMessage = error.localizedDescription
            }
        }
    }


    #if os(macOS)
    private func isDefaultMagnetHandler() -> Bool {
        MagnetLinkHandler.isDefault
    }

    private func setAsDefaultMagnetHandler() {
        Task { @MainActor in
            try? await MagnetLinkHandler.setAsDefault()
        }
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

    private var cleanuparrProfile: CleanuparrServiceProfile? {
        cleanuparrProfiles.first(where: { $0.isEnabled }) ?? cleanuparrProfiles.first
    }

    private var hasConfiguredAnyService: Bool {
        activeServer != nil || sabnzbdProfile != nil || sonarrProfile != nil || radarrProfile != nil || prowlarrProfile != nil || bazarrProfile != nil || seerrProfile != nil || jellyfinProfile != nil || cleanuparrProfile != nil
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

    private var cleanuparrProfilesSyncKey: String {
        cleanuparrProfiles
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
            sabnzbdProfilesSyncKey,
            cleanuparrProfilesSyncKey
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
                // presented once a retry reconnects - let the user know it wasn't lost.
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

        // `didRejectCredentials` and not merely `!isConnected`: a 401 clears the
        // connection, which re-keys this retry loop and lands straight back here,
        // so the app reconnected to the server that had just rejected its key. A
        // wrong key does not fix itself on a timer; the user has been told to
        // update it in Settings, and saving there connects directly.
        if !sabnzbdProfiles.isEmpty && !sabnzbdServiceManager.isConnected
            && !sabnzbdServiceManager.isConnecting && !sabnzbdServiceManager.didRejectCredentials {
            await sabnzbdServiceManager.initialize(from: sabnzbdProfiles)
        }

        if !cleanuparrProfiles.isEmpty && !cleanuparrServiceManager.isConnected && !cleanuparrServiceManager.isConnecting {
            await cleanuparrServiceManager.initialize(from: cleanuparrProfiles)
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

/// An NZB arriving from outside the app. There is no `nzb:` URL scheme worth
/// registering - nothing on iOS emits one - so the two shapes that actually
/// reach us are a `file:` URL (Files / Safari downloads / "Open in Trawl", via
/// the NZB document type declared in `TrawlApp-Info.plist`) and an http(s) link
/// whose path ends in `.nzb`. `trawl://add-nzb?url=…` is accepted too, for
/// Shortcuts.
private struct NZBDeepLink {
    enum Payload {
        case url(URL)
        case file(data: Data, name: String)
    }

    let payload: Payload
    let displayName: String

    init?(openedURL url: URL) {
        if url.isFileURL {
            guard Self.isNZBFileName(url.lastPathComponent) else { return nil }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            self.payload = .file(data: data, name: url.lastPathComponent)
            self.displayName = url.lastPathComponent
            return
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard Self.isNZBFileName(url.lastPathComponent) else { return nil }
        self.payload = .url(url)
        self.displayName = url.lastPathComponent
    }

    init?(trawlURL url: URL) {
        guard url.scheme?.lowercased() == "trawl", url.host?.lowercased() == "add-nzb" else {
            return nil
        }
        guard
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name.lowercased() == "url" })?
                .value,
            let target = URL(string: raw)
        else { return nil }

        self.payload = .url(target)
        self.displayName = target.lastPathComponent.isEmpty ? raw : target.lastPathComponent
    }

    /// Mirrors `AddTorrentSheet.isNZBFileName` - SABnzbd also serves gzipped NZBs.
    private static func isNZBFileName(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        return lowercased.hasSuffix(".nzb") || lowercased.hasSuffix(".nzb.gz")
    }
}

extension ContentView {
    /// `trawl://downloads/issues` or `trawl://downloads?section=issues` - both
    /// forms resolve to a `DownloadSection`. Absent or unknown means "leave the
    /// segment alone".
    fileprivate static func downloadsSection(from url: URL) -> DownloadSection? {
        let pathSegment = url.path
            .split(separator: "/")
            .first
            .map(String.init)
        let querySegment = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.lowercased() == "section" }?
            .value
        guard let raw = pathSegment ?? querySegment else { return nil }
        return DownloadSection.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
    }
}

private struct PendingDeepLink {
    let tab: RootTab
    let morePath: [MoreDestination]
    /// Only meaningful for `.downloads`; steers the segment bar once the tab is up.
    var downloadsSection: DownloadSection?
}

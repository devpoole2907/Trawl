import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
import CoreServices
#endif

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query private var servers: [ServerProfile]
    @State private var showOnboarding = false
    @State private var appServices: AppServices?
    @State private var connectionError: String?
    @State private var isConnecting = false
    @State private var selectedTab: RootTab = .torrents
    @State private var searchText = ""
    @State private var magnetDeepLink: MagnetDeepLink?
    @State private var pendingMagnetURL: String?  // holds URL during cold launch before services are ready
    #if os(macOS)
    @AppStorage("hasPromptedForMagnetHandler") private var hasPromptedForMagnetHandler = false
    @State private var showMagnetHandlerPrompt = false
    #endif

    var body: some View {
        Group {
            if let services = appServices {
                connectedContent(services: services)
            } else if isConnecting {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Connecting to qBittorrent")
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
                    Button("Retry", systemImage: "arrow.clockwise") {
                        initializeServices()
                    }
                    Button("Edit Server", systemImage: "server.rack") {
                        showOnboarding = true
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Welcome to Trawl", systemImage: "externaldrive.badge.wifi")
                } description: {
                    Text("Connect to your qBittorrent server to get started.")
                } actions: {
                    Button("Add Server", systemImage: "plus") {
                        showOnboarding = true
                    }
                }
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet(serverProfile: activeServer, onComplete: { initializeServices() })
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
            guard url.scheme?.lowercased() == "magnet" else { return }
            if appServices != nil {
                magnetDeepLink = MagnetDeepLink(url: url.absoluteString)
            } else {
                pendingMagnetURL = url.absoluteString
            }
        }
        .task {
            if servers.isEmpty {
                showOnboarding = true
            } else {
                initializeServices()
            }
        }
    }

    @ViewBuilder
    private func connectedContent(services: AppServices) -> some View {
        if horizontalSizeClass == .compact {
            // iPhone: dedicated search tab activated by tapping the search icon
            TabView(selection: $selectedTab) {
                Tab("Torrents", systemImage: "arrow.down.circle", value: RootTab.torrents) {
                    NavigationStack {
                        TorrentListView(title: activeServer?.displayName ?? "Trawl", searchText: $searchText, showsSearchField: false)
                            .environment(services.syncService)
                            .environment(services.torrentService)
                    }
                }

                Tab(value: RootTab.search, role: .search) {
                    NavigationStack {
                        TorrentListView(title: activeServer?.displayName ?? "Trawl", searchText: $searchText, showsSearchField: true)
                            .environment(services.syncService)
                            .environment(services.torrentService)
                            .searchable(text: $searchText, prompt: "Search torrents")
                    }
                }

                Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                    NavigationStack {
                        SettingsView(showsDoneButton: false)
                            .environment(services.syncService)
                            .environment(services.torrentService)
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
            #endif
            .tabViewSearchActivation(.searchTabSelection)
            .onChange(of: selectedTab) { _, newTab in
                if newTab != .search { searchText = "" }
            }
            .sheet(item: $magnetDeepLink) { link in
                AddTorrentSheet(initialMagnetURL: link.url)
                    .environment(services.syncService)
                    .environment(services.torrentService)
            }
        } else {
            // iPad/macOS: no search tab — persistent search bar in the navigation toolbar
            TabView(selection: $selectedTab) {
                Tab("Torrents", systemImage: "arrow.down.circle", value: RootTab.torrents) {
                    NavigationStack {
                        TorrentListView(title: activeServer?.displayName ?? "Trawl", searchText: $searchText, showsSearchField: true)
                            .environment(services.syncService)
                            .environment(services.torrentService)
                    }
                    .searchable(text: $searchText, prompt: "Search torrents")
                }

                Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                    NavigationStack {
                        SettingsView(showsDoneButton: false)
                            .environment(services.syncService)
                            .environment(services.torrentService)
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

    private func initializeServices() {
        guard let server = activeServer else {
            showOnboarding = true
            return
        }

        isConnecting = true
        connectionError = nil

        Task {
            do {
                let username = try await KeychainHelper.shared.read(key: server.usernameKey) ?? ""
                let password = try await KeychainHelper.shared.read(key: server.passwordKey) ?? ""

                guard !username.isEmpty, !password.isEmpty else {
                    connectionError = "Credentials not found. Please re-enter your server details."
                    isConnecting = false
                    return
                }

                let services = try await AppServices.build(from: server, username: username, password: password)

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
}

private struct MagnetDeepLink: Identifiable {
    let id = UUID()
    let url: String
}

private enum RootTab: Hashable {
    case torrents
    case search
    case settings
}

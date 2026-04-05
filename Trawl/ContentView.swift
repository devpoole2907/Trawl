import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [ServerProfile]
    @State private var showOnboarding = false
    @State private var appServices: AppServices?
    @State private var connectionError: String?
    @State private var isConnecting = false
    @State private var selectedTab: RootTab = .torrents
    @State private var searchText = ""

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
        .tabViewSearchActivation(.searchTabSelection)
    }

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
            } catch {
                connectionError = error.localizedDescription
                isConnecting = false
            }
        }
    }
}

private enum RootTab: Hashable {
    case torrents
    case search
    case settings
}

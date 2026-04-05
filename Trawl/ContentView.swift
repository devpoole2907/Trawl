import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [ServerProfile]
    @State private var showOnboarding = false
    @State private var appServices: AppServices?
    @State private var connectionError: String?
    @State private var isConnecting = false

    var body: some View {
        Group {
            if let services = appServices {
                TorrentListView()
                    .environment(services.syncService)
                    .environment(services.torrentService)
            } else if isConnecting {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Connecting to server...")
                        .foregroundStyle(.secondary)
                }
            } else if let error = connectionError {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Connection Failed")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { initializeServices() }
                        .buttonStyle(.borderedProminent)
                    Button("Edit Server") { showOnboarding = true }
                        .buttonStyle(.bordered)
                }
                .padding()
            } else {
                // Empty state — no server configured
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.wifi")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Welcome to Trawl")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Connect to your qBittorrent server to get started.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add Server") { showOnboarding = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet(onComplete: { initializeServices() })
        }
        .task {
            if servers.isEmpty {
                showOnboarding = true
            } else {
                initializeServices()
            }
        }
    }

    private func initializeServices() {
        guard let server = servers.first(where: { $0.isActive }) ?? servers.first else {
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
                isConnecting = false
            } catch {
                connectionError = error.localizedDescription
                isConnecting = false
            }
        }
    }
}

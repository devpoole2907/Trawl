import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @State private var viewModel = SettingsViewModel()
    @State private var showOnboarding = false

    var body: some View {
        NavigationStack {
            Form {
                // Server section
                Section("Server") {
                    if let server = viewModel.serverProfile {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(server.displayName)
                                    .font(.subheadline)
                                Text(server.hostURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if syncService.isPolling {
                                Image(systemName: "circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }

                        if let lastConnected = server.lastConnected {
                            HStack {
                                Text("Last Connected")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(lastConnected.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                            }
                        }

                        Button("Edit Server") {
                            showOnboarding = true
                        }
                    } else {
                        Button("Add Server") {
                            showOnboarding = true
                        }
                    }
                }

                // Polling section
                Section("Polling") {
                    VStack(alignment: .leading) {
                        Text("Refresh Interval: \(String(format: "%.0f", viewModel.pollingInterval))s")
                        Slider(value: $viewModel.pollingInterval, in: 1...10, step: 1) {
                            Text("Polling Interval")
                        }
                        .onChange(of: viewModel.pollingInterval) {
                            viewModel.updatePollingInterval()
                        }
                    }
                }

                // Notifications section
                Section("Notifications") {
                    Toggle("Download Notifications", isOn: $viewModel.notificationsEnabled)
                        .onChange(of: viewModel.notificationsEnabled) {
                            Task { await viewModel.toggleNotifications() }
                        }

                    if viewModel.notificationsEnabled && !viewModel.notificationPermissionGranted {
                        Label("Notification permission not granted. Enable in Settings.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // About section
                Section("About") {
                    if let appVersion = viewModel.appVersion {
                        HStack {
                            Text("App Version")
                            Spacer()
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let qbVersion = viewModel.qbVersion {
                        HStack {
                            Text("qBittorrent Version")
                            Spacer()
                            Text(qbVersion)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Connection")
                        Spacer()
                        Text(syncService.serverState?.connectionStatus ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }

                    if let dhtNodes = syncService.serverState?.dhtNodes {
                        HStack {
                            Text("DHT Nodes")
                            Spacer()
                            Text("\(dhtNodes)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet(onComplete: {
                    Task { await viewModel.loadSettings(modelContext: modelContext) }
                })
            }
            .task {
                viewModel.configure(torrentService: torrentService, syncService: syncService)
                await viewModel.loadSettings(modelContext: modelContext)
            }
        }
    }
}

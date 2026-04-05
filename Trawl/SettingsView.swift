import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @State private var viewModel = SettingsViewModel()
    @State private var showOnboarding = false
    let showsDoneButton: Bool

    init(showsDoneButton: Bool = true) {
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let server = viewModel.serverProfile {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(server.displayName)
                                    .font(.subheadline)
                                Text(server.hostURL)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if syncService.isPolling {
                                Label("Connected", systemImage: "circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .labelStyle(.titleAndIcon)
                            }
                        }

                        if let lastConnected = server.lastConnected {
                            LabeledContent("Last Connected") {
                                Text(lastConnected.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline)
                            }
                        }

                        Button("Edit Server", systemImage: "server.rack") {
                            showOnboarding = true
                        }
                
                    } else {
                        Button("Add Server", systemImage: "plus") {
                            showOnboarding = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Update the qBittorrent Web UI address, credentials, or display name.")
                }

                Section("Polling") {
                    LabeledContent("Refresh Interval") {
                        Text("\(String(format: "%.0f", viewModel.pollingInterval))s")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Slider(value: $viewModel.pollingInterval, in: 1...10, step: 1) {
                            Text("Polling Interval")
                        }
                        .onChange(of: viewModel.pollingInterval) {
                            viewModel.updatePollingInterval()
                        }
                    }
                }

                Section("Notifications") {
                    Toggle("Download Notifications", isOn: $viewModel.notificationsEnabled)
                        .onChange(of: viewModel.notificationsEnabled) {
                            Task { await viewModel.toggleNotifications() }
                        }

                    if viewModel.notificationsEnabled && !viewModel.notificationPermissionGranted {
                        Label("Notification permission not granted. Enable in Settings.", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Connection Details") {
                    if let appVersion = viewModel.appVersion {
                        LabeledContent("App Version") {
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let qbVersion = viewModel.qbVersion {
                        LabeledContent("qBittorrent Version") {
                            Text(qbVersion)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Connection") {
                        Text(syncService.serverState?.connectionStatus ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }

                    if let dhtNodes = syncService.serverState?.dhtNodes {
                        LabeledContent("DHT Nodes") {
                            Text("\(dhtNodes)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet(serverProfile: viewModel.serverProfile, onComplete: {
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

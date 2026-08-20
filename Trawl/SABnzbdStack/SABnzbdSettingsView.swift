import SwiftData
import SwiftUI

struct SABnzbdSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Query private var profiles: [SABnzbdServiceProfile]
    @State private var showingConnectionSheet = false
    @State private var showRemoveConfirmation = false

    private var profile: SABnzbdServiceProfile? {
        profiles.first(where: { $0.isEnabled }) ?? profiles.first
    }

    var body: some View {
        List {
            Section {
                if let profile {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(profile.hostURL)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Label(
                            serviceManager.isConnected ? "Connected" : "Disconnected",
                            systemImage: "circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(serviceManager.isConnected ? .green : .red)
                    }

                    if let error = serviceManager.connectionError, !serviceManager.isConnected {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }

                    Button("Edit Server", systemImage: "pencil") {
                        showingConnectionSheet = true
                    }
                } else {
                    Button("Add SABnzbd Server", systemImage: "plus") {
                        showingConnectionSheet = true
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                if profile == nil {
                    Text("Connect SABnzbd to add and manage Usenet downloads in Trawl.")
                }
            }

            if let profile {
                Section("System Status") {
                    if let version = profile.serverVersion, !version.isEmpty {
                        LabeledContent("Version", value: version)
                    }
                    if let lastSynced = profile.lastSynced {
                        LabeledContent("Last Connected") {
                            Text(lastSynced.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if serviceManager.isRefreshing {
                        HStack {
                            ProgressView()
                            Text("Refreshing…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        Task { await serviceManager.connectService(profile) }
                    }
                    .disabled(serviceManager.isConnecting)
                }

                Section {
                    Button("Remove SABnzbd Server", systemImage: "trash", role: .destructive) {
                        showRemoveConfirmation = true
                    }
                    .confirmationDialog(
                        "Remove SABnzbd Server?",
                        isPresented: $showRemoveConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Remove", role: .destructive) {
                            Task { await removeProfile(profile) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes the saved SABnzbd connection and API key from Trawl.")
                    }
                }
            }
        }
        .navigationTitle("SABnzbd")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: syncKey) {
            await serviceManager.initialize(from: profiles)
        }
        .refreshable {
            if let profile {
                await serviceManager.connectService(profile)
            }
        }
        .sheet(isPresented: $showingConnectionSheet) {
            SABnzbdSetupSheet(profile: profile) {
                Task { await serviceManager.initialize(from: profiles) }
            }
        }
    }

    private var syncKey: String {
        profiles
            .map { "\($0.id.uuidString):\($0.hostURL):\($0.isEnabled)" }
            .sorted()
            .joined(separator: "|")
    }

    private func removeProfile(_ profile: SABnzbdServiceProfile) async {
        serviceManager.stopPolling()
        do {
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Keychain Warning",
                message: "The server was removed, but its API key could not be deleted. \(error.localizedDescription)"
            )
        }

        modelContext.delete(profile)
        do {
            try modelContext.save()
            serviceManager.disconnect()
        } catch {
            modelContext.rollback()
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Remove SABnzbd",
                message: error.localizedDescription
            )
        }
    }
}

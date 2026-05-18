import SwiftUI

struct JellyfinSystemInfoView: View {
    let apiClient: JellyfinAPIClient
    @Environment(JellyfinServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    @State private var systemInfo: JellyfinSystemInfo?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showRestartConfirmation = false
    @State private var showShutdownConfirmation = false

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let systemInfo {
                Section("Server") {
                    labeledRow("Server Name", systemInfo.serverName)
                    labeledRow("Version", systemInfo.version)
                    labeledRow("Operating System", systemInfo.operatingSystem)
                    labeledRow("Product", systemInfo.productName)
                }

                if let id = systemInfo.id {
                    Section("Instance") {
                        labeledRow("Server ID", id)
                    }
                }

                if let port = systemInfo.webSocketPortNumber {
                    Section("Networking") {
                        labeledRow("WebSocket Port", String(port))
                    }
                }
            } else if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }

            Section("Server Control") {
                Button(role: .destructive) {
                    showRestartConfirmation = true
                } label: {
                    Label("Restart Server", systemImage: "arrow.circlepath")
                }

                Button(role: .destructive) {
                    showShutdownConfirmation = true
                } label: {
                    Label("Shutdown Server", systemImage: "power")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .navigationTitle("System Info")
        .refreshable { await loadSystemInfo() }
        .task { await loadSystemInfo() }
        .confirmationDialog("Restart Server", isPresented: $showRestartConfirmation, titleVisibility: .visible) {
            Button("Restart", role: .destructive) {
                Task { await restartServer() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disconnect all active sessions. The server may take a moment to become available again.")
        }
        .confirmationDialog("Shutdown Server", isPresented: $showShutdownConfirmation, titleVisibility: .visible) {
            Button("Shutdown", role: .destructive) {
                Task { await shutdownServer() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disconnect all active sessions and power off the server.")
        }
    }

    @ViewBuilder
    private func labeledRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
                #if os(iOS)
                .contextMenu { Button("Copy") { UIPasteboard.general.string = value } }
                #endif
        }
    }

    private func loadSystemInfo() async {
        isLoading = true
        errorMessage = nil
        do {
            systemInfo = try await apiClient.getSystemInfo()
            serviceManager.updateCachedSystemInfo(systemInfo)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func restartServer() async {
        inAppNotificationCenter.showProgress(
            title: "Restarting Server",
            message: "Jellyfin is restarting…",
            key: "jellyfin_restart",
            source: .inApp
        )
        do {
            try await apiClient.restartServer()
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_restart",
                title: "Restart Initiated",
                message: "Jellyfin is restarting. It may be unavailable for a moment."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_restart",
                title: "Restart Failed",
                message: error.localizedDescription
            )
        }
    }

    private func shutdownServer() async {
        inAppNotificationCenter.showProgress(
            title: "Shutting Down",
            message: "Jellyfin is shutting down…",
            key: "jellyfin_shutdown",
            source: .inApp
        )
        do {
            try await apiClient.shutdownServer()
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_shutdown",
                title: "Shutdown Initiated",
                message: "Jellyfin is shutting down."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_shutdown",
                title: "Shutdown Failed",
                message: error.localizedDescription
            )
        }
    }
}

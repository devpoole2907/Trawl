import SwiftUI

struct ArrServiceConnectionStatusView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var showingSettings = false

    let serviceType: ArrServiceType
    let title: String?
    let message: String

    var body: some View {
        ConnectionStatusCard(
            identity: serviceType.serviceIdentity,
            title: title ?? (isConnecting ? "Connecting to \(serviceType.displayName)" : "\(serviceType.displayName) Unreachable"),
            message: message,
            isConnecting: isConnecting,
            retryTitle: "Retry Connection",
            editTitle: "Edit Server",
            presentation: .embedded,
            onRetry: { Task { await serviceManager.retry(serviceType) } },
            onEdit: {
                withAnimation(.snappy) {
                    showingSettings = true
                }
            }
        )
        .sheet(isPresented: $showingSettings) {
            ArrServiceSettingsSheet(serviceType: serviceType, isPresented: $showingSettings)
                .environment(serviceManager)
        }
    }

    private var isConnecting: Bool {
        serviceManager.isInitializing || serviceManager.isConnecting(serviceType)
    }
}

struct ArrServicesConnectionStatusView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var showingServers = false

    let services: [ArrServiceType]
    let title: String
    let message: String

    var body: some View {
        ConnectionStatusCard(
            identity: nil,
            title: isConnecting ? "Connecting to Services" : title,
            message: message,
            isConnecting: isConnecting,
            retryTitle: "Retry Connections",
            editTitle: "Edit Servers",
            presentation: .embedded,
            onRetry: retryServices,
            onEdit: {
                withAnimation(.snappy) {
                    showingServers = true
                }
            }
        )
        .sheet(isPresented: $showingServers) {
            ArrOfflineServicesSheet(isPresented: $showingServers, services: services)
                .environment(serviceManager)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }

    private var isConnecting: Bool {
        serviceManager.isInitializing || services.contains { serviceManager.isConnecting($0) }
    }

    private func retryServices() {
        Task {
            for service in services {
                await serviceManager.retry(service)
            }
        }
    }
}

struct ArrOfflineServicesSheet: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Binding var isPresented: Bool
    @State private var settingsService: ArrServiceType?

    let services: [ArrServiceType]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(offlineServices) { service in
                        ConnectionIssueRow(
                            identity: service.serviceIdentity,
                            title: isConnecting(service) ? "Connecting to \(service.displayName)" : "\(service.displayName) Unreachable",
                            message: message(for: service),
                            isConnecting: isConnecting(service),
                            actionStyle: .glassIcons,
                            onRetry: { Task { await serviceManager.retry(service) } },
                            onEdit: {
                                withAnimation(.snappy) {
                                    settingsService = service
                                }
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } footer: {
                    Text("Trawl retries disconnected services automatically while the app is active.")
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("Edit Servers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        withAnimation(.snappy) {
                            isPresented = false
                        }
                    }
                }
            }
            .animation(.snappy, value: offlineServices.map(\.rawValue).joined(separator: "|"))
        }
        .sheet(item: $settingsService) { service in
            ArrServiceSettingsSheet(serviceType: service, isPresented: Binding(
                get: { settingsService != nil },
                set: { isPresented in
                    if !isPresented {
                        withAnimation(.snappy) {
                            settingsService = nil
                        }
                    }
                }
            ))
            .environment(serviceManager)
        }
    }

    private var offlineServices: [ArrServiceType] {
        let offline = services.filter { !serviceManager.isConnected($0) }
        return offline.isEmpty ? services : offline
    }

    private func isConnecting(_ service: ArrServiceType) -> Bool {
        serviceManager.isInitializing || serviceManager.isConnecting(service)
    }

    private func message(for service: ArrServiceType) -> String {
        serviceManager.connectionError(service) ?? "Unable to reach your configured \(service.displayName) server."
    }
}

struct ArrServiceSettingsSheet: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    let serviceType: ArrServiceType
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ArrServiceSettingsView(serviceType: serviceType)
                .environment(serviceManager)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            withAnimation(.snappy) {
                                isPresented = false
                            }
                        }
                    }
                }
        }
    }
}

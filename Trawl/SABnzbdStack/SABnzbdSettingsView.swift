import SwiftData
import SwiftUI

struct SABnzbdSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Query private var profiles: [SABnzbdServiceProfile]
    @State private var showingConnectionSheet = false
    @State private var showRemoveConfirmation = false

    @State private var speedLimitPercent = 0
    @State private var didLoadSpeedLimit = false
    @State private var isUpdatingSpeedLimit = false
    @State private var pauseDurationMinutes = 15
    @State private var isPausingForDuration = false
    @State private var showClearHistoryConfirmation = false
    @State private var settingsErrorAlert: ErrorAlertItem?

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
                    Picker("Speed Limit", selection: $speedLimitPercent) {
                        ForEach(speedLimitOptions(including: speedLimitPercent), id: \.self) { percent in
                            Text(speedLimitOptionLabel(percent)).tag(percent)
                        }
                    }
                    .disabled(isUpdatingSpeedLimit)
                    .onChange(of: speedLimitPercent) {
                        guard didLoadSpeedLimit, !isUpdatingSpeedLimit else { return }
                        Task { await updateSpeedLimit(speedLimitPercent) }
                    }
                    // The picker is the only thing showing this value now, so it
                    // has to follow the server rather than only local edits -
                    // otherwise a change made in SABnzbd's own UI leaves it stale.
                    .onChange(of: serviceManager.queue?.speedLimit) { _, serverValue in
                        guard let serverValue, didLoadSpeedLimit, !isUpdatingSpeedLimit else { return }
                        speedLimitPercent = serverValue
                    }
                } header: {
                    Text("Speed Limit")
                } footer: {
                    Text(speedLimitFooter)
                }

                Section {
                    Picker("Duration", selection: $pauseDurationMinutes) {
                        ForEach([5, 15, 30, 60, 120, 180], id: \.self) { minutes in
                            Text(pauseDurationLabel(minutes)).tag(minutes)
                        }
                    }
                    .disabled(isPausingForDuration)

                    Button {
                        Task { await pauseForDuration() }
                    } label: {
                        if isPausingForDuration {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Pause Queue for \(pauseDurationLabel(pauseDurationMinutes))")
                        }
                    }
                    .disabled(isPausingForDuration)
                } header: {
                    Text("Pause Queue")
                } footer: {
                    Text("Pauses all downloading for the chosen duration, then resumes automatically.")
                }

                Section {
                    Button("Clear History", systemImage: "trash", role: .destructive) {
                        showClearHistoryConfirmation = true
                    }
                    .confirmationDialog(
                        "Clear SABnzbd History?",
                        isPresented: $showClearHistoryConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear History", role: .destructive) {
                            Task { await clearHistory() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes every completed and failed job from SABnzbd's history. Downloaded files aren't affected.")
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
        .task(id: serviceManager.isConnected) {
            guard serviceManager.isConnected else { return }
            speedLimitPercent = serviceManager.queue?.speedLimit ?? 0
            // Defer setting didLoadSpeedLimit to avoid triggering onChange handlers.
            await Task.yield()
            didLoadSpeedLimit = true
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
        .errorAlert(item: $settingsErrorAlert)
    }

    private var syncKey: String {
        profiles
            .map { "\($0.id.uuidString):\($0.hostURL):\($0.isEnabled)" }
            .sorted()
            .joined(separator: "|")
    }

    /// The percentage is in the picker itself; the footer adds the one thing the
    /// picker can't say - what that percentage currently works out to.
    private var speedLimitFooter: String {
        let base = "Caps SABnzbd's download speed as a percentage of line speed. Unlimited removes the cap."
        guard let absolute = serviceManager.queue?.speedLimitAbsolute, absolute > 0 else {
            return base
        }
        return "\(base) Currently about \(ByteFormatter.format(bytes: Int64(absolute * 1024)))/s."
    }

    private func speedLimitOptions(including current: Int) -> [Int] {
        var options = [0, 25, 50, 75, 100]
        if !options.contains(current) {
            options.append(current)
            options.sort()
        }
        return options
    }

    private func speedLimitOptionLabel(_ percent: Int) -> String {
        percent <= 0 ? "Unlimited" : "\(percent)%"
    }

    private func updateSpeedLimit(_ percent: Int) async {
        guard !isUpdatingSpeedLimit else { return }
        isUpdatingSpeedLimit = true
        defer { isUpdatingSpeedLimit = false }

        do {
            try await serviceManager.setSpeedLimit(String(percent))
            settingsErrorAlert = nil
        } catch {
            speedLimitPercent = serviceManager.queue?.speedLimit ?? speedLimitPercent
            settingsErrorAlert = ErrorAlertItem(
                title: "Couldn't Set Speed Limit",
                message: error.localizedDescription
            )
        }
    }

    private func pauseDurationLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" : "\(minutes)m"
    }

    private func pauseForDuration() async {
        guard !isPausingForDuration else { return }
        isPausingForDuration = true
        defer { isPausingForDuration = false }

        do {
            try await serviceManager.pauseForDuration(minutes: pauseDurationMinutes)
            settingsErrorAlert = nil
        } catch {
            settingsErrorAlert = ErrorAlertItem(
                title: "Couldn't Pause Queue",
                message: error.localizedDescription
            )
        }
    }

    private func clearHistory() async {
        do {
            try await serviceManager.clearHistory()
            settingsErrorAlert = nil
        } catch {
            settingsErrorAlert = ErrorAlertItem(
                title: "Couldn't Clear History",
                message: error.localizedDescription
            )
        }
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

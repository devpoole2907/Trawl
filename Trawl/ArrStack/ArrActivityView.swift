import SwiftUI

struct ArrActivityView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var mode: ArrActivityMode = .queue
    @State private var sonarrQueue: [ArrQueueItem] = []
    @State private var radarrQueue: [ArrQueueItem] = []
    @State private var isLoading = false
    @State private var error: String?

    private var allItems: [ActivityItem] {
        (
            sonarrQueue.map { ActivityItem(item: $0, source: .sonarr) } +
            radarrQueue.map { ActivityItem(item: $0, source: .radarr) }
        )
        .sorted { ($0.item.sizeleft ?? 0) < ($1.item.sizeleft ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            contentView
        }
        .background(backgroundGradient)
        .overlay(alignment: .bottom) {
            if mode == .queue, let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
        .navigationTitle("Activity")
        .refreshable {
            if mode == .queue {
                await loadQueues()
            }
        }
        .task(id: "\(mode.rawValue)-\(activityReloadKey)") {
            guard mode == .queue else { return }

            guard serviceManager.sonarrConnected || serviceManager.radarrConnected else {
                sonarrQueue = []
                radarrQueue = []
                error = nil
                isLoading = false
                return
            }

            await loadQueues()
        }
    }

    private var modePicker: some View {
        Picker("Section", selection: Binding(
            get: { mode },
            set: { newMode in withAnimation { mode = newMode } }
        )) {
            ForEach(ArrActivityMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.2), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [Color.indigo.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var contentView: some View {
        switch mode {
        case .queue:
            queueContentView
        case .history:
            ArrHistoryView(embedded: true)
        }
    }

    @ViewBuilder
    private var queueContentView: some View {
        if isLoading && allItems.isEmpty {
            ProgressView("Loading activity...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !serviceManager.sonarrConnected && !serviceManager.radarrConnected {
            ContentUnavailableView(
                "No Arr Services Connected",
                systemImage: "server.rack",
                description: Text("This screen shows the current Sonarr and Radarr queue, including active downloads and imports.")
            )
        } else if allItems.isEmpty {
            ContentUnavailableView(
                "No Activity",
                systemImage: "tray",
                description: Text("Nothing is currently downloading or importing in Sonarr or Radarr.")
            )
        } else {
            let sonarrItems = allItems.filter { $0.source == .sonarr }
            let radarrItems = allItems.filter { $0.source == .radarr }
            List {
                if !sonarrItems.isEmpty {
                    Section("Sonarr") {
                        ForEach(sonarrItems) { activityItem in
                            QueueItemRow(item: activityItem.item, source: activityItem.source)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await removeItem(activityItem) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                if !radarrItems.isEmpty {
                    Section("Radarr") {
                        ForEach(radarrItems) { activityItem in
                            QueueItemRow(item: activityItem.item, source: activityItem.source)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await removeItem(activityItem) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func loadQueues() async {
        isLoading = true
        error = nil
        let sonarrClient = serviceManager.sonarrClient
        let radarrClient = serviceManager.radarrClient

        async let sonarrLoad: ([ArrQueueItem], String?) = {
            guard let client = sonarrClient else { return ([], nil) }
            do {
                let response = try await client.getQueue(page: 1, pageSize: 50)
                return (response.records ?? [], nil)
            } catch {
                return ([], "Sonarr: \(error.localizedDescription)")
            }
        }()

        async let radarrLoad: ([ArrQueueItem], String?) = {
            guard let client = radarrClient else { return ([], nil) }
            do {
                let response = try await client.getQueue(page: 1, pageSize: 50)
                return (response.records ?? [], nil)
            } catch {
                return ([], "Radarr: \(error.localizedDescription)")
            }
        }()

        let (sonarrResult, radarrResult) = await (sonarrLoad, radarrLoad)
        sonarrQueue = sonarrResult.0
        radarrQueue = radarrResult.0

        let errors = [sonarrResult.1, radarrResult.1].compactMap { $0 }
        if !errors.isEmpty {
            self.error = errors.joined(separator: ", ")
        }

        isLoading = false
    }

    private func removeItem(_ activityItem: ActivityItem) async {
        switch activityItem.source {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else {
                error = "Sonarr is not connected."
                return
            }
            do {
                try await client.deleteQueueItem(id: activityItem.item.id)
                sonarrQueue.removeAll { $0.id == activityItem.item.id }
            } catch {
                self.error = "Failed to remove from Sonarr: \(error.localizedDescription)"
            }
        case .radarr:
            guard let client = serviceManager.radarrClient else {
                error = "Radarr is not connected."
                return
            }
            do {
                try await client.deleteQueueItem(id: activityItem.item.id)
                radarrQueue.removeAll { $0.id == activityItem.item.id }
            } catch {
                self.error = "Failed to remove from Radarr: \(error.localizedDescription)"
            }
        case .prowlarr:
            break
        }
    }
}

private struct ActivityItem: Identifiable {
    let item: ArrQueueItem
    let source: ArrServiceType

    var id: String { "\(source.rawValue)-\(item.id)" }
}

private enum ArrActivityMode: String, CaseIterable, Identifiable {
    case queue
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .queue:
            "Queue"
        case .history:
            "History"
        }
    }
}

private extension ArrActivityView {
    var activityReloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
    }
}

// MARK: - Queue Item Row

private struct QueueItemRow: View {
    let item: ArrQueueItem
    let source: ArrServiceType

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: source.systemImage)
                    .font(.caption2)
                    .foregroundStyle(source == .sonarr ? .blue : .purple)

                Text(item.title ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }

            ProgressView(value: item.progress)
                .tint(progressTint)

            HStack(spacing: 12) {
                if let status = item.status {
                    Text(status.capitalized)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }

                if let size = item.size, size > 0 {
                    let downloaded = size - (item.sizeleft ?? 0)
                    Text("\(ByteFormatter.format(bytes: Int64(downloaded))) / \(ByteFormatter.format(bytes: Int64(size)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let timeleft = item.timeleft, !timeleft.isEmpty {
                    Label(timeleft, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(Int(item.progress * 100))%")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            if let messages = item.statusMessages, !messages.isEmpty {
                ForEach(Array(messages.enumerated()), id: \.0) { index, msg in
                    if let msgs = msg.messages {
                        Text(msgs.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var progressTint: Color {
        switch item.trackedDownloadStatus {
        case "warning": .orange
        case "error": .red
        default: .blue
        }
    }

    private var statusColor: Color {
        switch item.trackedDownloadStatus {
        case "warning": .orange
        case "error": .red
        default: .secondary
        }
    }
}

// MARK: - Health View

struct ArrHealthView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var sonarrHealth: [ArrHealthCheck] = []
    @State private var radarrHealth: [ArrHealthCheck] = []
    @State private var prowlarrHealth: [ArrHealthCheck] = []
    @State private var isLoading = false
    @State private var loadErrors: [String] = []

    private var allChecks: [HealthItem] {
        (
            sonarrHealth.enumerated().map { HealthItem(check: $0.element, source: .sonarr, index: $0.offset) } +
            radarrHealth.enumerated().map { HealthItem(check: $0.element, source: .radarr, index: $0.offset) } +
            prowlarrHealth.enumerated().map { HealthItem(check: $0.element, source: .prowlarr, index: $0.offset) }
        )
        .sorted { $0.severityRank > $1.severityRank }
    }

    private var sonarrItems: [HealthItem] {
        allChecks.filter { $0.source == .sonarr }
    }

    private var radarrItems: [HealthItem] {
        allChecks.filter { $0.source == .radarr }
    }

    private var prowlarrItems: [HealthItem] {
        allChecks.filter { $0.source == .prowlarr }
    }

    var body: some View {
        contentView
            .navigationTitle("Health")
            .navigationSubtitle(navigationSubtitle)
            .background(backgroundGradient)
            .refreshable { await loadHealth() }
            .task(id: healthReloadKey) {
                guard serviceManager.sonarrConnected || serviceManager.radarrConnected || serviceManager.prowlarrConnected else {
                    sonarrHealth = []
                    radarrHealth = []
                    prowlarrHealth = []
                    loadErrors = []
                    isLoading = false
                    return
                }

                await loadHealth()
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if isLoading && allChecks.isEmpty && loadErrors.isEmpty {
            ProgressView("Loading health checks...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !serviceManager.sonarrConnected && !serviceManager.radarrConnected && !serviceManager.prowlarrConnected {
            ContentUnavailableView(
                "No Arr Services Connected",
                systemImage: "heart.text.square",
                description: Text("This screen shows Sonarr, Radarr, and Prowlarr health warnings and errors.")
            )
        } else if allChecks.isEmpty && loadErrors.isEmpty {
            ContentUnavailableView(
                "No Health Issues",
                systemImage: "checkmark.circle",
                description: Text("Your connected Arr services are not currently reporting any health warnings.")
            )
        } else {
            List {
                if !sonarrItems.isEmpty {
                    Section("Sonarr") {
                        ForEach(sonarrItems) { item in
                            HealthCheckRow(item: item)
                        }
                    }
                }
                if !radarrItems.isEmpty {
                    Section("Radarr") {
                        ForEach(radarrItems) { item in
                            HealthCheckRow(item: item)
                        }
                    }
                }
                if !prowlarrItems.isEmpty {
                    Section("Prowlarr") {
                        ForEach(prowlarrItems) { item in
                            HealthCheckRow(item: item)
                        }
                    }
                }
                if !loadErrors.isEmpty {
                    Section("Load Errors") {
                        ForEach(loadErrors, id: \.self) { error in
                            Label(error, systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.orange)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.pink.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [Color.pink.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    private var navigationSubtitle: String {
        let issueCount = allChecks.count
        if issueCount > 0 {
            return issueCount == 1 ? "1 issue" : "\(issueCount) issues"
        }

        if !loadErrors.isEmpty {
            return loadErrors.count == 1 ? "1 load error" : "\(loadErrors.count) load errors"
        }

        return ""
    }

    private var healthReloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)-\(serviceManager.prowlarrConnected)"
    }

    private func loadHealth() async {
        isLoading = true
        loadErrors = []

        async let sonarrResult = loadHealthChecks(from: serviceManager.sonarrClient, source: .sonarr)
        async let radarrResult = loadHealthChecks(from: serviceManager.radarrClient, source: .radarr)
        async let prowlarrResult = loadHealthChecks(from: serviceManager.prowlarrClient, source: .prowlarr)

        let sonarrOutcome = await sonarrResult
        let radarrOutcome = await radarrResult
        let prowlarrOutcome = await prowlarrResult

        sonarrHealth = sonarrOutcome.checks
        radarrHealth = radarrOutcome.checks
        prowlarrHealth = prowlarrOutcome.checks
        loadErrors = [sonarrOutcome.errorMessage, radarrOutcome.errorMessage, prowlarrOutcome.errorMessage].compactMap { $0 }
        isLoading = false
    }

    private func loadHealthChecks(from client: ArrAPIClientProviding?, source: ArrServiceType) async -> HealthLoadResult {
        guard let client else { return HealthLoadResult(checks: [], errorMessage: nil) }

        do {
            return HealthLoadResult(checks: try await client.getHealth(), errorMessage: nil)
        } catch {
            return HealthLoadResult(checks: [], errorMessage: "\(source.displayName): \(error.localizedDescription)")
        }
    }
}

private struct HealthLoadResult {
    let checks: [ArrHealthCheck]
    let errorMessage: String?
}

private struct HealthItem: Identifiable {
    let check: ArrHealthCheck
    let source: ArrServiceType
    let index: Int

    var id: String { "\(source.rawValue)-\(check.id)-\(index)" }

    var severityRank: Int {
        switch check.type?.lowercased() {
        case "error": 3
        case "warning": 2
        case "notice": 1
        default: 0
        }
    }
}

private struct HealthCheckRow: View {
    let item: HealthItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    if let source = item.check.source, !source.isEmpty {
                        Text(source)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    } else {
                        Text(item.source.displayName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    if let message = item.check.message, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(statusLabel)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(iconColor)
            }

            if let wikiURL = item.check.wikiUrl, let url = URL(string: wikiURL) {
                Link(destination: url) {
                    Label("Open Help", systemImage: "safari")
                        .font(.caption2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLabel: String {
        switch item.check.type?.lowercased() {
        case "error": "Error"
        case "warning": "Warning"
        case "notice": "Notice"
        default: "Info"
        }
    }

    private var iconName: String {
        switch item.check.type?.lowercased() {
        case "error": "xmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        case "notice": "info.circle.fill"
        default: "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch item.check.type?.lowercased() {
        case "error": .red
        case "warning": .orange
        case "notice": .yellow
        default: .green
        }
    }
}

private protocol ArrAPIClientProviding: Sendable {
    func getHealth() async throws -> [ArrHealthCheck]
}

extension SonarrAPIClient: ArrAPIClientProviding {}
extension RadarrAPIClient: ArrAPIClientProviding {}
extension ProwlarrAPIClient: ArrAPIClientProviding {}

import SwiftUI

struct ArrActivityView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var mode: ArrActivityMode = .queue
    @State private var serviceFilter: ArrServiceFilter = .all
    @State private var sonarrQueue: [ArrQueueItem] = []
    @State private var radarrQueue: [ArrQueueItem] = []
    @State private var isLoading = false
    @State private var selectedItem: ActivityItem?

    private var allItems: [ActivityItem] {
        let sonarr = serviceFilter != .radarr ? sonarrQueue.map { ActivityItem(item: $0, source: .sonarr) } : []
        let radarr = serviceFilter != .sonarr ? radarrQueue.map { ActivityItem(item: $0, source: .radarr) } : []
        return (sonarr + radarr).sorted { ($0.item.sizeleft ?? 0) < ($1.item.sizeleft ?? 0) }
    }

    var body: some View {
        Group {
            contentView
        }
        .background(backgroundGradient)
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $serviceFilter) {
                        Label("All", systemImage: "square.grid.2x2").tag(ArrServiceFilter.all)
                        Label("Sonarr", systemImage: "tv").tag(ArrServiceFilter.sonarr)
                        Label("Radarr", systemImage: "film").tag(ArrServiceFilter.radarr)
                    }
                } label: {
                    Image(systemName: serviceFilter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .refreshable {
            if mode == .queue { await loadQueues() }
        }
        .task(id: "\(mode.rawValue)-\(activityReloadKey)") {
            guard mode == .queue else { return }
            guard serviceManager.sonarrConnected || serviceManager.radarrConnected else {
                sonarrQueue = []
                radarrQueue = []
                isLoading = false
                return
            }
            await loadQueues()
        }
        .safeAreaInset(edge: .top) {
            Picker("Section", selection: Binding(
                get: { mode },
                set: { newMode in withAnimation { mode = newMode } }
            )) {
                ForEach(ArrActivityMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.horizontal, 48)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .sheet(item: $selectedItem) { activity in
            QueueDetailSheet(item: activity)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch mode {
        case .queue:   queueContentView
        case .history: ArrHistoryView(embedded: true, serviceFilter: serviceFilter)
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
                description: Text("This screen shows the current Sonarr and Radarr queue.")
            )
        } else if allItems.isEmpty {
            ContentUnavailableView(
                "No Activity",
                systemImage: "tray",
                description: Text("Nothing is currently downloading or importing.")
            )
        } else {
            List {
                ForEach(allItems) { activityItem in
                    Button {
                        selectedItem = activityItem
                    } label: {
                        QueueItemRow(item: activityItem.item, source: activityItem.source)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await removeItem(activityItem) }
                        } label: {
                            Label("Remove", systemImage: "trash")
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

    private var activityReloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
    }

    private func loadQueues() async {
        isLoading = true
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
            InAppNotificationCenter.shared.showError(title: "Queue Error", message: errors.joined(separator: "\n"))
        }

        isLoading = false
    }

    private func removeItem(_ activityItem: ActivityItem) async {
        switch activityItem.source {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else {
                InAppNotificationCenter.shared.showError(title: "Remove Failed", message: "Sonarr is not connected.")
                return
            }
            do {
                try await client.deleteQueueItem(id: activityItem.item.id)
                sonarrQueue.removeAll { $0.id == activityItem.item.id }
                InAppNotificationCenter.shared.showSuccess(title: "Removed", message: "\(activityItem.item.friendlyTitle) removed from queue.")
            } catch {
                InAppNotificationCenter.shared.showError(title: "Remove Failed", message: error.localizedDescription)
            }
        case .radarr:
            guard let client = serviceManager.radarrClient else {
                InAppNotificationCenter.shared.showError(title: "Remove Failed", message: "Radarr is not connected.")
                return
            }
            do {
                try await client.deleteQueueItem(id: activityItem.item.id)
                radarrQueue.removeAll { $0.id == activityItem.item.id }
                InAppNotificationCenter.shared.showSuccess(title: "Removed", message: "\(activityItem.item.friendlyTitle) removed from queue.")
            } catch {
                InAppNotificationCenter.shared.showError(title: "Remove Failed", message: error.localizedDescription)
            }
        case .prowlarr:
            break
        }
    }
}

// MARK: - Supporting types

private struct ActivityItem: Identifiable {
    let item: ArrQueueItem
    let source: ArrServiceType

    var id: String { "\(source.rawValue)-\(item.id)" }
}

private enum ArrActivityMode: String, CaseIterable, Identifiable {
    case queue, history

    var id: Self { self }

    var title: String {
        switch self {
        case .queue:   "Queue"
        case .history: "History"
        }
    }
}

enum ArrServiceFilter: CaseIterable, Hashable {
    case all, sonarr, radarr, prowlarr

    var title: String {
        switch self {
        case .all:      "All"
        case .sonarr:   "Sonarr"
        case .radarr:   "Radarr"
        case .prowlarr: "Prowlarr"
        }
    }
}

// MARK: - Friendly title helper

private extension ArrQueueItem {
    /// Prefer the status message title (e.g. "Breaking Bad – S01E01") over the raw release name.
    var friendlyTitle: String {
        if let title = statusMessages?.first?.title, !title.isEmpty { return title }
        return title ?? "Unknown"
    }

    /// Compact ETA string, nil when unknown or zero.
    var shortETA: String? {
        guard let t = timeleft, !t.isEmpty, t != "00:00:00" else { return nil }
        // Drop leading zero segments: "00:23:45" → "23:45", "01:05:00" → "1:05:00"
        let parts = t.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return t }
        let h = Int(parts[0]) ?? 0
        let m = parts[1]
        let s = parts[2]
        if h > 0 { return "\(h)h \(m)m" }
        let mins = Int(m) ?? 0
        if mins > 0 { return "\(mins)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - Queue Item Row (compact)

private struct QueueItemRow: View {
    let item: ArrQueueItem
    let source: ArrServiceType

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source == .sonarr ? "tv" : "film")
                .foregroundStyle(source == .sonarr ? Color.purple : Color.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.friendlyTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Text(source.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(source == .sonarr ? Color.purple : Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((source == .sonarr ? Color.purple : Color.orange).opacity(0.14))
                        .clipShape(Capsule())
                }

                HStack(spacing: 4) {
                    if let status = item.trackedDownloadState ?? item.status {
                        Text(status
                            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                            .capitalized)
                            .foregroundStyle(statusColor)
                    }
                    if let eta = item.shortETA {
                        Text("·")
                        Label(eta, systemImage: "clock")
                    }
                    if let msg = item.statusMessages?.compactMap(\.messages).flatMap({ $0 }).first,
                       !msg.isEmpty {
                        Text("·")
                        Text(msg).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("\(Int(item.progress * 100))%")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(progressColor)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch item.trackedDownloadStatus {
        case "warning": .orange
        case "error":   .red
        default:        .secondary
        }
    }

    private var progressColor: Color {
        switch item.trackedDownloadStatus {
        case "warning": .orange
        case "error":   .red
        default:        item.progress >= 1 ? .green : .primary
        }
    }
}

// MARK: - Queue Detail Sheet

private struct QueueDetailSheet: View {
    let item: ActivityItem

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: item.source == .sonarr ? "tv" : "film")
                    .font(.title2)
                    .foregroundStyle(item.source == .sonarr ? Color.purple : Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.item.friendlyTitle)
                        .font(.headline)
                        .lineLimit(3)
                    Text(item.source == .sonarr ? "Sonarr" : "Radarr")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Progress
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(Int(item.item.progress * 100))% complete")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let eta = item.item.shortETA {
                        Label(eta, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: item.item.progress)
                    .tint(item.item.trackedDownloadStatus == "warning" ? .orange
                          : item.item.trackedDownloadStatus == "error" ? .red : .indigo)

                if let size = item.item.size, size > 0,
                   let sizeleft = item.item.sizeleft {
                    let downloaded = size - sizeleft
                    Text("\(ByteFormatter.format(bytes: Int64(downloaded))) of \(ByteFormatter.format(bytes: Int64(size)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Metadata
            VStack(alignment: .leading, spacing: 8) {
                if let state = item.item.trackedDownloadState ?? item.item.status {
                    metaRow(label: "Status",
                            value: state.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized)
                }
                if let client = item.item.downloadClient {
                    metaRow(label: "Client", value: client)
                }
                if let title = item.item.title, title != item.item.friendlyTitle {
                    metaRow(label: "Release", value: title)
                }
                if let path = item.item.outputPath {
                    metaRow(label: "Destination", value: path)
                }
            }

            // Warning messages
            if let messages = item.item.statusMessages?.compactMap(\.messages).flatMap({ $0 }),
               !messages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(messages, id: \.self) { msg in
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
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
    @State private var serviceFilter: ArrServiceFilter = .all
    @State private var selectedItem: HealthItem?

    private var allChecks: [HealthItem] {
        (
            sonarrHealth.enumerated().map { HealthItem(check: $0.element, source: .sonarr, index: $0.offset) } +
            radarrHealth.enumerated().map { HealthItem(check: $0.element, source: .radarr, index: $0.offset) } +
            prowlarrHealth.enumerated().map { HealthItem(check: $0.element, source: .prowlarr, index: $0.offset) }
        )
        .sorted { $0.severityRank > $1.severityRank }
    }

    private var filteredChecks: [HealthItem] {
        switch serviceFilter {
        case .all:      return allChecks
        case .sonarr:   return allChecks.filter { $0.source == .sonarr }
        case .radarr:   return allChecks.filter { $0.source == .radarr }
        case .prowlarr: return allChecks.filter { $0.source == .prowlarr }
        }
    }

    var body: some View {
        Group {
            contentView
        }
        .background(backgroundGradient)
        .navigationTitle("Health")
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $serviceFilter) {
                        Label("All", systemImage: "square.grid.2x2").tag(ArrServiceFilter.all)
                        if serviceManager.sonarrConnected {
                            Label("Sonarr", systemImage: "tv").tag(ArrServiceFilter.sonarr)
                        }
                        if serviceManager.radarrConnected {
                            Label("Radarr", systemImage: "film").tag(ArrServiceFilter.radarr)
                        }
                        if serviceManager.prowlarrConnected {
                            Label("Prowlarr", systemImage: "magnifyingglass.circle").tag(ArrServiceFilter.prowlarr)
                        }
                    }
                } label: {
                    Image(systemName: serviceFilter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .refreshable { await loadHealth() }
        .task(id: healthReloadKey) {
            guard serviceManager.sonarrConnected || serviceManager.radarrConnected || serviceManager.prowlarrConnected else {
                sonarrHealth = []
                radarrHealth = []
                prowlarrHealth = []
                isLoading = false
                return
            }
            await loadHealth()
        }
        .sheet(item: $selectedItem) { item in
            HealthDetailSheet(item: item)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if isLoading && allChecks.isEmpty {
            ProgressView("Loading health checks...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !serviceManager.sonarrConnected && !serviceManager.radarrConnected && !serviceManager.prowlarrConnected {
            ContentUnavailableView(
                "No Arr Services Connected",
                systemImage: "heart.text.square",
                description: Text("This screen shows Sonarr, Radarr, and Prowlarr health warnings and errors.")
            )
        } else if filteredChecks.isEmpty {
            ContentUnavailableView(
                "No Health Issues",
                systemImage: "checkmark.circle",
                description: Text("No health warnings reported for the selected service.")
            )
        } else {
            List {
                ForEach(filteredChecks) { item in
                    Button { selectedItem = item } label: {
                        HealthCheckRow(item: item)
                    }
                    .buttonStyle(.plain)
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
        let count = allChecks.count
        guard count > 0 else { return "" }
        return count == 1 ? "1 issue" : "\(count) issues"
    }

    private var healthReloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)-\(serviceManager.prowlarrConnected)"
    }

    private func loadHealth() async {
        isLoading = true

        async let sonarrResult = loadHealthChecks(from: serviceManager.sonarrClient, source: .sonarr)
        async let radarrResult = loadHealthChecks(from: serviceManager.radarrClient, source: .radarr)
        async let prowlarrResult = loadHealthChecks(from: serviceManager.prowlarrClient, source: .prowlarr)

        let s = await sonarrResult
        let r = await radarrResult
        let p = await prowlarrResult

        sonarrHealth = s.checks
        radarrHealth = r.checks
        prowlarrHealth = p.checks

        let errors = [s.errorMessage, r.errorMessage, p.errorMessage].compactMap { $0 }
        if !errors.isEmpty {
            InAppNotificationCenter.shared.showError(title: "Health Check Failed", message: errors.joined(separator: "\n"))
        }

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
        case "error": 3; case "warning": 2; case "notice": 1; default: 0
        }
    }
}

// MARK: - Health Check Row (compact)

private struct HealthCheckRow: View {
    let item: HealthItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.check.source ?? "General")
                        .font(.subheadline.weight(.semibold))

                    Text(item.source.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(serviceColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(serviceColor.opacity(0.14))
                        .clipShape(Capsule())
                }

                if let message = item.check.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(iconColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(iconColor.opacity(0.14))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statusLabel: String {
        switch item.check.type?.lowercased() {
        case "error": "Error"; case "warning": "Warning"; case "notice": "Notice"; default: "Info"
        }
    }

    private var iconName: String {
        switch item.check.type?.lowercased() {
        case "error": "xmark.octagon.fill"; case "warning": "exclamationmark.triangle.fill"
        case "notice": "info.circle.fill"; default: "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch item.check.type?.lowercased() {
        case "error": .red; case "warning": .orange; case "notice": .yellow; default: .green
        }
    }

    private var serviceColor: Color {
        switch item.source {
        case .sonarr: .purple
        case .radarr: .orange
        case .prowlarr: .yellow
        }
    }
}

// MARK: - Health Detail Sheet

private struct HealthDetailSheet: View {
    let item: HealthItem

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.check.source ?? item.source.displayName)
                        .font(.headline)
                    Text(item.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(iconColor.opacity(0.14))
                    .clipShape(Capsule())
            }

            if let message = item.check.message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let wikiURL = item.check.wikiUrl, let url = URL(string: wikiURL) {
                Link(destination: url) {
                    Label("Open Help Page", systemImage: "safari")
                        .font(.subheadline.weight(.medium))
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private var statusLabel: String {
        switch item.check.type?.lowercased() {
        case "error": "Error"; case "warning": "Warning"; case "notice": "Notice"; default: "Info"
        }
    }

    private var iconName: String {
        switch item.check.type?.lowercased() {
        case "error": "xmark.octagon.fill"; case "warning": "exclamationmark.triangle.fill"
        case "notice": "info.circle.fill"; default: "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch item.check.type?.lowercased() {
        case "error": .red; case "warning": .orange; case "notice": .yellow; default: .green
        }
    }
}

private protocol ArrAPIClientProviding: Sendable {
    func getHealth() async throws -> [ArrHealthCheck]
}

extension SonarrAPIClient: ArrAPIClientProviding {}
extension RadarrAPIClient: ArrAPIClientProviding {}
extension ProwlarrAPIClient: ArrAPIClientProviding {}

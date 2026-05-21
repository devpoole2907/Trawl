import SwiftUI

struct ArrActivityView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @State private var mode: ArrActivityMode = .queue
    @State private var serviceFilter: ArrServiceFilter = .all
    @State private var sonarrQueue: [ArrQueueItem] = []
    @State private var radarrQueue: [ArrQueueItem] = []
    @State private var bazarrTasks: [BazarrTask] = []
    @State private var isLoading = false
    @State private var selectedItem: ActivityItem?
    @State private var itemPendingRemoval: ActivityItem?
    @State private var manualImportPath: String?
    @State private var manualImportService: ArrServiceType = .sonarr
    @State private var showActivitySettings = false

    private var activityRows: [ActivityRow] {
        var rows: [ActivityRow] = []
        if serviceFilter == .all || serviceFilter == .sonarr {
            rows.append(contentsOf: sonarrQueue.map { .queue(ActivityItem(item: $0, source: .sonarr)) })
        }
        if serviceFilter == .all || serviceFilter == .radarr {
            rows.append(contentsOf: radarrQueue.map { .queue(ActivityItem(item: $0, source: .radarr)) })
        }
        if serviceFilter == .all || serviceFilter == .bazarr {
            let tasks = serviceFilter == .bazarr ? bazarrTasks : bazarrTasks.filter(\.jobRunning)
            rows.append(contentsOf: tasks.map { .bazarrTask($0) })
        }
        return rows.sorted { $0.sortRank < $1.sortRank }
    }

    var body: some View {
        Group {
            contentView
        }
        .background(backgroundGradient)
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                ActivityFilterMenu(serviceFilter: $serviceFilter, isHistoryMode: mode == .history)
            }
        }
        .refreshable {
            if mode == .queue { await loadQueues() }
        }
        .task(id: "\(mode.rawValue)-\(activityReloadKey)") {
            guard mode == .queue else { return }
            guard serviceManager.sonarrConnected || serviceManager.radarrConnected || serviceManager.hasAnyConnectedBazarrInstance else {
                sonarrQueue = []
                radarrQueue = []
                bazarrTasks = []
                isLoading = false
                return
            }
            await loadQueues()
        }
        .safeAreaInset(edge: .top) {
            ActivityModePicker(mode: $mode)
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .history && serviceFilter == .bazarr {
                serviceFilter = .all
            } else if newMode == .queue && serviceFilter == .prowlarr {
                serviceFilter = .all
            }
        }
        .sheet(item: $selectedItem) { activity in
            QueueDetailSheet(item: activity) { path, service in
                selectedItem = nil
                manualImportService = service
                manualImportPath = path
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: manualImportSheetPresented) {
            if let path = manualImportPath {
                NavigationStack {
                    ManualImportScanView(
                        path: path,
                        service: manualImportService,
                        serviceManager: serviceManager,
                        showsCloseButton: true
                    )
                    .environment(serviceManager)
                }
            }
        }
        .alert("Remove Queue Item?", isPresented: removeConfirmationPresented) {
            Button("Remove", role: .destructive) {
                if let itemPendingRemoval {
                    Task { await removeItem(itemPendingRemoval) }
                }
                itemPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                itemPendingRemoval = nil
            }
        } message: {
            Text("This removes the item from the Arr activity queue.")
        }
        .sheet(isPresented: $showActivitySettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: serviceManager.hasSonarrInstance && !serviceManager.sonarrConnected ? .sonarr : serviceManager.hasRadarrInstance && !serviceManager.radarrConnected ? .radarr : .sonarr)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showActivitySettings = false }
                        }
                    }
            }
        }
    }

    private var hasConfiguredService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance || serviceManager.hasBazarrInstance
    }

    private var isQueueConnecting: Bool {
        let noneConnected = !serviceManager.sonarrConnected && !serviceManager.radarrConnected && !serviceManager.hasAnyConnectedBazarrInstance
        guard noneConnected else { return false }
        return serviceManager.isInitializing ||
            serviceManager.isConnecting(.sonarr) ||
            serviceManager.isConnecting(.radarr) ||
            serviceManager.isConnecting(.bazarr)
    }

    private var queueServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        if serviceManager.hasBazarrInstance { services.append(.bazarr) }
        return services
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
        if !hasConfiguredService {
            ContentUnavailableView(
                "No Services Configured",
                systemImage: "server.rack",
                description: Text("Connect Sonarr, Radarr, or Bazarr to view service activity.")
            )
        } else if !serviceManager.sonarrConnected && !serviceManager.radarrConnected && !serviceManager.hasAnyConnectedBazarrInstance {
            ArrServicesConnectionStatusView(
                services: queueServices,
                title: "Services Unreachable",
                message: "Unable to reach your configured services."
            )
        } else {
            ArrLoadingErrorEmptyView(
                isLoading: isLoading,
                error: nil,
                isEmpty: activityRows.isEmpty,
                emptyTitle: "No Activity",
                emptyIcon: "tray",
                emptyDescription: "Nothing is currently downloading, importing, or running.",
                onRetry: nil
            ) {
                List {
                    ForEach(activityRows) { row in
                        switch row {
                        case .queue(let activityItem):
                            let linkedTorrent = linkedTorrent(for: activityItem.item)

                            if let linkedTorrent {
                                NavigationLink {
                                    TorrentDetailView(torrentHash: linkedTorrent.hash)
                                        .environment(syncService)
                                        .environment(torrentService)
                                } label: {
                                    QueueItemRow(
                                        item: activityItem.item,
                                        source: activityItem.source,
                                        linkedTorrent: linkedTorrent
                                    )
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        itemPendingRemoval = activityItem
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    if let path = activityItem.item.outputPath,
                                       activityItem.item.trackedDownloadStatus == "warning" || activityItem.item.trackedDownloadStatus == "error" {
                                        Button {
                                            manualImportService = activityItem.source
                                            manualImportPath = path
                                        } label: {
                                            Label("Manual Import", systemImage: "tray.and.arrow.down.fill")
                                        }
                                        .tint(.blue)
                                    }
                                }
                            } else {
                                Button {
                                    selectedItem = activityItem
                                } label: {
                                    QueueItemRow(item: activityItem.item, source: activityItem.source)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        itemPendingRemoval = activityItem
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    if let path = activityItem.item.outputPath,
                                       activityItem.item.trackedDownloadStatus == "warning" || activityItem.item.trackedDownloadStatus == "error" {
                                        Button {
                                            manualImportService = activityItem.source
                                            manualImportPath = path
                                        } label: {
                                            Label("Manual Import", systemImage: "tray.and.arrow.down.fill")
                                        }
                                        .tint(.blue)
                                    }
                                }
                            }
                        case .bazarrTask(let task):
                            BazarrTaskRow(task: task)
                        }
                    }
                }
                .animation(.default, value: activityRows.map(\.id))
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
            }
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
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)-\(serviceManager.hasAnyConnectedBazarrInstance)-\(serviceManager.activeBazarrProfileID?.uuidString ?? "none")"
    }

    private var manualImportSheetPresented: Binding<Bool> {
        Binding(
            get: { manualImportPath != nil },
            set: { if !$0 { manualImportPath = nil } }
        )
    }

    private var removeConfirmationPresented: Binding<Bool> {
        Binding(
            get: { itemPendingRemoval != nil },
            set: { if !$0 { itemPendingRemoval = nil } }
        )
    }

    private func loadQueues() async {
        isLoading = true
        let sonarrClient = serviceManager.sonarrClient
        let radarrClient = serviceManager.radarrClient
        let bazarrClient = serviceManager.activeBazarrEntry?.client

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
        async let bazarrLoad: ([BazarrTask], String?) = {
            guard let client = bazarrClient else { return ([], nil) }
            do {
                let tasks = try await client.getTasks()
                return (tasks, nil)
            } catch {
                return ([], "Bazarr: \(error.localizedDescription)")
            }
        }()

        let (sonarrResult, radarrResult, bazarrResult) = await (sonarrLoad, radarrLoad, bazarrLoad)
        sonarrQueue = sonarrResult.0
        radarrQueue = radarrResult.0
        bazarrTasks = bazarrResult.0

        let errors = [sonarrResult.1, radarrResult.1, bazarrResult.1].compactMap { $0 }
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
        case .prowlarr, .bazarr:
            break
        }
    }

    private func linkedTorrent(for item: ArrQueueItem) -> Torrent? {
        guard let downloadId = item.downloadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !downloadId.isEmpty else {
            return nil
        }

        return syncService.torrents[downloadId]
            ?? syncService.torrents[downloadId.lowercased()]
            ?? syncService.torrents[downloadId.uppercased()]
    }
}

// MARK: - Supporting types

private struct ActivityItem: Identifiable {
    let item: ArrQueueItem
    let source: ArrServiceType

    var id: String { "\(source.rawValue)-\(item.id)" }
}

private enum ActivityRow: Identifiable {
    case queue(ActivityItem)
    case bazarrTask(BazarrTask)

    var id: String {
        switch self {
        case .queue(let item):
            return item.id
        case .bazarrTask(let task):
            return "bazarr-task-\(task.id)"
        }
    }

    var sortRank: Double {
        switch self {
        case .queue(let item):
            return item.item.sizeleft ?? Double.greatestFiniteMagnitude / 2
        case .bazarrTask(let task):
            return task.jobRunning ? -1 : Double.greatestFiniteMagnitude - 1
        }
    }
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

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        switch self {
        case .queue:
            TrawlSegmentBarItem(title, value: self)
        case .history:
            TrawlSegmentBarItem(title, value: self)
        }
    }
}

enum ArrServiceFilter: CaseIterable, Hashable {
    case all, sonarr, radarr, prowlarr, bazarr

    var title: String {
        switch self {
        case .all:      "All"
        case .sonarr:   "Sonarr"
        case .radarr:   "Radarr"
        case .prowlarr: "Prowlarr"
        case .bazarr:   "Bazarr"
        }
    }

    var serviceColor: Color {
        switch self {
        case .all:      .secondary
        case .sonarr:   .purple
        case .radarr:   .orange
        case .prowlarr: .yellow
        case .bazarr:   .teal
        }
    }

    var systemImage: String {
        switch self {
        case .all:      "square.grid.3x3"
        case .sonarr:   "tv"
        case .radarr:   "film"
        case .prowlarr: "magnifyingglass.circle"
        case .bazarr:   "captions.bubble"
        }
    }
}

private struct ActivityFilterMenu: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Binding var serviceFilter: ArrServiceFilter
    let isHistoryMode: Bool

    var body: some View {
        Menu {
            Picker("Filter", selection: $serviceFilter) {
                Label("All", systemImage: "square.grid.2x2").tag(ArrServiceFilter.all)
                if serviceManager.hasSonarrInstance {
                    Label("Sonarr", systemImage: ServiceIdentity.sonarr.systemImage).tag(ArrServiceFilter.sonarr)
                }
                if serviceManager.hasRadarrInstance {
                    Label("Radarr", systemImage: ServiceIdentity.radarr.systemImage).tag(ArrServiceFilter.radarr)
                }
                if serviceManager.hasProwlarrInstance && isHistoryMode {
                    Label("Prowlarr", systemImage: ServiceIdentity.prowlarr.systemImage).tag(ArrServiceFilter.prowlarr)
                }
                if serviceManager.hasBazarrInstance && !isHistoryMode {
                    Label("Bazarr", systemImage: ServiceIdentity.bazarr.systemImage).tag(ArrServiceFilter.bazarr)
                }
            }
        } label: {
            Image(systemName: serviceFilter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

private struct ActivityModePicker: View {
    @Binding var mode: ArrActivityMode

    var body: some View {
        TrawlSegmentBar("Section", selection: Binding(
            get: { mode },
            set: { newMode in withAnimation { mode = newMode } }
        ), items: ArrActivityMode.allCases.map(\.segmentBarItem), alignment: .center)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct HealthFilterMenu: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Binding var serviceFilter: ArrServiceFilter

    var body: some View {
        Menu {
            Picker("Filter", selection: $serviceFilter) {
                Label("All", systemImage: "square.grid.2x2").tag(ArrServiceFilter.all)
                if serviceManager.sonarrConnected {
                    Label("Sonarr", systemImage: ServiceIdentity.sonarr.systemImage).tag(ArrServiceFilter.sonarr)
                }
                if serviceManager.radarrConnected {
                    Label("Radarr", systemImage: ServiceIdentity.radarr.systemImage).tag(ArrServiceFilter.radarr)
                }
                if serviceManager.prowlarrConnected {
                    Label("Prowlarr", systemImage: ServiceIdentity.prowlarr.systemImage).tag(ArrServiceFilter.prowlarr)
                }
            }
        } label: {
            Image(systemName: serviceFilter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

// MARK: - Friendly title helper

private extension ArrQueueItem {
    /// Prefer the actual queue item title; some status message titles are warning prose.
    var friendlyTitle: String {
        if let title, !title.isEmpty { return title }
        if let statusTitle = statusMessages?.first?.title, !statusTitle.isEmpty { return statusTitle }
        return "Unknown"
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
    var linkedTorrent: Torrent?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source == .sonarr ? "tv" : "film")
                .foregroundStyle(source == .sonarr ? Color.purple : Color.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.friendlyTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    if let status = item.trackedDownloadState ?? item.status {
                        Text(status
                            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                            .capitalized)
                            .foregroundStyle(statusColor)
                    }
                    if let linkedTorrent {
                        Text("·")
                        Label(ByteFormatter.formatSpeed(bytesPerSecond: linkedTorrent.dlspeed), systemImage: "arrow.down")
                            .foregroundStyle(.blue)
                    }
                    if let torrentETA {
                        Text("·")
                        Label(torrentETA, systemImage: "clock")
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

    private var torrentETA: String? {
        if let linkedTorrent, !linkedTorrent.state.isCompleted, linkedTorrent.eta > 0, linkedTorrent.eta < 8_640_000 {
            return ByteFormatter.formatETA(seconds: linkedTorrent.eta)
        }
        return item.shortETA
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

// MARK: - Bazarr Task Row

private struct BazarrTaskRow: View {
    let task: BazarrTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .foregroundStyle(Color.teal)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text("Bazarr")
                        .foregroundStyle(.teal)
                    if let detail {
                        Text("·")
                        Text(detail)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(task.jobRunning ? "Running" : "Scheduled")
                .font(.caption.weight(.medium))
                .foregroundStyle(task.jobRunning ? Color.green : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((task.jobRunning ? Color.green : Color.secondary).opacity(0.14))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var detail: String? {
        if task.jobRunning { return "Running now" }
        if let nextRunIn = task.nextRunIn, !nextRunIn.isEmpty { return "Next run in \(nextRunIn)" }
        if let nextRunTime = task.nextRunTime, !nextRunTime.isEmpty { return "Next run \(nextRunTime)" }
        if let interval = task.interval, !interval.isEmpty { return "Every \(interval)" }
        return nil
    }
}

// MARK: - Queue Detail Sheet

private struct QueueDetailSheet: View {
    let item: ActivityItem
    let onManualImport: (String, ArrServiceType) -> Void

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
                    ForEach(Array(messages.enumerated()), id: \.offset) { index, msg in
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Manual Import action
            if let path = item.item.outputPath,
               item.item.trackedDownloadStatus == "warning" || item.item.trackedDownloadStatus == "error" {
                Button {
                    onManualImport(path, item.source)
                } label: {
                    Label("Manual Import", systemImage: "tray.and.arrow.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
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
    @State private var serviceFilter: ArrServiceFilter = .all
    @State private var selectedItem: HealthItem?
    @State private var showSettings = false

    private var allChecks: [HealthItem] {
        (
            serviceManager.sonarrHealthChecks.enumerated().map { HealthItem(check: $0.element, source: .sonarr, index: $0.offset) } +
            serviceManager.radarrHealthChecks.enumerated().map { HealthItem(check: $0.element, source: .radarr, index: $0.offset) } +
            serviceManager.prowlarrHealthChecks.enumerated().map { HealthItem(check: $0.element, source: .prowlarr, index: $0.offset) }
        )
        .sorted { $0.severityRank > $1.severityRank }
    }

    private var filteredChecks: [HealthItem] {
        switch serviceFilter {
        case .all:      return allChecks
        case .sonarr:   return allChecks.filter { $0.source == .sonarr }
        case .radarr:   return allChecks.filter { $0.source == .radarr }
        case .prowlarr: return allChecks.filter { $0.source == .prowlarr }
        case .bazarr:   return []
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
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                HealthFilterMenu(serviceFilter: $serviceFilter)
            }
        }
        .refreshable { await serviceManager.loadHealth() }
        .task(id: healthReloadKey) {
            guard serviceManager.sonarrConnected || serviceManager.radarrConnected || serviceManager.prowlarrConnected else {
                return
            }
            await serviceManager.loadHealth()
        }
        .sheet(item: $selectedItem) { item in
            HealthDetailSheet(item: item)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: healthSettingsService)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
    }

    private var hasConfiguredService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance || serviceManager.hasProwlarrInstance
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected || serviceManager.prowlarrConnected
    }

    private var healthServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        if serviceManager.hasProwlarrInstance { services.append(.prowlarr) }
        return services
    }

    private var isHealthConnecting: Bool {
        guard !hasConnectedService else { return false }
        return serviceManager.isInitializing ||
            serviceManager.isConnecting(.sonarr) ||
            serviceManager.isConnecting(.radarr) ||
            serviceManager.isConnecting(.prowlarr)
    }

    private var healthSettingsService: ArrServiceType {
        if serviceManager.hasSonarrInstance && !serviceManager.sonarrConnected { return .sonarr }
        if serviceManager.hasRadarrInstance && !serviceManager.radarrConnected { return .radarr }
        if serviceManager.hasProwlarrInstance && !serviceManager.prowlarrConnected { return .prowlarr }
        return .sonarr
    }

    @ViewBuilder
    private var contentView: some View {
        if !hasConfiguredService {
            ContentUnavailableView(
                "No Services Configured",
                systemImage: "heart.text.square",
                description: Text("Add Sonarr, Radarr, or Prowlarr in Settings to view health checks.")
            )
        } else if !hasConnectedService {
            ArrServicesConnectionStatusView(
                services: healthServices,
                title: "Services Unreachable",
                message: "Unable to reach your configured servers."
            )
        } else if filteredChecks.isEmpty {
            ContentUnavailableView(
                "No Health Issues",
                systemImage: "checkmark.circle",
                description: Text("No health warnings reported for the selected services.")
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
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
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
        case .bazarr: .secondary
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

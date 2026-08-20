import SwiftUI

struct SABnzbdManagerView: View {
    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter

    @State private var selectedFilter: SABnzbdManagerFilter = .queue
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @State private var jobPendingDeletion: SABnzbdJob?
    /// Fetched once for the priority/category context menu rather than polled —
    /// same reasoning as `categoriesAndScripts()` itself.
    @State private var availableCategories: [String] = []

    var body: some View {
        content
            .background(backgroundGradient)
            .navigationTitle("SABnzbd")
            .navigationSubtitle(navigationSubtitle)
            #if os(iOS)
            .toolbarTitleDisplayMode(.inlineLarge)
            #endif
            .safeAreaInset(edge: .top) {
                TrawlSegmentBar(
                    "Filter",
                    selection: Binding(
                        get: { selectedFilter },
                        set: { filter in withAnimation { selectedFilter = filter } }
                    ),
                    items: SABnzbdManagerFilter.allCases.map(\.segmentBarItem),
                    searchText: $searchText,
                    searchHint: "Search SABnzbd",
                    isSearchExpanded: $isSearchExpanded,
                    searchPlacement: .leading,
                    alignment: .leading
                )
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if serviceManager.queue?.paused == true {
                            Button("Resume All", systemImage: "play.fill") {
                                perform { try await serviceManager.resumeAll() }
                            }
                        } else {
                            Button("Pause All", systemImage: "pause.fill") {
                                perform { try await serviceManager.pauseAll() }
                            }
                        }
                    } label: {
                        Label("SABnzbd Actions", systemImage: "ellipsis")
                    }
                }
            }
            .refreshable {
                await serviceManager.refresh()
            }
            .task {
                await serviceManager.refresh()
                serviceManager.startPolling()
            }
            .task {
                let (categories, _) = await serviceManager.categoriesAndScripts()
                availableCategories = categories
            }
            .onDisappear {
                serviceManager.stopPolling()
            }
            .alert("Remove Download?", isPresented: deletionConfirmationPresented) {
                Button("Remove and Delete Files", role: .destructive) {
                    deletePendingJob(deleteFiles: true)
                }
                Button("Remove Job Only", role: .destructive) {
                    deletePendingJob(deleteFiles: false)
                }
                Button("Cancel", role: .cancel) {
                    jobPendingDeletion = nil
                }
            } message: {
                Text("This action can’t be undone.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if serviceManager.isRefreshing && filteredJobs.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = serviceManager.connectionError, filteredJobs.isEmpty {
            ContentUnavailableView {
                Label("SABnzbd Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await serviceManager.refresh() } }
            }
            .scrollableUnavailableState()
        } else {
            // Keep the List mounted even when filtering yields zero results so the
            // segment-bar search field doesn't lose keyboard focus the moment the
            // results drop to empty. Swapping the List out for the empty state
            // tears down the scroll container and resigns first responder.
            ZStack {
                jobsList
                    .opacity(filteredJobs.isEmpty ? 0 : 1)
                    .allowsHitTesting(!filteredJobs.isEmpty)

                if filteredJobs.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySystemImage)
                    } description: {
                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No SABnzbd jobs match this filter.")
                        } else {
                            Text("No SABnzbd jobs match “\(searchText)”.")
                        }
                    }
                    .scrollableUnavailableState()
                }
            }
        }
    }

    private var jobsList: some View {
        List {
            ForEach(filteredJobs) { job in
                NavigationLink {
                    SABnzbdJobDetailView(jobID: job.id, fallbackName: job.name)
                } label: {
                    sabRow(for: job)
                }
                    .listRowBackground(Color.clear)
                    .contextMenu { actions(for: job) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if job.source == .queue {
                            if job.normalizedStatus == .paused {
                                Button("Resume", systemImage: "play.fill") {
                                    perform { try await serviceManager.resume(job: job) }
                                }
                                .tint(.green)
                            } else {
                                Button("Pause", systemImage: "pause.fill") {
                                    perform { try await serviceManager.pause(job: job) }
                                }
                                .tint(.orange)
                            }
                        } else if job.normalizedStatus == .failed {
                            Button("Retry", systemImage: "arrow.clockwise") {
                                perform { try await serviceManager.retry(job: job) }
                            }
                            .tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            jobPendingDeletion = job
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.default, value: filteredJobs.map(\.id))
    }

    private var allJobs: [SABnzbdJob] {
        switch selectedFilter {
        case .queue:
            serviceManager.activeJobs.filter { $0.source == .queue }
        case .downloading:
            serviceManager.activeJobs.filter { $0.normalizedStatus == .downloading }
        case .repairing:
            serviceManager.activeJobs.filter { $0.normalizedStatus == .repairing }
        case .unpacking:
            serviceManager.activeJobs.filter { $0.normalizedStatus == .unpacking }
        case .paused:
            serviceManager.activeJobs.filter { $0.normalizedStatus == .paused }
        case .history:
            serviceManager.historyJobs
        case .failed:
            serviceManager.historyJobs.filter { $0.normalizedStatus == .failed }
        }
    }

    private var filteredJobs: [SABnzbdJob] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allJobs }
        return allJobs.filter { job in
            [job.name, job.status, job.category, job.failureMessage]
                .compactMap { $0 }
                .joined(separator: " ")
                .localizedStandardContains(query)
        }
    }

    private func sabRow(for job: SABnzbdJob) -> some View {
        ArrInfoRowView(
            icon: (job.normalizedStatus.systemImage, job.normalizedStatus.color),
            title: job.name,
            subtitleLeading: job.normalizedStatus.displayName,
            subtitleLeadingColor: job.normalizedStatus.color,
            subtitleTrailing: job.timeRemaining,
            chips: chips(for: job),
            message: job.failureMessage.map { ($0, Color.red) }
        )
    }

    private func chips(for job: SABnzbdJob) -> [ArrReleaseInfoChip] {
        var chips = [
            ArrReleaseInfoChip("\(Int(job.progress * 100))%", color: job.normalizedStatus.color, isProminent: true),
            ArrReleaseInfoChip(job.size, color: .secondary),
            ArrReleaseInfoChip("SABnzbd", color: .indigo)
        ]
        if let category = job.category, !category.isEmpty {
            chips.insert(ArrReleaseInfoChip(category, color: .primary), at: 1)
        }
        return chips
    }

    @ViewBuilder
    private func actions(for job: SABnzbdJob) -> some View {
        if job.source == .queue {
            if job.normalizedStatus == .paused {
                Button("Resume", systemImage: "play.fill") {
                    perform { try await serviceManager.resume(job: job) }
                }
            } else {
                Button("Pause", systemImage: "pause.fill") {
                    perform { try await serviceManager.pause(job: job) }
                }
            }

            Menu("Priority", systemImage: "arrow.up.arrow.down") {
                ForEach(AddDownloadPriority.allCases.filter { $0 != .default }) { priority in
                    Button(priority.displayName) {
                        perform { try await serviceManager.setPriority(job: job, priority: priority) }
                    }
                }
            }

            if !availableCategories.isEmpty {
                Menu("Category", systemImage: "folder") {
                    ForEach(availableCategories, id: \.self) { category in
                        Button(category) {
                            perform { try await serviceManager.setCategory(job: job, category: category) }
                        }
                    }
                }
            }
        }
        if job.normalizedStatus == .failed {
            Button("Retry", systemImage: "arrow.clockwise") {
                perform { try await serviceManager.retry(job: job) }
            }
        }
        Divider()
        Button("Remove", systemImage: "trash", role: .destructive) {
            jobPendingDeletion = job
        }
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { jobPendingDeletion != nil },
            set: { if !$0 { jobPendingDeletion = nil } }
        )
    }

    private func deletePendingJob(deleteFiles: Bool) {
        guard let job = jobPendingDeletion else { return }
        jobPendingDeletion = nil
        perform {
            if job.source == .queue {
                try await serviceManager.delete(job: job, deleteFiles: deleteFiles)
            } else {
                try await serviceManager.deleteHistory(job: job, permanently: true, deleteFiles: deleteFiles)
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                notificationCenter.showError(title: "SABnzbd Action Failed", message: error.localizedDescription)
            }
        }
    }

    private var navigationSubtitle: String {
        let count = filteredJobs.count
        return count == 1 ? "1 job" : "\(count) jobs"
    }

    private var emptyTitle: String {
        switch selectedFilter {
        case .queue: "Queue is Empty"
        case .downloading: "Nothing Downloading"
        case .repairing: "Nothing Repairing"
        case .unpacking: "Nothing Unpacking"
        case .paused: "Nothing Paused"
        case .history: "No History"
        case .failed: "No Failed Jobs"
        }
    }

    private var emptySystemImage: String {
        switch selectedFilter {
        case .queue: "tray"
        case .downloading: "arrow.down.circle"
        case .repairing: "wrench.and.screwdriver"
        case .unpacking: "shippingbox"
        case .paused: "pause.circle"
        case .history: "clock.arrow.circlepath"
        case .failed: "checkmark.circle"
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [Color.indigo.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

private enum SABnzbdManagerFilter: String, CaseIterable, Hashable {
    case queue = "Queue"
    case downloading = "Downloading"
    case repairing = "Repairing"
    case unpacking = "Unpacking"
    case paused = "Paused"
    case history = "History"
    case failed = "Failed"

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }
}

extension SABnzbdNormalizedStatus {
    var displayName: String {
        switch self {
        case .waiting: "Queued"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .repairing: "Repairing"
        case .unpacking: "Unpacking"
        case .processing: "Processing"
        case .completed: "Completed"
        case .failed: "Failed"
        case .unknown(let value): value.isEmpty ? "Unknown" : value
        }
    }

    var color: Color {
        switch self {
        case .waiting, .paused: .secondary
        case .downloading: .blue
        case .repairing: .orange
        case .unpacking, .processing: .purple
        case .completed: .green
        case .failed: .red
        case .unknown: .gray
        }
    }

    var systemImage: String {
        switch self {
        case .waiting: "clock.fill"
        case .downloading: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .repairing: "wrench.and.screwdriver.fill"
        case .unpacking: "shippingbox.fill"
        case .processing: "gearshape.2.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

// MARK: - Job detail

/// Usenet counterpart to `TorrentDetailView`. Takes an `nzo_id` rather than a
/// `SABnzbdJob` value so the screen keeps tracking the polled job instead of
/// freezing on whatever was current at navigation time.
struct SABnzbdJobDetailView: View {
    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter
    @Environment(\.dismiss) private var dismiss

    let jobID: String
    /// Last known name, so the "job is gone" state can still say which job.
    var fallbackName: String?

    @State private var showRemoveAlert = false

    private var job: SABnzbdJob? {
        (serviceManager.activeJobs + serviceManager.historyJobs)
            .first { $0.id.caseInsensitiveCompare(jobID) == .orderedSame }
    }

    private var queueSlot: SABnzbdQueueSlot? {
        serviceManager.queue?.slots.first { $0.nzoID.caseInsensitiveCompare(jobID) == .orderedSame }
    }

    private var historySlot: SABnzbdHistorySlot? {
        serviceManager.history?.slots.first { $0.nzoID.caseInsensitiveCompare(jobID) == .orderedSame }
    }

    var body: some View {
        Group {
            if let job {
                content(for: job)
            } else {
                ContentUnavailableView(
                    "Job Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("\(fallbackName ?? "This SABnzbd job") is no longer in the queue or history.")
                )
            }
        }
        .navigationTitle(job?.name ?? fallbackName ?? "SABnzbd Job")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let job {
                ToolbarItem(placement: .primaryAction) {
                    actionsMenu(for: job)
                }
            }
        }
        .refreshable { await serviceManager.refresh() }
        .task {
            await serviceManager.refresh()
            serviceManager.startPolling()
        }
        .alert("Remove Download?", isPresented: $showRemoveAlert) {
            Button("Remove and Delete Files", role: .destructive) { remove(deleteFiles: true) }
            Button("Remove Job Only", role: .destructive) { remove(deleteFiles: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action can’t be undone.")
        }
    }

    @ViewBuilder
    private func content(for job: SABnzbdJob) -> some View {
        List {
            Section { header(for: job) }

            Section("Transfer") {
                SABnzbdDetailInfoRow(label: "Progress", value: "\(Int(job.progress * 100))%")
                SABnzbdDetailInfoRow(label: "Size", value: job.size)
                if let remaining = job.sizeRemaining, !remaining.isEmpty {
                    SABnzbdDetailInfoRow(label: "Remaining", value: remaining)
                }
                if let eta = activeTimeRemaining(for: job) {
                    SABnzbdDetailInfoRow(label: "Time Remaining", value: eta)
                }
                if let slot = queueSlot, slot.megabytesMissing > 0 {
                    SABnzbdDetailInfoRow(label: "Missing", value: String(format: "%.1f MB", slot.megabytesMissing))
                }
                if let slot = historySlot, slot.downloadTime > 0 {
                    SABnzbdDetailInfoRow(label: "Download Time", value: durationText(slot.downloadTime))
                }
                if let slot = historySlot, slot.postProcessingTime > 0 {
                    SABnzbdDetailInfoRow(label: "Post-Processing", value: durationText(slot.postProcessingTime))
                }
            }

            Section("Info") {
                SABnzbdDetailInfoRow(label: "Status", value: job.status)
                SABnzbdDetailInfoRow(label: "Source", value: job.source == .queue ? "Queue" : "History")
                if let category = job.category, !category.isEmpty {
                    SABnzbdDetailInfoRow(label: "Category", value: category)
                }
                if let slot = queueSlot {
                    SABnzbdDetailInfoRow(label: "Priority", value: slot.priority)
                    if let script = slot.script, !script.isEmpty, script != "None" {
                        SABnzbdDetailInfoRow(label: "Script", value: script)
                    }
                    if slot.timeAdded > 0 {
                        SABnzbdDetailInfoRow(label: "Added", value: dateText(Date(timeIntervalSince1970: TimeInterval(slot.timeAdded))))
                    }
                    if !slot.labels.isEmpty {
                        SABnzbdDetailInfoRow(label: "Labels", value: slot.labels.joined(separator: ", "))
                    }
                }
                if let slot = historySlot {
                    if let nzbName = slot.nzbName, !nzbName.isEmpty, nzbName != slot.name {
                        SABnzbdDetailInfoRow(label: "NZB", value: nzbName)
                    }
                    if slot.timeAdded > 0 {
                        SABnzbdDetailInfoRow(label: "Added", value: dateText(Date(timeIntervalSince1970: TimeInterval(slot.timeAdded))))
                    }
                    if let storage = storagePath(for: slot) {
                        SABnzbdDetailInfoRow(label: "Storage Path", value: storage)
                    }
                }
                if let completedAt = job.completedAt {
                    SABnzbdDetailInfoRow(label: "Completed", value: dateText(completedAt))
                }
            }

            if let failureMessage = job.failureMessage, !failureMessage.isEmpty {
                Section("Failure") {
                    Label(failureMessage, systemImage: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if let slot = historySlot, !slot.stageLog.isEmpty {
                Section("Stages") {
                    ForEach(Array(slot.stageLog.enumerated()), id: \.offset) { _, stage in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stage.name)
                                .font(.subheadline.weight(.semibold))
                            ForEach(Array(stage.actions.enumerated()), id: \.offset) { _, action in
                                Text(action)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let error = serviceManager.connectionError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    @ViewBuilder
    private func header(for job: SABnzbdJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.name)
                .font(.headline)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Image(systemName: job.normalizedStatus.systemImage)
                    .foregroundStyle(job.normalizedStatus.color)
                Text(job.normalizedStatus.displayName)
                    .font(.subheadline)
                    .foregroundStyle(job.normalizedStatus.color)
                if job.isPostProcessing {
                    Text("Post-Processing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                }
                Spacer()
                if let eta = activeTimeRemaining(for: job) {
                    Label(eta, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: job.progress)
                .tint(job.normalizedStatus.color)

            HStack(spacing: 6) {
                Text("\(Int(job.progress * 100))%")
                Text("·")
                Text(sizeSummary(for: job))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionsMenu(for job: SABnzbdJob) -> some View {
        Menu {
            if job.source == .queue {
                if job.normalizedStatus == .paused {
                    Button("Resume", systemImage: "play.fill") {
                        perform { try await serviceManager.resume(job: job) }
                    }
                } else {
                    Button("Pause", systemImage: "pause.fill") {
                        perform { try await serviceManager.pause(job: job) }
                    }
                }
            }
            if job.normalizedStatus == .failed {
                Button("Retry", systemImage: "arrow.clockwise") {
                    perform { try await serviceManager.retry(job: job) }
                }
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) {
                showRemoveAlert = true
            }
        } label: {
            Label("SABnzbd Job Actions", systemImage: "ellipsis")
        }
    }

    // MARK: - Helpers

    private func remove(deleteFiles: Bool) {
        guard let job else { return }
        Task {
            do {
                if job.source == .queue {
                    try await serviceManager.delete(job: job, deleteFiles: deleteFiles)
                } else {
                    try await serviceManager.deleteHistory(job: job, permanently: true, deleteFiles: deleteFiles)
                }
                dismiss()
            } catch {
                notificationCenter.showError(title: "SABnzbd Action Failed", message: error.localizedDescription)
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                notificationCenter.showError(title: "SABnzbd Action Failed", message: error.localizedDescription)
            }
        }
    }

    /// SABnzbd reports `0:00:00` for anything that isn't actively downloading.
    private func activeTimeRemaining(for job: SABnzbdJob) -> String? {
        guard let value = job.timeRemaining?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.split(separator: ":").allSatisfy { Int($0) == 0 } ? nil : value
    }

    /// Queue sizes arrive preformatted, so the summary reads "3.1 GB left of
    /// 12.4 GB" rather than recomputing a byte pair.
    private func sizeSummary(for job: SABnzbdJob) -> String {
        guard let remaining = job.sizeRemaining, !remaining.isEmpty else { return job.size }
        return "\(remaining) left of \(job.size)"
    }

    private func storagePath(for slot: SABnzbdHistorySlot) -> String? {
        let candidates = [slot.storage, slot.path].compactMap { $0 }
        return candidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SABnzbdDetailInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("Manager") {
    PreviewHost(profiles: .sabnzbdOnly, sabnzbd: .preview(.populated)) {
        NavigationStack {
            SABnzbdManagerView()
        }
    }
}

#Preview("Job Detail – Downloading") {
    PreviewHost(profiles: .sabnzbdOnly, sabnzbd: .preview(.populated)) {
        NavigationStack {
            SABnzbdJobDetailView(jobID: SABnzbdJob.previewDownloading.id)
        }
    }
}

#Preview("Job Detail – Paused") {
    PreviewHost(profiles: .sabnzbdOnly, sabnzbd: .preview(.populated)) {
        NavigationStack {
            SABnzbdJobDetailView(jobID: SABnzbdJob.previewPaused.id)
        }
    }
}

#Preview("Job Detail – Completed History") {
    PreviewHost(profiles: .sabnzbdOnly, sabnzbd: .preview(.populated)) {
        NavigationStack {
            SABnzbdJobDetailView(jobID: SABnzbdJob.previewCompleted.id)
        }
    }
}

#Preview("Job Detail – Failed History") {
    PreviewHost(profiles: .sabnzbdOnly, sabnzbd: .preview(.populated)) {
        NavigationStack {
            SABnzbdJobDetailView(jobID: SABnzbdJob.previewFailed.id)
        }
    }
}

#Preview("Job Detail – Missing") {
    PreviewHost(profiles: .sabnzbdOnly, sabnzbd: .preview(.populated)) {
        NavigationStack {
            SABnzbdJobDetailView(jobID: "SABnzbd_nzo_gone", fallbackName: "Removed.Release.1080p")
        }
    }
}
#endif

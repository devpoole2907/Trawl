import SwiftUI

struct SABnzbdManagerView: View {
    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter

    @State private var selectedFilter: SABnzbdManagerFilter = .queue
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @State private var jobPendingDeletion: SABnzbdJob?

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
                sabRow(for: job)
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

import SwiftUI
import Observation

struct SeerrDashboardView: View {
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @State private var viewModel: SeerrRequestManagementViewModel?
    @State private var deleteTarget: SeerrRequestDisplayItem?
    @State private var isOverviewExpanded = true
    @State private var requestSearchText = ""
    @State private var isSearchExpanded = false

    var body: some View {
        Group {
            if let viewModel {
                requestList(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Requests")
        .task {
            if viewModel == nil, let client = seerrServiceManager.activeClient {
                viewModel = SeerrRequestManagementViewModel(apiClient: client)
            }
            await viewModel?.loadIfNeeded()
        }
    }

    @ViewBuilder
    private func requestList(viewModel: SeerrRequestManagementViewModel) -> some View {
        let query = requestSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredRequests = query.isEmpty
            ? viewModel.requests
            : viewModel.requests.filter { item in
                item.title.localizedCaseInsensitiveContains(query)
                    || item.request.requestedBy?.displayName.localizedCaseInsensitiveContains(query) == true
            }

        List {
            if let requestCount = viewModel.requestCount {
                seerrOverviewSection(requestCount)
            }

            if let errorMessage = viewModel.errorMessage {
                Section("Unavailable") {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isLoading && viewModel.requests.isEmpty {
                loadingRows
            } else if viewModel.requests.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(filteredRequests) { item in
                        SeerrRequestRow(item: item)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if item.request.requestStatus == .pending {
                                    Button {
                                        Task { await viewModel.approve(item) }
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.circle")
                                    }
                                    .tint(.green)

                                    Button {
                                        Task { await viewModel.decline(item) }
                                    } label: {
                                        Label("Decline", systemImage: "xmark.circle")
                                    }
                                    .tint(.orange)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteTarget = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                if item.request.requestStatus == .pending {
                                    Button {
                                        Task { await viewModel.approve(item) }
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.circle")
                                    }

                                    Button {
                                        Task { await viewModel.decline(item) }
                                    } label: {
                                        Label("Decline", systemImage: "xmark.circle")
                                    }
                                }

                                Button(role: .destructive) {
                                    deleteTarget = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }

                    if viewModel.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task { await viewModel.loadMore() }
                    }
                } header: {
                    Text(viewModel.selectedFilter.rawValue)
                } footer: {
                    Text("\(viewModel.totalRequestCount) \(viewModel.totalRequestCount == 1 ? "request" : "requests")")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Filter",
                selection: Binding(
                    get: { viewModel.selectedFilter },
                    set: { newFilter in withAnimation { viewModel.selectedFilter = newFilter } }
                ),
                items: SeerrRequestFilter.allCases.map(\.segmentBarItem),
                searchText: $requestSearchText,
                searchHint: "Search requests",
                isSearchExpanded: $isSearchExpanded,
                searchPlacement: .leading
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .refreshable { await viewModel.loadRequests() }
        .alert(
            "Delete Request?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let deleteTarget else { return }
                self.deleteTarget = nil
                Task { await viewModel.delete(deleteTarget) }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This removes the request from Seerr.")
        }
    }

    private func seerrOverviewSection(_ requestCount: SeerrRequestCount) -> some View {
        Section {
            DisclosureGroup("Seerr Overview", isExpanded: $isOverviewExpanded) {
                LabeledContent("Total", value: "\(requestCount.total ?? 0)")
                LabeledContent("Pending", value: "\(requestCount.pending ?? 0)")
                LabeledContent("Approved", value: "\(requestCount.approved ?? 0)")
                LabeledContent("Available", value: "\(requestCount.available ?? 0)")
                LabeledContent("Movies", value: "\(requestCount.movie ?? 0)")
                LabeledContent("Series", value: "\(requestCount.tv ?? 0)")
            }
        }
    }

    private var loadingRows: some View {
        Section("Requests") {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 64)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 180, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 130, height: 11)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Requests",
            systemImage: "tray",
            description: Text("No requests match the current filter.")
        )
        .listRowBackground(Color.clear)
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [ServiceIdentity.seerr.brandColor.opacity(0.11), Color.teal.opacity(0.06), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [ServiceIdentity.seerr.brandColor.opacity(0.13), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }
}

extension EnvironmentValues {
    @Entry var navigateToSeerrIssues: () -> Void = {}
}

@MainActor
@Observable
private final class SeerrRequestManagementViewModel {
    private(set) var requests: [SeerrRequestDisplayItem] = []
    private(set) var requestCount: SeerrRequestCount?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    var selectedFilter: SeerrRequestFilter = .pending {
        didSet {
            guard selectedFilter != oldValue else { return }
            withAnimation(.default) {
                requests = []
                totalResults = 0
                currentSkip = 0
                requestVersion += 1
                isLoading = true
                errorMessage = nil
            }
            Task { await loadRequests() }
        }
    }

    private let apiClient: SeerrAPIClient
    private let pageSize = 20
    private var currentSkip = 0
    private var totalResults = 0
    private var hasLoaded = false
    private var requestVersion = 0

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    var hasMore: Bool {
        currentSkip + pageSize < totalResults
    }

    var totalRequestCount: Int {
        max(totalResults, requests.count)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await loadRequests()
    }

    func loadRequests() async {
        requestVersion += 1
        let capturedVersion = requestVersion
        let filterValue = selectedFilter.apiValue
        isLoading = true
        errorMessage = nil
        currentSkip = 0

        do {
            async let requestLoad = apiClient.getRequests(
                take: pageSize,
                skip: 0,
                filter: filterValue
            )
            async let countLoad = apiClient.getRequestCount()
            let response = try await requestLoad
            let count = try? await countLoad
            guard capturedVersion == requestVersion else { return }
            let newItems = response.results.map(SeerrRequestDisplayItem.init(from:))
            withAnimation(.default) {
                requests = newItems
                requestCount = count
                totalResults = response.pageInfo.results ?? response.results.count
            }
            hasLoaded = true
            await enrichIfNeeded()
        } catch {
            guard capturedVersion == requestVersion else { return }
            errorMessage = error.localizedDescription
        }

        guard capturedVersion == requestVersion else { return }
        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        let capturedVersion = requestVersion
        let filterValue = selectedFilter.apiValue
        isLoadingMore = true
        let nextSkip = currentSkip + pageSize

        do {
            let response = try await apiClient.getRequests(
                take: pageSize,
                skip: nextSkip,
                filter: filterValue
            )
            guard capturedVersion == requestVersion else {
                isLoadingMore = false
                return
            }
            let displayItems = response.results.map(SeerrRequestDisplayItem.init(from:))
            let existingIds = Set(requests.map(\.id))
            let appended = displayItems.filter { !existingIds.contains($0.id) }
            withAnimation(.default) {
                requests.append(contentsOf: appended)
                currentSkip = nextSkip
                totalResults = response.pageInfo.results ?? totalResults
            }
            await enrichIfNeeded()
        } catch {
            guard capturedVersion == requestVersion else {
                isLoadingMore = false
                return
            }
            errorMessage = error.localizedDescription
        }

        isLoadingMore = false
    }

    private func enrichIfNeeded() async {
        let toEnrich = requests.filter(\.needsEnrichment)
        guard !toEnrich.isEmpty else { return }

        await withTaskGroup(of: (Int, SeerrMediaSummary?).self) { group in
            for item in toEnrich {
                guard let tmdbId = item.request.media?.tmdbId,
                      let mediaType = item.request.media?.mediaType else { continue }
                let itemId = item.id
                group.addTask { [apiClient] in
                    let summary = try? await apiClient.getMediaSummary(tmdbId: tmdbId, mediaType: mediaType)
                    return (itemId, summary)
                }
            }
            for await (id, summary) in group {
                guard let summary else { continue }
                if let index = requests.firstIndex(where: { $0.id == id }) {
                    requests[index].enrich(with: summary)
                }
            }
        }
    }

    func approve(_ item: SeerrRequestDisplayItem) async {
        await update(item) {
            try await apiClient.approveRequest(id: item.request.id)
        }
    }

    func decline(_ item: SeerrRequestDisplayItem) async {
        await update(item) {
            try await apiClient.declineRequest(id: item.request.id)
        }
    }

    func delete(_ item: SeerrRequestDisplayItem) async {
        do {
            try await apiClient.deleteRequest(id: item.request.id)
            withAnimation(.default) {
                requests.removeAll { $0.id == item.id }
                totalResults = max(0, totalResults - 1)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(_ item: SeerrRequestDisplayItem, action: () async throws -> SeerrMediaRequest) async {
        let filterAtStart = selectedFilter
        do {
            let updated = try await action()
            // The user may have switched filters during the network call. Only
            // mutate the visible list if we're still on the same filter.
            if filterAtStart == selectedFilter {
                withAnimation(.default) {
                    if filterAtStart == .all {
                        replace(SeerrRequestDisplayItem(from: updated))
                    } else {
                        requests.removeAll { $0.id == item.id }
                        totalResults = max(0, totalResults - 1)
                    }
                }
            }
            requestCount = try? await apiClient.getRequestCount()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replace(_ item: SeerrRequestDisplayItem) {
        if let index = requests.firstIndex(where: { $0.id == item.id }) {
            requests[index] = item
        }
    }
}

private struct SeerrRequestDisplayItem: Identifiable {
    let request: SeerrMediaRequest
    var title: String
    var mediaTypeLabel: String
    var symbolName: String
    var posterURL: URL?
    var yearText: String?

    var id: Int { request.id }

    var needsEnrichment: Bool {
        guard request.media?.tmdbId != nil else { return false }
        let media = request.media
        return (media?.title == nil && media?.name == nil &&
                media?.originalTitle == nil && media?.originalName == nil) ||
               posterURL == nil
    }

    init(from request: SeerrMediaRequest) {
        let mediaType = request.media?.mediaType
        self.request = request
        self.title = request.media?.displayTitle ?? "Unknown Media"
        self.mediaTypeLabel = request.media?.typeLabel ?? "Media"
        self.symbolName = mediaType == "tv" ? "tv" : "film"
        self.posterURL = request.media?.posterURL
        self.yearText = nil
    }

    mutating func enrich(with summary: SeerrMediaSummary) {
        let newTitle = summary.displayTitle
        if !newTitle.isEmpty && !newTitle.hasPrefix("TMDb ") {
            self.title = newTitle
        }
        if let url = summary.posterURL {
            self.posterURL = url
        }
        self.yearText = summary.yearText
    }
}

private struct SeerrRequestRow: View {
    let item: SeerrRequestDisplayItem

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: item.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: item.symbolName).foregroundStyle(.secondary))
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: item.symbolName)
                        Text(item.mediaTypeLabel)
                    }

                    if let year = item.yearText {
                        Text(year)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let user = item.request.requestedBy {
                        Text("Requested by \(user.displayName)")
                            .lineLimit(1)
                    }

                    if let dateText = item.request.createdAtRelativeText {
                        Text(dateText)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                if item.request.is4k == true {
                    Text("4K")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ServiceIdentity.seerr.brandColor)
                }

                if let status = item.request.badgeStatus {
                    Text(status.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(status.statusColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(status.statusColor)
                }
            }
        }
        .padding(.vertical, 2)
    }

}

// Treated as a list view (request stream); state coverage matches list canon.
#if DEBUG
extension SeerrDashboardView {
    fileprivate init(previewViewModel: SeerrRequestManagementViewModel) {
        self._viewModel = State(initialValue: previewViewModel)
    }
}

extension SeerrRequestManagementViewModel {
    fileprivate convenience init(
        previewRequests: [SeerrMediaRequest],
        requestCount: SeerrRequestCount? = .preview,
        isLoading: Bool = false,
        isLoadingMore: Bool = false,
        errorMessage: String? = nil,
        selectedFilter: SeerrRequestFilter = .pending,
        totalResults: Int? = nil,
        apiClient: SeerrAPIClient = .preview()
    ) {
        self.init(apiClient: apiClient)
        self.requests = previewRequests.map(SeerrRequestDisplayItem.init(from:))
        self.requestCount = requestCount
        self.isLoading = isLoading
        self.isLoadingMore = isLoadingMore
        self.errorMessage = errorMessage
        self.selectedFilter = selectedFilter
        self.totalResults = totalResults ?? previewRequests.count
        self.hasLoaded = true
    }
}

#Preview("Seerr Requests - Loaded") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrDashboardView(
                previewViewModel: SeerrRequestManagementViewModel(
                    previewRequests: SeerrMediaRequest.previewList
                )
            )
        }
    }
}

#Preview("Seerr Requests - Loaded Heavy") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrDashboardView(
                previewViewModel: SeerrRequestManagementViewModel(
                    previewRequests: SeerrMediaRequest.previewHeavyList,
                    requestCount: .preview,
                    selectedFilter: .all
                )
            )
        }
    }
}

#Preview("Seerr Requests - Empty") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrDashboardView(
                previewViewModel: SeerrRequestManagementViewModel(
                    previewRequests: [],
                    requestCount: .previewEmpty
                )
            )
        }
    }
}

#Preview("Seerr Requests - Loading") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connecting)) {
        NavigationStack {
            SeerrDashboardView(
                previewViewModel: SeerrRequestManagementViewModel(
                    previewRequests: [],
                    requestCount: nil,
                    isLoading: true
                )
            )
        }
    }
}

#Preview("Seerr Requests - Error") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.error("Unable to reach Seerr."))) {
        NavigationStack {
            SeerrDashboardView(
                previewViewModel: SeerrRequestManagementViewModel(
                    previewRequests: [],
                    requestCount: nil,
                    errorMessage: "Seerr returned 502 Bad Gateway."
                )
            )
        }
    }
}
#endif

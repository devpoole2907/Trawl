import SwiftUI

struct ArrReleaseActionContent: View {
    let release: ArrRelease
    let artURL: URL?
    let accentColor: Color
    let isGrabbing: Bool
    let onGrab: () async -> Void

    @State private var grabInFlight = false

    private var canDownload: Bool {
        !isGrabbing && release.downloadAllowed != false
    }

    private var qualityScoreText: String? {
        guard let score = release.customFormatScore, score != 0 else { return nil }
        return score > 0 ? "+\(score)" : "\(score)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                heroHeader
                qualityBadgeRow
                statsGrid

                if let rejections = release.rejections, !rejections.isEmpty {
                    rejectionsCard(rejections)
                }

                downloadButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background {
            ArrArtworkView(url: artURL, contentMode: .fill) {
                Rectangle().fill(accentColor.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(1.4)
            .blur(radius: 60)
            .saturation(1.6)
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .navigationTitle("Release")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var heroHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.25))
                    .frame(width: 78, height: 78)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(spacing: 6) {
                Text(release.title ?? "Unknown Release")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                    Text(release.indexer ?? "Unknown Indexer")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var qualityBadgeRow: some View {
        HStack(spacing: 8) {
            badge(text: release.qualityName, systemImage: "sparkles", tint: accentColor)
            badge(text: release.protocolName, systemImage: "network", tint: .blue)
            if let score = qualityScoreText {
                badge(text: score, systemImage: "star.fill", tint: .yellow)
            }
            if release.approved == true {
                badge(text: "Approved", systemImage: "checkmark.seal.fill", tint: .green)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statsGrid: some View {
        let cells: [StatCell] = [
            release.size.map { StatCell(systemImage: "externaldrive.fill", label: "Size", value: ByteFormatter.format(bytes: $0), tint: .cyan) },
            release.ageDescription.map { StatCell(systemImage: "clock.fill", label: "Age", value: $0, tint: .pink) },
            release.seeders.map { StatCell(systemImage: "arrow.up.circle.fill", label: "Seeders", value: "\($0)", tint: seederColor(for: $0)) },
            release.leechers.map { StatCell(systemImage: "arrow.down.circle.fill", label: "Leechers", value: "\($0)", tint: .orange) }
        ].compactMap { $0 }

        if !cells.isEmpty {
            let columns = [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ]
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(cells) { cell in
                    statCellView(cell)
                }
            }
        }
    }

    private func statCellView(_ cell: StatCell) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(cell.tint.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: cell.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(cell.tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(cell.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(cell.value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func rejectionsCard(_ rejections: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Alerts", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(rejections, id: \.self) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.orange.opacity(0.8))
                            .padding(.top, 5)
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var downloadButton: some View {
        Button {
            guard !grabInFlight else { return }
            Task {
                grabInFlight = true
                defer { grabInFlight = false }
                await onGrab()
            }
        } label: {
            HStack(spacing: 12) {
                if isGrabbing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.headline)
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Download Release")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(release.indexer ?? release.qualityName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!canDownload)
    }

    private func badge(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.18), in: Capsule())
        .overlay(
            Capsule().stroke(tint.opacity(0.4), lineWidth: 1)
        )
    }

    private func seederColor(for seeders: Int) -> Color {
        switch seeders {
        case 50...: .green
        case 10...: .mint
        case 1...: .orange
        default: .red
        }
    }

    private struct StatCell: Identifiable {
        let id = UUID()
        let systemImage: String
        let label: String
        let value: String
        let tint: Color
    }
}

struct ArrReleaseRowView: View {
    let release: ArrRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(release.title ?? "Unknown Release")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(release.indexer ?? "Unknown Indexer")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let age = release.ageDescription {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(age)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if release.approved != true {
                        releaseChip(release.rejected == true ? "Rejected" : "Not Approved", color: .orange)
                    }
                    releaseChip(release.qualityName, color: .primary)
                    if let size = release.size, size > 0 {
                        releaseChip(ByteFormatter.format(bytes: size), color: .secondary)
                    }
                    releaseChip(release.protocolName, color: .secondary)
                    if let seederLabel {
                        releaseChip(seederLabel, color: seederColor(for: release.seeders ?? 0), isProminent: true)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var seederLabel: String? {
        switch (release.seeders, release.leechers) {
        case let (seeders?, leechers?):
            "S:\(seeders) L:\(leechers)"
        case let (seeders?, nil):
            "S:\(seeders)"
        case let (nil, leechers?):
            "L:\(leechers)"
        case (nil, nil):
            nil
        }
    }

    private func releaseChip(_ label: String, color: Color, isProminent: Bool = false) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(isProminent ? 0.22 : 0.1))
            .clipShape(Capsule())
    }

    private func seederColor(for seeders: Int) -> Color {
        switch seeders {
        case 50...: .green
        case 10...: .mint
        case 1...: .orange
        default: .red
        }
    }
}

struct ArrInteractiveSearchBrowser<Destination: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let emptyDescription: String
    let loadingDescription: String
    let supportsSeasonPackFiltering: Bool
    let loadAction: () async throws -> [ArrRelease]
    let grabAction: (ArrRelease) async -> Bool
    let currentErrorMessage: () -> String?
    @ViewBuilder let destination: (ArrRelease, Bool, @escaping () async -> Void) -> Destination

    @State private var releases: [ArrRelease] = []
    @State private var isLoading = false
    @State private var grabbingReleaseID: String?
    @State private var hasLoaded = false
    @State private var searchText = ""
    @State private var releaseSort: ArrReleaseSort
    @State private var searchError: String?

    init(
        title: String,
        emptyDescription: String,
        loadingDescription: String,
        supportsSeasonPackFiltering: Bool = false,
        initialSort: ArrReleaseSort = ArrReleaseSort(),
        loadAction: @escaping () async throws -> [ArrRelease],
        grabAction: @escaping (ArrRelease) async -> Bool,
        currentErrorMessage: @escaping () -> String?,
        @ViewBuilder destination: @escaping (ArrRelease, Bool, @escaping () async -> Void) -> Destination
    ) {
        self.title = title
        self.emptyDescription = emptyDescription
        self.loadingDescription = loadingDescription
        self.supportsSeasonPackFiltering = supportsSeasonPackFiltering
        self.loadAction = loadAction
        self.grabAction = grabAction
        self.currentErrorMessage = currentErrorMessage
        self.destination = destination
        self._releaseSort = State(initialValue: initialSort)
    }

    private var availableIndexers: [String] {
        Array(Set(releases.compactMap(\.indexer))).sorted()
    }

    private var availableQualities: [String] {
        Array(Set(releases.map(\.qualityName))).sorted()
    }

    private var sortedFilteredReleases: [ArrRelease] {
        let filtered = releases.filter { release in
            let matchesIndexer = releaseSort.indexer.isEmpty || releaseSort.indexer == release.indexer
            let matchesQuality = releaseSort.quality.isEmpty || releaseSort.quality == release.qualityName
            let matchesApproved = !releaseSort.approvedOnly || release.approved == true
            let matchesSeasonPack = matchesSeasonPack(for: release)
            return matchesIndexer && matchesQuality && matchesApproved && matchesSeasonPack
        }
        guard releaseSort.option != .default else { return filtered }
        return filtered.sorted { lhs, rhs in
            let asc = releaseSort.isAscending
            switch releaseSort.option {
            case .default: return false
            case .age:
                let lhsAge = lhs.ageHours ?? Double(lhs.age ?? 0) * 24
                let rhsAge = rhs.ageHours ?? Double(rhs.age ?? 0) * 24
                return asc ? lhsAge < rhsAge : lhsAge > rhsAge
            case .quality:
                return asc ? lhs.qualityName < rhs.qualityName : lhs.qualityName > rhs.qualityName
            case .size:
                return asc ? (lhs.size ?? 0) < (rhs.size ?? 0) : (lhs.size ?? 0) > (rhs.size ?? 0)
            case .seeders:
                return asc ? (lhs.seeders ?? 0) < (rhs.seeders ?? 0) : (lhs.seeders ?? 0) > (rhs.seeders ?? 0)
            }
        }
    }

    private var displayedReleases: [ArrRelease] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return sortedFilteredReleases }
        return sortedFilteredReleases.filter { release in
            release.title?.localizedCaseInsensitiveContains(text) == true ||
            release.indexer?.localizedCaseInsensitiveContains(text) == true
        }
    }

    private var hiddenByFiltersCount: Int {
        releases.count - sortedFilteredReleases.count
    }

    private var qualityFilterItems: [TrawlSegmentBarItem<String>] {
        [TrawlSegmentBarItem("All", value: "")]
            + availableQualities.map { TrawlSegmentBarItem($0, value: $0) }
    }

    private var releaseCountSubtitle: String {
        guard !releases.isEmpty else { return "" }
        let shown = displayedReleases.count
        let total = releases.count
        if shown == total {
            return total == 1 ? "\(total) release" : "\(total) releases"
        }
        return total == 1 ? "\(shown) of \(total) release" : "\(shown) of \(total) releases"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error = searchError, !error.isEmpty {
                    ContentUnavailableView {
                        Label("Search Failed", systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            searchError = nil
                            hasLoaded = false
                            Task { await loadReleases() }
                        }
                    }
                } else if releases.isEmpty && hasLoaded {
                    ContentUnavailableView(
                        "No Releases Found",
                        systemImage: "magnifyingglass",
                        description: Text(emptyDescription)
                    )
                } else if !releases.isEmpty && displayedReleases.isEmpty {
                    ContentUnavailableView {
                        Label("No Releases", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Some releases are hidden by the selected filters.")
                    } actions: {
                        Button("Clear Filters") { clearFilters() }
                    }
                } else {
                    List {
                        if isLoading && releases.isEmpty {
                            Section {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Searching indexers…")
                                            .font(.subheadline.weight(.semibold))
                                        Text(loadingDescription)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        ForEach(displayedReleases) { release in
                            NavigationLink {
                                destination(
                                    release,
                                    grabbingReleaseID == release.id,
                                    { await grab(release: release) }
                                )
                            } label: {
                                ArrReleaseRowView(release: release)
                            }
                        }
                        .animation(.default, value: displayedReleases.map(\.id))

                        if releaseSort.isFiltered && hiddenByFiltersCount > 0 {
                            Section {
                                EmptyView()
                            } footer: {
                                Label(
                                    "\(hiddenByFiltersCount) release\(hiddenByFiltersCount == 1 ? "" : "s") hidden by filters",
                                    systemImage: "line.3.horizontal.decrease.circle"
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                }
            }
            .searchable(text: $searchText, prompt: "Search releases…")
            .safeAreaInset(edge: .top) {
                if !releases.isEmpty {
                    qualityFilterBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(releaseCountSubtitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                    sortMenu
                    filterMenu
                }
            }
            .task {
                await loadReleases()
            }
            .onChange(of: releaseSort.option) { _, _ in
                releaseSort.isAscending = false
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $releaseSort.option) {
                ForEach(ArrReleaseSortKey.allCases) { key in
                    Label(key.rawValue, systemImage: key.systemImage).tag(key)
                }
            }
            .pickerStyle(.inline)
            .menuIndicator(.hidden)

            if releaseSort.option != .default {
                Picker("Direction", selection: $releaseSort.isAscending) {
                    Label("Descending", systemImage: "arrow.down").tag(false)
                    Label("Ascending", systemImage: "arrow.up").tag(true)
                }
                .pickerStyle(.inline)
                .menuIndicator(.hidden)
            }
        } label: {
            Image(systemName: releaseSort.option != .default ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down")
        }
    }

    private var qualityFilterBar: some View {
        TrawlSegmentBar(
            "Quality",
            selection: Binding(
                get: { releaseSort.quality },
                set: { quality in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        releaseSort.quality = quality
                    }
                }
            ),
            items: qualityFilterItems
        )
    }

    private var filterMenu: some View {
        Menu {
            if supportsSeasonPackFiltering {
                Picker("Type", selection: $releaseSort.seasonPack) {
                    ForEach(ArrSeasonPackFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.inline)
                .menuIndicator(.hidden)
            }

            if !availableIndexers.isEmpty {
                Picker("Indexer", selection: $releaseSort.indexer) {
                    Text("All Indexers").tag("")
                    ForEach(availableIndexers, id: \.self) { indexer in
                        Text(indexer).tag(indexer)
                    }
                }
                .pickerStyle(.inline)
                .menuIndicator(.hidden)
            }

            Toggle("Approved Only", isOn: $releaseSort.approvedOnly)
        } label: {
            Image(systemName: releaseSort.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private func matchesSeasonPack(for release: ArrRelease) -> Bool {
        guard supportsSeasonPackFiltering else { return true }
        switch releaseSort.seasonPack {
        case .any:
            return true
        case .season:
            return release.fullSeason == true
        case .episode:
            return release.fullSeason != true
        }
    }

    private func clearFilters() {
        releaseSort.indexer = ""
        releaseSort.quality = ""
        releaseSort.approvedOnly = false
        releaseSort.seasonPack = .any
    }

    private func loadReleases() async {
        guard !hasLoaded else { return }
        isLoading = true
        releases = []
        searchError = nil
        do {
            let results = try await loadAction()
            isLoading = false
            let batchSize = results.count > 30 ? 6 : 3
            for batch in results.chunked(into: batchSize) {
                guard !Task.isCancelled else { break }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    releases.append(contentsOf: batch)
                }
                try? await Task.sleep(nanoseconds: 18_000_000)
            }
            hasLoaded = true
        } catch is CancellationError {
            hasLoaded = false
            isLoading = false
        } catch {
            searchError = interactiveSearchErrorMessage(error)
            hasLoaded = true
            isLoading = false
        }
    }

    private func grab(release: ArrRelease) async {
        guard grabbingReleaseID == nil else { return }
        grabbingReleaseID = release.id
        let didGrab = await grabAction(release)
        grabbingReleaseID = nil

        if didGrab {
            dismiss()
        } else if let error = currentErrorMessage(), !error.isEmpty {
            InAppNotificationCenter.shared.showError(title: "Grab Failed", message: error)
        }
    }

    private func interactiveSearchErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription)\n\nCode: \(nsError.domain) \(nsError.code)"
    }
}

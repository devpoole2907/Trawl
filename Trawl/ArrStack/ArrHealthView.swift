import SwiftUI

// MARK: - Service Filter

enum ArrServiceFilter: CaseIterable, Hashable {
    case all, sonarr, radarr, prowlarr, bazarr

    static let healthFilters: [Self] = [.all, .sonarr, .radarr, .prowlarr]

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
        case .sonarr:   ServiceIdentity.sonarr.brandColor
        case .radarr:   ServiceIdentity.radarr.brandColor
        case .prowlarr: ServiceIdentity.prowlarr.brandColor
        case .bazarr:   ServiceIdentity.bazarr.brandColor
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

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(title, value: self)
    }
}

struct ArrServiceFilterBar: View {
    let title: String
    @Binding var selection: ArrServiceFilter
    let filters: [ArrServiceFilter]
    var alignment: TrawlSegmentBarAlignment = .center

    var body: some View {
        TrawlSegmentBar(title, selection: Binding(
            get: { selection },
            set: { newValue in withAnimation { selection = newValue } }
        ), items: filters.map(\.segmentBarItem), alignment: alignment)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Health View

struct ArrHealthView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var serviceFilter: ArrServiceFilter = .all
    @State private var selectedItem: HealthItem?
    @State private var showSettings = false
    private let previewHealthItems: [HealthItem]?

    init() {
        self.previewHealthItems = nil
    }

    #if DEBUG
    init(previewChecks: [ArrHealthCheck], service: ArrServiceType = .sonarr) {
        self.previewHealthItems = previewChecks.enumerated().map {
            HealthItem(check: $0.element, source: service, index: $0.offset)
        }
    }
    #endif

    private var allChecks: [HealthItem] {
        if let previewHealthItems {
            return previewHealthItems.sorted { $0.severityRank > $1.severityRank }
        }

        return (
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
        .safeAreaInset(edge: .top) {
            if hasConfiguredService {
                ArrServiceFilterBar(title: "Service", selection: $serviceFilter, filters: healthFilters, alignment: .leading)
            }
        }
        .task(id: healthReloadKey) {
            if previewHealthItems != nil { return }
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
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

    private var healthFilters: [ArrServiceFilter] {
        var filters: [ArrServiceFilter] = [.all]
        if serviceManager.hasSonarrInstance { filters.append(.sonarr) }
        if serviceManager.hasRadarrInstance { filters.append(.radarr) }
        if serviceManager.hasProwlarrInstance { filters.append(.prowlarr) }
        return filters
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
            ContentUnavailableView {
                Label("No Services Configured", systemImage: "heart.text.square")
            } description: {
                Text("Add Sonarr, Radarr, or Prowlarr in Settings to view health checks.")
            } actions: {
                MoreSettingsNavigationLink()
            }
            .scrollableUnavailableState()
        } else if !hasConnectedService {
            ArrServicesConnectionStatusView(
                services: healthServices,
                title: "Services Unreachable",
                message: "Unable to reach your configured servers."
            )
        } else {
            healthList
        }
    }

    private var healthList: some View {
        List {
            if filteredChecks.isEmpty {
                ContentUnavailableView(
                    "No Health Issues",
                    systemImage: "checkmark.circle",
                    description: Text("No health warnings reported for the selected services.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredChecks) { item in
                    Button { selectedItem = item } label: {
                        HealthCheckRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await serviceManager.loadHealth() }
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
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
        // Active Sonarr/Radarr instance IDs ensure health checks reload for the now-active
        // instance when switching between connected instances.
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)-\(serviceManager.prowlarrConnected)-\(serviceManager.activeSonarrInstanceID?.uuidString ?? "none")-\(serviceManager.activeRadarrInstanceID?.uuidString ?? "none")"
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
        item.source.serviceIdentity.brandColor
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

#if DEBUG
#Preview("Health - Issues") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrHealthView(previewChecks: ArrHealthCheck.previewList, service: .sonarr)
        }
    }
}

#Preview("Health - Empty") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrHealthView()
        }
    }
}
#endif

import SwiftUI

struct ArrDiskSpaceView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(ArrDiskSpaceBrowserState.self) private var sharedBrowser: ArrDiskSpaceBrowserState?
    @State private var localBrowser = ArrDiskSpaceBrowserState()

    private var browser: ArrDiskSpaceBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }
    private var showsDetailPane: Bool { sidebarColumn != nil }

    #if DEBUG
    init(previewSnapshots: [ArrDiskSpaceSnapshot] = [], isLoading: Bool = false) {
        let browser = ArrDiskSpaceBrowserState()
        browser.snapshots = previewSnapshots
        browser.isLoading = isLoading
        _localBrowser = State(initialValue: browser)
    }
    #else
    init() {}
    #endif

    var body: some View {
        Group {
            if showsDetailPane {
                TrawlListDetailPanes(title: "Disk Space", subtitle: "Storage") {
                    diskList
                } detail: {
                    selectedDiskDetail
                }
                .task(id: reloadKey) {
                    #if DEBUG
                    if ArrPreviewRuntime.isActive { return }
                    #endif
                    guard sidebarColumn != .detail else { return }
                    await browser.loadDiskSpace(serviceManager: serviceManager)
                }
            } else {
                compactContent
            }
        }
    }

    // MARK: - Split View List Column
    @ViewBuilder
    private var diskList: some View {
        @Bindable var browser = self.browser
        Group {
            if !hasConfiguredService {
                ServiceSetupView(title: "No Services Configured", message: "Connect Sonarr or Radarr to inspect storage usage.", systemImage: "server.rack")
                    .scrollableUnavailableState()
            } else if !hasConnectedService {
                ArrServicesConnectionStatusView(
                    services: diskSpaceServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else if browser.isLoading && browser.snapshots.isEmpty {
                ProgressView("Loading disk space...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.snapshots.isEmpty {
                ContentUnavailableView(
                    "No Disk Data",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("No disk space information is currently available from your services.")
                )
                .scrollableUnavailableState()
            } else {
                List(selection: $browser.selectedDiskID) {
                    ForEach(groupedSnapshots, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.snapshots) { snapshot in
                                diskRow(snapshot)
                                    .tag(snapshot.id)
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
                .refreshable {
                    await browser.loadDiskSpace(serviceManager: serviceManager)
                }
            }
        }
        .background(backgroundGradient)
        .onChange(of: browser.snapshots.map(\.id), initial: true) { _, _ in
            browser.reconcileSelection()
        }
    }

    // MARK: - Split View Detail Column
    @ViewBuilder
    private var selectedDiskDetail: some View {
        if let selectedID = browser.selectedDiskID,
           let snapshot = browser.snapshots.first(where: { $0.id == selectedID }) {
            ArrDiskDetailView(snapshot: snapshot)
                .id(snapshot.id)
        } else if browser.snapshots.isEmpty {
            listDetailPlaceholder("No Drives", systemImage: "internaldrive")
        } else {
            listDetailPlaceholder("Select a Drive", systemImage: "internaldrive")
        }
    }

    // MARK: - Compact Content (iPhone)
    @ViewBuilder
    private var compactContent: some View {
        Group {
            if !hasConfiguredService {
                ServiceSetupView(title: "No Services Configured", message: "Connect Sonarr or Radarr to inspect storage usage.", systemImage: "server.rack")
                    .scrollableUnavailableState()
            } else if !hasConnectedService {
                ArrServicesConnectionStatusView(
                    services: diskSpaceServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else if browser.isLoading && browser.snapshots.isEmpty {
                ProgressView("Loading disk space...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.snapshots.isEmpty {
                ContentUnavailableView(
                    "No Disk Data",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("No disk space information is currently available from your services.")
                )
                .scrollableUnavailableState()
            } else {
                List {
                    ForEach(groupedSnapshots, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.snapshots) { snapshot in
                                NavigationLink {
                                    ArrDiskDetailView(snapshot: snapshot)
                                } label: {
                                    diskRow(snapshot)
                                }
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
                .refreshable {
                    await browser.loadDiskSpace(serviceManager: serviceManager)
                }
            }
        }
        .background(backgroundGradient)
        .navigationTitle("Disk Space")
        .task(id: reloadKey) {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await browser.loadDiskSpace(serviceManager: serviceManager)
        }
    }

    private var hasConfiguredService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
    }

    private var diskSpaceServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var reloadKey: String {
        // Active Sonarr/Radarr instance IDs are part of the key so switching between
        // connected instances reloads disk space for the now-active instance.
        serviceManager.visibleArrInstances.map(\.ref.id.uuidString).joined(separator: "|")
    }

    /// Snapshots grouped by the server that reported them, in configured order.
    private var groupedSnapshots: [(title: String, snapshots: [ArrDiskSpaceSnapshot])] {
        var groups: [(title: String, snapshots: [ArrDiskSpaceSnapshot])] = []
        for ref in serviceManager.visibleArrInstances.map(\.ref) {
            let matching = browser.snapshots.filter { $0.instance?.id == ref.id }
            guard !matching.isEmpty else { continue }
            groups.append((title: sectionTitle(for: ref), snapshots: matching))
        }
        // Preview and fixture snapshots carry no server; keep them visible under
        // their service name rather than dropping them off the screen.
        for serviceType in [ArrServiceType.sonarr, .radarr] {
            let orphans = browser.snapshots.filter { $0.instance == nil && $0.serviceType == serviceType }
            if !orphans.isEmpty {
                groups.append((title: serviceType.displayName, snapshots: orphans))
            }
        }
        return groups
    }

    private func sectionTitle(for ref: ArrInstanceRef) -> String {
        guard serviceManager.showsInstanceProvenance(for: ref.serviceType) else {
            return ref.serviceType.displayName
        }
        return "\(ref.serviceType.displayName) - \(ref.shortLabel)"
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [Color.teal.opacity(0.24), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [Color.teal.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    private func diskRow(_ snapshot: ArrDiskSpaceSnapshot) -> some View {
        let total = snapshot.totalSpace ?? 0
        let free = snapshot.freeSpace ?? 0
        let used = max(0, total - free)
        let percent = total > 0 ? Int((Double(used) / Double(total)) * 100) : 0
        let isLowSpace = total > 0 && free < total / 10
        let isModerateSpace = total > 0 && free < total / 5

        let statusColor: Color = isLowSpace ? .red : (isModerateSpace ? .orange : .teal)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isLowSpace ? "internaldrive.badge.exclamationmark" : "internaldrive.fill")
                    .font(.subheadline)
                    .foregroundStyle(statusColor)

                Text(snapshot.label ?? (snapshot.path.isEmpty ? "Storage" : snapshot.path))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let freeSpace = snapshot.freeSpace {
                    Text("\(ByteFormatter.format(bytes: freeSpace)) free")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isLowSpace ? .red : .secondary)
                }
            }

            Text(snapshot.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if total > 0 {
                ProgressView(value: Double(used), total: Double(total))
                    .tint(statusColor)

                HStack {
                    Text("\(percent)% full")
                    Spacer()
                    Text("Total \(ByteFormatter.format(bytes: total))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ArrDiskDetailView: View {
    let snapshot: ArrDiskSpaceSnapshot
    @Environment(ArrServiceManager.self) private var serviceManager

    private var total: Int64 { snapshot.totalSpace ?? 0 }
    private var free: Int64 { snapshot.freeSpace ?? 0 }
    private var used: Int64 { max(0, total - free) }
    private var usedFraction: Double {
        total > 0 ? min(1.0, max(0.0, Double(used) / Double(total))) : 0
    }
    private var usedPercent: Int {
        Int(usedFraction * 100)
    }

    private var isLowSpace: Bool {
        total > 0 && free < total / 10
    }
    private var isModerateSpace: Bool {
        total > 0 && free < total / 5
    }

    private var statusColor: Color {
        if isLowSpace { return .red }
        if isModerateSpace { return .orange }
        return .teal
    }

    private var statusText: String {
        if isLowSpace { return "Critically Low" }
        if isModerateSpace { return "Low Space" }
        return "Healthy"
    }

    private var statusIcon: String {
        if isLowSpace { return "exclamationmark.triangle.fill" }
        if isModerateSpace { return "exclamationmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var driveTitle: String {
        snapshot.label ?? (snapshot.path.isEmpty ? "Storage" : snapshot.path)
    }

    private var serverName: String {
        if let instance = snapshot.instance {
            if serviceManager.showsInstanceProvenance(for: instance.serviceType) {
                return "\(instance.serviceType.displayName) - \(instance.shortLabel)"
            }
            return instance.serviceType.displayName
        }
        return snapshot.serviceType.displayName
    }

    private var matchingRootFolders: [ArrRootFolder] {
        guard let instance = snapshot.instance else { return [] }
        let allRoots = serviceManager.rootFolders(for: instance.id)
        let mount = snapshot.path
        if mount == "/" {
            return allRoots
        }
        return allRoots.filter { folder in
            folder.path.hasPrefix(mount)
        }
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        if total > 0 {
            badges.append(ArrDetailBadge(
                icon: "chart.pie.fill",
                label: "\(usedPercent)% Full",
                color: statusColor
            ))
        }
        if free > 0 {
            badges.append(ArrDetailBadge(
                icon: "arrow.down.circle.fill",
                label: "\(ByteFormatter.format(bytes: free)) Free",
                color: isLowSpace ? .red : .secondary
            ))
        }
        if total > 0 {
            badges.append(ArrDetailBadge(
                icon: "internaldrive.fill",
                label: "\(ByteFormatter.format(bytes: total)) Total",
                color: .secondary
            ))
        }
        badges.append(ArrDetailBadge(
            icon: statusIcon,
            label: statusText,
            color: statusColor
        ))
        return badges
    }

    var body: some View {
        Form {
            Section {
                TrawlEntityHeader(
                    title: driveTitle,
                    subtitle: "\(snapshot.path) on \(serverName)",
                    systemImage: isLowSpace ? "internaldrive.badge.exclamationmark" : "internaldrive.fill",
                    tint: statusColor,
                    shape: .rounded,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            if total > 0 {
                Section("Storage Capacity") {
                    storageRingCard
                }
            }

            if !matchingRootFolders.isEmpty {
                Section("Root Folders on this Volume") {
                    ForEach(matchingRootFolders) { folder in
                        rootFolderRow(folder)
                    }
                }
            }

            Section("Drive Information") {
                LabeledContent("Mount Path") {
                    Text(snapshot.path)
                        .textSelection(.enabled)
                }
                if let label = snapshot.label, !label.isEmpty {
                    LabeledContent("Volume Label", value: label)
                }
                LabeledContent("Server") {
                    HStack(spacing: 6) {
                        Image(systemName: snapshot.serviceType.systemImage)
                            .foregroundStyle(snapshot.serviceType.serviceIdentity.brandColor)
                        Text(serverName)
                    }
                }
                if let tier = snapshot.instance?.tier {
                    LabeledContent("Quality Tier", value: tier.label)
                }
                LabeledContent("Status") {
                    HStack(spacing: 4) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                        Text(statusText)
                            .foregroundStyle(statusColor)
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .paneAwareNavigationTitle(
            driveTitle,
            subtitle: "Disk Space",
            whenPane: driveTitle
        )
    }

    private var storageRingCard: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 14)

                Circle()
                    .trim(from: 0, to: CGFloat(usedFraction))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: isLowSpace ? [.red, .orange] : [.teal, statusColor]),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: usedFraction)

                VStack(spacing: 2) {
                    Text("\(usedPercent)%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Used")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, height: 130)
            .padding(.top, 8)

            HStack(spacing: 0) {
                storageMetricBox(
                    title: "Used",
                    value: ByteFormatter.format(bytes: used),
                    color: statusColor
                )
                Divider()
                    .frame(height: 36)
                storageMetricBox(
                    title: "Free",
                    value: ByteFormatter.format(bytes: free),
                    color: isLowSpace ? .red : .primary
                )
                Divider()
                    .frame(height: 36)
                storageMetricBox(
                    title: "Capacity",
                    value: ByteFormatter.format(bytes: total),
                    color: .secondary
                )
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func storageMetricBox(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private func rootFolderRow(_ folder: ArrRootFolder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: folder.accessible == false ? "folder.badge.minus" : "folder.fill")
                .font(.title3)
                .foregroundStyle(folder.accessible == false ? .red : .teal)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.path)
                    .font(.subheadline.weight(.medium))
                    .textSelection(.enabled)

                if folder.accessible == false {
                    Text("Inaccessible")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            if folder.accessible == false {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview("Disk Space - Loaded") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrDiskSpaceView(previewSnapshots: ArrDiskSpaceSnapshot.previewList)
        }
    }
}

#Preview("Disk Space - Detail") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            if let snapshot = ArrDiskSpaceSnapshot.previewList.first {
                ArrDiskDetailView(snapshot: snapshot)
            }
        }
    }
}

#Preview("Disk Space - Empty") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrDiskSpaceView()
        }
    }
}

#Preview("Disk Space - Loading") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrDiskSpaceView(isLoading: true)
        }
    }
}

#Preview("Disk Space - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrDiskSpaceView()
        }
    }
}
#endif

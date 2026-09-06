import SwiftUI
import SwiftData

struct CleanuparrDashboardView: View {
    @Environment(CleanuparrServiceManager.self) private var serviceManager
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(\.hasDetailPane) private var hasDetailPane
    @Environment(CleanuparrBrowserState.self) private var sharedBrowser: CleanuparrBrowserState?
    @State private var localBrowser = CleanuparrBrowserState()
    @Query private var profiles: [CleanuparrServiceProfile]
    @State private var showingEditServerSheet = false

    private var browser: CleanuparrBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }

    private var profile: CleanuparrServiceProfile? {
        profiles.first(where: { $0.isEnabled }) ?? profiles.first
    }

    var body: some View {
        TrawlListDetailPanes(title: "Cleanuparr") {
            cleanuparrListContent
        } detail: {
            cleanuparrDetailContent
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(ServiceIdentity.cleanuparr.brandColor)
        .task(id: refreshKey) {
            guard sidebarColumn != .detail else { return }
            guard serviceManager.hasConfiguredProfile else { return }
            await serviceManager.refresh(hours: browser.timeframeHours, includeDryRun: browser.includeDryRun)
        }
        .refreshable {
            guard sidebarColumn != .detail else { return }
            guard serviceManager.hasConfiguredProfile else { return }
            await serviceManager.refresh(hours: browser.timeframeHours, includeDryRun: browser.includeDryRun)
        }
    }

    // MARK: - List Content (Middle Column or Single Page on iOS)

    @ViewBuilder
    private var cleanuparrListContent: some View {
        List(selection: hasDetailPane ? Binding(
            get: { browser.selectedItem ?? .overview },
            set: { browser.selectedItem = $0 }
        ) : .constant(nil)) {
            if !serviceManager.hasConfiguredProfile {
                ServiceSetupView(
                    title: "Cleanuparr Not Set Up",
                    message: "Add a Cleanuparr server in Settings to see cleanup activity, strikes, and job runs.",
                    systemImage: ServiceIdentity.cleanuparr.systemImage
                )
                .listRowBackground(Color.clear)
            } else {
                controlsSection

                if let error = serviceManager.connectionError, serviceManager.stats != nil {
                    ServiceErrorView(
                        title: "Cleanuparr Unavailable",
                        message: error,
                        identity: .cleanuparr,
                        hasContent: true,
                        onRetry: { await serviceManager.refresh(hours: browser.timeframeHours, includeDryRun: browser.includeDryRun) }
                    )
                }

                if let stats = serviceManager.stats {
                    if hasDetailPane {
                        // Regular width (macOS & iPadOS): Content column renders selectable categories/items
                        splitViewSections(stats: stats)
                    } else {
                        // Compact width (iPhone): Preserves the full single-page dashboard inline
                        compactSections(stats: stats)
                    }
                } else if serviceManager.isConnecting || serviceManager.isRefreshing {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading Cleanuparr…")
                            Spacer()
                        }
                    }
                } else {
                    Section {
                        ServiceErrorView(
                            title: "Cleanuparr Unavailable",
                            message: serviceManager.connectionError ?? "Set up Cleanuparr in Settings to view cleanup activity.",
                            identity: .cleanuparr,
                            onRetry: { await serviceManager.refresh(hours: browser.timeframeHours, includeDryRun: browser.includeDryRun) }
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showingEditServerSheet) {
            CleanuparrSetupSheet {
                Task {
                    await serviceManager.initialize(from: profiles)
                }
            }
        }
    }

    private var controlsSection: some View {
        Section {
            Picker("Timeframe", selection: Binding(
                get: { browser.timeframeHours },
                set: { browser.timeframeHours = $0 }
            )) {
                Text("24 Hours").tag(24)
                Text("7 Days").tag(168)
                Text("30 Days").tag(720)
                Text("1 Year").tag(8_760)
            }
            Toggle("Include Dry Runs", isOn: Binding(
                get: { browser.includeDryRun },
                set: { browser.includeDryRun = $0 }
            ))
        } footer: {
            Text("Activity comes from Cleanuparr's documented read-only Stats API.")
        }
    }

    // MARK: - Regular Split-View Sections (Content Column)

    @ViewBuilder
    private func splitViewSections(stats: CleanuparrStats) -> some View {
        Section("Activity") {
            Button {
                browser.selectedItem = .overview
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(ServiceIdentity.cleanuparr.brandColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity Overview")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("\(stats.events.total) Events • \(stats.strikes.total) Strikes • \(stats.removals.total) Removed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tag(CleanuparrDetailItem.overview)
        }

        Section("Jobs") {
            LabeledContent("Runs", value: stats.jobs.total, format: .number)
            LabeledContent("Failed Runs", value: stats.jobs.failed, format: .number)

            ForEach(stats.jobs.byType.sorted(by: { $0.key < $1.key }), id: \.key) { name, job in
                Button {
                    browser.selectedItem = .job(name: name)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(displayName(for: name))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(job.completed)/\(job.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if job.failed > 0 {
                            Label("\(job.failed) failed", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let nextRun = formattedDate(job.nextRunAt) {
                            Text("Next: \(nextRun)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(CleanuparrDetailItem.job(name: name))
            }
        }

        if !stats.health.downloadClients.isEmpty {
            Section("Download Client Health") {
                ForEach(stats.health.downloadClients) { service in
                    Button {
                        browser.selectedItem = .serviceHealth(id: service.id)
                    } label: {
                        healthRow(service)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(CleanuparrDetailItem.serviceHealth(id: service.id))
                }
            }
        }

        if !stats.health.arrInstances.isEmpty {
            Section("Arr Health") {
                ForEach(stats.health.arrInstances) { service in
                    Button {
                        browser.selectedItem = .serviceHealth(id: service.id)
                    } label: {
                        healthRow(service)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(CleanuparrDetailItem.serviceHealth(id: service.id))
                }
            }
        }

        Section("Server") {
            Button {
                browser.selectedItem = .server
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.title3)
                        .foregroundStyle(ServiceIdentity.cleanuparr.brandColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile?.displayName ?? "Cleanuparr Server")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(readinessDescription)
                            .font(.caption)
                            .foregroundStyle(readinessColor)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tag(CleanuparrDetailItem.server)
        }
    }

    // MARK: - Compact Sections (iPhone)

    @ViewBuilder
    private func compactSections(stats: CleanuparrStats) -> some View {
        Section("Activity") {
            LabeledContent("Events", value: stats.events.total, format: .number)
            LabeledContent("Strikes", value: stats.strikes.total, format: .number)
            LabeledContent("Recovered", value: stats.strikes.recovered, format: .number)
            LabeledContent("Removed", value: stats.removals.total, format: .number)
            LabeledContent("Seeded Downloads Cleaned", value: stats.cleaned.total, format: .number)
        }

        if !stats.removals.byReason.isEmpty {
            Section("Removal Reasons") {
                ForEach(stats.removals.byReason.sorted(by: { $0.key < $1.key }), id: \.key) { reason, count in
                    LabeledContent(displayName(for: reason), value: count, format: .number)
                }
            }
        }

        Section("Searches") {
            LabeledContent("Started", value: stats.searches.total, format: .number)
            LabeledContent("Completed", value: stats.searches.completed, format: .number)
            LabeledContent("Failed", value: stats.searches.failed, format: .number)
            LabeledContent("Grabbed", value: stats.searches.grabbed, format: .number)
        }

        Section("Jobs") {
            LabeledContent("Runs", value: stats.jobs.total, format: .number)
            LabeledContent("Failed Runs", value: stats.jobs.failed, format: .number)

            ForEach(stats.jobs.byType.sorted(by: { $0.key < $1.key }), id: \.key) { name, job in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(displayName(for: name))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(job.completed)/\(job.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if job.failed > 0 {
                        Label("\(job.failed) failed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let nextRun = formattedDate(job.nextRunAt) {
                        Text("Next: \(nextRun)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if !stats.health.downloadClients.isEmpty {
            Section("Download Client Health") {
                ForEach(stats.health.downloadClients) { service in
                    healthRow(service)
                }
            }
        }

        if !stats.health.arrInstances.isEmpty {
            Section("Arr Health") {
                ForEach(stats.health.arrInstances) { service in
                    healthRow(service)
                }
            }
        }

        Section {
            LabeledContent("Cleanuparr Readiness") {
                Text(readinessDescription)
                    .foregroundStyle(readinessColor)
            }
            if let generatedAt = formattedDate(stats.generatedAt) {
                LabeledContent("Generated") {
                    Text(generatedAt)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Detail Content (Right Column)

    @ViewBuilder
    private var cleanuparrDetailContent: some View {
        if !serviceManager.hasConfiguredProfile {
            listDetailPlaceholder("Cleanuparr Not Set Up", systemImage: ServiceIdentity.cleanuparr.systemImage)
        } else if let stats = serviceManager.stats {
            switch browser.selectedItem ?? .overview {
            case .overview:
                overviewDetailPane(stats: stats)
            case .job(let name):
                if let job = stats.jobs.byType[name] {
                    jobDetailPane(name: name, job: job)
                } else {
                    listDetailPlaceholder("Select a Job", systemImage: "clock.arrow.2.circlepath")
                }
            case .serviceHealth(let id):
                if let service = (stats.health.downloadClients + stats.health.arrInstances).first(where: { $0.id == id }) {
                    serviceHealthDetailPane(service: service)
                } else {
                    listDetailPlaceholder("Select a Service", systemImage: "stethoscope")
                }
            case .server:
                serverDetailPane(stats: stats)
            }
        } else if serviceManager.isConnecting || serviceManager.isRefreshing {
            ProgressView("Loading Cleanuparr…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            listDetailPlaceholder("Cleanuparr Unavailable", systemImage: "exclamationmark.triangle")
        }
    }

    // MARK: - Specific Detail Panes

    private func overviewDetailPane(stats: CleanuparrStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Activity Analytics", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(ServiceIdentity.cleanuparr.brandColor)
                        Spacer()
                        Text(timeframeLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }

                    if browser.includeDryRun {
                        Label("Including Dry Run Calculations", systemImage: "eye.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                // Key metrics grid
                VStack(alignment: .leading, spacing: 10) {
                    Text("Activity Metrics")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            metricTile(title: "Events", value: "\(stats.events.total)", icon: "bolt.fill", color: .blue)
                            metricTile(title: "Strikes", value: "\(stats.strikes.total)", icon: "exclamationmark.shield.fill", color: .orange)
                        }
                        GridRow {
                            metricTile(title: "Recovered", value: "\(stats.strikes.recovered)", icon: "arrow.counterclockwise.circle.fill", color: .green)
                            metricTile(title: "Removed", value: "\(stats.removals.total)", icon: "trash.fill", color: .red)
                        }
                        GridRow {
                            metricTile(title: "Seeded Cleaned", value: "\(stats.cleaned.total)", icon: "leaf.fill", color: .teal)
                            metricTile(title: "Searches Grabbed", value: "\(stats.searches.grabbed)", icon: "arrow.down.circle.fill", color: .purple)
                        }
                    }
                }

                // Removal reasons
                if !stats.removals.byReason.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Removal Reasons")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 8) {
                            ForEach(stats.removals.byReason.sorted(by: { $0.value > $1.value }), id: \.key) { reason, count in
                                HStack {
                                    Text(displayName(for: reason))
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(count)")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)

                                if reason != stats.removals.byReason.sorted(by: { $0.value > $1.value }).last?.key {
                                    Divider()
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                // Searches breakdown
                VStack(alignment: .leading, spacing: 10) {
                    Text("Search Operations")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        labeledDetailRow("Started Searches", value: "\(stats.searches.total)")
                        Divider()
                        labeledDetailRow("Completed Searches", value: "\(stats.searches.completed)")
                        Divider()
                        labeledDetailRow("Grabbed Searches", value: "\(stats.searches.grabbed)")
                        Divider()
                        labeledDetailRow("Failed Searches", value: "\(stats.searches.failed)")
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                // Metadata
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Readiness")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(readinessDescription)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(readinessColor)
                    }

                    if let generatedAt = formattedDate(stats.generatedAt) {
                        HStack {
                            Text("Stats Generated")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(generatedAt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .navigationTitle("Activity")
    }

    private func jobDetailPane(name: String, job: CleanuparrStats.Jobs.Job) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 32))
                        .foregroundStyle(ServiceIdentity.cleanuparr.brandColor)
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: name))
                            .font(.title3.weight(.semibold))

                        HStack(spacing: 8) {
                            if job.failed > 0 {
                                Label("\(job.failed) Failed", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            } else {
                                Label("Healthy", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                // Execution statistics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Execution Performance")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            metricTile(title: "Total Runs", value: "\(job.total)", icon: "play.fill", color: .blue)
                            metricTile(title: "Completed", value: "\(job.completed)", icon: "checkmark.circle.fill", color: .green)
                        }
                        GridRow {
                            metricTile(title: "Failed Runs", value: "\(job.failed)", icon: "exclamationmark.triangle.fill", color: job.failed > 0 ? .orange : .secondary)
                            let successRate = job.total > 0 ? Int(Double(job.completed) / Double(job.total) * 100) : 100
                            metricTile(title: "Success Rate", value: "\(successRate)%", icon: "percent", color: successRate >= 95 ? .green : .orange)
                        }
                    }
                }

                // Timing & schedule
                VStack(alignment: .leading, spacing: 10) {
                    Text("Schedule & History")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        if let lastRun = formattedDate(job.lastRunAt) {
                            labeledDetailRow("Last Run", value: lastRun)
                            Divider()
                        }
                        if let nextRun = formattedDate(job.nextRunAt) {
                            labeledDetailRow("Next Scheduled Run", value: nextRun)
                        } else {
                            labeledDetailRow("Next Scheduled Run", value: "Not scheduled")
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                // Description card
                VStack(alignment: .leading, spacing: 8) {
                    Text("About This Job")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(jobDescription(for: name))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)
        }
        .navigationTitle(displayName(for: name))
    }

    private func serviceHealthDetailPane(service: CleanuparrStats.Health.Service) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack(spacing: 14) {
                    Image(systemName: service.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(service.isHealthy ? .green : .orange)
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.name)
                            .font(.title3.weight(.semibold))

                        Text(service.type.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                // Error callout if unhealthy
                if let error = service.errorMessage, !error.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Health Warning", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)

                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                // Diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connection Diagnostics")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        labeledDetailRow("Service ID", value: service.id)
                        Divider()
                        labeledDetailRow("Status", value: service.isHealthy ? "Healthy" : "Degraded / Unreachable")
                        Divider()
                        if let responseTime = service.responseTimeMs {
                            labeledDetailRow("Response Latency", value: "\(responseTime.formatted(.number.precision(.fractionLength(0...1)))) ms")
                            Divider()
                        }
                        if let lastChecked = formattedDate(service.lastChecked) {
                            labeledDetailRow("Last Checked", value: lastChecked)
                        } else {
                            labeledDetailRow("Last Checked", value: "Unknown")
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)
        }
        .navigationTitle(service.name)
    }

    private func serverDetailPane(stats: CleanuparrStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .foregroundStyle(ServiceIdentity.cleanuparr.brandColor)
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile?.displayName ?? "Cleanuparr Server")
                            .font(.title3.weight(.semibold))

                        Text(profile?.hostURL ?? "Configured in Settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                // Readiness card
                VStack(alignment: .leading, spacing: 10) {
                    Text("Readiness Check")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Status")
                                .font(.subheadline)
                            Spacer()
                            Text(readinessDescription)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(readinessColor)
                        }
                        Divider()
                        if let lastChecked = formattedDate(stats.generatedAt) {
                            HStack {
                                Text("Last Synced")
                                    .font(.subheadline)
                                Spacer()
                                Text(lastChecked)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                // Actions
                VStack(spacing: 10) {
                    Button {
                        showingEditServerSheet = true
                    } label: {
                        Label("Edit Cleanuparr Server", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ServiceIdentity.cleanuparr.brandColor)

                    Button {
                        Task {
                            await serviceManager.refresh(hours: browser.timeframeHours, includeDryRun: browser.includeDryRun)
                        }
                    } label: {
                        Label("Refresh Stats Now", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .navigationTitle("Server Settings")
    }

    // MARK: - Helper Views

    private func metricTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
            }
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func labeledDetailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers & Computations

    private var refreshKey: String {
        "\(browser.timeframeHours):\(browser.includeDryRun)"
    }

    private var timeframeLabel: String {
        switch browser.timeframeHours {
        case 24: "Last 24 Hours"
        case 168: "Last 7 Days"
        case 720: "Last 30 Days"
        case 8_760: "Last Year"
        default: "\(browser.timeframeHours) Hours"
        }
    }

    private var readinessDescription: String {
        switch serviceManager.isReady {
        case true: "Ready"
        case false: "Not Ready"
        case nil: "Unknown"
        }
    }

    private var readinessColor: Color {
        switch serviceManager.isReady {
        case true: .green
        case false: .orange
        case nil: .secondary
        }
    }

    private func displayName(for value: String) -> String {
        value
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacing("Q Bit", with: "qBittorrent")
    }

    private func formattedDate(_ value: String?) -> String? {
        guard let value else { return nil }
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func jobDescription(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("queue") {
            return "Monitors active download queues across connected download clients and assigns strikes or removes stalled and non-responsive downloads according to your configured thresholds."
        } else if lower.contains("seed") {
            return "Cleans seeded downloads after seed time or ratio criteria are met, freeing disk space and keeping client queues trimmed."
        } else if lower.contains("strike") {
            return "Evaluates accumulated strikes and enforces automatic removal or re-search actions when strike thresholds are exceeded."
        } else if lower.contains("tag") || lower.contains("sync") {
            return "Synchronizes categories, tags, and state between download clients and Arr service profiles."
        } else {
            return "Automated maintenance task configured in Cleanuparr to manage download client queues and Arr instance health."
        }
    }

    private func healthRow(_ service: CleanuparrStats.Health.Service) -> some View {
        HStack(spacing: 12) {
            Image(systemName: service.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(service.isHealthy ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if let errorMessage = service.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let responseTime = service.responseTimeMs {
                    Text("\(responseTime, format: .number.precision(.fractionLength(0...1))) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

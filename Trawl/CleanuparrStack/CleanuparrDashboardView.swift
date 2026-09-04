import SwiftUI

struct CleanuparrDashboardView: View {
    @Environment(CleanuparrServiceManager.self) private var serviceManager
    @State private var timeframeHours = 168
    @State private var includeDryRun = false

    var body: some View {
        List {
            if !serviceManager.hasConfiguredProfile {
                // No server, rather than a server that will not answer. The
                // error card below says "Cleanuparr Unavailable" and offers a
                // retry, which reads as a broken connection to someone who has
                // simply never set Cleanuparr up - the same distinction the
                // subtitle screen draws for Bazarr.
                ServiceSetupView(
                    title: "Cleanuparr Not Set Up",
                    message: "Add a Cleanuparr server in Settings to see cleanup activity, strikes, and job runs.",
                    systemImage: ServiceIdentity.cleanuparr.systemImage
                )
                .listRowBackground(Color.clear)
            } else {
            Section {
                Picker("Timeframe", selection: $timeframeHours) {
                    Text("24 Hours").tag(24)
                    Text("7 Days").tag(168)
                    Text("30 Days").tag(720)
                    Text("1 Year").tag(8_760)
                }
                Toggle("Include Dry Runs", isOn: $includeDryRun)
            } footer: {
                Text("Activity comes from Cleanuparr's documented read-only Stats API.")
            }

            if let error = serviceManager.connectionError, serviceManager.stats != nil {
                ServiceErrorView(
                    title: "Cleanuparr Unavailable",
                    message: error,
                    identity: .cleanuparr,
                    hasContent: true,
                    onRetry: { await serviceManager.refresh(hours: timeframeHours, includeDryRun: includeDryRun) }
                )
            }

            if let stats = serviceManager.stats {
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
                        onRetry: { await serviceManager.refresh(hours: timeframeHours, includeDryRun: includeDryRun) }
                    )
                }
            }
            }
        }
        .navigationTitle("Cleanuparr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(ServiceIdentity.cleanuparr.brandColor)
        .task(id: refreshKey) {
            guard serviceManager.hasConfiguredProfile else { return }
            await serviceManager.refresh(hours: timeframeHours, includeDryRun: includeDryRun)
        }
        .refreshable {
            guard serviceManager.hasConfiguredProfile else { return }
            await serviceManager.refresh(hours: timeframeHours, includeDryRun: includeDryRun)
        }
    }

    private var refreshKey: String {
        "\(timeframeHours):\(includeDryRun)"
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

    private func healthRow(_ service: CleanuparrStats.Health.Service) -> some View {
        HStack(spacing: 12) {
            Image(systemName: service.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(service.isHealthy ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.subheadline.weight(.medium))
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

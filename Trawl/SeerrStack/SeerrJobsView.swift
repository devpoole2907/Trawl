import SwiftUI

struct SeerrJobsView: View {
    let apiClient: SeerrAPIClient

    @State private var jobs: [SeerrJob] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pollingTask: Task<Void, Never>?
    #if DEBUG
    private var isPreview = false
    #endif

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        List {
            if let error = errorMessage, jobs.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && jobs.isEmpty {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else if jobs.isEmpty {
                ContentUnavailableView(
                    "No Jobs",
                    systemImage: "clock.arrow.2.circlepath",
                    description: Text("No scheduled jobs were returned by Seerr.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(jobs) { job in
                        SeerrJobRow(job: job) {
                            await trigger(job)
                        } onCancel: {
                            await cancel(job)
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
        .background(MoreDestinationGradientBackground(accent: .seerr))
        .navigationTitle("Seerr Jobs")
        .refreshable { await load() }
        .task {
            #if DEBUG
            if isPreview { return }
            #endif
            await load()
            startPolling()
        }
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            jobs = try await apiClient.getJobs()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if let updated = try? await apiClient.getJobs() {
                    jobs = updated
                }
            }
        }
    }

    private func trigger(_ job: SeerrJob) async {
        try? await apiClient.runJob(id: job.id)
        try? await Task.sleep(for: .seconds(1))
        await load()
    }

    private func cancel(_ job: SeerrJob) async {
        try? await apiClient.cancelJob(id: job.id)
        try? await Task.sleep(for: .seconds(1))
        await load()
    }
}

#if DEBUG
extension SeerrJobsView {
    init(
        apiClient: SeerrAPIClient = .preview(),
        previewJobs: [SeerrJob],
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.apiClient = apiClient
        self._jobs = State(initialValue: previewJobs)
        self._isLoading = State(initialValue: isLoading)
        self._errorMessage = State(initialValue: errorMessage)
        self.isPreview = true
    }
}

#Preview("Seerr Jobs - Loaded") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrJobsView(previewJobs: SeerrJob.previewList)
        }
    }
}

#Preview("Seerr Jobs - Empty") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrJobsView(previewJobs: [])
        }
    }
}

#Preview("Seerr Jobs - Loading") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connecting)) {
        NavigationStack {
            SeerrJobsView(previewJobs: [], isLoading: true)
        }
    }
}

#Preview("Seerr Jobs - Error") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.error("Unable to load jobs."))) {
        NavigationStack {
            SeerrJobsView(
                previewJobs: [],
                errorMessage: "Scheduled jobs endpoint returned 503."
            )
        }
    }
}
#endif

// MARK: - Row

private struct SeerrJobRow: View {
    let job: SeerrJob
    let onRun: () async -> Void
    let onCancel: () async -> Void

    var body: some View {
        ScheduledTaskRowView(
            status: jobStatus,
            title: job.name ?? job.id,
            subtitle: jobSubtitle,
            details: jobDetails,
            action: jobAction
        )
    }

    private var jobAction: ScheduledTaskRowAction {
        let title = job.name ?? job.id

        if job.running == true {
            return ScheduledTaskRowAction.stop(
                accessibilityLabel: "Cancel \(title)"
            ) {
                await onCancel()
            }
        } else {
            return ScheduledTaskRowAction.run(
                accessibilityLabel: "Run \(title)"
            ) {
                await onRun()
            }
        }
    }

    private var jobStatus: ScheduledTaskRowStatus {
        job.running == true ? .running : .idle
    }

    private var jobSubtitle: String? {
        guard let type = cleanedText(job.type), type.lowercased() != "process" else { return nil }
        return type.capitalized
    }

    private var jobDetails: [ScheduledTaskRowDetail] {
        var details: [ScheduledTaskRowDetail] = []

        if let interval = intervalText(job.interval) {
            details.append(ScheduledTaskRowDetail(icon: "clock", text: interval))
        }
        if let next = nextExecutionText(job.nextExecutionTime) {
            details.append(ScheduledTaskRowDetail(icon: "arrow.clockwise", text: next))
        }

        return details
    }

    private func intervalText(_ raw: String?) -> String? {
        guard let raw = cleanedText(raw) else { return nil }
        if raw.localizedCaseInsensitiveContains("every") {
            return raw
        }
        if let namedCadence = namedCadence(raw) {
            return namedCadence
        }
        guard let components = iso8601DurationComponents(raw),
              let formatted = formattedDuration(components) else {
            return raw.rangeOfCharacter(from: .decimalDigits) == nil ? nil : "Every \(raw)"
        }
        return "Every \(formatted)"
    }

    private func namedCadence(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "minute", "minutes", "minutely": "Every minute"
        case "hour", "hours", "hourly": "Hourly"
        case "day", "days", "daily": "Daily"
        case "week", "weeks", "weekly": "Weekly"
        case "month", "months", "monthly": "Monthly"
        default: nil
        }
    }

    private func iso8601DurationComponents(_ raw: String) -> DateComponents? {
        var remaining = raw.uppercased()
        guard remaining.hasPrefix("P") else { return nil }

        remaining.removeFirst()
        var components = DateComponents()
        var number = ""
        var isTimeComponent = false
        var hasValue = false

        for character in remaining {
            if character == "T" {
                isTimeComponent = true
            } else if character.isNumber {
                number.append(character)
            } else {
                guard let value = Int(number) else { return nil }
                applyDuration(value, for: character, isTimeComponent: isTimeComponent, to: &components)
                hasValue = true
                number = ""
            }
        }

        return hasValue ? components : nil
    }

    private func applyDuration(
        _ value: Int,
        for component: Character,
        isTimeComponent: Bool,
        to dateComponents: inout DateComponents
    ) {
        switch component {
        case "Y":
            dateComponents.year = value
        case "M" where isTimeComponent:
            dateComponents.minute = value
        case "M":
            dateComponents.month = value
        case "W":
            dateComponents.day = value * 7
        case "D":
            dateComponents.day = (dateComponents.day ?? 0) + value
        case "H":
            dateComponents.hour = value
        case "S":
            dateComponents.second = value
        default:
            break
        }
    }

    private func formattedDuration(_ components: DateComponents) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: components)
    }

    private func nextExecutionText(_ raw: String?) -> String? {
        guard let raw = cleanedText(raw) else { return nil }
        return relativeDate(raw)
    }

    private func relativeDate(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date.formatted(.relative(presentation: .named)) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date.formatted(.relative(presentation: .named)) }
        return raw
    }

    private func cleanedText(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

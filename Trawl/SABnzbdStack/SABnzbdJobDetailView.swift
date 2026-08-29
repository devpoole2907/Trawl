import SwiftUI

// Lifted out of `SABnzbdManagerView.swift` when the Downloads tab absorbed
// SABnzbd's queue: the manager screen it used to live beside no longer exists,
// but the job detail screen is still pushed to from the Downloads list and from
// an *arr item's queue row, and the status extension below is read across the
// whole app.

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
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .accessibilityHidden(true)
                        Text(eta)
                    }
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
                        perform(successTitle: "Resumed", successMessage: job.name) {
                            try await serviceManager.resume(job: job)
                        }
                    }
                } else {
                    Button("Pause", systemImage: "pause.fill") {
                        perform(successTitle: "Paused", successMessage: job.name) {
                            try await serviceManager.pause(job: job)
                        }
                    }
                }
            }
            if job.normalizedStatus == .failed {
                Button("Retry", systemImage: "arrow.clockwise") {
                    perform(successTitle: "Retrying", successMessage: job.name) {
                        try await serviceManager.retry(job: job)
                    }
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
                notificationCenter.showSuccess(title: "Removed", message: job.name)
                dismiss()
            } catch {
                notificationCenter.showError(title: "SABnzbd Action Failed", message: error.localizedDescription)
            }
        }
    }

    private func perform(
        successTitle: String,
        successMessage: String,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        Task {
            do {
                try await operation()
                notificationCenter.showSuccess(title: successTitle, message: successMessage)
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

    private func sizeSummary(for job: SABnzbdJob) -> String {
        job.downloadedSizeSummary
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

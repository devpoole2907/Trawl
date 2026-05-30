import SwiftUI

struct TrackerListView: View {
    @Bindable var viewModel: TorrentDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var actionErrorAlert: ErrorAlertItem?
    @State private var showAddSheet = false
    @State private var trackerPendingEdit: TorrentTracker?
    @State private var trackerPendingDeletion: TorrentTracker?

    var body: some View {
        List {
            if viewModel.trackers.isEmpty {
                ContentUnavailableView(
                    "No Trackers",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("No tracker information available for this torrent.")
                )
            } else {
                Section {
                    ForEach(viewModel.trackers) { tracker in
                        TrackerRow(
                            tracker: tracker,
                            onEdit: isMutable(tracker) ? { trackerPendingEdit = tracker } : nil,
                            onDelete: isMutable(tracker) ? { trackerPendingDeletion = tracker } : nil
                        )
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Trackers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: trackerRefreshToolbarPlacement) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Tracker", systemImage: "plus")
                }
            }
            ToolbarItem(placement: trackerRefreshToolbarPlacement) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task { await refreshTrackers() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddTrackersSheet { urls in
                try await viewModel.addTrackers(urls)
            }
        }
        .sheet(item: $trackerPendingEdit) { tracker in
            EditTrackerSheet(tracker: tracker) { newURL in
                try await viewModel.editTracker(originalURL: tracker.url, newURL: newURL)
            }
        }
        .alert("Remove Tracker?", isPresented: deleteAlertBinding) {
            Button("Remove", role: .destructive) {
                guard let trackerPendingDeletion else { return }
                let url = trackerPendingDeletion.url
                self.trackerPendingDeletion = nil
                Task {
                    do {
                        try await viewModel.removeTrackers([url])
                    } catch {
                        actionErrorAlert = ErrorAlertItem(
                            title: "Couldn't Remove Tracker",
                            message: error.localizedDescription
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                trackerPendingDeletion = nil
            }
        } message: {
            Text("This will stop announcing this torrent to the tracker.")
        }
        .errorAlert(item: $actionErrorAlert)
        .task {
            try? await viewModel.loadTrackers()
        }
        .refreshable {
            try? await viewModel.loadTrackers()
        }
    }

    // qBittorrent reports pseudo-trackers (DHT/PEX/LSD) with tier < 0 and a URL like `** [DHT] **`.
    // These aren't real announce URLs and the edit/remove endpoints will reject them.
    private func isMutable(_ tracker: TorrentTracker) -> Bool {
        tracker.tier >= 0
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { trackerPendingDeletion != nil },
            set: { if !$0 { trackerPendingDeletion = nil } }
        )
    }

    private func refreshTrackers() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        async let refresh: Void = {
            do {
                try await viewModel.loadTrackers()
            } catch {}
        }()
        async let feedback: Void = {
            try? await Task.sleep(for: .seconds(2))
        }()
        _ = await (refresh, feedback)
        isRefreshing = false
    }
}

private struct TrackerRow: View {
    let tracker: TorrentTracker
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayUrl)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    if tracker.tier >= 0 {
                        Text("Tier \(tracker.tier)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                statusBadge
            }

            HStack(spacing: 16) {
                statLabel(value: "\(tracker.numSeeds)", icon: "arrow.up.circle.fill", color: .green, label: "Seeds")
                statLabel(value: "\(tracker.numLeeches)", icon: "arrow.down.circle.fill", color: .blue, label: "Leeches")
                statLabel(value: "\(tracker.numPeers)", icon: "person.2.fill", color: .secondary, label: "Peers")
            }

            if !tracker.msg.isEmpty {
                Text(tracker.msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if let onEdit {
                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.blue)
            }
        }
    }

    private var displayUrl: String {
        tracker.url.replacingOccurrences(of: "udp://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    private func statLabel(value: String, icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.caption.weight(.medium))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }

    private var statusText: String {
        switch tracker.status {
        case 0: "Disabled"
        case 1: "Not Contacted"
        case 2: "Working"
        case 3: "Updating"
        case 4: "Not Working"
        default: "Unknown"
        }
    }

    private var statusColor: Color {
        switch tracker.status {
        case 2: .green
        case 3: .orange
        case 4: .red
        default: .secondary
        }
    }
}

private struct AddTrackersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var isSubmitting = false
    @State private var errorAlert: ErrorAlertItem?

    let onSubmit: ([String]) async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .font(.callout.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        #endif
                } footer: {
                    Text("One URL per line. Only http, https, and udp schemes are accepted.")
                }
            }
            .navigationTitle("Add Trackers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Add") {
                            Task { await submit() }
                        }
                        .disabled(parsedURLs.isEmpty)
                    }
                }
            }
            .errorAlert(item: $errorAlert)
        }
    }

    private var parsedURLs: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isValidTrackerURL($0) }
    }

    private func submit() async {
        let urls = parsedURLs
        guard !urls.isEmpty else { return }
        isSubmitting = true
        do {
            try await onSubmit(urls)
            dismiss()
        } catch {
            errorAlert = ErrorAlertItem(
                title: "Couldn't Add Trackers",
                message: error.localizedDescription
            )
        }
        isSubmitting = false
    }
}

private struct EditTrackerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tracker: TorrentTracker
    let onSubmit: (String) async throws -> Void

    @State private var newURL: String
    @State private var isSubmitting = false
    @State private var errorAlert: ErrorAlertItem?

    init(tracker: TorrentTracker, onSubmit: @escaping (String) async throws -> Void) {
        self.tracker = tracker
        self.onSubmit = onSubmit
        self._newURL = State(initialValue: tracker.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Original") {
                    Text(tracker.url)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Section("New URL") {
                    TextField("https://tracker.example.org/announce", text: $newURL, axis: .vertical)
                        .font(.callout.monospaced())
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        #endif
                }
            }
            .navigationTitle("Edit Tracker")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await submit() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .errorAlert(item: $errorAlert)
        }
    }

    private var trimmedNewURL: String {
        newURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        isValidTrackerURL(trimmedNewURL) && trimmedNewURL != tracker.url
    }

    private func submit() async {
        let candidate = trimmedNewURL
        guard isValidTrackerURL(candidate), candidate != tracker.url else { return }
        isSubmitting = true
        do {
            try await onSubmit(candidate)
            dismiss()
        } catch {
            errorAlert = ErrorAlertItem(
                title: "Couldn't Edit Tracker",
                message: error.localizedDescription
            )
        }
        isSubmitting = false
    }
}

private func isValidTrackerURL(_ string: String) -> Bool {
    guard !string.isEmpty, let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
        return false
    }
    return scheme == "http" || scheme == "https" || scheme == "udp"
}

private var trackerRefreshToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .primaryAction
    #endif
}

#if DEBUG
#Preview("Loaded") {
    let vm = TorrentDetailViewModel(trackers: TorrentTracker.previewList)
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TrackerListView(viewModel: vm)
        }
    }
}

#Preview("Empty") {
    let vm = TorrentDetailViewModel(trackers: [])
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TrackerListView(viewModel: vm)
        }
    }
}

#Preview("Loading") {
    let vm = TorrentDetailViewModel(trackers: [], isLoading: true)
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TrackerListView(viewModel: vm)
        }
    }
}

#Preview("Error") {
    let vm = TorrentDetailViewModel(trackers: [], error: "Connection refused — qBittorrent unreachable.")
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TrackerListView(viewModel: vm)
        }
    }
}

#Preview("With Action Error") {
    let vm = TorrentDetailViewModel(trackers: TorrentTracker.previewList)
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TrackerListView(viewModel: vm)
        }
        .modifier(PresentTrackerActionErrorPreviewModifier())
    }
}

private struct PresentTrackerActionErrorPreviewModifier: ViewModifier {
    @State private var alert: ErrorAlertItem? = ErrorAlertItem(
        title: "Couldn't Remove Tracker",
        message: "qBittorrent returned 400 Bad Request."
    )

    func body(content: Content) -> some View {
        content.errorAlert(item: $alert)
    }
}
#endif

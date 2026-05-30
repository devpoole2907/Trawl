import SwiftUI

struct ProwlarrIndexerDetailView: View {
    let indexer: ProwlarrIndexer
    let viewModel: ProwlarrViewModel
    @State private var showDeleteConfirm = false
    @State private var showTestResult = false
    @State private var testActionError: String?
    @Environment(\.dismiss) private var dismiss

    private var status: ProwlarrIndexerStatus? {
        viewModel.statusForIndexer(id: indexer.id)
    }

    private var currentIndexer: ProwlarrIndexer {
        viewModel.indexers.first(where: { $0.id == indexer.id }) ?? indexer
    }

    private var currentStateLabel: String {
        if viewModel.isIndexerTemporarilyDisabled(id: indexer.id) {
            return "Temporarily Disabled"
        }

        return currentIndexer.enable ? "Active" : "Disabled"
    }

    var body: some View {
        List {
            // MARK: Status Section
            Section("Status") {
                Toggle("Enabled in Prowlarr", isOn: Binding(
                    get: {
                        currentIndexer.enable
                    },
                    set: { _ in
                        Task { await viewModel.toggleIndexer(currentIndexer) }
                    }
                ))

                detailRow(label: "Current State", value: currentStateLabel)

                if let proto = indexer.protocol {
                    detailRow(label: "Protocol", value: proto.displayName)
                }

                if let priority = indexer.priority {
                    detailRow(label: "Priority", value: String(priority))
                }

                if let supportsRss = indexer.supportsRss {
                    detailRow(label: "Supports RSS", value: supportsRss ? "Yes" : "No")
                }

                if let supportsSearch = indexer.supportsSearch {
                    detailRow(label: "Supports Search", value: supportsSearch ? "Yes" : "No")
                }

                if status?.isDisabled == true {
                    Label("Prowlarr temporarily disabled this indexer after recent failures.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            // MARK: Configuration Section
            if let fields = indexer.fields, !fields.isEmpty {
                let visibleFields = fields.filter { field in
                    field.hidden != "hidden"
                }.filter { field in
                    field.type != "password" && field.advanced != true
                }

                if !visibleFields.isEmpty {
                    Section("Configuration") {
                        ForEach(Array(visibleFields.enumerated()), id: \.offset) { _, field in
                            if let label = field.label, let value = field.value?.displayString, !value.isEmpty {
                                detailRow(label: label, value: value)
                            }
                        }
                    }
                }
            }

            // MARK: Stats Section
            if let stats = viewModel.indexerStats?.indexers?.first(where: { $0.indexerId == indexer.id }) {
                Section("Statistics") {
                    if let queries = stats.numberOfQueries {
                        detailRow(label: "Queries", value: String(queries))
                    }
                    if let grabs = stats.numberOfGrabs {
                        detailRow(label: "Grabs", value: String(grabs))
                    }
                    if let failed = stats.numberOfFailedQueries {
                        detailRow(label: "Failed Queries", value: String(failed))
                    }
                    if let rate = stats.successRate {
                        detailRow(label: "Success Rate", value: String(format: "%.1f%%", rate * 100))
                    }
                    if let avg = stats.avgResponseTimeFormatted {
                        detailRow(label: "Avg Response", value: avg)
                    }
                }
            }

            // MARK: Actions Section
            Section {
                Button {
                    Task {
                        await viewModel.testIndexer(indexer)
                        if viewModel.testSucceeded == false, viewModel.testResult == nil {
                            testActionError = "Test failed."
                        }
                    }
                } label: {
                    Label("Test Indexer", systemImage: "checkmark.circle")
                }
                .disabled(viewModel.isTesting)

                if viewModel.isTesting {
                    HStack {
                        ProgressView()
                        Text("Testing…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Remove Indexer", systemImage: "trash")
                }
            }
        }
        .navigationTitle(indexer.name ?? "Indexer")
        .navigationSubtitle("Prowlarr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable {
            await viewModel.loadIndexers()
            await viewModel.loadStats()
        }
        .onChange(of: viewModel.testResult) { _, newValue in
            if newValue != nil {
                testActionError = nil
                showTestResult = true
            }
        }
        .onChange(of: testActionError) { _, newValue in
            if newValue != nil {
                showTestResult = true
            }
        }
        .onChange(of: showTestResult) { _, isPresented in
            if !isPresented {
                viewModel.clearTestOutcome()
                testActionError = nil
            }
        }
        .alert("Test Result", isPresented: $showTestResult) {
            Button("Done", role: .cancel) {
                viewModel.clearTestOutcome()
                testActionError = nil
            }
        } message: {
            Text(viewModel.testResult ?? testActionError ?? "No result available")
        }
        .alert("Remove Indexer?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) {
                Task {
                    let success = await viewModel.deleteIndexer(indexer)
                    if success {
                        dismiss()
                    } else if let error = viewModel.indexerError, !error.isEmpty {
                        InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error)
                        viewModel.clearIndexerError()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \"\(indexer.name ?? "this indexer")\" from Prowlarr.")
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

#if DEBUG
#Preview("Typical") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        NavigationStack {
            ProwlarrIndexerDetailView(
                indexer: .preview,
                viewModel: ProwlarrViewModel(
                    previewIndexers: ProwlarrIndexer.previewList,
                    indexerStatuses: ProwlarrIndexerStatus.previewList,
                    stats: .preview,
                    serviceManager: manager
                )
            )
        }
    }
}

#Preview("Disabled") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        NavigationStack {
            ProwlarrIndexerDetailView(
                indexer: .previewDisabled,
                viewModel: ProwlarrViewModel(
                    previewIndexers: ProwlarrIndexer.previewList,
                    indexerStatuses: ProwlarrIndexerStatus.previewList,
                    stats: .preview,
                    serviceManager: manager
                )
            )
        }
    }
}

#Preview("Long Name") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        NavigationStack {
            ProwlarrIndexerDetailView(
                indexer: .previewLongName,
                viewModel: ProwlarrViewModel(
                    previewIndexers: ProwlarrIndexer.previewList,
                    stats: .preview,
                    serviceManager: manager
                )
            )
        }
    }
}

#Preview("Missing Metadata") {
    let manager = ArrServiceManager.preview(.allConfigured)
    PreviewHost(profiles: ProwlarrPreviewSupport.profiles(matching: manager, includeRemotes: false), arr: manager) {
        NavigationStack {
            ProwlarrIndexerDetailView(
                indexer: .previewMissingMetadata,
                viewModel: ProwlarrViewModel(
                    previewIndexers: [.previewMissingMetadata],
                    serviceManager: manager
                )
            )
        }
    }
}
#endif

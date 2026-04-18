import SwiftUI

struct ProwlarrIndexerDetailView: View {
    let indexer: ProwlarrIndexer
    let viewModel: ProwlarrViewModel
    @State private var showDeleteConfirm = false
    @State private var showTestResult = false
    @Environment(\.dismiss) private var dismiss

    private var status: ProwlarrIndexerStatus? {
        viewModel.statusForIndexer(id: indexer.id)
    }

    var body: some View {
        List {
            // MARK: Status Section
            Section("Status") {
                Toggle("Enabled", isOn: Binding(
                    get: {
                        viewModel.indexers.first(where: { $0.id == indexer.id })?.enable ?? indexer.enable
                    },
                    set: { _ in Task { await viewModel.toggleIndexer(indexer) } }
                ))

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
                    Label("Temporarily disabled by Prowlarr", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            // MARK: Configuration Section
            if let fields = indexer.fields, !fields.isEmpty {
                let visibleFields = fields.filter { field in
                    guard let hidden = field.hidden else { return true }
                    return hidden == "visible" || hidden.isEmpty
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: viewModel.testResult) { _, newValue in
            if newValue != nil {
                showTestResult = true
            }
        }
        .onChange(of: viewModel.indexerError) { _, newValue in
            if newValue != nil {
                showTestResult = true
            }
        }
        .onChange(of: showTestResult) { _, isPresented in
            if !isPresented {
                viewModel.clearTestResult()
            }
        }
        .alert("Test Result", isPresented: $showTestResult) {
            Button("OK", role: .cancel) {
                viewModel.clearTestResult()
            }
        } message: {
            Text(viewModel.testResult ?? viewModel.indexerError ?? "No result available")
        }
        .alert("Remove Indexer?", isPresented: $showDeleteConfirm) {
            Button("Remove", role: .destructive) {
                Task {
                    await viewModel.deleteIndexer(indexer)
                    if viewModel.indexerError == nil {
                        dismiss()
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

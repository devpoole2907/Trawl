import SwiftUI

struct ArrQualityDefinitionsView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var definitions: [ArrQualityDefinition] = []
    @State private var isEditing = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    var body: some View {
        Group {
            if isLoading && definitions.isEmpty {
                ProgressView("Loading quality definitions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, definitions.isEmpty {
                ContentUnavailableView(
                    "Could Not Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                definitionsList
            }
        }
        .navigationTitle("Quality Definitions")
        .moreDestinationBackground(.mediaManagement)
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Service",
                selection: Binding(
                    get: { selectedService },
                    set: { newService in withAnimation { selectedService = newService } }
                ),
                items: availableServices.map(\.segmentBarItem),
                alignment: .center
            )
            .disabled(isEditing || isSaving)
        }
        .overlay(alignment: .top) {
            if isSaving { ProgressView().padding(8) }
        }
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(isEditing ? "Done" : "Edit", action: toggleEditing)
                        .disabled(isLoading || definitions.isEmpty)
                }
            }
        }
        .task(id: selectedService.rawValue) {
            await load()
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    private var definitionsList: some View {
        List {
            Section {
                Text("Minimum and maximum file size per quality. Maximum of 0 means unlimited.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach($definitions) { $def in
                ArrQualityDefinitionRow(
                    definition: $def,
                    isEditing: isEditing && !isSaving
                )
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable {
            guard !isEditing else { return }
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let client = try currentClient()
            definitions = (try await client.getQualityDefinitions())
                .sorted { ($0.weight ?? 0) < ($1.weight ?? 0) }
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleEditing() {
        if isEditing {
            Task {
                if await save() {
                    withAnimation { isEditing = false }
                }
            }
        } else {
            withAnimation { isEditing = true }
        }
    }

    private func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let client = try currentClient()
            let normalizedDefinitions = definitions.map { definition in
                var normalizedDefinition = definition
                normalizedDefinition.normalizeSizeBoundsForServer()
                return normalizedDefinition
            }
            definitions = try await client.updateQualityDefinitions(normalizedDefinitions)
                .sorted { ($0.weight ?? 0) < ($1.weight ?? 0) }
            return true
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            return false
        }
    }

    private func currentClient() throws -> any SharedArrClient {
        switch selectedService {
        case .sonarr:
            guard let c = serviceManager.sonarrClient else { throw ArrClientError.unavailable }
            return c
        case .radarr:
            guard let c = serviceManager.radarrClient else { throw ArrClientError.unavailable }
            return c
        case .prowlarr, .bazarr:
            throw ArrClientError.unavailable
        }
    }
}

// MARK: - Row

private struct ArrQualityDefinitionRow: View {
    @Binding var definition: ArrQualityDefinition
    let isEditing: Bool

    private let maxSliderValue: Double = 400
    private let step: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(definition.title ?? definition.quality?.name ?? "Unknown")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(sizeLabel(definition.minSize ?? 0) + " – " + maxLabel(definition.maxSize ?? 0))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 6) {
                sliderRow(
                    label: "Min",
                    value: Binding(
                        get: { definition.minSize ?? 0 },
                        set: { newVal in
                            definition.setMinSize(newVal)
                        }
                    ),
                    color: .blue
                )

                sliderRow(
                    label: "Max",
                    value: Binding(
                        get: { definition.maxSize ?? 0 },
                        set: { newVal in
                            definition.setMaxSize(newVal)
                        }
                    ),
                    color: .orange,
                    zeroLabel: "∞"
                )
            }
        }
        .padding(.vertical, 4)
        .disabled(!isEditing)
    }

    private func sliderRow(label: String, value: Binding<Double>, color: Color, zeroLabel: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)

            Slider(value: value, in: 0...maxSliderValue, step: step)
                .tint(color)

            Text(zeroLabel != nil && value.wrappedValue == 0 ? zeroLabel! : sizeLabel(value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func sizeLabel(_ mbPerMin: Double) -> String {
        if mbPerMin == 0 { return "0" }
        return String(format: "%.1f", mbPerMin)
    }

    private func maxLabel(_ mbPerMin: Double) -> String {
        mbPerMin == 0 ? "∞" : String(format: "%.1f", mbPerMin)
    }
}

// MARK: - Error

private enum ArrClientError: Error {
    case unavailable
}

private extension ArrQualityDefinition {
    mutating func setMinSize(_ value: Double) {
        minSize = value

        if let maxSize, maxSize > 0, value > maxSize {
            self.maxSize = value
        }

        clampPreferredSize()
    }

    mutating func setMaxSize(_ value: Double) {
        maxSize = value

        if value > 0, let minSize, minSize > value {
            self.minSize = value
        }

        clampPreferredSize()
    }

    mutating func normalizeSizeBoundsForServer() {
        if let minSize, let maxSize, maxSize > 0, minSize > maxSize {
            self.minSize = maxSize
        }

        clampPreferredSize()
    }

    mutating func clampPreferredSize() {
        guard let preferredSize else { return }

        let lowerBound = minSize ?? 0
        var clampedPreferredSize = max(preferredSize, lowerBound)

        if let maxSize, maxSize > 0 {
            clampedPreferredSize = min(clampedPreferredSize, maxSize)
        }

        self.preferredSize = clampedPreferredSize
    }
}

import SwiftUI

// MARK: - Field Selection

private enum QualitySizeField: CaseIterable, Hashable {
    case min, preferred, max

    var label: String {
        switch self {
        case .min: "Min"
        case .preferred: "Preferred"
        case .max: "Max"
        }
    }

    var color: Color {
        switch self {
        case .min: .blue
        case .preferred: .green
        case .max: .orange
        }
    }

    func displayLabel(for value: Double) -> String {
        switch self {
        case .min: value == 0 ? "None" : String(format: "%.1f", value)
        case .preferred: value == 0 ? "None" : String(format: "%.1f", value)
        case .max: value == 0 ? "∞" : String(format: "%.1f", value)
        }
    }

    func zeroLabel() -> String {
        switch self {
        case .min: "No minimum"
        case .preferred: "No preference"
        case .max: "Unlimited (∞)"
        }
    }
}

// MARK: - Main View

struct ArrQualityDefinitionsView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var definitions: [ArrQualityDefinition] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var editingDefinition: ArrQualityDefinition?

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
        .navigationSubtitle(selectedService.displayName)
        .moreDestinationBackground(.qualityDefinitions)
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
            .disabled(isSaving)
        }
        .task(id: selectedService.rawValue) {
            await load()
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
        .sheet(item: $editingDefinition) { def in
            ArrQualityDefinitionSheet(definition: def) { updated in
                await save(updated: updated)
            }
            #if os(iOS)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            #endif
        }
    }

    private var definitionsList: some View {
        List {
            Section("How to Use") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Tap a quality row to edit its file size limits.", systemImage: "hand.tap")
                    Label("Values are MB per minute. Multiply by 60 for MB/hr, or divide by about 1024 for GB/hr.", systemImage: "speedometer")
                    Label("In the editor, choose Min, Preferred, or Max, then drag the bar or use the wheel. Max 0 means unlimited.", systemImage: "slider.horizontal.3")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            ForEach(definitions) { def in
                Button {
                    editingDefinition = def
                } label: {
                    ArrQualityDefinitionRow(definition: def)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable {
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(updated: ArrQualityDefinition) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        var toSave = definitions
        if let idx = toSave.firstIndex(where: { $0.id == updated.id }) {
            var normalized = updated
            normalized.normalizeSizeBoundsForServer()
            toSave[idx] = normalized
        }
        do {
            let client = try currentClient()
            definitions = try await client.updateQualityDefinitions(toSave)
                .sorted { ($0.weight ?? 0) < ($1.weight ?? 0) }
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
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
    let definition: ArrQualityDefinition

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(definition.title ?? definition.quality?.name ?? "Unknown")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                QualityRangeBarView(
                    minSize: definition.minSize ?? 0,
                    preferredSize: definition.preferredSize ?? 0,
                    maxSize: definition.maxSize ?? 0,
                    selectedField: nil,
                    barHeight: 6
                )

                Text(rangeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var rangeLabel: String {
        let minVal = definition.minSize ?? 0
        let maxVal = definition.maxSize ?? 0
        let minStr = minVal == 0 ? "0" : String(format: "%.1f", minVal)
        let maxStr = maxVal == 0 ? "∞" : String(format: "%.1f", maxVal)
        return "\(minStr) – \(maxStr) MB/min"
    }
}

// MARK: - Range Bar

private struct QualityRangeBarView: View {
    let minSize: Double
    let preferredSize: Double
    let maxSize: Double
    let selectedField: QualitySizeField?
    let barHeight: CGFloat
    var onChangeValue: ((QualitySizeField, Double) -> Void)?
    var onSelectField: ((QualitySizeField) -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var activeDragField: QualitySizeField?

    private static let scale = 400.0
    private var markerSize: CGFloat { barHeight * 2.5 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let minX = x(minSize, in: w)
            let prefX = x(preferredSize, in: w)
            let maxX = maxSize == 0 ? w : x(maxSize, in: w)
            let cy = markerSize / 2

            let rangeBar = ZStack(alignment: .topLeading) {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: barHeight)
                    .offset(y: cy - barHeight / 2)

                // Acceptable zone
                if maxX > minX {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: maxX - minX, height: barHeight)
                        .offset(x: minX, y: cy - barHeight / 2)
                }

                // Min marker
                markerCircle(.min)
                    .offset(x: clampedMarkerX(minX, in: w), y: 0)

                // Preferred marker (only if set)
                if preferredSize > 0 {
                    markerCircle(.preferred)
                        .offset(x: clampedMarkerX(prefX, in: w), y: 0)
                }

                // Max marker
                markerCircle(.max)
                    .offset(x: clampedMarkerX(maxX, in: w), y: 0)
            }

            if onChangeValue != nil {
                rangeBar
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { dragValue in
                                let field: QualitySizeField
                                if let active = activeDragField {
                                    field = active
                                } else {
                                    field = nearestField(
                                        to: dragValue.location.x,
                                        minX: minX,
                                        prefX: prefX,
                                        maxX: maxX,
                                        preferredVisible: preferredSize > 0
                                    )
                                    activeDragField = field
                                    if selectedField != field {
                                        onSelectField?(field)
                                    }
                                }
                                let newValue = value(for: dragValue.location.x, field: field, width: w)
                                onChangeValue?(field, newValue)
                            }
                            .onEnded { _ in
                                activeDragField = nil
                                onDragEnded?()
                            }
                    )
                    .accessibilityHint("Drag a marker to change its size value.")
            } else {
                rangeBar
            }
        }
        .frame(height: markerSize)
    }

    private func nearestField(
        to x: CGFloat,
        minX: CGFloat,
        prefX: CGFloat,
        maxX: CGFloat,
        preferredVisible: Bool
    ) -> QualitySizeField {
        var best: (field: QualitySizeField, dist: CGFloat) = (.min, abs(x - minX))
        if preferredVisible {
            let d = abs(x - prefX)
            if d < best.dist { best = (.preferred, d) }
        }
        let dMax = abs(x - maxX)
        if dMax < best.dist { best = (.max, dMax) }
        return best.field
    }

    private func markerCircle(_ field: QualitySizeField) -> some View {
        let isSelected = selectedField == field
        return Circle()
            .fill(isSelected ? field.color : platformBackgroundColor)
            .overlay(Circle().strokeBorder(field.color, lineWidth: 2))
            .frame(width: markerSize, height: markerSize)
            .shadow(color: field.color.opacity(isSelected ? 0.4 : 0), radius: 4)
    }

    private func x(_ value: Double, in width: CGFloat) -> CGFloat {
        CGFloat(min(max(value / Self.scale, 0), 1)) * width
    }

    private func clampedMarkerX(_ cx: CGFloat, in width: CGFloat) -> CGFloat {
        min(max(cx - markerSize / 2, 0), width - markerSize)
    }

    private func value(for x: CGFloat, field: QualitySizeField, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }

        let clampedX = min(max(x, 0), width)
        if field == .max, clampedX >= width - markerSize {
            return 0
        }

        let rawValue = Double(clampedX / width) * Self.scale
        return (rawValue * 2).rounded() / 2
    }

    private var platformBackgroundColor: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

// MARK: - Edit Sheet

private struct ArrQualityDefinitionSheet: View {
    let original: ArrQualityDefinition
    @State private var draft: ArrQualityDefinition
    @State private var selectedField: QualitySizeField = .min
    @State private var wheelValue: Double
    @State private var isSaving = false
    let onSave: (ArrQualityDefinition) async -> Void

    @Environment(\.dismiss) private var dismiss

    init(definition: ArrQualityDefinition, onSave: @escaping (ArrQualityDefinition) async -> Void) {
        self.original = definition
        _draft = State(initialValue: definition)
        _wheelValue = State(initialValue: definition.minSize ?? 0)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                QualityRangeBarView(
                    minSize: draft.minSize ?? 0,
                    preferredSize: draft.preferredSize ?? 0,
                    maxSize: draft.maxSize ?? 0,
                    selectedField: selectedField,
                    barHeight: 10,
                    onChangeValue: updateValue,
                    onSelectField: { selectedField = $0 },
                    onDragEnded: { wheelValue = fieldValue(selectedField) }
                )
                .padding(.horizontal, 24)
                .padding(.top, 20)

                chipRow
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

                valueHint
                    .padding(.top, 10)

                Divider()
                    .padding(.top, 12)

                WheelValuePicker(value: wheelBinding, selectedField: selectedField)
                    .onChange(of: selectedField) { _, _ in
                        wheelValue = fieldValue(selectedField)
                    }

                Spacer(minLength: 0)
            }
            .navigationTitle(draft.title ?? draft.quality?.name ?? "Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                isSaving = true
                                await onSave(draft)
                                isSaving = false
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: Chips

    private var chipRow: some View {
        HStack(spacing: 10) {
            ForEach(QualitySizeField.allCases, id: \.self) { field in
                chipButton(field)
            }
        }
    }

    private func chipButton(_ field: QualitySizeField) -> some View {
        let isSelected = selectedField == field
        let value = fieldValue(field)
        return Button {
            withAnimation(.spring(duration: 0.2)) { selectedField = field }
        } label: {
            VStack(spacing: 4) {
                Text(field.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : field.color)
                Text(field.displayLabel(for: value))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? field.color : field.color.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? .clear : field.color.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.2), value: isSelected)
    }

    // MARK: Hint line

    private var valueHint: some View {
        let value = fieldValue(selectedField)
        let gbPerHr = value * 60.0 / 1024.0

        return HStack(spacing: 6) {
            if value > 0 {
                Text(String(format: "%.1f MB/min", value))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                Text("≈ \(String(format: "%.1f", gbPerHr)) GB/hr")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            } else {
                Text(selectedField.zeroLabel())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private var wheelBinding: Binding<Double> {
        Binding(
            get: { wheelValue },
            set: { newValue in
                wheelValue = newValue
                updateValue(selectedField, value: newValue)
            }
        )
    }

    private func fieldValue(_ field: QualitySizeField) -> Double {
        switch field {
        case .min: draft.minSize ?? 0
        case .preferred: draft.preferredSize ?? 0
        case .max: draft.maxSize ?? 0
        }
    }

    private func updateValue(_ field: QualitySizeField, value: Double) {
        if fieldValue(field) == value { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch field {
            case .min:
                draft.setMinSize(value)
            case .preferred:
                draft.preferredSize = value
                draft.clampPreferredSize()
            case .max:
                draft.setMaxSize(value)
            }
        }
    }
}

// MARK: - Wheel Picker (isolated subview so drag-tick re-renders don't reach it)

private struct WheelValuePicker: View {
    @Binding var value: Double
    let selectedField: QualitySizeField

    private static let pickerValues: [Double] = Array(stride(from: 0.0, through: 400.0, by: 0.5))

    var body: some View {
        Picker("", selection: $value) {
            ForEach(Self.pickerValues, id: \.self) { v in
                Text(v == 0 ? selectedField.zeroLabel() : String(format: "%.1f", v))
                    .tag(v)
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 200)
        .animation(.none, value: selectedField)
    }
}

// MARK: - Error

private enum ArrClientError: Error {
    case unavailable
}

// MARK: - Model Helpers

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
        var clamped = max(preferredSize, lowerBound)
        if let maxSize, maxSize > 0 {
            clamped = min(clamped, maxSize)
        }
        self.preferredSize = clamped
    }
}

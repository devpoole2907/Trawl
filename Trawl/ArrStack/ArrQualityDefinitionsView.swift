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
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(ArrQualityDefinitionBrowserState.self) private var sharedBrowser: ArrQualityDefinitionBrowserState?

    /// Quality definitions - the size limits per quality - are per-server, and an
    /// HD/4K pair sets them very differently. Scoped to a server, not a service.
    @State private var localBrowser = ArrQualityDefinitionBrowserState()
    @State private var sheetDefinition: ArrQualityDefinition?
    @State private var showSettings = false

    private var browser: ArrQualityDefinitionBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }

    private var selectedInstanceID: UUID? {
        get { browser.selectedInstanceID }
        nonmutating set { browser.selectedInstanceID = newValue }
    }

    private var selectedService: ArrServiceType {
        selectedInstance?.serviceType ?? browser.selectedService
    }

    private var definitions: [ArrQualityDefinition] {
        get { browser.definitions }
        nonmutating set { browser.definitions = newValue }
    }

    private var isLoading: Bool {
        get { browser.isLoading }
        nonmutating set { browser.isLoading = newValue }
    }

    private var isSaving: Bool {
        get { browser.isSaving }
        nonmutating set { browser.isSaving = newValue }
    }

    private var errorMessage: String? {
        get { browser.errorMessage }
        nonmutating set { browser.errorMessage = newValue }
    }

    #if DEBUG
    init(
        previewDefinitions: [ArrQualityDefinition] = [],
        selectedService: ArrServiceType = .sonarr,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        let browser = ArrQualityDefinitionBrowserState()
        browser.definitions = previewDefinitions
        browser.selectedService = selectedService
        browser.isLoading = isLoading
        browser.errorMessage = errorMessage
        _localBrowser = State(initialValue: browser)
    }
    #endif

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var availableInstances: [ArrInstanceRef] {
        serviceManager.visibleArrInstances.map(\.ref)
    }

    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID } ?? availableInstances.first
    }

    private var isSelectedConnecting: Bool {
        !serviceManager.isConnected(selectedService) &&
        (serviceManager.isInitializing || serviceManager.isConnecting(selectedService))
    }

    private var isSelectedUnreachable: Bool {
        !serviceManager.isConnected(selectedService) && !serviceManager.isConnecting(selectedService) && !serviceManager.isInitializing
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    private var selectedDefinition: ArrQualityDefinition? {
        definitions.first { $0.id == browser.selectedDefinitionID }
    }

    var body: some View {
        TrawlListDetailPanes(title: "Quality Definitions") {
            definitionsScreen
        } detail: {
            selectedDefinitionDetail
        }
        .sheet(item: $sheetDefinition) { definition in
            ArrQualityDefinitionSheet(definition: definition, onEditingChanged: { browser.isEditingDefinition = $0 }) { updated in
                await save(updated: updated)
            }
            #if os(iOS)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            #endif
        }
    }

    @ViewBuilder
    private var definitionsScreen: some View {
        @Bindable var browser = browser
        Group {
            if isSelectedConnecting || (isSelectedUnreachable && definitions.isEmpty) {
                ArrServiceConnectionStatusView(
                    serviceType: selectedService,
                    title: isSelectedConnecting ? "Connecting to \(selectedService.displayName)" : "\(selectedService.displayName) Unreachable",
                    message: serviceManager.connectionError(selectedService) ?? "Check your server connection and try again."
                )
            } else if isLoading && definitions.isEmpty {
                TrawlInitialLoadingView(label: "Loading quality definitions")
            } else if let error = errorMessage, definitions.isEmpty {
                ServiceErrorView(title: "Could Not Load", message: error, onRetry: { await load() })
            } else {
                definitionsList
            }
        }
        .moreDestinationBackground(.qualityDefinitions)
        .safeAreaInset(edge: .top) {
            ArrInstanceScopeBar(instances: availableInstances, selection: $browser.selectedInstanceID)
                .disabled(isSaving || browser.isEditingDefinition)
        }
        .task(id: selectedInstance?.id) {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await load()
        }
        .onAppear {
            selectedInstanceID = serviceManager.defaultScopeInstanceID(preferring: selectedInstanceID)
            reconcileSelection()
        }
        .onChange(of: selectedInstanceID) {
            browser.selectedDefinitionID = nil
            sheetDefinition = nil
            if let serviceType = selectedInstance?.serviceType {
                browser.selectedService = serviceType
            }
        }
        .onChange(of: definitions.map(\.id)) { reconcileSelection() }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: selectedService)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
            .macSheetSizing()
        }
    }

    private var definitionsList: some View {
        @Bindable var browser = browser
        return List(selection: showsDetailPane ? Binding(
            get: { browser.selectedDefinitionID },
            set: { if !browser.isEditingDefinition && !isSaving { browser.selectedDefinitionID = $0 } }
        ) : .constant(nil)) {
            Section("How to Use") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Open a quality row, then use Edit to change its file size limits.", systemImage: "hand.tap")
                    Label("Values are MB per minute. Multiply by 60 for MB/hr, or divide by about 1024 for GB/hr.", systemImage: "speedometer")
                    Label("In the editor, choose Min, Preferred, or Max, then drag the bar or use the wheel. Max 0 means unlimited.", systemImage: "slider.horizontal.3")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            ForEach(definitions) { def in
                Group {
                    if showsDetailPane {
                        ArrQualityDefinitionRow(definition: def)
                            .tag(def.id)
                    } else {
                        Button {
                            sheetDefinition = def
                        } label: {
                            ArrQualityDefinitionRow(definition: def)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .disabled(isSaving || browser.isEditingDefinition)
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

    @ViewBuilder
    private var selectedDefinitionDetail: some View {
        if let definition = selectedDefinition {
            ArrQualityDefinitionSheet(definition: definition, instance: selectedInstance, onEditingChanged: { browser.isEditingDefinition = $0 }) { updated in
                await save(updated: updated)
            }
            .id(ArrScopedID(selectedInstance?.id, definition.id))
        } else {
            listDetailPlaceholder("Select a Quality Definition", systemImage: "chart.bar")
        }
    }

    private func reconcileSelection() {
        guard showsDetailPane else {
            browser.selectedDefinitionID = nil
            return
        }
        if let selectedDefinitionID = browser.selectedDefinitionID,
           !definitions.contains(where: { $0.id == selectedDefinitionID }) {
            browser.selectedDefinitionID = nil
        }
    }

    private func load() async {
        guard !browser.isEditingDefinition && !isSaving else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let client = try currentClient()
            browser.selectedService = selectedInstance?.serviceType ?? browser.selectedService
            definitions = (try await client.getQualityDefinitions())
                .sorted { ($0.weight ?? 0) < ($1.weight ?? 0) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Return the accepted definition so the editor uses the server-confirmed baseline.
    private func save(updated: ArrQualityDefinition) async -> ArrQualityDefinition? {
        guard !isSaving else { return nil }
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
            return definitions.first { $0.id == updated.id }
        } catch {
            notificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            return nil
        }
    }

    /// The server whose definitions are on screen - every read and save goes
    /// through it, so a size limit edited on the 4K server cannot land on the HD
    /// one.
    private func currentClient() throws -> any SharedArrClient {
        guard let instance = selectedInstance,
              let client = serviceManager.sharedClient(for: instance) else {
            throw ArrClientError.unavailable
        }
        return client
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
        .contentShape(Rectangle())
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
    let latestDefinition: ArrQualityDefinition
    @State private var original: ArrQualityDefinition
    /// The server the definition was loaded from, named in the detail header.
    let instance: ArrInstanceRef?
    @State private var draft: ArrQualityDefinition
    @State private var selectedField: QualitySizeField = .min
    @State private var wheelValue: Double
    @State private var isSaving = false
    /// Existing definitions open read-only in every presentation.
    @State private var isEditing = false
    /// A rejected save returns nil and preserves the draft.
    let onSave: (ArrQualityDefinition) async -> ArrQualityDefinition?
    let onEditingChanged: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isDetailPane) private var isDetailPane

    init(
        definition: ArrQualityDefinition,
        instance: ArrInstanceRef? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        onSave: @escaping (ArrQualityDefinition) async -> ArrQualityDefinition?
    ) {
        self.latestDefinition = definition
        _original = State(initialValue: definition)
        self.instance = instance
        _draft = State(initialValue: definition)
        _wheelValue = State(initialValue: definition.minSize ?? 0)
        self.onEditingChanged = onEditingChanged
        self.onSave = onSave
    }

    private var displayTitle: String {
        draft.title ?? draft.quality?.name ?? "Quality"
    }

    private var isEditable: Bool { isEditing && !isSaving }

    /// The sizes the server accepts; the bar and the iOS wheel cover the same span.
    private static let sizeRange: ClosedRange<Double> = 0...400

    var body: some View {
        Group {
            if isDetailPane {
                editorChrome(detailForm)
            } else {
                NavigationStack {
                    editorChrome(sheetContent.disabled(!isEditable))
                }
                .macSheetSizing(minWidth: 460, idealWidth: 500, minHeight: 380)
            }
        }
    }

    // MARK: Detail pane

    /// The detail column has the height a medium sheet does not, so it opens on the
    /// same centred header as a quality profile and groups the controls beneath it.
    private var detailForm: some View {
        Form {
            Section {
                TrawlEntityHeader(
                    title: displayTitle,
                    subtitle: headerSubtitle,
                    systemImage: "chart.bar",
                    tint: instance?.serviceType.serviceIdentity.brandColor ?? .accentColor,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            Section {
                QualityRangeBarView(
                    minSize: draft.minSize ?? 0,
                    preferredSize: draft.preferredSize ?? 0,
                    maxSize: draft.maxSize ?? 0,
                    selectedField: detailHighlightedField,
                    barHeight: 10,
                    onChangeValue: rangeBarChange,
                    onSelectField: { selectedField = $0 },
                    onDragEnded: { wheelValue = fieldValue(selectedField) }
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 12)

                #if os(macOS)
                sizeFieldRow
                    .padding(.vertical, 4)
                #else
                chipRow
                    .padding(.vertical, 4)

                valueHint
                    .frame(maxWidth: .infinity)
                #endif
            } header: {
                Text("File Size Limits")
            } footer: {
                #if os(macOS)
                Text("Values are MB per minute. Drag the bar or set each limit. A Max of 0 means unlimited.")
                #else
                Text("Values are MB per minute. Choose Min, Preferred or Max, then drag the bar or pick a value below. Max 0 means unlimited.")
                #endif
            }
            .disabled(!isEditable)

            #if os(iOS)
            Section {
                valuePicker
            } header: {
                Text("\(selectedField.label) Value")
            }
            .disabled(!isEditable)
            #endif
        }
        .serviceSettingsFormStyle()
        .animation(.snappy, value: isEditing)
    }

    /// The bar is only draggable while editing; without a handler it draws read-only.
    private var rangeBarChange: ((QualitySizeField, Double) -> Void)? {
        guard isEditable else { return nil }
        return { field, value in updateValue(field, value: value) }
    }

    /// iOS edits one selected limit at a time, so its marker is highlighted. The Mac
    /// edits all three in place and has no selection to show.
    private var detailHighlightedField: QualitySizeField? {
        #if os(macOS)
        nil
        #else
        selectedField
        #endif
    }

    #if os(macOS)
    /// On a Mac each limit is its own number field and stepper. Selecting a chip and
    /// scrolling a menu of 801 half-steps is a touch idiom that does not translate.
    private var sizeFieldRow: some View {
        HStack(spacing: 10) {
            ForEach(QualitySizeField.allCases, id: \.self) { field in
                sizeField(field)
            }
        }
    }

    private func sizeField(_ field: QualitySizeField) -> some View {
        let value = fieldValue(field)
        let binding = Binding(
            get: { fieldValue(field) },
            set: { updateValue(field, value: min(max($0, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)) }
        )
        return VStack(spacing: 6) {
            Text(field.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(field.color)

            HStack(spacing: 4) {
                TextField(field.label, value: binding, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                Stepper(field.label, value: binding, in: Self.sizeRange, step: 0.5)
                    .labelsHidden()
            }

            Text(value == 0 ? field.zeroLabel() : String(format: "≈ %.1f GB/hr", value * 60 / 1024))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(field.color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(field.color.opacity(0.25), lineWidth: 1)
        )
    }
    #endif

    private var headerSubtitle: String? {
        var parts: [String] = []
        if let instance { parts.append(instance.serviceType.displayName) }
        if let name = draft.quality?.name, name != displayTitle { parts.append(name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        if let instance {
            badges.append(ArrDetailBadge(
                icon: instance.serviceType.systemImage,
                label: instance.qualifiedLabel,
                color: instance.serviceType.serviceIdentity.brandColor
            ))
        }
        if let resolution = draft.quality?.resolution, resolution > 0 {
            badges.append(ArrDetailBadge(icon: "rectangle.inset.filled", label: "\(resolution)p", color: .blue))
        }
        let isUnlimited = (draft.maxSize ?? 0) == 0
        badges.append(ArrDetailBadge(
            icon: isUnlimited ? "infinity" : "gauge.with.dots.needle.67percent",
            label: isUnlimited ? "No Maximum" : "Size Capped",
            color: isUnlimited ? .secondary : .orange
        ))
        return badges
    }

    private var valuePicker: some View {
        WheelValuePicker(value: wheelBinding, selectedField: selectedField)
            .onChange(of: selectedField) { _, _ in
                wheelValue = fieldValue(selectedField)
            }
    }

    // MARK: Shared chrome

    private func editorChrome(_ content: some View) -> some View {
        content
            .trawlCentralHeaderNavigationTitle(displayTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onChange(of: [latestDefinition.minSize, latestDefinition.preferredSize, latestDefinition.maxSize]) { _, _ in
                guard !isEditing && !isSaving else { return }
                original = latestDefinition
                draft = latestDefinition
                wheelValue = fieldValue(selectedField)
            }
            .onChange(of: isEditing) { _, editing in onEditingChanged(editing) }
            .onDisappear { onEditingChanged(false) }
            .trawlEditingGuard(isEditing: isEditing, isSaving: isSaving)
            .toolbar {
                TrawlEditToolbar(isEditing: $isEditing, isSaving: isSaving,
                    canSave: draft.minSize != original.minSize || draft.maxSize != original.maxSize || draft.preferredSize != original.preferredSize,
                    onCancel: { draft = original; wheelValue = fieldValue(selectedField) },
                    onSave: {
                        Task {
                            guard !isSaving else { return }
                            isSaving = true
                            let saved = await onSave(draft)
                            isSaving = false
                            if let saved {
                                draft = saved
                                original = saved
                                wheelValue = fieldValue(selectedField)
                                isEditing = false
                            }
                        }
                    }, onClose: isDetailPane ? nil : { dismiss() })
            }
    }

    // MARK: Sheet

    private var sheetContent: some View {
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
        // No wheel on macOS; a menu is the native equivalent and needs no fixed height.
        #if os(iOS)
        .pickerStyle(.wheel)
        .frame(height: 200)
        #else
        .pickerStyle(.menu)
        .labelsHidden()
        #endif
        .animation(.none, value: selectedField)
    }
}

// MARK: - Error

private enum ArrClientError: Error {
    case unavailable
}

// MARK: - Model Helpers

/// The bounds rules for a definition's three sizes. Internal rather than private
/// because these decide what is PUT to the server - `QualityDefinitionSizeBoundsTests`
/// pins them. A max of 0 means unlimited, so it never pulls the other two down.
extension ArrQualityDefinition {
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

#if DEBUG
#Preview("Quality Definitions - Loaded") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrQualityDefinitionsView(previewDefinitions: ArrQualityDefinition.previewList)
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Quality Definitions - Error") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        NavigationStack {
            ArrQualityDefinitionsView(errorMessage: "Quality definitions endpoint returned 503.")
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Quality Definition - Editor") {
    ArrQualityDefinitionSheet(definition: .preview) { definition in definition }
}

#Preview("Quality Definition - Detail Pane") {
    NavigationStack {
        ArrQualityDefinitionSheet(definition: .preview) { definition in definition }
    }
    .environment(\.isDetailPane, true)
    // Tall enough to show the size limits, which sit below the header.
    .frame(width: 600, height: 900)
}
#endif

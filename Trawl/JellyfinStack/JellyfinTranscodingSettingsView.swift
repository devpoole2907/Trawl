import SwiftUI

struct JellyfinTranscodingSettingsView: View {
    let apiClient: JellyfinAPIClient
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    @State private var options: JellyfinEncodingOptions?
    @State private var originalOptions: JellyfinEncodingOptions?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showHardwareChangeConfirmation = false
    @State private var showNvencPresetConfirmation = false
    #if DEBUG
    private var isPreview = false
    #endif

    private static let baseHardwareAccelerationChoices: [(label: String, value: String)] = [
        ("None", "none"),
        ("NVIDIA NVENC", "nvenc"),
        ("VA-API", "vaapi"),
        ("Intel QSV", "qsv"),
    ]

    private static let recommendedNvencCodecs = [
        "h264",
        "hevc",
        "mpeg2video",
        "vc1",
        "vp8",
        "vp9",
    ]

    private var hasChanges: Bool {
        options != originalOptions
    }

    private var shouldConfirmHardwareAccelerationChange: Bool {
        normalizedHardwareAcceleration(options?.hardwareAccelerationType) !=
            normalizedHardwareAcceleration(originalOptions?.hardwareAccelerationType)
    }

    private var hardwareAccelerationChoices: [(label: String, value: String)] {
        let current = normalizedHardwareAcceleration(options?.hardwareAccelerationType)
        guard !Self.baseHardwareAccelerationChoices.contains(where: { $0.value == current }) else {
            return Self.baseHardwareAccelerationChoices
        }

        return [(displayHardwareAcceleration(current), current)] + Self.baseHardwareAccelerationChoices
    }

    private var hardwareAccelerationBinding: Binding<String> {
        Binding(
            get: { normalizedHardwareAcceleration(options?.hardwareAccelerationType) },
            set: { setOption(\.hardwareAccelerationType, to: $0) }
        )
    }

    var body: some View {
        Form {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && options == nil {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if let options {
                currentSection(options)
                hardwareSection
                decodingSection
                qualitySection(options)
                presetSection
            } else {
                ContentUnavailableView(
                    "No Transcoding Settings",
                    systemImage: "cpu",
                    description: Text("Jellyfin did not return playback and transcoding settings.")
                )
                .listRowBackground(Color.clear)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .navigationTitle("Transcoding")
        .navigationSubtitle("Jellyfin")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await loadEncodingOptions() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Save", action: requestSave)
                        .disabled(options == nil || isLoading || !hasChanges)
                }
            }
        }
        .task {
            #if DEBUG
            if isPreview { return }
            #endif
            await loadEncodingOptions()
        }
        .confirmationDialog(
            "Change Hardware Acceleration?",
            isPresented: $showHardwareChangeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save Changes") {
                Task { await save() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changing hardware acceleration can affect active and future transcodes. Jellyfin may require a restart before every setting is applied.")
        }
        .confirmationDialog(
            "Apply Recommended NVENC Preset?",
            isPresented: $showNvencPresetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply Preset", action: applyNvencPreset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sets NVIDIA NVENC hardware acceleration, common decoding codecs, tone mapping, and native/NVDEC decoder preferences. AV1 encoding stays off because not every NVIDIA GPU supports it.")
        }
    }

    @ViewBuilder
    private func currentSection(_ options: JellyfinEncodingOptions) -> some View {
        Section("Current") {
            LabeledContent("Hardware Acceleration", value: displayHardwareAcceleration(options.hardwareAccelerationType))
            LabeledContent("Hardware Decoding", value: codecSummary(options.hardwareDecodingCodecs))

            if let encoderPath = options.encoderAppPathDisplay, !encoderPath.isEmpty {
                LabeledContent("FFmpeg", value: encoderPath)
            }
        }
    }

    @ViewBuilder
    private var hardwareSection: some View {
        Section {
            Picker("Hardware Acceleration", selection: hardwareAccelerationBinding) {
                ForEach(hardwareAccelerationChoices.indices, id: \.self) { index in
                    let choice = hardwareAccelerationChoices[index]
                    Text(choice.label).tag(choice.value)
                }
            }

            Toggle("Hardware Encoding", isOn: boolBinding(\.enableHardwareEncoding))
            Toggle("HEVC / H.265 Encoding", isOn: boolBinding(\.allowHevcEncoding))
            Toggle("AV1 Encoding", isOn: boolBinding(\.allowAv1Encoding))
        } header: {
            Text("Hardware")
        } footer: {
            Text("Enable AV1 encoding only when the server GPU and Jellyfin FFmpeg build support AV1 encode.")
        }
    }

    @ViewBuilder
    private var decodingSection: some View {
        Section {
            Toggle("Tone Mapping", isOn: boolBinding(\.enableTonemapping))
            Toggle("Enhanced NVDEC Decoder", isOn: boolBinding(\.enableEnhancedNvdecDecoder))
            Toggle("Prefer System Native Decoder", isOn: boolBinding(\.preferSystemNativeHwDecoder))
            Toggle("HEVC 10-bit Decode", isOn: boolBinding(\.enableDecodingColorDepth10Hevc))
            Toggle("VP9 10-bit Decode", isOn: boolBinding(\.enableDecodingColorDepth10Vp9))
            Toggle("Throttling", isOn: boolBinding(\.enableThrottling))
        } header: {
            Text("Playback Conversion")
        } footer: {
            Text("Tone mapping and native decoder settings affect HDR and hardware decode paths during playback conversion.")
        }
    }

    @ViewBuilder
    private func qualitySection(_ options: JellyfinEncodingOptions) -> some View {
        Section("Quality") {
            if let h264Crf = options.h264Crf {
                LabeledContent("H.264 CRF", value: String(h264Crf))
            }
            if let h265Crf = options.h265Crf {
                LabeledContent("H.265 CRF", value: String(h265Crf))
            }
            if let encoderPreset = options.encoderPreset, !encoderPreset.isEmpty {
                LabeledContent("Encoder Preset", value: encoderPreset)
            }
        }
    }

    @ViewBuilder
    private var presetSection: some View {
        Section {
            Button {
                showNvencPresetConfirmation = true
            } label: {
                Label("Recommended NVIDIA/NVENC", systemImage: "sparkles")
            }
            .disabled(options == nil || isSaving)
        } footer: {
            Text("Applies the preset locally first. Review the settings, then Save to update Jellyfin. AV1 encoding remains off.")
        }
    }

    private func boolBinding(
        _ keyPath: WritableKeyPath<JellyfinEncodingOptions, Bool?>,
        default defaultValue: Bool = false
    ) -> Binding<Bool> {
        Binding(
            get: { options?[keyPath: keyPath] ?? defaultValue },
            set: { setOption(keyPath, to: $0) }
        )
    }

    private func setOption<Value>(
        _ keyPath: WritableKeyPath<JellyfinEncodingOptions, Value?>,
        to value: Value
    ) {
        guard var current = options else { return }
        current[keyPath: keyPath] = value
        options = current
    }

    private func requestSave() {
        if shouldConfirmHardwareAccelerationChange {
            showHardwareChangeConfirmation = true
        } else {
            Task { await save() }
        }
    }

    private func loadEncodingOptions() async {
        isLoading = true
        errorMessage = nil
        do {
            let fetchedOptions = try await apiClient.getEncodingOptions()
            options = fetchedOptions
            originalOptions = fetchedOptions
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard let options else { return }

        isSaving = true
        inAppNotificationCenter.showProgress(
            title: "Saving Transcoding",
            message: "Updating Jellyfin playback settings...",
            key: "jellyfin_transcoding_save",
            source: .inApp
        )

        do {
            try await apiClient.updateEncodingOptions(options)
            originalOptions = options
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_transcoding_save",
                title: "Transcoding Updated",
                message: "Settings saved. A Jellyfin restart may be required for every change to take effect."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_transcoding_save",
                title: "Save Failed",
                message: error.localizedDescription
            )
        }

        isSaving = false
    }

    private func applyNvencPreset() {
        guard var current = options else { return }

        current.hardwareAccelerationType = "nvenc"
        current.enableHardwareEncoding = true
        current.enableEnhancedNvdecDecoder = true
        current.preferSystemNativeHwDecoder = true
        current.enableDecodingColorDepth10Hevc = true
        current.enableTonemapping = true
        current.allowAv1Encoding = false
        current.hardwareDecodingCodecs = Self.recommendedNvencCodecs.reduce(into: current.hardwareDecodingCodecs ?? []) { codecs, codec in
            if !codecs.contains(where: { $0.caseInsensitiveCompare(codec) == .orderedSame }) {
                codecs.append(codec)
            }
        }

        options = current
        inAppNotificationCenter.showSuccess(
            title: "Preset Applied",
            message: "Review and Save to update Jellyfin."
        )
    }

    private func normalizedHardwareAcceleration(_ value: String?) -> String {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return "none" }
        return normalized
    }

    private func displayHardwareAcceleration(_ value: String?) -> String {
        displayHardwareAcceleration(normalizedHardwareAcceleration(value))
    }

    private func displayHardwareAcceleration(_ value: String) -> String {
        switch value {
        case "none": "None"
        case "nvenc": "NVIDIA NVENC"
        case "vaapi": "VA-API"
        case "qsv": "Intel QSV"
        case "amf": "AMD AMF"
        case "videotoolbox": "VideoToolbox"
        default: value.uppercased()
        }
    }

    private func codecSummary(_ codecs: [String]?) -> String {
        guard let codecs, !codecs.isEmpty else { return "None" }
        return codecs.map(codecDisplayName).joined(separator: ", ")
    }

    private func codecDisplayName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "h264": "H.264"
        case "hevc", "h265": "HEVC"
        case "mpeg2video": "MPEG-2"
        case "vc1": "VC-1"
        case "vp8": "VP8"
        case "vp9": "VP9"
        case "av1": "AV1"
        default: codec.uppercased()
        }
    }
}

#if DEBUG
extension JellyfinTranscodingSettingsView {
    init(
        apiClient: JellyfinAPIClient = .preview(),
        previewOptions: JellyfinEncodingOptions?,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.apiClient = apiClient
        self._options = State(initialValue: previewOptions)
        self._originalOptions = State(initialValue: previewOptions)
        self._isLoading = State(initialValue: isLoading)
        self._errorMessage = State(initialValue: errorMessage)
        self.isPreview = true
    }
}

#Preview("Jellyfin Transcoding - Loaded") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinTranscodingSettingsView(previewOptions: .previewNvenc)
        }
    }
}

#Preview("Jellyfin Transcoding - Loading") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connecting)) {
        NavigationStack {
            JellyfinTranscodingSettingsView(previewOptions: nil, isLoading: true)
        }
    }
}

#Preview("Jellyfin Transcoding - Error") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.error("Unable to load encoding settings."))) {
        NavigationStack {
            JellyfinTranscodingSettingsView(
                previewOptions: nil,
                errorMessage: "The encoding configuration could not be loaded."
            )
        }
    }
}
#endif

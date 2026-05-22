import SwiftUI

struct ArrEditItemSheet<TypeFields: View>: View {
    let title: String
    let serviceType: ArrServiceType
    let itemKindLabel: String
    let serviceName: String
    @Binding var monitored: Bool
    @Binding var qualityProfileId: Int
    @Binding var rootFolderPath: String
    @Binding var selectedTags: Set<Int>
    @Binding var moveFiles: Bool
    let isSaving: Bool
    let hasExistingFiles: Bool
    let rootFolderChanged: Bool
    let qualityProfiles: [ArrQualityProfile]
    let rootFolders: [ArrRootFolder]
    let tags: [ArrTag]
    let onSave: () -> Void
    @ViewBuilder let typeFields: () -> TypeFields

    @State private var qualityProfileForDetails: ArrQualityProfile?

    var body: some View {
        ArrSheetShell(
            title: title,
            confirmTitle: "Save",
            isConfirmDisabled: isSaving || qualityProfileId == 0 || rootFolderPath.isEmpty,
            isConfirmLoading: isSaving,
            onConfirm: onSave
        ) {
            Form {
                Section {
                    ArrMonitoredToggle(isMonitored: $monitored)

                    ArrQualityProfilePicker(
                        selection: Binding(
                            get: { qualityProfileId },
                            set: { if let val = $0 { qualityProfileId = val } }
                        ),
                        profiles: qualityProfiles
                    ) { profile in
                        qualityProfileForDetails = profile
                    }

                    typeFields()

                    ArrRootFolderPicker(
                        selection: Binding(
                            get: { rootFolderPath },
                            set: { if let val = $0 { rootFolderPath = val } }
                        ),
                        folders: rootFolders
                    )

                    if rootFolderChanged && hasExistingFiles {
                        Toggle("Move Existing Files", isOn: $moveFiles)
                    }
                } header: {
                    Text("Library")
                } footer: {
                    if rootFolderChanged {
                        if hasExistingFiles {
                            Text(moveFiles
                                 ? "This updates the \(itemKindLabel) folder and asks \(serviceName) to move existing files into the new root."
                                 : "This updates the \(itemKindLabel) folder, but existing files stay where they are until you move them manually.")
                        } else {
                            Text("This updates the \(itemKindLabel) folder so future imports target the new root.")
                        }
                    }
                }

                Section("Tags") {
                    if tags.isEmpty {
                        Text("No tags available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tags) { tag in
                            Toggle(isOn: tagBinding(for: tag.id)) {
                                Text(tag.label)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $qualityProfileForDetails) { profile in
            NavigationStack {
                ArrQualityProfileDetailView(serviceType: serviceType, profile: profile)
            }
        }
    }

    private func tagBinding(for tagId: Int) -> Binding<Bool> {
        Binding(
            get: { selectedTags.contains(tagId) },
            set: { isSelected in
                if isSelected {
                    selectedTags.insert(tagId)
                } else {
                    selectedTags.remove(tagId)
                }
            }
        )
    }
}

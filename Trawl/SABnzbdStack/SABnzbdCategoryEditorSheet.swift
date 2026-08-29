import SwiftUI

/// Creates or edits one SABnzbd category.
struct SABnzbdCategoryEditorSheet: View {
    /// `nil` creates a new category.
    let existingCategory: SABnzbdCategory?
    let onSaved: () -> Void

    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var directory = ""
    @State private var script = SABnzbdCategory.inheritScript
    /// `nil` is SABnzbd's "inherit the global setting", which is what an empty
    /// `pp` means on the wire. Not the same as picking a level.
    @State private var postProcessing: SABnzbdPostProcessing?
    @State private var priority: SABnzbdCategoryPriority = .default

    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isEditing: Bool { existingCategory != nil }
    /// SABnzbd's catch-all is addressed by the literal "*", so renaming it would
    /// orphan every job pointing at it.
    private var isDefaultCategory: Bool { existingCategory?.isDefault == true }

    /// The installed scripts, plus whatever this category already points at if
    /// that script has since been removed from the server - otherwise the picker
    /// would have a selection with no matching row and render blank.
    private var scriptOptions: [String] {
        var options = serviceManager.scripts
        if let existing = existingCategory?.realScriptName, !options.contains(existing) {
            options.append(existing)
        }
        return options
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        AppSheetShell(
            title: isEditing ? "Edit Category" : "Add Category",
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            Form {
                Section {
                    if isDefaultCategory {
                        LabeledContent("Name", value: "Default")
                    } else {
                        TextField("Name", text: $name)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Category")
                } footer: {
                    if isDefaultCategory {
                        Text("This is SABnzbd's catch-all category. Its settings apply to anything without a category of its own, and it can't be renamed or removed.")
                    }
                }

                Section {
                    TextField("Folder", text: $directory)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Folder")
                } footer: {
                    Text("Relative to SABnzbd's completed-downloads folder, or an absolute path. Leave empty to use the default.")
                }

                Section("Processing") {
                    Picker("Post-Processing", selection: $postProcessing) {
                        Text("Default").tag(SABnzbdPostProcessing?.none)
                        ForEach(SABnzbdPostProcessing.allCases) { level in
                            Text(level.title).tag(SABnzbdPostProcessing?.some(level))
                        }
                    }

                    Picker("Priority", selection: $priority) {
                        ForEach(SABnzbdCategoryPriority.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }

                    Picker("Script", selection: $script) {
                        Text("Default").tag(SABnzbdCategory.inheritScript)
                        Text("None").tag(SABnzbdCategory.noScript)
                        ForEach(scriptOptions, id: \.self) { available in
                            Text(available).tag(available)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isEditing ? "Save Changes" : "Add Category")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(!canSave)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .tint(ServiceIdentity.sabnzbd.brandColor)
            .onAppear(perform: seedFields)
        }
    }

    private func seedFields() {
        guard let existingCategory, name.isEmpty else { return }
        name = existingCategory.name
        directory = existingCategory.directory ?? ""
        let existingScript = existingCategory.script ?? ""
        script = existingScript.isEmpty ? SABnzbdCategory.inheritScript : existingScript
        // An absent pp means inherit; leave the selection on Default rather than
        // inventing a level this category never had.
        if let pp = existingCategory.postProcessing {
            postProcessing = SABnzbdPostProcessing(rawValue: pp)
        }
        if let value = existingCategory.priority, let named = SABnzbdCategoryPriority(rawValue: value) {
            priority = named
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let category = SABnzbdCategory(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            order: existingCategory?.order,
            postProcessing: postProcessing?.rawValue,
            script: script,
            directory: directory.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority.rawValue
        )

        do {
            try await serviceManager.saveCategory(category, originalName: existingCategory?.name)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

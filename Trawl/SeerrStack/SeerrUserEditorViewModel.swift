import Foundation
import Observation

@Observable
final class SeerrUserEditorViewModel {
    let user: SeerrUser
    var permissionsValue: Int
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let apiClient: SeerrAPIClient
    private var originalPermissionsValue: Int

    init(user: SeerrUser, apiClient: SeerrAPIClient) {
        self.user = user
        self.apiClient = apiClient
        let value = user.permissions ?? 0
        self.permissionsValue = value
        self.originalPermissionsValue = value
    }

    var permissionLevelLabel: String {
        SeerrPermission.permissionLevelLabel(for: permissionsValue)
    }

    var isAdminEnabled: Bool {
        contains(.admin)
    }

    var hasChanges: Bool {
        permissionsValue != originalPermissionsValue
    }

    func contains(_ permission: SeerrPermission) -> Bool {
        SeerrPermission.has(permission, in: permissionsValue)
    }

    func set(_ permission: SeerrPermission, enabled: Bool) {
        if enabled {
            permissionsValue |= permission.rawValue
        } else {
            permissionsValue &= ~permission.rawValue
        }
    }

    func reset() {
        permissionsValue = originalPermissionsValue
    }

    func save() async -> SeerrUser? {
        guard !isSaving else { return nil }
        isSaving = true
        errorMessage = nil

        defer { isSaving = false }

        do {
            let updatedUser = try await apiClient.updateUser(id: user.id, permissions: permissionsValue)
            permissionsValue = updatedUser.permissions ?? permissionsValue
            originalPermissionsValue = updatedUser.permissions ?? permissionsValue
            return updatedUser
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func clearError() {
        errorMessage = nil
    }
}

#if DEBUG
extension SeerrUserEditorViewModel {
    convenience init(
        previewUser: SeerrUser = .preview,
        permissionsValue: Int? = nil,
        isSaving: Bool = false,
        errorMessage: String? = nil,
        apiClient: SeerrAPIClient = .preview()
    ) {
        self.init(user: previewUser, apiClient: apiClient)
        let value = permissionsValue ?? previewUser.permissions ?? 0
        self.permissionsValue = value
        self.originalPermissionsValue = value
        self.isSaving = isSaving
        self.errorMessage = errorMessage
    }
}
#endif

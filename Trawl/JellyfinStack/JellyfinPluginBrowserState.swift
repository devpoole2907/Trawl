import SwiftUI

/// Shared by the plugins list and detail columns of the root split view.
///
/// Hoisting plugins state here avoids duplicate `/Plugins` requests between
/// the content and detail columns, and keeps selection and deletion synchronized.
@MainActor
@Observable
final class JellyfinPluginBrowserState {
    var selectedPluginID: String?
    var plugins: [JellyfinPlugin] = []
    var isLoading = false
    var errorMessage: String?

    func refresh(apiClient: JellyfinAPIClient) async {
        await loadPlugins(apiClient: apiClient, showLoading: false)
    }

    func loadPlugins(apiClient: JellyfinAPIClient, showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        errorMessage = nil

        do {
            plugins = try await apiClient.getPlugins()
        } catch {
            errorMessage = error.localizedDescription
        }

        if showLoading { isLoading = false }
    }

    func deletePlugin(_ plugin: JellyfinPlugin, apiClient: JellyfinAPIClient) async {
        do {
            try await apiClient.deletePlugin(id: plugin.id, version: plugin.version)
            plugins.removeAll { $0.id == plugin.id }
            if selectedPluginID == plugin.id {
                selectedPluginID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Uninstall Plugin",
                message: error.localizedDescription
            )
        }
    }
}

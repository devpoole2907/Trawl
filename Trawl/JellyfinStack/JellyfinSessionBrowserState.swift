import SwiftUI

/// Shared by the sessions list and detail columns of the root split view.
///
/// Hoisting sessions and polling here avoids duplicate `/Sessions` requests between
/// the two columns, and allows the detail inspector to react instantly as playback
/// ticks forward or sessions change.
@MainActor
@Observable
final class JellyfinSessionBrowserState {
    var selectedSessionID: String?
    var sessions: [JellyfinSession] = []
    var isLoading = false
    var errorMessage: String?
    private var pollingTask: Task<Void, Never>?

    func startPolling(apiClient: JellyfinAPIClient) async {
        await loadSessions(apiClient: apiClient)
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await loadSessions(apiClient: apiClient, showLoading: false)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh(apiClient: JellyfinAPIClient) async {
        await loadSessions(apiClient: apiClient, showLoading: false)
    }

    func loadSessions(apiClient: JellyfinAPIClient, showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        errorMessage = nil

        do {
            sessions = try await apiClient.getSessions()
        } catch {
            errorMessage = error.localizedDescription
        }

        if showLoading { isLoading = false }
    }

    func stopPlayback(sessionId: String, apiClient: JellyfinAPIClient) async {
        do {
            try await apiClient.stopPlayback(sessionId: sessionId)
            await loadSessions(apiClient: apiClient, showLoading: false)
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Stop Playback",
                message: error.localizedDescription
            )
        }
    }
}

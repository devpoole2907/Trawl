import Foundation
import Observation

@Observable
final class SeerrIssueDetailViewModel {
    private(set) var issue: SeerrIssue
    private(set) var comments: [SeerrIssueComment]
    var replyMessage = ""
    private(set) var isLoadingComments = false
    private(set) var isSendingReply = false
    private(set) var isUpdatingStatus = false
    private(set) var errorMessage: String?

    private let apiClient: SeerrAPIClient

    init(issue: SeerrIssue, apiClient: SeerrAPIClient) {
        self.issue = issue
        self.comments = issue.comments ?? []
        self.apiClient = apiClient
    }

    var statusTitle: String {
        issue.issueStatus?.title ?? "Unknown"
    }

    var toggleButtonTitle: String {
        issue.issueStatus == .resolved ? "Reopen Issue" : "Resolve Issue"
    }

    func loadComments() async {
        isLoadingComments = true
        errorMessage = nil

        defer { isLoadingComments = false }

        do {
            comments = try await apiClient.getIssueComments(issueId: issue.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleStatus() async -> SeerrIssue? {
        isUpdatingStatus = true
        errorMessage = nil

        defer { isUpdatingStatus = false }

        do {
            let updatedIssue: SeerrIssue
            if issue.issueStatus == .resolved {
                updatedIssue = try await apiClient.reopenIssue(issueId: issue.id)
            } else {
                updatedIssue = try await apiClient.resolveIssue(issueId: issue.id)
            }
            issue = updatedIssue
            if let updatedComments = updatedIssue.comments, !updatedComments.isEmpty {
                comments = updatedComments
            }
            return updatedIssue
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func sendReply() async -> SeerrIssue? {
        let trimmed = replyMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        isSendingReply = true
        errorMessage = nil

        defer { isSendingReply = false }

        do {
            let updatedIssue = try await apiClient.replyToIssue(issueId: issue.id, message: trimmed)
            issue = updatedIssue
            comments = updatedIssue.comments ?? comments
            replyMessage = ""
            if comments.isEmpty {
                await loadComments()
            }
            return updatedIssue
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func clearError() {
        errorMessage = nil
    }
}

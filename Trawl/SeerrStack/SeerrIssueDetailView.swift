import Observation
import SwiftUI

struct SeerrIssueDetailView: View {
    let apiClient: SeerrAPIClient
    let onUpdate: (SeerrIssue) -> Void

    @State private var viewModel: SeerrIssueDetailViewModel
    @State private var errorAlert: ErrorAlertItem?

    init(issue: SeerrIssue, apiClient: SeerrAPIClient, onUpdate: @escaping (SeerrIssue) -> Void) {
        self.apiClient = apiClient
        self.onUpdate = onUpdate
        self._viewModel = State(initialValue: SeerrIssueDetailViewModel(issue: issue, apiClient: apiClient))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            Section("Issue") {
                HStack(alignment: .top, spacing: 12) {
                    ArrArtworkView(url: viewModel.issue.media?.posterURL) {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 56, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.issue.media?.displayTitle ?? "Unknown Media")
                            .font(.title2.bold())

                        if let issueType = viewModel.issue.issueKind {
                            Label(issueType.title, systemImage: issueType.symbolName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let status = viewModel.issue.issueStatus {
                            Label(status.title, systemImage: status.symbolName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(status == .resolved ? Color.green : Color.orange)
                        }

                        if let createdBy = viewModel.issue.createdBy {
                            Text("Reported by \(createdBy.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let createdAt = viewModel.issue.createdAtRelativeText {
                            Text("Opened \(createdAt)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let updatedAt = viewModel.issue.updatedAtRelativeText,
                           updatedAt != viewModel.issue.createdAtRelativeText {
                            Text("Updated \(updatedAt)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section("Comments") {
                if viewModel.isLoadingComments && viewModel.comments.isEmpty {
                    ProgressView("Loading comments…")
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if viewModel.comments.isEmpty {
                    Text("No comments yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.comments) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(comment.user?.displayName ?? "Unknown User")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if let createdAt = comment.createdAtRelativeText {
                                    Text(createdAt)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(comment.message)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Issue #\(viewModel.issue.id)")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
#endif
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Reply to issue", text: $viewModel.replyMessage, axis: .vertical)
#if os(iOS)
                        .textFieldStyle(.roundedBorder)
#endif
                        .lineLimit(1...4)

                    Button {
                        Task {
                            if let updatedIssue = await viewModel.sendReply() {
                                onUpdate(updatedIssue)
                            }
                        }
                    } label: {
                        if viewModel.isSendingReply {
                            ProgressView()
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.headline)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.replyMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSendingReply || viewModel.isUpdatingStatus)
                }

                Button {
                    Task {
                        if let updatedIssue = await viewModel.toggleStatus() {
                            onUpdate(updatedIssue)
                        }
                    }
                } label: {
                    HStack {
                        if viewModel.isUpdatingStatus {
                            ProgressView()
                        }
                        Text(viewModel.toggleButtonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(viewModel.issue.issueStatus == .resolved ? .orange : .green)
                .disabled(viewModel.isUpdatingStatus || viewModel.isSendingReply)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .task { await viewModel.loadComments() }
        .errorAlert(item: $errorAlert)
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            errorAlert = ErrorAlertItem(title: "Issue Action Failed", message: message)
            viewModel.clearError()
        }
    }
}

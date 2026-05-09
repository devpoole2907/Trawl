import SwiftUI

struct SeerrDashboardView: View {
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(\.navigateToSeerrIssues) private var navigateToSeerrIssues
    @Environment(\.navigateToSeerrUserManagement) private var navigateToSeerrUserManagement
    @State private var requestCount: SeerrRequestCount?
    @State private var dashboardClient: SeerrAPIClient?
    @State private var fetchError: String?

    var body: some View {
        List {
            Section {
                if let count = requestCount, let client = dashboardClient {
                    SeerrDashboardCard(requestCount: count, apiClient: client)
                } else if fetchError != nil {
                    ContentUnavailableView {
                        Label("Failed to Load Dashboard", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(fetchError ?? "An error occurred")
                    } actions: {
                        Button("Retry") {
                            Task { await fetchRequestCount() }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    ProgressView()
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section {
                Button(action: navigateToSeerrIssues) {
                    Label("Manage Issues", systemImage: "exclamationmark.bubble.fill")
                        .foregroundStyle(.orange)
                }

                Button(action: navigateToSeerrUserManagement) {
                    Label("Manage Users", systemImage: "person.2.fill")
                        .foregroundStyle(.indigo)
                }
            }
        }
        .navigationTitle("Seerr Admin")
        .task {
            await fetchRequestCount()
        }
    }

    private func fetchRequestCount() async {
        fetchError = nil
        guard let client = seerrServiceManager.activeClient else {
            fetchError = "Client not available"
            return
        }

        do {
            requestCount = try await client.getRequestCount()
            dashboardClient = client
        } catch {
            fetchError = error.localizedDescription
        }
    }
}

extension EnvironmentValues {
    @Entry var navigateToSeerrIssues: () -> Void = {}
    @Entry var navigateToSeerrUserManagement: () -> Void = {}
    @Entry var navigateToSeerrSettings: () -> Void = {}
}

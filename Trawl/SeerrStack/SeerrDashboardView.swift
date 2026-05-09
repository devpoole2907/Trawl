import SwiftUI

struct SeerrDashboardView: View {
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(\.navigateToSeerrIssues) private var navigateToSeerrIssues
    @Environment(\.navigateToSeerrUserManagement) private var navigateToSeerrUserManagement
    @State private var requestCount: SeerrRequestCount?

    var body: some View {
        List {
            Section {
                if let count = requestCount {
                    SeerrDashboardCard(requestCount: count, apiClient: seerrServiceManager.activeClient!)
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
            if let client = seerrServiceManager.activeClient {
                requestCount = try? await client.getRequestCount()
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var navigateToSeerrIssues: () -> Void = {}
    @Entry var navigateToSeerrUserManagement: () -> Void = {}
    @Entry var navigateToSeerrSettings: () -> Void = {}
}

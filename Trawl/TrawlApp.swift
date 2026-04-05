import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct TrawlApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            ServerProfile.self,
            CachedTorrentState.self,
            RecentSavePath.self
        ])
        let config = ModelConfiguration(
            groupContainer: .identifier(AppGroup.identifier)
        )
        modelContainer = try! ModelContainer(for: schema, configurations: [config])

        // Register background task for torrent completion notifications
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.poole.james.Trawl.torrentCheck",
            using: nil
        ) { task in
            Task {
                await NotificationService.shared.handleBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}

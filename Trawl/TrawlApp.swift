import SwiftUI
import SwiftData
#if os(iOS)
import BackgroundTasks
#endif
#if os(macOS)
import CoreServices
#endif

@main
struct TrawlApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            ServerProfile.self,
            CachedTorrentState.self,
            RecentSavePath.self
        ])
        // Try the shared app group container first (needed for Share Extension access).
        // Fall back to the default container if the group isn't provisioned (e.g. simulator).
        if let container = try? ModelContainer(for: schema, configurations: [
            ModelConfiguration(groupContainer: .identifier(AppGroup.identifier))
        ]) {
            modelContainer = container
        } else {
            modelContainer = try! ModelContainer(for: schema)
        }

        // Register with Launch Services so macOS knows this app handles magnet: URLs
        #if os(macOS)
        LSRegisterURL(Bundle.main.bundleURL as CFURL, false)
        #endif

        // Register background task for torrent completion notifications (iOS only)
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.poole.james.Trawl.torrentCheck",
            using: nil
        ) { task in
            Task {
                await NotificationService.shared.handleBackgroundRefresh()
                task.setTaskCompleted(success: true)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}

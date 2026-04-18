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
    @State private var arrServiceManager = ArrServiceManager()
    @State private var sshSessionStore = SSHSessionStore()
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared

    init() {
        let schema = Schema([
            ServerProfile.self,
            CachedTorrentState.self,
            RecentSavePath.self,
            ArrServiceProfile.self,
            SSHProfile.self
        ])
        // Try the shared app group container first (needed for Share Extension access).
        // Fall back to the default container if the group isn't provisioned (e.g. simulator).
        do {
            let groupConfiguration = ModelConfiguration(groupContainer: .identifier(AppGroup.identifier))
            modelContainer = try ModelContainer(for: schema, configurations: [groupConfiguration])
        } catch {
            print("Failed to initialize App Group ModelContainer: \(error)")
            do {
                modelContainer = try ModelContainer(for: schema)
            } catch {
                print("Failed to initialize default ModelContainer: \(error)")
                do {
                    let inMemoryConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
                    modelContainer = try ModelContainer(for: schema, configurations: [inMemoryConfiguration])
                    
                    Task { @MainActor in
                        InAppNotificationCenter.shared.showError(
                            title: "Storage Error",
                            message: "Failed to load saved data. Changes will not be saved."
                        )
                    }
                } catch {
                    fatalError("Failed to initialize even an in-memory ModelContainer: \(error)")
                }
            }
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
                .environment(arrServiceManager)
                .environment(sshSessionStore)
                .environment(inAppNotificationCenter)
        }
        .modelContainer(modelContainer)
    }
}

import SwiftUI
import SwiftData
import OSLog
#if os(iOS)
import BackgroundTasks
#endif
#if os(macOS)
import CoreServices
#endif

@main
struct TrawlApp: App {
    private static let logger = Logger(subsystem: "com.poole.james.Trawl", category: "App")
    
    let modelContainer: ModelContainer
    @State private var arrServiceManager = ArrServiceManager()
    @State private var sshSessionStore = SSHSessionStore()
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared

    init() {
        try? Libssh2RuntimeBootstrap.bootstrap()
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
            let groupContainer = try ModelContainer(for: schema, configurations: [groupConfiguration])
            try Self.migrateDefaultStoreIfNeeded(schema: schema, destination: groupContainer)
            modelContainer = groupContainer
        } catch {
            Self.logger.error("Failed to initialize App Group ModelContainer: \(error.localizedDescription, privacy: .public)")
            do {
                modelContainer = try ModelContainer(for: schema)
            } catch {
                Self.logger.error("Failed to initialize default ModelContainer: \(error.localizedDescription, privacy: .public)")
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
                    Self.logger.fault("Failed to initialize even an in-memory ModelContainer: \(error.localizedDescription, privacy: .public)")
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

    private static func migrateDefaultStoreIfNeeded(schema: Schema, destination: ModelContainer) throws {
        let destinationContext = ModelContext(destination)
        guard !destinationContextHasData(destinationContext) else { return }

        let sourceConfiguration = ModelConfiguration(
            "DefaultStoreMigration",
            schema: schema,
            allowsSave: false,
            groupContainer: .none
        )

        let sourceContainer = try ModelContainer(for: schema, configurations: [sourceConfiguration])
        let sourceContext = ModelContext(sourceContainer)
        guard sourceContextHasData(sourceContext) else { return }

        try copyModels(from: sourceContext, to: destinationContext)
        try destinationContext.save()
    }

    private static func destinationContextHasData(_ context: ModelContext) -> Bool {
        sourceContextHasData(context)
    }

    private static func sourceContextHasData(_ context: ModelContext) -> Bool {
        do {
            var serverDescriptor = FetchDescriptor<ServerProfile>()
            serverDescriptor.fetchLimit = 1

            var cachedStateDescriptor = FetchDescriptor<CachedTorrentState>()
            cachedStateDescriptor.fetchLimit = 1

            var recentPathDescriptor = FetchDescriptor<RecentSavePath>()
            recentPathDescriptor.fetchLimit = 1

            var arrProfileDescriptor = FetchDescriptor<ArrServiceProfile>()
            arrProfileDescriptor.fetchLimit = 1

            var sshProfileDescriptor = FetchDescriptor<SSHProfile>()
            sshProfileDescriptor.fetchLimit = 1

            return
                try !context.fetch(serverDescriptor).isEmpty ||
                !context.fetch(cachedStateDescriptor).isEmpty ||
                !context.fetch(recentPathDescriptor).isEmpty ||
                !context.fetch(arrProfileDescriptor).isEmpty ||
                !context.fetch(sshProfileDescriptor).isEmpty
        } catch {
            logger.error("SwiftData migration probe failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func copyModels(from sourceContext: ModelContext, to destinationContext: ModelContext) throws {
        do {
            for profile in try sourceContext.fetch(FetchDescriptor<ServerProfile>()) {
                let copy = ServerProfile(displayName: profile.displayName, hostURL: profile.hostURL)
                copy.id = profile.id
                copy.isActive = profile.isActive
                copy.dateAdded = profile.dateAdded
                copy.lastConnected = profile.lastConnected
                copy.defaultSavePath = profile.defaultSavePath
                destinationContext.insert(copy)
            }

            for cachedState in try sourceContext.fetch(FetchDescriptor<CachedTorrentState>()) {
                let copy = CachedTorrentState(
                    hash: cachedState.hash,
                    name: cachedState.name,
                    state: cachedState.state,
                    progress: cachedState.progress
                )
                copy.lastUpdated = cachedState.lastUpdated
                destinationContext.insert(copy)
            }

            for recentPath in try sourceContext.fetch(FetchDescriptor<RecentSavePath>()) {
                let copy = RecentSavePath(path: recentPath.path)
                copy.lastUsed = recentPath.lastUsed
                copy.useCount = recentPath.useCount
                destinationContext.insert(copy)
            }

            for arrProfile in try sourceContext.fetch(FetchDescriptor<ArrServiceProfile>()) {
                let serviceType = arrProfile.resolvedServiceType ?? .sonarr
                let copy = ArrServiceProfile(
                    displayName: arrProfile.displayName,
                    hostURL: arrProfile.hostURL,
                    serviceType: serviceType
                )
                copy.id = arrProfile.id
                copy.isEnabled = arrProfile.isEnabled
                copy.dateAdded = arrProfile.dateAdded
                copy.lastSynced = arrProfile.lastSynced
                copy.apiVersion = arrProfile.apiVersion
                destinationContext.insert(copy)
            }

            for sshProfile in try sourceContext.fetch(FetchDescriptor<SSHProfile>()) {
                let copy = SSHProfile(
                    displayName: sshProfile.displayName,
                    host: sshProfile.host,
                    port: sshProfile.port,
                    username: sshProfile.username,
                    authType: sshProfile.authType
                )
                copy.id = sshProfile.id
                copy.knownHostFingerprint = sshProfile.knownHostFingerprint
                copy.createdAt = sshProfile.createdAt
                destinationContext.insert(copy)
            }
        } catch {
            logger.error("SwiftData migration copy failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

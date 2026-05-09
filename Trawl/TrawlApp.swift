import SwiftUI
import SwiftData
import OSLog
#if os(macOS)
import CoreServices
#endif

@main
struct TrawlApp: App {
    private static let logger = Logger(subsystem: "com.poole.james.Trawl", category: "App")

    #if os(iOS)
    @UIApplicationDelegateAdaptor(TrawlAppDelegate.self) var appDelegate
    #endif

    let modelContainer: ModelContainer
    @State private var arrServiceManager = ArrServiceManager()
    @State private var seerrServiceManager = SeerrServiceManager()
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared
    @State private var appLockController = AppLockController()

    init() {
        let schema = Schema([
            ServerProfile.self,
            CachedTorrentState.self,
            RecentSavePath.self,
            ArrServiceProfile.self,
            SeerrServiceProfile.self
        ])

        do {
            let groupConfiguration = ModelConfiguration(
                schema: schema,
                groupContainer: .identifier(AppGroup.identifier)
            )
            let groupContainer = try ModelContainer(for: schema, configurations: [groupConfiguration])
            try Self.migrateDefaultStoreIfNeeded(schema: schema, destination: groupContainer)
            modelContainer = groupContainer
        } catch {
            Self.logger.error("Failed to initialize App Group ModelContainer: \(error.localizedDescription, privacy: .public)")
            do {
                let localConfiguration = ModelConfiguration(schema: schema)
                modelContainer = try ModelContainer(for: schema, configurations: [localConfiguration])
            } catch {
                Self.logger.error("Failed to initialize default ModelContainer: \(error.localizedDescription, privacy: .public)")
                do {
                    let inMemoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
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

        #if os(macOS)
        LSRegisterURL(Bundle.main.bundleURL as CFURL, false)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(arrServiceManager)
                .environment(seerrServiceManager)
                .environment(inAppNotificationCenter)
                .environment(appLockController)
                .task {
                    appLockController.bootstrap()
                }
        }
        .modelContainer(modelContainer)
    }

    private static func migrateDefaultStoreIfNeeded(schema: Schema, destination: ModelContainer) throws {
        let destinationContext = ModelContext(destination)
        guard !destinationContextHasData(destinationContext) else { return }

        let sourceConfiguration = ModelConfiguration(
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

            return
                try !context.fetch(serverDescriptor).isEmpty ||
                !context.fetch(cachedStateDescriptor).isEmpty ||
                !context.fetch(recentPathDescriptor).isEmpty ||
                !context.fetch(arrProfileDescriptor).isEmpty
        } catch {
            logger.error("SwiftData migration probe failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func copyModels(from sourceContext: ModelContext, to destinationContext: ModelContext) throws {
        do {
            for profile in try sourceContext.fetch(FetchDescriptor<ServerProfile>()) {
                let copy = ServerProfile(
                    displayName: profile.displayName,
                    hostURL: profile.hostURL,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
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
                guard let serviceType = arrProfile.resolvedServiceType else {
                    logger.warning("Skipping ArrServiceProfile with invalid service type: \(arrProfile.serviceType, privacy: .public)")
                    continue
                }
                let copy = ArrServiceProfile(
                    displayName: arrProfile.displayName,
                    hostURL: arrProfile.hostURL,
                    serviceType: serviceType,
                    allowsUntrustedTLS: arrProfile.allowsUntrustedTLS
                )
                copy.id = arrProfile.id
                copy.isEnabled = arrProfile.isEnabled
                copy.dateAdded = arrProfile.dateAdded
                copy.lastSynced = arrProfile.lastSynced
                copy.apiVersion = arrProfile.apiVersion
                copy.importFolders = arrProfile.importFolders
                destinationContext.insert(copy)
            }
        } catch {
            logger.error("SwiftData migration copy failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

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
    @State private var jellyfinServiceManager = JellyfinServiceManager()
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared
    @State private var appLockController = AppLockController()

    init() {
        let schema = TrawlModelSchema.full

        do {
            let groupConfiguration = ModelConfiguration(
                schema: schema,
                groupContainer: .identifier(AppGroup.identifier)
            )
            let groupContainer = try ModelContainer(for: schema, configurations: [groupConfiguration])
            do {
                try Self.migrateDefaultStoreIfNeeded(schema: schema, destination: groupContainer)
            } catch {
                Self.logger.warning("Default store migration skipped: \(error.localizedDescription, privacy: .public)")
            }
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
                .environment(jellyfinServiceManager)
                .environment(inAppNotificationCenter)
                .environment(appLockController)
                .task {
                    appLockController.bootstrap()
                }
        }
        .modelContainer(modelContainer)
    }

    private static func migrateDefaultStoreIfNeeded(schema: Schema, destination: ModelContainer) throws {
        guard defaultStoreExists() else { return }

        let destinationContext = ModelContext(destination)

        let sourceConfiguration = ModelConfiguration(
            schema: schema,
            allowsSave: false,
            groupContainer: .none
        )

        let sourceContainer = try ModelContainer(for: schema, configurations: [sourceConfiguration])
        let sourceContext = ModelContext(sourceContainer)
        guard sourceContextHasData(sourceContext) else { return }

        try copyMissingModels(from: sourceContext, to: destinationContext)
        try destinationContext.save()
    }

    private static func defaultStoreExists() -> Bool {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }

        return FileManager.default.fileExists(
            atPath: applicationSupportURL.appendingPathComponent("default.store").path
        )
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

            var seerrProfileDescriptor = FetchDescriptor<SeerrServiceProfile>()
            seerrProfileDescriptor.fetchLimit = 1

            var jellyfinProfileDescriptor = FetchDescriptor<JellyfinServiceProfile>()
            jellyfinProfileDescriptor.fetchLimit = 1

            return
                try !context.fetch(serverDescriptor).isEmpty ||
                !context.fetch(cachedStateDescriptor).isEmpty ||
                !context.fetch(recentPathDescriptor).isEmpty ||
                !context.fetch(arrProfileDescriptor).isEmpty ||
                !context.fetch(seerrProfileDescriptor).isEmpty ||
                !context.fetch(jellyfinProfileDescriptor).isEmpty
        } catch {
            logger.error("SwiftData migration probe failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func copyMissingModels(from sourceContext: ModelContext, to destinationContext: ModelContext) throws {
        do {
            let existingServerIDs = Set(try destinationContext.fetch(FetchDescriptor<ServerProfile>()).map(\.id))
            for profile in try sourceContext.fetch(FetchDescriptor<ServerProfile>()) {
                guard !existingServerIDs.contains(profile.id) else { continue }
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

            let existingCachedHashes = Set(try destinationContext.fetch(FetchDescriptor<CachedTorrentState>()).map(\.hash))
            for cachedState in try sourceContext.fetch(FetchDescriptor<CachedTorrentState>()) {
                guard !existingCachedHashes.contains(cachedState.hash) else { continue }
                let copy = CachedTorrentState(
                    hash: cachedState.hash,
                    name: cachedState.name,
                    state: cachedState.state,
                    progress: cachedState.progress
                )
                copy.lastUpdated = cachedState.lastUpdated
                destinationContext.insert(copy)
            }

            let existingRecentPaths = Set(try destinationContext.fetch(FetchDescriptor<RecentSavePath>()).map(\.path))
            for recentPath in try sourceContext.fetch(FetchDescriptor<RecentSavePath>()) {
                guard !existingRecentPaths.contains(recentPath.path) else { continue }
                let copy = RecentSavePath(path: recentPath.path)
                copy.lastUsed = recentPath.lastUsed
                copy.useCount = recentPath.useCount
                destinationContext.insert(copy)
            }

            let existingArrIDs = Set(try destinationContext.fetch(FetchDescriptor<ArrServiceProfile>()).map(\.id))
            for arrProfile in try sourceContext.fetch(FetchDescriptor<ArrServiceProfile>()) {
                guard !existingArrIDs.contains(arrProfile.id) else { continue }
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

            let existingSeerrIDs = Set(try destinationContext.fetch(FetchDescriptor<SeerrServiceProfile>()).map(\.id))
            for seerrProfile in try sourceContext.fetch(FetchDescriptor<SeerrServiceProfile>()) {
                guard !existingSeerrIDs.contains(seerrProfile.id) else { continue }
                let copy = SeerrServiceProfile(
                    displayName: seerrProfile.displayName,
                    hostURL: seerrProfile.hostURL,
                    allowsUntrustedTLS: seerrProfile.allowsUntrustedTLS
                )
                copy.id = seerrProfile.id
                copy.isEnabled = seerrProfile.isEnabled
                copy.dateAdded = seerrProfile.dateAdded
                destinationContext.insert(copy)
            }

            let existingJellyfinIDs = Set(try destinationContext.fetch(FetchDescriptor<JellyfinServiceProfile>()).map(\.id))
            for jellyfinProfile in try sourceContext.fetch(FetchDescriptor<JellyfinServiceProfile>()) {
                guard !existingJellyfinIDs.contains(jellyfinProfile.id) else { continue }
                let copy = JellyfinServiceProfile(
                    displayName: jellyfinProfile.displayName,
                    hostURL: jellyfinProfile.hostURL,
                    authMode: jellyfinProfile.authMode,
                    userID: jellyfinProfile.userID,
                    allowsUntrustedTLS: jellyfinProfile.allowsUntrustedTLS
                )
                copy.id = jellyfinProfile.id
                copy.isEnabled = jellyfinProfile.isEnabled
                copy.dateAdded = jellyfinProfile.dateAdded
                copy.serverName = jellyfinProfile.serverName
                copy.serverVersion = jellyfinProfile.serverVersion
                destinationContext.insert(copy)
            }
        } catch {
            logger.error("SwiftData migration copy failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

import SwiftUI
import SwiftData
import OSLog
#if DEBUG
import Security
#endif
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
    @State private var sabnzbdServiceManager = SABnzbdServiceManager()
    @State private var cleanuparrServiceManager = CleanuparrServiceManager()
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared
    @State private var appLockController = AppLockController()

    init() {
        let schema = TrawlModelSchema.full

        #if DEBUG
        // UI tests need a deterministic, empty starting state, but the simulator's
        // on-disk App Group container may already hold the developer's real service
        // profiles. Rather than wiping and reusing that real store — which would risk
        // destroying actual user data if this flag were ever passed by accident — hand
        // tests an in-memory store instead: it's inherently empty and can't touch
        // anything on disk. DEBUG-only so this can never exist in a Release build.
        if ProcessInfo.processInfo.arguments.contains("-TrawlUITestInMemoryStore") {
            do {
                let inMemoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                modelContainer = try ModelContainer(for: schema, configurations: [inMemoryConfiguration])
            } catch {
                fatalError("Failed to initialize in-memory ModelContainer for UI tests: \(error)")
            }

            Self.seedUITestArrServiceIfRequested(into: modelContainer)

            #if os(macOS)
            LSRegisterURL(Bundle.main.bundleURL as CFURL, false)
            #endif
            return
        }
        #endif

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
                .environment(sabnzbdServiceManager)
                .environment(cleanuparrServiceManager)
                .environment(inAppNotificationCenter)
                .environment(appLockController)
                .task {
                    appLockController.bootstrap()
                }
                .task {
                    // Make configured *arr services discoverable by Spotlight / Apple Intelligence.
                    // Cheap (SwiftData only); library content is indexed opportunistically by the
                    // search intents and on demand via ArrSpotlightIndexer.indexLibraries().
                    await ArrSpotlightIndexer.indexConfiguredServices()
                }
        }
        .modelContainer(modelContainer)
    }

    #if DEBUG
    /// UI tests that need to get past the welcome gate into the real tab UI pass a
    /// loopback fixture server's base URL through `TRAWL_UITEST_SONARR_BASE_URL` (see
    /// the fixture server in `TrawlUITests`). When present, seed one real
    /// `ArrServiceProfile` plus its Keychain-stored API key into the in-memory store
    /// created above, then let the app's *normal* startup take over from there:
    /// `ContentView` will query this profile, `ArrServiceManager.initialize(from:)` will
    /// call the real `connectService(_:)`, and the real `SonarrAPIClient` will make real
    /// HTTP requests to the fixture server. Nothing about the connect path itself is
    /// stubbed — only the external Sonarr server is faked, which is the whole point.
    ///
    /// A second, optional Sonarr profile can be seeded alongside the first through
    /// `TRAWL_UITEST_SONARR_B_BASE_URL`, for journeys that need two live instances to
    /// switch between (see `ArrInstanceSwitchJourneyUITests`). It is intentionally
    /// additive: the first variable and profile behave exactly as before whether or
    /// not the second is present.
    private static func seedUITestArrServiceIfRequested(into modelContainer: ModelContainer) {
        guard let sonarrBaseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_SONARR_BASE_URL"],
              !sonarrBaseURL.isEmpty else {
            return
        }

        let profile = ArrServiceProfile(
            displayName: "Fixture Sonarr",
            hostURL: sonarrBaseURL,
            serviceType: .sonarr
        )
        // Fixed, hardcoded UUID (not `UUID()`): the in-memory ModelContainer is wiped on
        // every launch, but the simulator's real Keychain is not. Reusing the same ID
        // means each run overwrites one Keychain entry instead of orphaning a new one.
        profile.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000001")!

        // Both writes below are synchronous, and deliberately so. `ContentView` latches
        // its welcome-vs-tabs decision the first time it evaluates, so a profile inserted
        // asynchronously arrives after the app has already committed to the welcome
        // screen. And `connectService` reads the API key as its first step, so an
        // asynchronous key write races the first connection attempt. Doing both before
        // `init()` returns removes both races — and note an earlier attempt to await the
        // async path from `init()` under a semaphore hung the main thread at launch.
        seedUITestKeychainValue("uitest-api-key", forKey: profile.apiKeyKeychainKey)

        let context = ModelContext(modelContainer)
        context.insert(profile)
        do {
            try context.save()
        } catch {
            fatalError("Failed to seed UI test Sonarr profile: \(error)")
        }

        // Second instance, only when a journey asks for one. Seeded strictly after the
        // first profile's insert+save has already committed, so the two profiles have a
        // stable, ordered insertion sequence for the unsorted `@Query private var
        // arrProfiles: [ArrServiceProfile]` in ContentView to return them in — the first
        // profile connects first and becomes `activeSonarrProfileID` by default
        // (`ArrServiceManager.connectService` only sets it `if activeSonarrProfileID ==
        // nil`), which is what lets a test assert which instance is active immediately
        // after launch.
        if let sonarrBBaseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_SONARR_B_BASE_URL"],
           !sonarrBBaseURL.isEmpty {
            // Deliberately does not start with, or contain, "Fixture Sonarr": UI tests
            // that seed both profiles need to select one of the two "Instance" switcher
            // menu buttons unambiguously by a `label CONTAINS[c]` match, and "Fixture
            // Sonarr" is itself a substring match against the first profile's name.
            let profileB = ArrServiceProfile(
                displayName: "Alternate Sonarr",
                hostURL: sonarrBBaseURL,
                serviceType: .sonarr
            )
            // Distinct fixed UUID from the first profile, for the same orphaned-Keychain-
            // entry reason given above.
            profileB.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000002")!

            seedUITestKeychainValue("uitest-api-key", forKey: profileB.apiKeyKeychainKey)

            context.insert(profileB)
            do {
                try context.save()
            } catch {
                fatalError("Failed to seed second UI test Sonarr profile: \(error)")
            }
        }
    }

    /// Writes one Keychain item the way `KeychainHelper` would, but synchronously.
    ///
    /// `KeychainHelper` is an actor, so its `save` cannot be called from a synchronous
    /// `init()` without either racing or blocking. The Keychain is external state, so
    /// seeding it directly is legitimate here — the production *read* path
    /// (`KeychainHelper.read`) is still the one under test. The query mirrors
    /// `KeychainHelper`'s: same class, same service, same account, and the same access
    /// group derived from `AppIdentifierPrefix`, so the production read finds it.
    private static func seedUITestKeychainValue(_ value: String, forKey key: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.poole.james.Trawl",
            kSecAttrAccount as String: key
        ]
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
           !prefix.isEmpty {
            query[kSecAttrAccessGroup as String] = "\(prefix)com.poole.james.Trawl.shared"
        }

        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            fatalError("Failed to seed UI test Keychain entry: OSStatus \(status)")
        }
    }

    #endif

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

            var sabnzbdProfileDescriptor = FetchDescriptor<SABnzbdServiceProfile>()
            sabnzbdProfileDescriptor.fetchLimit = 1

            var cleanuparrProfileDescriptor = FetchDescriptor<CleanuparrServiceProfile>()
            cleanuparrProfileDescriptor.fetchLimit = 1

            return
                try !context.fetch(serverDescriptor).isEmpty ||
                !context.fetch(cachedStateDescriptor).isEmpty ||
                !context.fetch(recentPathDescriptor).isEmpty ||
                !context.fetch(arrProfileDescriptor).isEmpty ||
                !context.fetch(seerrProfileDescriptor).isEmpty ||
                !context.fetch(jellyfinProfileDescriptor).isEmpty ||
                !context.fetch(sabnzbdProfileDescriptor).isEmpty ||
                !context.fetch(cleanuparrProfileDescriptor).isEmpty
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

            let existingSABnzbdIDs = Set(try destinationContext.fetch(FetchDescriptor<SABnzbdServiceProfile>()).map(\.id))
            for sabnzbdProfile in try sourceContext.fetch(FetchDescriptor<SABnzbdServiceProfile>()) {
                guard !existingSABnzbdIDs.contains(sabnzbdProfile.id) else { continue }
                let copy = SABnzbdServiceProfile(
                    displayName: sabnzbdProfile.displayName,
                    hostURL: sabnzbdProfile.hostURL,
                    allowsUntrustedTLS: sabnzbdProfile.allowsUntrustedTLS
                )
                copy.id = sabnzbdProfile.id
                copy.isEnabled = sabnzbdProfile.isEnabled
                copy.dateAdded = sabnzbdProfile.dateAdded
                copy.lastSynced = sabnzbdProfile.lastSynced
                copy.serverVersion = sabnzbdProfile.serverVersion
                destinationContext.insert(copy)
            }

            let existingCleanuparrIDs = Set(try destinationContext.fetch(FetchDescriptor<CleanuparrServiceProfile>()).map(\.id))
            for cleanuparrProfile in try sourceContext.fetch(FetchDescriptor<CleanuparrServiceProfile>()) {
                guard !existingCleanuparrIDs.contains(cleanuparrProfile.id) else { continue }
                let copy = CleanuparrServiceProfile(
                    displayName: cleanuparrProfile.displayName,
                    hostURL: cleanuparrProfile.hostURL,
                    allowsUntrustedTLS: cleanuparrProfile.allowsUntrustedTLS
                )
                copy.id = cleanuparrProfile.id
                copy.isEnabled = cleanuparrProfile.isEnabled
                copy.dateAdded = cleanuparrProfile.dateAdded
                copy.lastSynced = cleanuparrProfile.lastSynced
                destinationContext.insert(copy)
            }
        } catch {
            logger.error("SwiftData migration copy failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

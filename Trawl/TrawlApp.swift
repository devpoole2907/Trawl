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
    /// App-level so any screen can show what the configuration audit found without
    /// re-running it: a badge, a hub row, or the setup-check wizard.
    @State private var configurationAuditStore = ConfigurationAuditStore()
    @State private var seerrServiceManager = SeerrServiceManager()
    @State private var jellyfinServiceManager = JellyfinServiceManager()
    @State private var sabnzbdServiceManager = SABnzbdServiceManager()
    @State private var cleanuparrServiceManager = CleanuparrServiceManager()
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared
    @State private var appLockController = AppLockController()

    init() {
        // Ahead of everything, including the DEBUG UI-test branch below - which
        // returns early. That branch is the one that most needs tips suppressed, and
        // `Tips.hideAllTipsForTesting()` only takes effect once `Tips` is configured.
        TrawlTips.configure()

        let schema = TrawlModelSchema.full

        #if DEBUG
        // UI tests need a deterministic, empty starting state, but the simulator's
        // on-disk App Group container may already hold the developer's real service
        // profiles. Rather than wiping and reusing that real store - which would risk
        // destroying actual user data if this flag were ever passed by accident - hand
        // tests an in-memory store instead: it's inherently empty and can't touch
        // anything on disk. DEBUG-only so this can never exist in a Release build.
        if ProcessInfo.processInfo.arguments.contains("-TrawlUITestInMemoryStore") {
            do {
                let inMemoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                modelContainer = try ModelContainer(for: schema, configurations: [inMemoryConfiguration])
            } catch {
                fatalError("Failed to initialize in-memory ModelContainer for UI tests: \(error)")
            }

            // The in-memory store covers SwiftData, but not `UserDefaults`, which
            // survives every launch on the simulator. The instance filter lives
            // there and the seeded profiles use fixed UUIDs, so a test that
            // narrows the library to one server leaves every later launch - of
            // every other test - starting with the other server hidden. Cleared
            // here so each UI-test launch begins showing the whole library.
            UserDefaults.standard.removeObject(forKey: ArrInstanceFilterState.defaultsKey)

            Self.seedUITestArrServiceIfRequested(into: modelContainer)
            Self.seedUITestRadarrServiceIfRequested(into: modelContainer)
            Self.seedUITestSABnzbdServiceIfRequested(into: modelContainer)
            Self.seedUITestQBittorrentServiceIfRequested(into: modelContainer)
            Self.seedUITestJellyfinServiceIfRequested(into: modelContainer)
            Self.seedUITestSeerrServiceIfRequested(into: modelContainer)
            Self.seedUITestArrAdminServicesIfRequested(into: modelContainer)
            Self.seedUITestCleanuparrServiceIfRequested(into: modelContainer)
            Self.seedUITestAPNSDeviceTokenIfRequested()

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
                .environment(configurationAuditStore)
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
                // `Form` defaults to the columns style on macOS, which draws a section
                // header as an ordinary row and a field's label beside the field. Every
                // screen written as an iOS grouped form therefore came out with its
                // headings folded into the value column and its labels in a ragged
                // right-aligned strip - Jellyfin's Transcoding screen worst of all.
                // Declared once here because `formStyle` travels through the
                // environment: the alternative was the same line in thirty-odd files,
                // and a thirty-first would have been written without it.
                #if os(macOS)
                .formStyle(.grouped)
                #endif
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        // Settings is a sidebar row like everything else, but a Mac user looks in the
        // menu bar first - and ⌘, is the shortcut they will try without being told.
        // `openSettings` selects the row rather than opening a second window, so
        // there is only ever one Settings on screen.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .trawlOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        #endif
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
    /// stubbed - only the external Sonarr server is faked, which is the whole point.
    ///
    /// A second, optional Sonarr profile can be seeded alongside the first through
    /// `TRAWL_UITEST_SONARR_B_BASE_URL`, for journeys that need two live instances to
    /// present as one blended library (see `ArrBlendedLibraryJourneyUITests`). It is intentionally
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
        // `init()` returns removes both races - and note an earlier attempt to await the
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
        // arrProfiles: [ArrServiceProfile]` in ContentView to return them in - the first
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

    /// Same treatment as `seedUITestArrServiceIfRequested(into:)`, for UI journeys
    /// (`RadarrJourneyUITests`) that need a real Radarr connection rather than a
    /// stubbed one. Sonarr has several journeys already; Radarr - specifically
    /// `RadarrMovieDetailView`, the largest untested view in the project - had none,
    /// which is what this hook exists to fix. `TRAWL_UITEST_RADARR_BASE_URL` points
    /// at `RadarrFixtureServer`, a real loopback HTTP server the test process hosts;
    /// from there `ArrServiceManager.connectService(_:)` and the real
    /// `RadarrAPIClient` run entirely unmodified against it, exactly like the Sonarr
    /// seeding above.
    ///
    /// Entirely additive alongside the Sonarr seeding above - this reads its own
    /// environment variable, seeds its own profile type (`serviceType: .radarr`)
    /// with its own fixed UUID, and leaves the Sonarr seeding path untouched whether
    /// or not this variable is set.
    private static func seedUITestRadarrServiceIfRequested(into modelContainer: ModelContainer) {
        guard let radarrBaseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_RADARR_BASE_URL"],
              !radarrBaseURL.isEmpty else {
            return
        }

        let profile = ArrServiceProfile(
            displayName: "Fixture Radarr",
            hostURL: radarrBaseURL,
            serviceType: .radarr
        )
        // Fixed, hardcoded UUID distinct from the four already in use (Sonarr x2,
        // SABnzbd, qBittorrent) - see the comment on the Sonarr seeding above for why
        // a random UUID would orphan a Keychain entry on every run.
        profile.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000005")!

        // Same synchronous-write requirement as the Sonarr seeding above: both the
        // Keychain write and the SwiftData insert+save must complete before `init()`
        // returns, or ContentView latches onto the welcome screen and/or
        // `connectService` races an empty Keychain read.
        seedUITestKeychainValue("uitest-api-key", forKey: profile.apiKeyKeychainKey)

        let context = ModelContext(modelContainer)
        context.insert(profile)
        do {
            try context.save()
        } catch {
            fatalError("Failed to seed UI test Radarr profile: \(error)")
        }

        // Second Radarr, on the same terms as the second Sonarr above: seeded strictly
        // after the first has committed, so the pair has a stable insertion order and
        // the older profile takes the HD tier.
        if let radarrBBaseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_RADARR_B_BASE_URL"],
           !radarrBBaseURL.isEmpty {
            let profileB = ArrServiceProfile(
                displayName: "Alternate Radarr",
                hostURL: radarrBBaseURL,
                serviceType: .radarr
            )
            profileB.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000006")!

            seedUITestKeychainValue("uitest-api-key", forKey: profileB.apiKeyKeychainKey)

            context.insert(profileB)
            do {
                try context.save()
            } catch {
                fatalError("Failed to seed second UI test Radarr profile: \(error)")
            }
        }
    }

    /// Same treatment as `seedUITestArrServiceIfRequested(into:)`, for the UI journey
    /// in `SABnzbdUnauthorizedJourneyUITests` that needs a real SABnzbd connection
    /// (`Trawl/SABnzbdStack/SABnzbdServiceManager.swift`) rather than a stubbed one.
    /// `TRAWL_UITEST_SABNZBD_BASE_URL` points at `SABnzbdFixtureServer`, a real
    /// loopback HTTP server the test process hosts; from there `SABnzbdServiceManager
    /// .initialize(from:)`, `connectService(_:)`, and the real `SABnzbdAPIClient` run
    /// unmodified against it.
    ///
    /// Entirely additive alongside the Sonarr seeding above - this reads its own
    /// environment variable, seeds its own profile type with its own fixed UUID, and
    /// leaves the Sonarr seeding path untouched whether or not this variable is set.
    private static func seedUITestSABnzbdServiceIfRequested(into modelContainer: ModelContainer) {
        guard let sabnzbdBaseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_SABNZBD_BASE_URL"],
              !sabnzbdBaseURL.isEmpty else {
            return
        }

        let profile = SABnzbdServiceProfile(
            displayName: "Fixture SABnzbd",
            hostURL: sabnzbdBaseURL
        )
        // Fixed, hardcoded UUID distinct from the Sonarr fixtures' - see the comment
        // on that seeding above for why a random UUID would orphan a Keychain entry
        // on every run.
        profile.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000003")!

        // Same synchronous-write requirement as the Sonarr seeding above: both the
        // Keychain write and the SwiftData insert+save must complete before `init()`
        // returns, or ContentView latches onto the welcome screen and/or
        // `connectService` races an empty Keychain read.
        seedUITestKeychainValue("uitest-api-key", forKey: profile.apiKeyKeychainKey)

        let context = ModelContext(modelContainer)
        context.insert(profile)
        do {
            try context.save()
        } catch {
            fatalError("Failed to seed UI test SABnzbd profile: \(error)")
        }
    }

    /// Same treatment as `seedUITestArrServiceIfRequested(into:)` and
    /// `seedUITestSABnzbdServiceIfRequested(into:)`, for UI journeys
    /// (`DownloadsJourneyUITests`) that need a real qBittorrent connection
    /// (`Trawl/Services/QBittorrentAPIClient.swift`, `Trawl/Services/AuthService.swift`)
    /// rather than a stubbed one. `TRAWL_UITEST_QBITTORRENT_BASE_URL` points at
    /// `QBittorrentFixtureServer`, a real loopback HTTP server the test process hosts;
    /// from there `ContentView.initializeServices()`, `QBittorrentClientFactory
    /// .makeAndLogin`, and the real `AuthService`/`QBittorrentAPIClient` run
    /// unmodified against it.
    ///
    /// Unlike the Sonarr/SABnzbd profiles above, `ContentView.initializeServices()`
    /// does not read credentials off the profile itself - it reads them from the
    /// Keychain via `server.usernameKey`/`server.passwordKey` (see
    /// `ContentView.swift`'s `initializeServices()`), which is exactly what gets
    /// seeded here. `ServerProfile.init(displayName:hostURL:allowsUntrustedTLS:)` sets
    /// `isActive = true` itself, so this profile becomes `ContentView.activeServer`
    /// (`servers.first(where: { $0.isActive })`) as soon as it's inserted.
    ///
    /// Entirely additive alongside the Sonarr and SABnzbd seeding above - this reads
    /// its own environment variable, seeds its own profile type with its own fixed
    /// UUID, and leaves the other two seeding paths untouched whether or not this
    /// variable is set.
    private static func seedUITestQBittorrentServiceIfRequested(into modelContainer: ModelContainer) {
        guard let qbittorrentBaseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_QBITTORRENT_BASE_URL"],
              !qbittorrentBaseURL.isEmpty else {
            return
        }

        let profile = ServerProfile(
            displayName: "Fixture qBittorrent",
            hostURL: qbittorrentBaseURL
        )
        // Fixed, hardcoded UUID distinct from the Sonarr and SABnzbd fixtures' - see
        // the comment on the Sonarr seeding above for why a random UUID would orphan
        // a Keychain entry on every run.
        profile.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000004")!

        // Same synchronous-write requirement as the seeding above: both Keychain
        // writes and the SwiftData insert+save must complete before `init()` returns,
        // or ContentView latches onto the welcome screen and/or `initializeServices`
        // races an empty Keychain read.
        seedUITestKeychainValue("uitest-username", forKey: profile.usernameKey)
        seedUITestKeychainValue("uitest-password", forKey: profile.passwordKey)

        let context = ModelContext(modelContainer)
        context.insert(profile)
        do {
            try context.save()
        } catch {
            fatalError("Failed to seed UI test qBittorrent profile: \(error)")
        }
    }

    /// Seeds the real Jellyfin profile/token inputs before ContentView evaluates its
    /// welcome gate. The server itself remains a loopback fixture owned by the UI test;
    /// startup still runs through JellyfinServiceManager and JellyfinAPIClient.
    private static func seedUITestJellyfinServiceIfRequested(into modelContainer: ModelContainer) {
        guard let baseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_JELLYFIN_BASE_URL"],
              !baseURL.isEmpty else { return }

        let profile = JellyfinServiceProfile(
            displayName: "Fixture Jellyfin",
            hostURL: baseURL,
            authMode: .apiKey
        )
        profile.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000006")!
        seedUITestKeychainValue("uitest-api-key", forKey: profile.accessTokenKey)
        insertUITestProfile(profile, into: modelContainer, serviceName: "Jellyfin")
    }

    /// Seeds Seerr's persisted session cookie so its normal authenticated startup can
    /// be exercised without driving the login sheet in every unrelated journey.
    private static func seedUITestSeerrServiceIfRequested(into modelContainer: ModelContainer) {
        guard let baseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_SEERR_BASE_URL"],
              !baseURL.isEmpty else { return }

        let profile = SeerrServiceProfile(displayName: "Fixture Seerr", hostURL: baseURL)
        profile.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000007")!
        seedUITestKeychainValue("uitest-session", forKey: profile.sessionCookieKey)
        insertUITestProfile(profile, into: modelContainer, serviceName: "Seerr")
    }

    /// Prowlarr and Bazarr share ArrServiceProfile and ArrServiceManager, so one helper
    /// handles their independent optional fixture URLs while preserving real routing.
    private static func seedUITestArrAdminServicesIfRequested(into modelContainer: ModelContainer) {
        let fixtures: [(environment: String, name: String, type: ArrServiceType, id: String)] = [
            ("TRAWL_UITEST_PROWLARR_BASE_URL", "Fixture Prowlarr", .prowlarr, "9C6F1B4A-0000-4000-8000-000000000008"),
            ("TRAWL_UITEST_BAZARR_BASE_URL", "Fixture Bazarr", .bazarr, "9C6F1B4A-0000-4000-8000-000000000009"),
            // A second Bazarr, for the journeys that need a pair. Its name
            // deliberately avoids containing "Fixture Bazarr", so a test can match
            // either server unambiguously with `label CONTAINS[c]` - the same reason
            // the second Sonarr is called "Alternate Sonarr".
            ("TRAWL_UITEST_BAZARR_B_BASE_URL", "Alternate Bazarr", .bazarr, "9C6F1B4A-0000-4000-8000-00000000000A")
        ]

        for fixture in fixtures {
            guard let baseURL = ProcessInfo.processInfo.environment[fixture.environment],
                  !baseURL.isEmpty else { continue }
            let profile = ArrServiceProfile(
                displayName: fixture.name,
                hostURL: baseURL,
                serviceType: fixture.type
            )
            profile.id = UUID(uuidString: fixture.id)!
            seedUITestKeychainValue("uitest-api-key", forKey: profile.apiKeyKeychainKey)
            insertUITestProfile(profile, into: modelContainer, serviceName: fixture.type.displayName)
        }
    }

    /// Seeds Cleanuparr's profile and Keychain key for a real manager-to-client launch.
    private static func seedUITestCleanuparrServiceIfRequested(into modelContainer: ModelContainer) {
        guard let baseURL = ProcessInfo.processInfo.environment["TRAWL_UITEST_CLEANUPARR_BASE_URL"],
              !baseURL.isEmpty else { return }

        let profile = CleanuparrServiceProfile(displayName: "Fixture Cleanuparr", hostURL: baseURL)
        profile.id = UUID(uuidString: "9C6F1B4A-0000-4000-8000-000000000010")!
        seedUITestKeychainValue("uitest-api-key", forKey: profile.apiKeyKeychainKey)
        insertUITestProfile(profile, into: modelContainer, serviceName: "Cleanuparr")
    }

    /// Notification configuration normally depends on APNs completing registration,
    /// which is unavailable to the simulator test runner. An explicit UI-test launch
    /// environment marker seeds one fixed, non-production token into the same
    /// Keychain key that `NotificationService.deviceToken` reads. This stays entirely
    /// inside DEBUG, runs before ContentView evaluates, and deliberately does nothing
    /// unless a notification journey asks for it.
    private static func seedUITestAPNSDeviceTokenIfRequested() {
        guard ProcessInfo.processInfo.environment["TRAWL_UITEST_APNS_TOKEN"] == "1" else {
            return
        }

        seedUITestKeychainValue(
            "trawl-ui-test-apns-token-v1",
            forKey: NotificationConstants.apnsTokenKey
        )
    }

    private static func insertUITestProfile<Model: PersistentModel>(
        _ profile: Model,
        into modelContainer: ModelContainer,
        serviceName: String
    ) {
        let context = ModelContext(modelContainer)
        context.insert(profile)
        do {
            try context.save()
        } catch {
            fatalError("Failed to seed UI test \(serviceName) profile: \(error)")
        }
    }

    /// Writes one Keychain item the way `KeychainHelper` would, but synchronously.
    ///
    /// `KeychainHelper` is an actor, so its `save` cannot be called from a synchronous
    /// `init()` without either racing or blocking. The Keychain is external state, so
    /// seeding it directly is legitimate here - the production *read* path
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

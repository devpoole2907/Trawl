#if DEBUG
import SwiftData
import SwiftUI

enum PreviewSupport {
    enum ProfileScenario {
        case empty
        case qBittorrentOnly
        case arrOnly
        case jellyfinOnly
        case seerrOnly
        case allServices
        case custom(@MainActor (ModelContext) -> Void)
    }

    @MainActor
    static func container(_ scenario: ProfileScenario = .allServices) -> ModelContainer {
        let config = ModelConfiguration(schema: TrawlModelSchema.full, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: TrawlModelSchema.full, configurations: [config])
        let context = container.mainContext
        switch scenario {
        case .empty:
            break
        case .qBittorrentOnly:
            context.insert(ServerProfile.preview())
        case .arrOnly:
            context.insert(ArrServiceProfile.preview(.sonarr))
            context.insert(ArrServiceProfile.preview(.radarr))
        case .jellyfinOnly:
            context.insert(JellyfinServiceProfile.preview())
        case .seerrOnly:
            context.insert(SeerrServiceProfile.preview())
        case .allServices:
            context.insert(ServerProfile.preview())
            context.insert(ArrServiceProfile.preview(.sonarr))
            context.insert(ArrServiceProfile.preview(.radarr))
            context.insert(ArrServiceProfile.preview(.prowlarr))
            context.insert(ArrServiceProfile.preview(.bazarr))
            context.insert(JellyfinServiceProfile.preview())
            context.insert(SeerrServiceProfile.preview())
        case .custom(let configure):
            configure(context)
        }
        try? context.save()
        return container
    }
}

/// One-call wrapper: model container + every @Environment Observable manager.
///
/// ```swift
/// #Preview("Connected") {
///     PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
///         NavigationStack { SonarrSeriesListView() }
///     }
/// }
/// ```
struct PreviewHost<Content: View>: View {
    let profiles: PreviewSupport.ProfileScenario
    let arr: ArrServiceManager
    let jellyfin: JellyfinServiceManager
    let seerr: SeerrServiceManager
    let sync: SyncService
    let torrent: TorrentService
    let appServices: AppServices
    let appLockController: AppLockController
    let notificationCenter: InAppNotificationCenter
    let content: () -> Content

    init(
        profiles: PreviewSupport.ProfileScenario = .allServices,
        arr: ArrServiceManager = .preview(),
        jellyfin: JellyfinServiceManager = .preview(),
        seerr: SeerrServiceManager = .preview(),
        sync: SyncService = .preview(),
        torrent: TorrentService = .preview(),
        appServices: AppServices? = nil,
        appLockController: AppLockController = AppLockController(),
        notificationCenter: InAppNotificationCenter = .shared,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.profiles = profiles
        self.arr = arr
        self.jellyfin = jellyfin
        self.seerr = seerr
        self.sync = sync
        self.torrent = torrent
        self.appLockController = appLockController
        self.notificationCenter = notificationCenter
        if let appServices {
            self.appServices = appServices
        } else {
            let authService = AuthService(serverProfileID: UUID())
            let apiClient = QBittorrentAPIClient(
                baseURL: "http://preview.invalid",
                authService: authService
            )
            self.appServices = AppServices(
                authService: authService,
                apiClient: apiClient,
                torrentService: torrent,
                syncService: sync
            )
        }
        self.content = content
    }

    var body: some View {
        content()
            .environment(arr)
            .environment(jellyfin)
            .environment(seerr)
            .environment(sync)
            .environment(torrent)
            .environment(appServices)
            .environment(appLockController)
            .environment(notificationCenter)
            .modelContainer(PreviewSupport.container(profiles))
    }
}
#endif

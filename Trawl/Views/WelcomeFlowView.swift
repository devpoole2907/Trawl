import SwiftUI

enum WelcomeStep: Hashable {
    case services
}

enum SetupTarget: Identifiable {
    case qbittorrent
    case sonarr
    case radarr
    case prowlarr
    case bazarr
    case seerr
    case jellyfin

    var id: String {
        switch self {
        case .qbittorrent: "qbittorrent"
        case .sonarr: "sonarr"
        case .radarr: "radarr"
        case .prowlarr: "prowlarr"
        case .bazarr: "bazarr"
        case .seerr: "seerr"
        case .jellyfin: "jellyfin"
        }
    }
}

struct WelcomeServicesState {
    var qbittorrent: Bool
    var sonarr: Bool
    var radarr: Bool
    var prowlarr: Bool
    var bazarr: Bool
    var seerr: Bool
    var jellyfin: Bool

    var hasAny: Bool {
        qbittorrent || sonarr || radarr || prowlarr || bazarr || seerr || jellyfin
    }
}

struct WelcomeFlowView: View {
    @Binding var isInWelcomeFlow: Bool
    @Binding var setupTarget: SetupTarget?
    let configuredServices: WelcomeServicesState

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var welcomePath: [WelcomeStep] = []

    var body: some View {
        NavigationStack(path: $welcomePath) {
            introScreen
                .navigationDestination(for: WelcomeStep.self) { step in
                    switch step {
                    case .services:
                        serviceSelectionScreen
                    }
                }
        }
    }

    private var introScreen: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Welcome to Trawl")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Your home for torrents, TV, and movies.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                featureRow(icon: ServiceIdentity.qbittorrent.systemImage, color: ServiceIdentity.qbittorrent.brandColor,
                           title: "qBittorrent", description: "Manage and monitor your downloads")
                featureRow(icon: ServiceIdentity.sonarr.systemImage, color: ServiceIdentity.sonarr.brandColor,
                           title: "Sonarr", description: "Track and automate your TV series")
                featureRow(icon: ServiceIdentity.radarr.systemImage, color: ServiceIdentity.radarr.brandColor,
                           title: "Radarr", description: "Discover and collect movies")
                featureRow(icon: ServiceIdentity.prowlarr.systemImage, color: ServiceIdentity.prowlarr.brandColor,
                           title: "Prowlarr", description: "Manage and search your indexers")
                featureRow(icon: ServiceIdentity.bazarr.systemImage, color: ServiceIdentity.bazarr.brandColor,
                           title: "Bazarr", description: "Manage subtitles for series and movies")
                featureRow(icon: ServiceIdentity.seerr.systemImage, color: ServiceIdentity.seerr.brandColor,
                           title: "Seerr", description: "Manage requests and users")
            }
            .padding(.horizontal, 8)
        }
        .padding(32)
        .frame(maxWidth: hSizeClass == .regular ? 600 : 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .prominentBottomButton("Get Started") {
            welcomePath.append(.services)
        }
    }

    private var serviceSelectionScreen: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Text("Choose Your Services")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text("Set up the services you want to use, then continue into the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    setupRow(icon: ServiceIdentity.qbittorrent.systemImage, color: ServiceIdentity.qbittorrent.brandColor,
                             title: "qBittorrent", description: "Manage and monitor your downloads",
                             isConfigured: configuredServices.qbittorrent) { setupTarget = .qbittorrent }

                    setupRow(icon: ServiceIdentity.sonarr.systemImage, color: ServiceIdentity.sonarr.brandColor,
                             title: "Sonarr", description: "Track and automate your TV series",
                             isConfigured: configuredServices.sonarr) { setupTarget = .sonarr }

                    setupRow(icon: ServiceIdentity.radarr.systemImage, color: ServiceIdentity.radarr.brandColor,
                             title: "Radarr", description: "Discover and collect your movies",
                             isConfigured: configuredServices.radarr) { setupTarget = .radarr }

                    setupRow(icon: ServiceIdentity.prowlarr.systemImage, color: ServiceIdentity.prowlarr.brandColor,
                             title: "Prowlarr", description: "Manage and search your indexers",
                             isConfigured: configuredServices.prowlarr) { setupTarget = .prowlarr }

                    setupRow(icon: ServiceIdentity.bazarr.systemImage, color: ServiceIdentity.bazarr.brandColor,
                             title: "Bazarr", description: "Manage subtitles for series and movies",
                             isConfigured: configuredServices.bazarr) { setupTarget = .bazarr }

                    setupRow(icon: ServiceIdentity.seerr.systemImage, color: ServiceIdentity.seerr.brandColor,
                             title: "Seerr", description: "Manage requests and user access",
                             isConfigured: configuredServices.seerr) { setupTarget = .seerr }

                    setupRow(icon: ServiceIdentity.jellyfin.systemImage, color: ServiceIdentity.jellyfin.brandColor,
                             title: "Jellyfin", description: "Manage users, libraries, and server activity",
                             isConfigured: configuredServices.jellyfin) { setupTarget = .jellyfin }
                }
            }
            .padding(32)
            .frame(maxWidth: hSizeClass == .regular ? 600 : 440)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .prominentBottomButton("Go", isDisabled: !configuredServices.hasAny) {
            withAnimation { isInWelcomeFlow = false }
        }
        .navigationTitle("Choose Services")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setupRow(
        icon: String,
        color: Color,
        title: String,
        description: String,
        isConfigured: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isConfigured ? Color.green : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

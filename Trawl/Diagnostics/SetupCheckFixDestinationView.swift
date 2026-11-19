//
//  SetupCheckFixDestinationView.swift
//  Trawl
//
//  The real management screen a Setup Check finding is fixed on.
//

import SwiftUI

/// The screen where a finding gets fixed, pushed onto whatever stack the finding is
/// showing in.
///
/// Every fix pushes the real management screen rather than reimplementing it: the
/// change happens in the same place the user would have found on their own, which is
/// what makes it stick after they leave the Setup Check. There used to be two copies
/// of this switch, one in the phone wizard and one in the split-view detail pane, and
/// nothing kept them from drifting.
struct SetupCheckFixDestinationView: View {
    let destination: ConfigurationFixDestination

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager: SeerrServiceManager?
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?

    var body: some View {
        switch destination {
        case .downloadClientsManagement:
            ArrDownloadClientListView(serviceType: .sonarr)
                .environment(serviceManager)
        case .arrDownloadClients(let serviceType, let instanceID):
            ArrDownloadClientListView(serviceType: serviceType, initialInstanceID: instanceID)
                .environment(serviceManager)
        case .rootFolders(let instanceID):
            ArrRootFoldersView(initialInstanceID: instanceID)
                .environment(serviceManager)
        case .prowlarrIndexers:
            ProwlarrIndexerListView()
                .environment(serviceManager)
        case .prowlarrApplications:
            ProwlarrApplicationsListView()
                .environment(serviceManager)
        case .bazarrLinkedApplications(let instanceID):
            BazarrLinkedApplicationsListView(initialInstanceID: instanceID)
                .environment(serviceManager)
        case .bazarrLanguageProfiles:
            BazarrLanguageProfilesView()
                .environment(serviceManager)
        case .bazarrProviders:
            BazarrProvidersView()
                .environment(serviceManager)
        case .serviceSettings(let serviceType, let instanceID):
            ArrServiceSettingsView(serviceType: serviceType, initialProfileID: instanceID)
                .environment(serviceManager)
        case .arrRemotePathMappings:
            ArrRemotePathMappingListView()
                .environment(serviceManager)
        case .arrHealth:
            ArrHealthView()
                .environment(serviceManager)
        case .seerrLinkedApplications:
            if let client = seerrServiceManager?.activeClient {
                SeerrLinkedApplicationsView(apiClient: client)
            } else {
                // Shown rather than hidden: the finding is real, and a button that
                // opens a blank screen teaches people the check is broken rather than
                // that their service is.
                ServiceErrorView(
                    title: "Seerr is not connected",
                    message: "Reconnect Seerr from Settings, then run the setup check again.",
                    systemImage: "network.slash"
                )
            }
        case .cleanuparr:
            CleanuparrDashboardView()
        case .sabnzbdCategories:
            if let sabnzbdServiceManager {
                SABnzbdCategoriesView()
                    .environment(sabnzbdServiceManager)
            } else {
                ServiceErrorView(
                    title: "SABnzbd is not connected",
                    message: "Reconnect SABnzbd from Settings, then run the setup check again.",
                    systemImage: "network.slash"
                )
            }
        }
    }
}

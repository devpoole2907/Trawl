#if DEBUG
import Foundation

extension ProwlarrIndexer {
    static let preview = ProwlarrIndexer.makePreview()
    static let previewDisabled = ProwlarrIndexer.makePreview(
        id: 2,
        name: "RARBG Archive",
        enable: false,
        shouldSearch: false,
        supportsRss: false
    )
    static let previewUsenet = ProwlarrIndexer.makePreview(
        id: 3,
        name: "NZBgeek",
        implementation: "Newznab",
        implementationName: "NZBgeek",
        configContract: "NewznabSettings",
        protocol: .usenet
    )
    static let previewLongName = ProwlarrIndexer.makePreview(
        id: 4,
        name: "Very Long Private Tracker Name With Regional Freeleech Rules And Scene Releases"
    )
    static let previewMissingMetadata = ProwlarrIndexer.makePreview(
        id: 5,
        name: nil,
        implementationName: nil,
        supportsRss: nil,
        supportsSearch: nil,
        protocol: nil,
        fields: nil
    )

    static let previewList: [ProwlarrIndexer] = [
        preview,
        previewDisabled,
        previewUsenet,
        previewLongName,
        .makePreview(id: 6, name: "TorrentLeech", priority: 10),
    ]

    static let previewHeavyList: [ProwlarrIndexer] = (1...36).map { index in
        .makePreview(
            id: 100 + index,
            name: index.isMultiple(of: 7) ? "Very Long Tracker Name \(index) With Multiple Release Groups" : "Indexer \(index)",
            enable: !index.isMultiple(of: 5),
            implementation: index.isMultiple(of: 3) ? "Newznab" : "Cardigann",
            implementationName: index.isMultiple(of: 3) ? "Usenet \(index)" : "Tracker \(index)",
            configContract: index.isMultiple(of: 3) ? "NewznabSettings" : "CardigannSettings",
            priority: index % 50 + 1,
            protocol: index.isMultiple(of: 3) ? .usenet : .torrent,
            fields: index.isMultiple(of: 4) ? nil : ProwlarrIndexerField.previewConfiguration
        )
    }

    static let previewSchema = ProwlarrIndexer.makePreview(
        id: 0,
        name: "Torznab",
        enable: false,
        implementation: "Torznab",
        implementationName: "Torznab",
        configContract: "TorznabSettings",
        shouldSearch: nil,
        protocol: .torrent,
        fields: ProwlarrIndexerField.previewConfiguration
    )
    static let previewUsenetSchema = ProwlarrIndexer.makePreview(
        id: 0,
        name: "Newznab",
        enable: false,
        implementation: "Newznab",
        implementationName: "Newznab",
        configContract: "NewznabSettings",
        shouldSearch: nil,
        protocol: .usenet,
        fields: ProwlarrIndexerField.previewConfiguration
    )
    static let previewSchemaList: [ProwlarrIndexer] = [
        previewSchema,
        previewUsenetSchema,
        .makePreview(id: 0, name: "Cardigann", implementationName: "Cardigann", fields: ProwlarrIndexerField.previewConfiguration),
    ]

    fileprivate static func makePreview(
        id: Int = 1,
        name: String? = "1337x",
        enable: Bool = true,
        implementation: String? = "Cardigann",
        implementationName: String? = "1337x",
        configContract: String? = "CardigannSettings",
        infoLink: String? = "https://wiki.servarr.com/prowlarr",
        tags: [Int]? = [1],
        priority: Int? = 25,
        appProfileId: Int? = nil,
        shouldSearch: Bool? = true,
        supportsRss: Bool? = true,
        supportsSearch: Bool? = true,
        protocol: ProwlarrIndexerProtocol? = .torrent,
        fields: [ProwlarrIndexerField]? = ProwlarrIndexerField.previewConfiguration
    ) -> ProwlarrIndexer {
        ProwlarrIndexer(
            id: id,
            name: name,
            enable: enable,
            implementation: implementation,
            implementationName: implementationName,
            configContract: configContract,
            infoLink: infoLink,
            tags: tags,
            priority: priority,
            appProfileId: appProfileId,
            shouldSearch: shouldSearch,
            supportsRss: supportsRss,
            supportsSearch: supportsSearch,
            protocol: `protocol`,
            fields: fields
        )
    }
}

extension ProwlarrIndexerField {
    static let preview = ProwlarrIndexerField(
        name: "baseUrl",
        label: "Base URL",
        value: .string("https://tracker.example"),
        type: "textbox",
        advanced: false,
        hidden: nil,
        selectOptions: nil
    )

    static let previewConfiguration: [ProwlarrIndexerField] = [
        .init(name: "baseUrl", label: "Base URL", value: .string("https://tracker.example"), type: "textbox", advanced: false, hidden: nil, selectOptions: nil),
        .init(name: "apiKey", label: "API Key", value: .string("preview-api-key"), type: "password", advanced: false, hidden: nil, selectOptions: nil),
        .init(name: "minimumSeeders", label: "Minimum Seeders", value: .int(10), type: "number", advanced: false, hidden: nil, selectOptions: nil),
        .init(name: "freeleechOnly", label: "Freeleech Only", value: .bool(false), type: "checkbox", advanced: false, hidden: nil, selectOptions: nil),
        .init(name: "category", label: "Category", value: .int(2000), type: "select", advanced: false, hidden: nil, selectOptions: ProwlarrSelectOption.previewList),
        .init(name: "requestDelay", label: "Request Delay", value: .int(2), type: "number", advanced: true, hidden: nil, selectOptions: nil),
        .init(name: "notes", label: nil, value: .string("Use a Torznab-compatible URL from the tracker profile."), type: "info", advanced: false, hidden: nil, selectOptions: nil),
    ]
}

extension ProwlarrSelectOption {
    static let preview = ProwlarrSelectOption(name: "Movies", value: .int(2000), order: 1, hint: nil)
    static let previewList: [ProwlarrSelectOption] = [
        preview,
        .init(name: "TV", value: .int(5000), order: 2, hint: nil),
        .init(name: "Audio", value: .int(3000), order: 3, hint: nil),
    ]
}

extension ProwlarrIndexerStatus {
    static let previewDisabled = ProwlarrIndexerStatus.makePreview(indexerId: ProwlarrIndexer.previewDisabled.id)
    static let previewList: [ProwlarrIndexerStatus] = [previewDisabled]

    fileprivate static func makePreview(indexerId: Int, disabledTill: String = "2099-01-01T00:00:00Z") -> ProwlarrIndexerStatus {
        let json: [String: Any] = [
            "id": indexerId,
            "indexerId": indexerId,
            "disabledTill": disabledTill,
            "lastRssSyncReleaseDate": "2026-05-24T10:00:00Z",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(ProwlarrIndexerStatus.self, from: data)
    }
}

extension ProwlarrIndexerStats {
    static let preview = ProwlarrIndexerStats(indexers: ProwlarrIndexerStatEntry.previewList)
    static let previewHeavy = ProwlarrIndexerStats(
        indexers: ProwlarrIndexer.previewHeavyList.map {
            ProwlarrIndexerStatEntry.makePreview(indexerId: $0.id, indexerName: $0.name ?? "Indexer")
        }
    )
}

extension ProwlarrIndexerStatEntry {
    static let preview = ProwlarrIndexerStatEntry.makePreview()
    static let previewList: [ProwlarrIndexerStatEntry] = [
        preview,
        .makePreview(indexerId: ProwlarrIndexer.previewDisabled.id, indexerName: ProwlarrIndexer.previewDisabled.name ?? "RARBG Archive", failedQueries: 12),
        .makePreview(indexerId: ProwlarrIndexer.previewUsenet.id, indexerName: ProwlarrIndexer.previewUsenet.name ?? "NZBgeek", queries: 890, grabs: 32),
    ]

    static func makePreview(
        indexerId: Int = ProwlarrIndexer.preview.id,
        indexerName: String = ProwlarrIndexer.preview.name ?? "1337x",
        averageResponseTime: Double = 426,
        queries: Int = 1_284,
        grabs: Int = 48,
        failedQueries: Int = 3
    ) -> ProwlarrIndexerStatEntry {
        ProwlarrIndexerStatEntry(
            indexerId: indexerId,
            indexerName: indexerName,
            averageResponseTime: averageResponseTime,
            numberOfQueries: queries,
            numberOfGrabs: grabs,
            numberOfRssQueries: queries / 2,
            numberOfAuthQueries: 0,
            numberOfFailedQueries: failedQueries,
            numberOfFailedGrabs: failedQueries / 2,
            numberOfFailedRssQueries: failedQueries / 2,
            numberOfFailedAuthQueries: 0
        )
    }
}

extension ProwlarrApplication {
    static let previewSonarr = ProwlarrApplication.makePreview(.sonarr)
    static let previewRadarr = ProwlarrApplication.makePreview(.radarr, id: 2, name: "Radarr 4K")
    static let previewDisabled = ProwlarrApplication.makePreview(.sonarr, id: 3, name: "Sonarr Archive", syncLevel: .disabled)
    static let previewLongName = ProwlarrApplication.makePreview(
        .radarr,
        id: 4,
        name: "Very Long Radarr Application Name For A Remote UHD Library"
    )

    static let previewList: [ProwlarrApplication] = [
        previewSonarr,
        previewRadarr,
        previewDisabled,
    ]

    static let previewSchemaList: [ProwlarrApplication] = [
        previewSchema(.sonarr),
        previewSchema(.radarr),
    ]

    static func previewSchema(_ type: ProwlarrLinkedAppType) -> ProwlarrApplication {
        makePreview(type, id: 0, name: type.displayName, fields: ProwlarrApplicationField.previewConnectionFields(for: type))
    }

    fileprivate static func makePreview(
        _ type: ProwlarrLinkedAppType,
        id: Int = 1,
        name: String? = nil,
        fields: [ProwlarrApplicationField]? = nil,
        tags: [Int]? = [1],
        syncLevel: ProwlarrApplicationSyncLevel? = .fullSync
    ) -> ProwlarrApplication {
        ProwlarrApplication(
            id: id,
            name: name ?? type.displayName,
            fields: fields ?? ProwlarrApplicationField.previewConnectionFields(for: type),
            implementationName: type.implementationName,
            implementation: type.implementationName,
            configContract: type.configContract,
            infoLink: "https://wiki.servarr.com/prowlarr/settings",
            message: nil,
            tags: tags,
            presets: nil,
            syncLevel: syncLevel,
            testCommand: nil
        )
    }
}

extension ProwlarrApplicationField {
    static let preview = ProwlarrApplicationField(
        name: "baseUrl",
        label: "Base URL",
        value: .string("http://192.168.1.50:8989"),
        type: "textbox",
        advanced: false,
        hidden: nil,
        selectOptions: nil
    )

    static func previewConnectionFields(for type: ProwlarrLinkedAppType) -> [ProwlarrApplicationField] {
        let baseURL = switch type {
        case .sonarr:
            "http://192.168.1.50:8989"
        case .radarr:
            "http://192.168.1.51:7878"
        }

        return [
            .init(name: "prowlarrUrl", label: "Prowlarr URL", value: .string("http://192.168.1.52:9696"), type: "textbox", advanced: false, hidden: nil, selectOptions: nil),
            .init(name: "baseUrl", label: "Base URL", value: .string(baseURL), type: "textbox", advanced: false, hidden: nil, selectOptions: nil),
            .init(name: "apiKey", label: "API Key", value: .string("preview-api-key"), type: "password", advanced: false, hidden: nil, selectOptions: nil),
            .init(name: "syncCategories", label: "Sync Categories", value: .bool(true), type: "checkbox", advanced: true, hidden: nil, selectOptions: nil),
        ]
    }
}

extension ProwlarrApplicationSelectOption {
    static let preview = ProwlarrApplicationSelectOption(name: "Full Sync", value: .string("fullSync"), order: 1, hint: nil)
    static let previewList: [ProwlarrApplicationSelectOption] = [
        preview,
        .init(name: "Add Only", value: .string("addOnly"), order: 2, hint: nil),
    ]
}

extension ArrManagedIndexer {
    static let preview = ArrManagedIndexer.makePreview()
    static let previewDisabled = ArrManagedIndexer.makePreview(
        id: 2,
        name: "Disabled Direct Tracker",
        enableRss: false,
        enableAutomaticSearch: false,
        enableInteractiveSearch: false
    )
    static let previewUsenet = ArrManagedIndexer.makePreview(
        id: 3,
        name: "Direct NZB",
        implementationName: "Newznab",
        implementation: "Newznab",
        configContract: "NewznabSettings",
        protocol: .usenet
    )
    static let previewProwlarrMirror = ArrManagedIndexer.makePreview(
        id: 4,
        name: "1337x (Prowlarr)",
        fields: [
            .init(
                order: 0,
                name: "baseUrl",
                label: "Base URL",
                unit: nil,
                helpText: nil,
                helpTextWarning: nil,
                helpLink: nil,
                value: .string("http://192.168.1.52:9696/1/api"),
                type: "textbox",
                advanced: false,
                selectOptions: nil,
                selectOptionsProviderAction: nil,
                section: nil,
                hidden: nil,
                placeholder: nil,
                isFloat: nil
            ),
        ]
    )

    static let previewList: [ArrManagedIndexer] = [
        preview,
        previewDisabled,
        previewUsenet,
    ]

    static let previewSchema = ArrManagedIndexer.makePreview(
        id: 0,
        name: "Torznab",
        implementationName: "Torznab",
        implementation: "Torznab",
        configContract: "TorznabSettings"
    )
    static let previewSchemaList: [ArrManagedIndexer] = [
        previewSchema,
        .makePreview(id: 0, name: "Newznab", implementationName: "Newznab", implementation: "Newznab", configContract: "NewznabSettings", protocol: .usenet),
    ]

    fileprivate static func makePreview(
        id: Int = 1,
        name: String? = "Direct 1337x",
        fields: [ArrIndexerField]? = ArrIndexerField.previewConfiguration,
        implementationName: String? = "Torznab",
        implementation: String? = "Torznab",
        configContract: String? = "TorznabSettings",
        infoLink: String? = "https://wiki.servarr.com",
        message: ArrProviderMessage? = nil,
        tags: [Int]? = [1],
        presets: [ArrManagedIndexer]? = nil,
        enableRss: Bool = true,
        enableAutomaticSearch: Bool = true,
        enableInteractiveSearch: Bool = true,
        supportsRss: Bool? = true,
        supportsSearch: Bool? = true,
        protocol: ArrIndexerProtocol? = .torrent,
        priority: Int? = 25,
        seasonSearchMaximumSingleEpisodeAge: Int? = nil,
        downloadClientId: Int? = nil
    ) -> ArrManagedIndexer {
        ArrManagedIndexer(
            id: id,
            name: name,
            fields: fields,
            implementationName: implementationName,
            implementation: implementation,
            configContract: configContract,
            infoLink: infoLink,
            message: message,
            tags: tags,
            presets: presets,
            enableRss: enableRss,
            enableAutomaticSearch: enableAutomaticSearch,
            enableInteractiveSearch: enableInteractiveSearch,
            supportsRss: supportsRss,
            supportsSearch: supportsSearch,
            protocol: `protocol`,
            priority: priority,
            seasonSearchMaximumSingleEpisodeAge: seasonSearchMaximumSingleEpisodeAge,
            downloadClientId: downloadClientId
        )
    }
}

extension ArrIndexerField {
    static let preview = ArrIndexerField(
        order: 0,
        name: "baseUrl",
        label: "Base URL",
        unit: nil,
        helpText: "Torznab URL for the indexer.",
        helpTextWarning: nil,
        helpLink: nil,
        value: .string("https://tracker.example/api"),
        type: "textbox",
        advanced: false,
        selectOptions: nil,
        selectOptionsProviderAction: nil,
        section: nil,
        hidden: nil,
        placeholder: nil,
        isFloat: nil
    )

    static let previewConfiguration: [ArrIndexerField] = [
        preview,
        .init(
            order: 1,
            name: "apiKey",
            label: "API Key",
            unit: nil,
            helpText: nil,
            helpTextWarning: nil,
            helpLink: nil,
            value: .string("preview-api-key"),
            type: "password",
            advanced: false,
            selectOptions: nil,
            selectOptionsProviderAction: nil,
            section: nil,
            hidden: nil,
            placeholder: nil,
            isFloat: nil
        ),
        .init(
            order: 2,
            name: "minimumSeeders",
            label: "Minimum Seeders",
            unit: nil,
            helpText: nil,
            helpTextWarning: nil,
            helpLink: nil,
            value: .int(10),
            type: "number",
            advanced: false,
            selectOptions: nil,
            selectOptionsProviderAction: nil,
            section: nil,
            hidden: nil,
            placeholder: nil,
            isFloat: nil
        ),
        .init(
            order: 3,
            name: "category",
            label: "Category",
            unit: nil,
            helpText: nil,
            helpTextWarning: nil,
            helpLink: nil,
            value: .int(5000),
            type: "select",
            advanced: false,
            selectOptions: ArrIndexerSelectOption.previewList,
            selectOptionsProviderAction: nil,
            section: nil,
            hidden: nil,
            placeholder: nil,
            isFloat: nil
        ),
    ]
}

extension ArrIndexerSelectOption {
    static let preview = ArrIndexerSelectOption(value: 5000, name: "TV", order: 1, hint: nil)
    static let previewList: [ArrIndexerSelectOption] = [
        preview,
        .init(value: 2000, name: "Movies", order: 2, hint: nil),
        .init(value: 3000, name: "Audio", order: 3, hint: nil),
    ]
}
#endif

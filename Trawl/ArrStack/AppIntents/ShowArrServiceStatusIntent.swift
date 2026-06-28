import AppIntents
import Foundation

/// Reports version and health for configured *arr services. Read-only.
/// If no service is chosen, all configured Radarr/Sonarr/Prowlarr services are checked.
struct ShowArrServiceStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Service Status"
    static let description = IntentDescription(
        "Check the version and health of your Radarr, Sonarr and Prowlarr services.",
        categoryName: "Status"
    )

    @Parameter(title: "Service")
    var service: ArrServiceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Check service status") {
            \.$service
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services: [ArrServiceSnapshot]
        if let service {
            services = [try await ArrIntentSupport.resolveService(preferred: service, ofTypes: Set(ArrServiceType.allCases))]
        } else {
            services = try await ArrIntentSupport.loadServices(ofTypes: [.radarr, .sonarr, .prowlarr])
            guard !services.isEmpty else {
                throw ArrIntentError.noServiceConfigured("service")
            }
        }

        var lines: [String] = []
        for snapshot in services {
            lines.append(await statusLine(for: snapshot))
        }
        let summary = lines.joined(separator: " ")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }

    private func statusLine(for service: ArrServiceSnapshot) async -> String {
        do {
            let (version, warnings, errors) = try await fetchStatus(for: service)
            var line = "\(service.displayName)"
            if let version { line += " \(version)" }
            if warnings == 0 && errors == 0 {
                line += " is healthy."
            } else {
                var issues: [String] = []
                if errors > 0 { issues.append("\(errors) error\(errors == 1 ? "" : "s")") }
                if warnings > 0 { issues.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
                line += " has \(issues.joined(separator: " and "))."
            }
            return line
        } catch {
            return "\(service.displayName) is unreachable."
        }
    }

    private func fetchStatus(for service: ArrServiceSnapshot) async throws -> (version: String?, warnings: Int, errors: Int) {
        func summarize(_ status: ArrSystemStatus, _ health: [ArrHealthCheck]) -> (String?, Int, Int) {
            let warnings = health.filter { ($0.type ?? "").lowercased() == "warning" }.count
            let errors = health.filter { ($0.type ?? "").lowercased() == "error" }.count
            return (status.version, warnings, errors)
        }

        switch service.serviceType {
        case .radarr:
            let client = try await ArrIntentSupport.makeRadarrClient(service)
            return summarize(try await client.getSystemStatus(), try await client.getHealth())
        case .sonarr:
            let client = try await ArrIntentSupport.makeSonarrClient(service)
            return summarize(try await client.getSystemStatus(), try await client.getHealth())
        case .prowlarr:
            let client = try await ArrIntentSupport.makeProwlarrClient(service)
            return summarize(try await client.getSystemStatus(), try await client.getHealth())
        case .bazarr:
            throw ArrIntentError.unsupportedServiceType
        }
    }
}

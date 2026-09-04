import Foundation

/// Trawl knowing about a download client and Sonarr/Radarr knowing about the same
/// client are completely independent facts. Nothing in either app reconciles them, so
/// a user can finish setup in Trawl, see a healthy SABnzbd queue, and still have every
/// Arr grab fail with "no download client available" - silently, from Trawl's side.
///
/// This walks each connected Arr and reports whether it is actually pointed at the
/// client Trawl is talking to.
enum DownloadClientLinkKind: String, Hashable, Sendable {
    case qbittorrent
    case sabnzbd

    /// Matches the `implementation` value Sonarr/Radarr report for this client.
    var arrImplementation: String {
        switch self {
        case .qbittorrent: "QBittorrent"
        case .sabnzbd: "Sabnzbd"
        }
    }

    var displayName: String {
        switch self {
        case .qbittorrent: "qBittorrent"
        case .sabnzbd: "SABnzbd"
        }
    }
}

enum DownloadClientLinkState: Hashable, Sendable {
    /// The Arr has an enabled client of this kind whose host matches Trawl's profile.
    case linked
    /// The Arr has no enabled client of this kind at all. Unambiguous: grabs of this
    /// protocol cannot reach the client Trawl is showing.
    case missing
    /// The Arr has one, but it points somewhere else. Often *correct* - a Docker
    /// hostname and a LAN IP can be the same box - so this is reported as a note
    /// rather than a fault.
    case differentHost(String)
}

struct DownloadClientLink: Identifiable, Hashable, Sendable {
    let service: ArrServiceType
    let kind: DownloadClientLinkKind
    let state: DownloadClientLinkState

    var id: String { "\(service.rawValue)-\(kind.rawValue)" }

    var isProblem: Bool {
        if case .missing = state { return true }
        return false
    }

    var isNote: Bool {
        if case .differentHost = state { return true }
        return false
    }
}

enum DownloadClientLinkChecker {
    /// Only Sonarr and Radarr own download clients; Prowlarr and Bazarr don't.
    private static let checkedServices: [ArrServiceType] = [.sonarr, .radarr]

    @MainActor
    static func check(
        kinds: [DownloadClientLinkKind: String],
        serviceManager: ArrServiceManager
    ) async -> [DownloadClientLink] {
        guard !kinds.isEmpty else { return [] }

        var links: [DownloadClientLink] = []

        for service in checkedServices {
            guard let clients = await downloadClients(for: service, serviceManager: serviceManager) else {
                // Not configured, not connected, or the request failed. Staying silent
                // beats claiming a link is broken when we simply couldn't look.
                continue
            }

            for (kind, trawlHostURL) in kinds.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let matches = clients.filter {
                    $0.enable && $0.implementation?.caseInsensitiveCompare(kind.arrImplementation) == .orderedSame
                }

                guard !matches.isEmpty else {
                    links.append(DownloadClientLink(service: service, kind: kind, state: .missing))
                    continue
                }

                let trawlHost = normalizedHost(from: trawlHostURL)
                let hostMatched = matches.contains { client in
                    guard let host = client.hostDisplayValue, !host.isEmpty else { return false }
                    return normalizedHost(from: host) == trawlHost
                }

                if hostMatched {
                    links.append(DownloadClientLink(service: service, kind: kind, state: .linked))
                } else {
                    let other = matches.compactMap(\.hostDisplayValue).first { !$0.isEmpty } ?? "another host"
                    links.append(DownloadClientLink(service: service, kind: kind, state: .differentHost(other)))
                }
            }
        }

        return links
    }

    @MainActor
    private static func downloadClients(
        for service: ArrServiceType,
        serviceManager: ArrServiceManager
    ) async -> [ArrDownloadClient]? {
        switch service {
        case .sonarr, .radarr:
            break
        case .prowlarr, .bazarr:
            return nil
        }

        // Every server of this service, unioned. A download client attached only to
        // the 4K server is still linked - asking the active server alone reports it
        // as unlinked and sends the user looking for a problem that isn't there.
        let instances = serviceManager.visibleArrInstances.filter { $0.ref.serviceType == service }
        guard !instances.isEmpty else { return nil }

        var clients: [ArrDownloadClient] = []
        var reachedAny = false
        for (_, client) in instances {
            guard let fetched = try? await client.getDownloadClients() else { continue }
            reachedAny = true
            clients += fetched
        }
        // Nil means "could not tell", which suppresses the warning. An empty array
        // means "asked, and there are none" - a real answer, and a different one.
        return reachedAny ? clients : nil
    }

    /// Reduces a host to something comparable across the two ways it gets written.
    /// Trawl stores a full URL ("http://10.0.0.5:8080"); the Arr stores a bare host
    /// ("10.0.0.5"). Loopback spellings are folded together so a same-machine setup
    /// isn't flagged just because one side says "localhost" and the other "127.0.0.1".
    static func normalizedHost(from value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]", "host.docker.internal"].contains(host) {
            return "localhost"
        }

        if let components = URLComponents(string: host), let urlHost = components.host {
            host = urlHost.lowercased()
        } else if !host.contains("://"),
                  let components = URLComponents(string: "http://\(host)"),
                  let urlHost = components.host {
            host = urlHost.lowercased()
        } else {
            // Not parseable as a URL - strip a scheme, then any port/path by hand.
            if let schemeRange = host.range(of: "://") {
                host = String(host[schemeRange.upperBound...])
            }
            host = host.split(separator: "/").first.map(String.init) ?? host
            host = host.split(separator: ":").first.map(String.init) ?? host
        }

        if ["localhost", "127.0.0.1", "0.0.0.0", "::1", "host.docker.internal"].contains(host) {
            return "localhost"
        }

        return host
    }

    /// Host and port identity for one concrete download-client endpoint. Sonarr and
    /// Radarr store these as separate fields while Trawl stores a full URL; comparing
    /// only the host makes two qBittorrent containers on different ports look like
    /// the same client.
    static func normalizedEndpoint(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: candidate), let host = components.host else {
            return "\(normalizedHost(from: value)):?"
        }
        let port = components.port ?? defaultPort(for: components.scheme)
        return normalizedEndpoint(host: host, port: port.map(String.init))
    }

    static func normalizedEndpoint(host: String, port: String?) -> String {
        let normalizedPort = port?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
            .first
            .map(String.init)
        return "\(normalizedHost(from: host)):\(normalizedPort.flatMap { $0.isEmpty ? nil : $0 } ?? "?")"
    }

    static func displayEndpoint(host: String, port: String?) -> String {
        guard let port = port?.trimmingCharacters(in: .whitespacesAndNewlines), !port.isEmpty else {
            return host
        }
        return "\(host):\(port)"
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}

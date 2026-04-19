import ActivityKit
import SwiftUI
import WidgetKit

struct SSHSessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String
        var statusText: String
    }

    var profileID: String
    var hostDisplay: String
}

struct SSHLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SSHSessionActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(context.state.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(context.state.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .activityBackgroundTint(.clear)
            .widgetURL(deepLink(for: context.attributes.profileID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "terminal")
                        .font(.title3)
                        .foregroundStyle(.green)
                        .padding(.leading, 8)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                Image(systemName: "terminal")
                    .foregroundStyle(.green)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: "terminal")
                    .foregroundStyle(.green)
            }
            .widgetURL(deepLink(for: context.attributes.profileID))
        }
    }

    private func deepLink(for profileID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "trawl"
        components.host = "ssh-session"
        components.queryItems = [
            URLQueryItem(name: "profile", value: profileID)
        ]
        return components.url
    }
}

import Foundation

#if os(iOS)
import ActivityKit

@MainActor
final class SSHLiveActivityManager {
    private var activity: Activity<SSHSessionActivityAttributes>?

    init() {
        activity = Activity<SSHSessionActivityAttributes>.activities.first
    }

    func sync(
        profileID: String?,
        hostDisplay: String,
        title: String,
        subtitle: String,
        statusText: String
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Task { await end() }
            return
        }

        guard let profileID else {
            Task { await end() }
            return
        }

        let attributes = SSHSessionActivityAttributes(
            profileID: profileID,
            hostDisplay: hostDisplay
        )
        let content = ActivityContent(
            state: SSHSessionActivityAttributes.ContentState(
                title: title,
                subtitle: subtitle,
                statusText: statusText
            ),
            staleDate: nil,
            relevanceScore: 100
        )

        Task {
            if let activity {
                if activity.attributes.profileID != attributes.profileID {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    self.activity = nil
                } else {
                    await activity.update(content)
                    return
                }
            }

            do {
                activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                activity = nil
            }
        }
    }

    func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
#else
@MainActor
final class SSHLiveActivityManager {
    func sync(profileID: String?, hostDisplay: String, title: String, subtitle: String, statusText: String) {}
    func end() async {}
}
#endif

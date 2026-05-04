import Foundation

enum InstanceDisplayNameResolver {
    static func displayName(
        for profile: ArrServiceProfile,
        in profiles: [ArrServiceProfile],
        serviceType: ArrServiceType
    ) -> String {
        let baseName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingNames = profiles.filter {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(baseName) == .orderedSame
        }

        if !baseName.isEmpty,
           baseName.localizedCaseInsensitiveCompare(serviceType.displayName) != .orderedSame,
           matchingNames.count == 1 {
            return baseName
        }

        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            return "\(serviceType.displayName) (\(index + 1))"
        }

        return serviceType.displayName
    }
}

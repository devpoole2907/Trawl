import SwiftUI

struct ArrQualityProfilePicker: View {
    @Binding var selection: Int?
    let profiles: [ArrQualityProfile]
    var showInfoButton: Bool = true
    var onInfo: ((ArrQualityProfile) -> Void)? = nil
    
    var body: some View {
        Picker("Quality Profile", selection: $selection) {
            Text("None").tag(Optional<Int>.none)
            ForEach(profiles, id: \.id) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
        
        if showInfoButton, let selection, let selectedProfile = profiles.first(where: { $0.id == selection }) {
            if let onInfo {
                Button {
                    onInfo(selectedProfile)
                } label: {
                    Label {
                        Text("View Selected Profile Details")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

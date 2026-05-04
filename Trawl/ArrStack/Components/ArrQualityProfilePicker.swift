import SwiftUI

struct ArrQualityProfilePicker: View {
    @Binding var selection: Int?
    let profiles: [ArrQualityProfile]
    var showInfoButton: Bool = true
    var onInfo: ((ArrQualityProfile) -> Void)? = nil
    
    var body: some View {
        Picker("Quality Profile", selection: $selection) {
            ForEach(profiles, id: \.id) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
        
        if showInfoButton, let selection, let selectedProfile = profiles.first(where: { $0.id == selection }) {
            if let onInfo {
                Button {
                    onInfo(selectedProfile)
                } label: {
                    Label("View Selected Profile Details", systemImage: "info.circle")
                }
            }
        }
    }
}

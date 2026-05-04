import SwiftUI

struct CredentialsSection: View {
    @Binding var username: String
    @Binding var password: String
    var headerTitle: String = "Credentials"
    var footerMessage: String? = nil
    
    var body: some View {
        Section {
            TextField("Username", text: $username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .textContentType(.username)
                #endif
                .autocorrectionDisabled()
            
            SecureField("Password", text: $password)
                #if os(iOS)
                .textContentType(.password)
                #endif
        } header: {
            Text(headerTitle)
        } footer: {
            if let footerMessage {
                Label(footerMessage, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }
}

import SwiftUI

struct AllowUntrustedTLSToggle: View {
    @Binding var allow: Bool
    
    var body: some View {
        Toggle("Allow Self-Signed Certificates", isOn: $allow)
    }
}

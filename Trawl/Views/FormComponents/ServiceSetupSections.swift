import SwiftUI

/// The one-line explanation a setup sheet opens with.
///
/// Every sheet had one except the Arr sheet, which opened straight onto a field.
struct ServiceSetupBlurb: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Section {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The "Server" section every setup sheet shares: what to call this server, where
/// it is, and whether to trust a certificate it signed itself.
///
/// A component rather than a written-down convention, because the six sheets had
/// already drifted into four different field orders, two different names for the
/// section, and two different labels for the same optional display name. Passing
/// the three bindings is now less work than re-typing the section, which is the
/// only thing that reliably stops it drifting again.
struct ServiceServerSection: View {
    @Binding var displayName: String
    @Binding var url: String
    /// The address phrased as an example - "Jellyfin URL (e.g. http://192.168.1.50:8096)".
    /// The placeholder on iOS, the field's prompt on macOS.
    let urlTitle: String
    /// The Mac's short leading-column label - "Jellyfin URL". See `ServerURLField`.
    let urlMacLabel: String
    @Binding var allowsUntrustedTLS: Bool
    var footer: String?
    /// Shown in place of `footer`, in red, once a submit has been attempted with
    /// this section incomplete. Only the qBittorrent sheet teaches this way today;
    /// it is here so the others can adopt it without re-deriving the section.
    var footerError: String?

    var body: some View {
        Section {
            TextField("Display Name", text: $displayName)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .autocorrectionDisabled()

            ServerURLField(url: $url, title: urlTitle, macLabel: urlMacLabel)

            AllowUntrustedTLSToggle(allow: $allowsUntrustedTLS)
        } header: {
            Text("Server")
        } footer: {
            if let footerError {
                Label(footerError, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else if let footer {
                Text(footer)
            }
        }
    }
}

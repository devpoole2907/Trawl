import SwiftUI

extension View {
    /// The one question asked before an unsaved naming draft would stop being the
    /// thing on screen: Back, another format, or another server. It is an alert, so it
    /// interrupts rather than offering a list, and it names the format and the server,
    /// so Save and Continue is its own confirmation.
    func namingUnsavedChangesDialog(
        for session: ArrNamingEditorSession?,
        isPresented: Binding<Bool>,
        onSave: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) -> some View {
        alert("Unsaved Changes", isPresented: isPresented, presenting: session) { _ in
            Button("Save and Continue", action: onSave)
            Button("Discard Changes", role: .destructive, action: onDiscard)
            Button("Keep Editing", role: .cancel) {}
        } message: { session in
            Text("Your changes to \(session.target.title) on \(session.serverName) haven't been saved.")
        }
    }
}

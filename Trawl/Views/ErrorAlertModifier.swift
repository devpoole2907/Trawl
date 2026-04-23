import SwiftUI

private struct ErrorAlertModifier: ViewModifier {
    @Binding var item: ErrorAlertItem?

    func body(content: Content) -> some View {
        content.alert(item: $item) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

extension View {
    func errorAlert(item: Binding<ErrorAlertItem?>) -> some View {
        modifier(ErrorAlertModifier(item: item))
    }
}

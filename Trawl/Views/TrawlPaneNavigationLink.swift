import SwiftUI

/// Reads the pane environment at the row, below the container that supplies it.
struct TrawlPaneNavigationLink<Value: Hashable, Label: View>: View {
    @Environment(\.hasDetailPane) private var hasDetailPane
    @Binding var selection: Value?
    let value: Value
    @ViewBuilder var label: Label

    var body: some View {
        Group {
            if hasDetailPane {
                Button {
                    selection = value
                } label: {
                    label
                }
                .background {
                    if selection == value {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                            .padding(.horizontal, -8)
                    }
                }
            } else {
                NavigationLink(value: value) { label }
            }
        }
        .buttonStyle(.plain)
    }
}

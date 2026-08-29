import SwiftUI

/// One option in a `TrawlTitleMenu`.
struct TrawlTitleMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let systemImage: String

    var id: Value { value }

    init(value: Value, title: String, systemImage: String) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
    }
}

/// A navigation title that is also the control for what the screen is showing.
///
/// Deliberately a `Menu` inside a `ToolbarItem(placement: .principal)` styled to
/// read as the title, not `ToolbarTitleMenu`: that modifier does nothing for a
/// large title, which is what these screens use.
///
/// Because a `.principal` item *replaces* the navigation title rather than
/// sitting beside it, any screen using this has to stop drawing a title of its
/// own while the menu is up — and has to take the menu down again whenever the
/// title needs to say something else, such as a selection count during editing.
struct TrawlTitleMenu<Value: Hashable>: View {
    let options: [TrawlTitleMenuOption<Value>]
    @Binding var selection: Value
    var animation: Animation = .snappy

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Menu {
            Picker("View", selection: Binding(
                get: { selection },
                set: { newValue in withAnimation(animation) { selection = newValue } }
            )) {
                ForEach(options) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option.value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(currentTitle)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(currentTitle), change view")
    }
}

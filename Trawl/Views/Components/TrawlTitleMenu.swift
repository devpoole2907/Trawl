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
/// The caller places this at the leading edge of a native sidebar content column,
/// or in the principal title position on compact layouts. The regular navigation
/// title is suppressed while the menu is visible.
struct TrawlTitleMenu<Value: Hashable>: View {
    let options: [TrawlTitleMenuOption<Value>]
    @Binding var selection: Value
    /// Shrinks the title to inline size. A `.principal` item is fixed - it takes no
    /// part in the large-title collapse the system runs on scroll - so the screens
    /// using this drive it from their own scroll position via
    /// `trawlTitleMenuShrinksOnScroll(_:)`.
    var isCompact: Bool = false
    var subtitle: String? = nil
    var animation: Animation = .snappy

    private var titleFont: Font {
        #if os(macOS)
        isCompact ? .headline : .title2.bold()
        #else
        isCompact ? .headline : .title.bold()
        #endif
    }

    private var chevronFont: Font {
        isCompact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold)
    }

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
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: isCompact ? 3 : 4) {
                    Text(currentTitle)
                        .font(titleFont)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(chevronFont)
                        .foregroundStyle(.secondary)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .animation(animation, value: isCompact)
            .contentShape(Rectangle())
        }
        // This label already carries its own `chevron.up.chevron.down`. iOS draws no
        // indicator behind a custom label, but macOS appends one, so the Mac title read
        // "Downloads ⌃⌄ ⌄" - two affordances for one menu.
        .menuIndicator(.hidden)
        .accessibilityLabel("\(currentTitle), change view")
    }
}

extension View {
    /// Reports whether the scroll view has moved off the top, so a `TrawlTitleMenu`
    /// can shrink the way a system large title does.
    ///
    /// The menu lives in a `.principal` toolbar item, which the system never
    /// resizes, so this is the only way it can respond to scrolling at all. The
    /// threshold is a few points rather than zero: a rubber-band overscroll crosses
    /// zero constantly, and toggling the title on every bounce reads as a flicker.
    func trawlTitleMenuShrinksOnScroll(_ isCompact: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 12
        } action: { _, scrolled in
            guard isCompact.wrappedValue != scrolled else { return }
            withAnimation(.snappy) { isCompact.wrappedValue = scrolled }
        }
    }
}

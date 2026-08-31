import SwiftUI

/// One icon segment in a `TrawlIconSegmentedPicker`.
///
/// `label` is never drawn - the segment shows only its symbol - but it is the
/// segment's accessibility label and the string a UI test matches on, so it has to
/// read as the thing being chosen ("Rain", "Wind"), not as an instruction.
struct TrawlIconSegment<Value: Hashable>: Identifiable {
    let value: Value
    let systemImage: String
    let label: String

    var id: Value { value }

    init(_ label: String, systemImage: String, value: Value) {
        self.label = label
        self.systemImage = systemImage
        self.value = value
    }
}

/// A compact, icon-only segmented picker in a single glass capsule - the control
/// Apple Weather puts above its hourly strip to switch that strip between
/// temperature, precipitation and wind.
///
/// Deliberately unlike `TrawlSegmentBar`, which is the full-width, scrolling,
/// text-labelled bar that heads a screen: this one is small enough to sit inline in
/// a card header next to a title, and it never scrolls. Reach for it when the
/// choice is between different *views of the same data* and each view has an
/// obvious symbol; use `TrawlSegmentBar` when the choice needs words.
///
/// Two details that make it read as a system control rather than three buttons in a
/// row: the selection highlight slides between segments (one `matchedGeometryEffect`
/// source, so SwiftUI interpolates the frame), and the hairline separators hide
/// themselves next to the selected segment, the way `UISegmentedControl` does.
///
/// ```swift
/// @State private var metric: Metric = .temperature
///
/// TrawlIconSegmentedPicker(
///     "Conditions",
///     selection: $metric,
///     segments: [
///         TrawlIconSegment("Temperature", systemImage: "cloud.sun.fill", value: .temperature),
///         TrawlIconSegment("Precipitation", systemImage: "drop.fill", value: .precipitation),
///         TrawlIconSegment("Wind", systemImage: "wind", value: .wind)
///     ]
/// )
/// ```
struct TrawlIconSegmentedPicker<Value: Hashable>: View {
    /// Names the control as a whole for VoiceOver, e.g. "Conditions". Not drawn.
    let title: String
    @Binding var selection: Value
    let segments: [TrawlIconSegment<Value>]
    var segmentWidth: CGFloat = 46
    var segmentHeight: CGFloat = 34

    @Namespace private var highlight
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        selection: Binding<Value>,
        segments: [TrawlIconSegment<Value>],
        segmentWidth: CGFloat = 46,
        segmentHeight: CGFloat = 34
    ) {
        self.title = title
        _selection = selection
        self.segments = segments
        self.segmentWidth = segmentWidth
        self.segmentHeight = segmentHeight
    }

    private static var highlightID: String { "TrawlIconSegmentedPicker.highlight" }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    separator(before: index)
                }
                segmentButton(segment)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .contentShape(.capsule)
        .animation(.snappy(duration: 0.28, extraBounce: 0.05), value: selection)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder
    private func segmentButton(_ segment: TrawlIconSegment<Value>) -> some View {
        let isSelected = selection == segment.value

        Button {
            // Guarded so re-tapping the current segment doesn't restage the
            // highlight transition or fire selection feedback.
            guard selection != segment.value else { return }
            selection = segment.value
        } label: {
            Image(systemName: segment.systemImage)
                .font(.system(size: 15, weight: .semibold))
                // Not `.secondary`: this control usually sits over artwork, where the
                // secondary tone dims far enough to read as disabled. The unselected
                // segments stay legible and the highlight capsule carries the
                // selection, the way the system control does it.
                .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.72))
                .frame(width: segmentWidth, height: segmentHeight)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.primary.opacity(0.14))
                            .matchedGeometryEffect(id: Self.highlightID, in: highlight)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(segment.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The hairline between two segments, hidden whenever it touches the selected
    /// one - otherwise it collides with the edge of the highlight capsule.
    @ViewBuilder
    private func separator(before index: Int) -> some View {
        let touchesSelection = selection == segments[index].value
            || selection == segments[index - 1].value

        Capsule()
            .fill(.primary.opacity(0.18))
            .frame(width: 1, height: segmentHeight * 0.5)
            .opacity(touchesSelection ? 0 : 1)
            .accessibilityHidden(true)
    }
}

#if DEBUG
private enum PreviewMetric: Hashable {
    case temperature, precipitation, wind
}

#Preview("Over artwork") {
    @Previewable @State var metric = PreviewMetric.temperature

    ZStack {
        LinearGradient(
            colors: [Color(red: 0.36, green: 0.44, blue: 0.53), Color(red: 0.22, green: 0.28, blue: 0.36)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()

        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conditions")
                        .font(.title3.weight(.semibold))
                    Text("Temperature (°C)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TrawlIconSegmentedPicker(
                    "Conditions",
                    selection: $metric,
                    segments: [
                        TrawlIconSegment("Temperature", systemImage: "cloud.sun.fill", value: .temperature),
                        TrawlIconSegment("Precipitation", systemImage: "drop.fill", value: .precipitation),
                        TrawlIconSegment("Wind", systemImage: "wind", value: .wind)
                    ]
                )
            }
            Text(String(describing: metric))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Two segments, light") {
    @Previewable @State var showsPoster = true

    TrawlIconSegmentedPicker(
        "Layout",
        selection: $showsPoster,
        segments: [
            TrawlIconSegment("Posters", systemImage: "square.grid.2x2.fill", value: true),
            TrawlIconSegment("List", systemImage: "list.bullet", value: false)
        ]
    )
    .padding()
}
#endif

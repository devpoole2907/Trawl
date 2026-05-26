import SwiftUI

struct ScheduledTaskRowView<Action: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let subtitleLineLimit: Int?
    let badge: ScheduledTaskRowBadge?
    let details: [ScheduledTaskRowDetail]
    let progress: Double?
    let result: ScheduledTaskRowResult?
    @ViewBuilder let action: Action

    init(
        icon: String = "clock",
        iconColor: Color = .secondary,
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = 1,
        badge: ScheduledTaskRowBadge? = nil,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.subtitleLineLimit = subtitleLineLimit
        self.badge = badge
        self.details = details
        self.progress = progress
        self.result = result
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if let badge {
                        ScheduledTaskBadgeView(badge: badge)
                    }
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !details.isEmpty {
                    ScheduledTaskDetailFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                        ForEach(details) { detail in
                            ScheduledTaskDetailPill(detail: detail)
                        }
                    }
                }

                if let progress {
                    ProgressView(value: progress, total: 100)
                        .tint(.green)
                }

                if let result {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(result.color)
                            .frame(width: 6, height: 6)

                        Text(result.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(result.color)

                        if let detail = result.detail, !detail.isEmpty {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            action
        }
        .padding(.vertical, 4)
    }
}

extension ScheduledTaskRowView {
    init(
        status: ScheduledTaskRowStatus,
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = 1,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.init(
            icon: status.icon,
            iconColor: status.color,
            title: title,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            details: details,
            progress: progress,
            result: result,
            action: action
        )
    }
}

extension ScheduledTaskRowView where Action == EmptyView {
    init(
        icon: String = "clock",
        iconColor: Color = .secondary,
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = 1,
        badge: ScheduledTaskRowBadge? = nil,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil
    ) {
        self.init(
            icon: icon,
            iconColor: iconColor,
            title: title,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            badge: badge,
            details: details,
            progress: progress,
            result: result
        ) {
            EmptyView()
        }
    }
}

extension ScheduledTaskRowView where Action == ScheduledTaskRowActionButton {
    init(
        icon: String = "clock",
        iconColor: Color = .secondary,
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = 1,
        badge: ScheduledTaskRowBadge? = nil,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil,
        action: ScheduledTaskRowAction
    ) {
        self.init(
            icon: icon,
            iconColor: iconColor,
            title: title,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            badge: badge,
            details: details,
            progress: progress,
            result: result
        ) {
            ScheduledTaskRowActionButton(action: action)
        }
    }

    init(
        status: ScheduledTaskRowStatus,
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = 1,
        details: [ScheduledTaskRowDetail] = [],
        progress: Double? = nil,
        result: ScheduledTaskRowResult? = nil,
        action: ScheduledTaskRowAction
    ) {
        self.init(
            status: status,
            title: title,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            details: details,
            progress: progress,
            result: result
        ) {
            ScheduledTaskRowActionButton(action: action)
        }
    }
}

protocol ScheduledTaskRowRepresentable {
    var scheduledTaskRowTitle: String { get }
    var scheduledTaskRowSubtitle: String? { get }
    var scheduledTaskRowSubtitleLineLimit: Int? { get }
    var scheduledTaskRowStatus: ScheduledTaskRowStatus { get }
    var scheduledTaskRowDetails: [ScheduledTaskRowDetail] { get }
    var scheduledTaskRowProgress: Double? { get }
    var scheduledTaskRowResult: ScheduledTaskRowResult? { get }
}

extension ScheduledTaskRowRepresentable {
    var scheduledTaskRowSubtitle: String? { nil }
    var scheduledTaskRowSubtitleLineLimit: Int? { 1 }
    var scheduledTaskRowDetails: [ScheduledTaskRowDetail] { [] }
    var scheduledTaskRowProgress: Double? { nil }
    var scheduledTaskRowResult: ScheduledTaskRowResult? { nil }
}

struct ScheduledTaskControlRow<Item: ScheduledTaskRowRepresentable>: View {
    let item: Item
    let action: ScheduledTaskRowAction

    var body: some View {
        ScheduledTaskRowView(
            status: item.scheduledTaskRowStatus,
            title: item.scheduledTaskRowTitle,
            subtitle: item.scheduledTaskRowSubtitle,
            subtitleLineLimit: item.scheduledTaskRowSubtitleLineLimit,
            details: item.scheduledTaskRowDetails,
            progress: item.scheduledTaskRowProgress,
            result: item.scheduledTaskRowResult,
            action: action
        )
    }
}

struct ScheduledTaskRowBadge {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
}

struct ScheduledTaskRowStatus {
    let title: String
    let icon: String
    let color: Color

    static let idle = ScheduledTaskRowStatus(
        title: "Idle",
        icon: "clock",
        color: .secondary
    )

    static let running = ScheduledTaskRowStatus(
        title: "Running",
        icon: "clock.arrow.2.circlepath",
        color: .green
    )

    static let cancelling = ScheduledTaskRowStatus(
        title: "Cancelling",
        icon: "clock.arrow.2.circlepath",
        color: .orange
    )

    static func activity(isRunning: Bool, isCancelling: Bool = false) -> ScheduledTaskRowStatus {
        if isRunning { return .running }
        if isCancelling { return .cancelling }
        return .idle
    }
}

struct ScheduledTaskRowDetail: Identifiable {
    let id: String
    let icon: String
    let content: ScheduledTaskRowDetailContent
    let color: Color

    init(icon: String, text: String, color: Color = .secondary) {
        self.id = "\(icon)-\(text)"
        self.icon = icon
        self.content = .text(text)
        self.color = color
    }

    private init(icon: String, timer: ScheduledTaskRowTimer, color: Color = .secondary) {
        self.id = "\(icon)-\(timer.id)"
        self.icon = icon
        self.content = .relativeDate(timer.relativeDate)
        self.color = color
    }

    static func interval(_ text: String) -> ScheduledTaskRowDetail {
        ScheduledTaskRowDetail(icon: "clock", text: text)
    }

    static func lastRun(_ text: String) -> ScheduledTaskRowDetail {
        ScheduledTaskRowDetail(icon: "arrow.counterclockwise", text: text)
    }

    static func lastRun(since date: Date, now: Date = .now) -> ScheduledTaskRowDetail? {
        guard date <= now else { return nil }
        return ScheduledTaskRowDetail(icon: "arrow.counterclockwise", timer: .countingUp(from: date))
    }

    static func lastRun(from raw: String?) -> ScheduledTaskRowDetail? {
        relativeDateDetail(from: raw, makeRelativeDetail: { lastRun(since: $0) }, makeFallbackDetail: { lastRun($0) })
    }

    static func nextRun(_ text: String) -> ScheduledTaskRowDetail {
        ScheduledTaskRowDetail(icon: "arrow.clockwise", text: text)
    }

    static func nextRun(until date: Date, now: Date = .now) -> ScheduledTaskRowDetail? {
        guard date > now else { return nil }
        return ScheduledTaskRowDetail(icon: "arrow.clockwise", timer: .countingDown(from: now, to: date))
    }

    static func nextRun(from raw: String?) -> ScheduledTaskRowDetail? {
        relativeDateDetail(from: raw, makeRelativeDetail: { nextRun(until: $0) }, makeFallbackDetail: { nextRun($0) })
    }

    static func duration(_ text: String) -> ScheduledTaskRowDetail {
        ScheduledTaskRowDetail(icon: "timer", text: text)
    }

    static func queued(_ text: String) -> ScheduledTaskRowDetail {
        ScheduledTaskRowDetail(icon: "clock", text: text)
    }

    static func queued(since date: Date, now: Date = .now) -> ScheduledTaskRowDetail? {
        guard date <= now else { return nil }
        return ScheduledTaskRowDetail(icon: "clock", timer: .countingUp(from: date))
    }

    static func queued(from raw: String?) -> ScheduledTaskRowDetail? {
        relativeDateDetail(from: raw, makeRelativeDetail: { queued(since: $0) }, makeFallbackDetail: { queued($0) })
    }

    private static func relativeDateDetail(
        from raw: String?,
        makeRelativeDetail: (Date) -> ScheduledTaskRowDetail?,
        makeFallbackDetail: (String) -> ScheduledTaskRowDetail
    ) -> ScheduledTaskRowDetail? {
        if let date = ScheduledTaskRowFormatter.date(from: raw),
           let detail = makeRelativeDetail(date) {
            return detail
        }
        return ScheduledTaskRowFormatter.relativeDateText(from: raw).map(makeFallbackDetail)
    }
}

enum ScheduledTaskRowDetailContent {
    case text(String)
    case relativeDate(ScheduledTaskRowRelativeDate)
}

struct ScheduledTaskRowTimer {
    enum Mode {
        case countingDown
        case countingUp
    }

    let interval: Range<Date>
    let mode: Mode

    var relativeDate: ScheduledTaskRowRelativeDate {
        switch mode {
        case .countingDown:
            ScheduledTaskRowRelativeDate(date: interval.upperBound)
        case .countingUp:
            ScheduledTaskRowRelativeDate(date: interval.lowerBound)
        }
    }

    var id: String {
        switch mode {
        case .countingDown:
            "\(mode)-\(interval.upperBound.timeIntervalSinceReferenceDate)"
        case .countingUp:
            "\(mode)-\(interval.lowerBound.timeIntervalSinceReferenceDate)"
        }
    }

    static func countingDown(from start: Date, to end: Date) -> ScheduledTaskRowTimer {
        ScheduledTaskRowTimer(interval: start..<end, mode: .countingDown)
    }

    static func countingUp(from start: Date) -> ScheduledTaskRowTimer {
        ScheduledTaskRowTimer(interval: start..<Date.distantFuture, mode: .countingUp)
    }
}

struct ScheduledTaskRowRelativeDate {
    let date: Date

    var id: String {
        "\(date.timeIntervalSinceReferenceDate)"
    }

    var text: String {
        date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

struct ScheduledTaskRowAction: Sendable {
    let accessibilityLabel: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let perform: @MainActor @Sendable () async -> Void

    init(
        accessibilityLabel: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool = false,
        perform: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.systemImage = systemImage
        self.tint = tint
        self.isDisabled = isDisabled
        self.perform = perform
    }

    static func run(
        accessibilityLabel: String = "Run task",
        systemImage: String = "play.circle",
        tint: Color = .green,
        isDisabled: Bool = false,
        perform: @escaping @MainActor @Sendable () async -> Void
    ) -> ScheduledTaskRowAction {
        ScheduledTaskRowAction(
            accessibilityLabel: accessibilityLabel,
            systemImage: systemImage,
            tint: tint,
            isDisabled: isDisabled,
            perform: perform
        )
    }

    static func stop(
        accessibilityLabel: String = "Stop task",
        systemImage: String = "stop.circle",
        tint: Color = .red,
        isDisabled: Bool = false,
        perform: @escaping @MainActor @Sendable () async -> Void
    ) -> ScheduledTaskRowAction {
        ScheduledTaskRowAction(
            accessibilityLabel: accessibilityLabel,
            systemImage: systemImage,
            tint: tint,
            isDisabled: isDisabled,
            perform: perform
        )
    }

    static func runTask(
        title: String,
        isDisabled: Bool = false,
        perform: @escaping @MainActor @Sendable () async -> Void
    ) -> ScheduledTaskRowAction {
        run(
            accessibilityLabel: "Run \(title)",
            isDisabled: isDisabled,
            perform: perform
        )
    }

    static func stopTask(
        title: String,
        verb: String = "Stop",
        isDisabled: Bool = false,
        perform: @escaping @MainActor @Sendable () async -> Void
    ) -> ScheduledTaskRowAction {
        stop(
            accessibilityLabel: "\(verb) \(title)",
            isDisabled: isDisabled,
            perform: perform
        )
    }

    static func runOrStopTask(
        title: String,
        isRunning: Bool,
        stopVerb: String = "Stop",
        run: @escaping @MainActor @Sendable () async -> Void,
        stop: @escaping @MainActor @Sendable () async -> Void
    ) -> ScheduledTaskRowAction {
        if isRunning {
            stopTask(title: title, verb: stopVerb, perform: stop)
        } else {
            runTask(title: title, perform: run)
        }
    }
}

struct ScheduledTaskRowActionButton: View {
    let action: ScheduledTaskRowAction
    @State private var isPerforming = false

    var body: some View {
        Button {
            performAction()
        } label: {
            Group {
                if isPerforming {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                } else {
                    Label(action.accessibilityLabel, systemImage: action.systemImage)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(action.isDisabled ? Color.secondary.opacity(0.4) : action.tint)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action.isDisabled || isPerforming)
        .accessibilityLabel(action.accessibilityLabel)
        .help(action.accessibilityLabel)
    }

    @MainActor
    private func performAction() {
        guard !action.isDisabled, !isPerforming else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isPerforming = true
        }

        Task { @MainActor in
            defer {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isPerforming = false
                }
            }
            await action.perform()
        }
    }
}

struct ScheduledTaskRowResult {
    let title: String
    let detail: String?
    let color: Color

    init(title: String, detail: String? = nil, color: Color) {
        self.title = title
        self.detail = detail
        self.color = color
    }
}

enum ScheduledTaskRowFormatter {
    static func cleanedText(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    static func relativeDateText(from raw: String?) -> String? {
        guard let raw = cleanedText(raw) else { return nil }
        return formattedRelativeDateText(from: raw)
    }

    static func relativeDateText(from raw: String) -> String {
        formattedRelativeDateText(from: raw)
    }

    static func date(from raw: String?) -> Date? {
        guard let raw = cleanedText(raw) else { return nil }
        return parsedDate(from: raw)
    }

    private static func formattedRelativeDateText(from raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return raw }
        guard let date = parsedDate(from: text) else { return text }
        return date.formatted(.relative(presentation: .named))
    }

    static func compactIntervalText(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    static func cadenceText(from raw: String?) -> String? {
        guard let raw = cleanedText(raw) else { return nil }
        if raw.localizedCaseInsensitiveContains("every") {
            return raw
        }
        if let namedCadence = namedCadence(raw) {
            return namedCadence
        }
        guard let components = iso8601DurationComponents(raw),
              let formatted = formattedDuration(components) else {
            return raw.rangeOfCharacter(from: .decimalDigits) == nil ? nil : "Every \(raw)"
        }
        return "Every \(formatted)"
    }

    static func durationText(start: String?, end: String?) -> String? {
        guard let start = cleanedText(start),
              let end = cleanedText(end),
              let startDate = parsedDate(from: start),
              let endDate = parsedDate(from: end) else {
            return nil
        }

        let interval = max(0, endDate.timeIntervalSince(startDate))
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval / 3600))h \(Int(interval.truncatingRemainder(dividingBy: 3600) / 60))m"
        }
    }

    private static func parsedDate(from raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }

        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return timestampFormatter.date(from: raw)
    }

    private static func namedCadence(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "minute", "minutes", "minutely": "Every minute"
        case "hour", "hours", "hourly": "Hourly"
        case "day", "days", "daily": "Daily"
        case "week", "weeks", "weekly": "Weekly"
        case "month", "months", "monthly": "Monthly"
        default: nil
        }
    }

    private static func iso8601DurationComponents(_ raw: String) -> DateComponents? {
        var remaining = raw.uppercased()
        guard remaining.hasPrefix("P") else { return nil }

        remaining.removeFirst()
        var components = DateComponents()
        var number = ""
        var isTimeComponent = false
        var hasValue = false

        for character in remaining {
            if character == "T" {
                isTimeComponent = true
            } else if character.isNumber {
                number.append(character)
            } else {
                guard let value = Int(number) else { return nil }
                applyDuration(value, for: character, isTimeComponent: isTimeComponent, to: &components)
                hasValue = true
                number = ""
            }
        }

        return hasValue ? components : nil
    }

    private static func applyDuration(
        _ value: Int,
        for component: Character,
        isTimeComponent: Bool,
        to dateComponents: inout DateComponents
    ) {
        switch component {
        case "Y":
            dateComponents.year = value
        case "M" where isTimeComponent:
            dateComponents.minute = value
        case "M":
            dateComponents.month = value
        case "W":
            dateComponents.day = value * 7
        case "D":
            dateComponents.day = (dateComponents.day ?? 0) + value
        case "H":
            dateComponents.hour = value
        case "S":
            dateComponents.second = value
        default:
            break
        }
    }

    private static func formattedDuration(_ components: DateComponents) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: components)
    }
}

private struct ScheduledTaskBadgeView: View {
    let badge: ScheduledTaskRowBadge

    var body: some View {
        Text(badge.text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badge.color.opacity(0.15), in: Capsule())
            .foregroundStyle(badge.color)
    }
}

private struct ScheduledTaskDetailPill: View {
    let detail: ScheduledTaskRowDetail

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: detail.icon)
                .imageScale(.small)
                .accessibilityHidden(true)

            content
                .lineLimit(1)
                .monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(detail.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(detail.color.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(detail.color.opacity(0.16), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch detail.content {
        case .text(let text):
            Text(text)
        case .relativeDate(let relativeDate):
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(relativeDate.text)
            }
        }
    }
}

private struct ScheduledTaskDetailFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, proposal: proposal)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, proposal: proposal)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for element in row.elements {
                element.subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: element.size.width, height: element.size.height)
                )
                x += element.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func rows(for subviews: Subviews, proposal: ProposedViewSize) -> [Row] {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if current.width > 0, current.width + horizontalSpacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.append(subview: subview, size: size, spacing: horizontalSpacing)
        }

        if !current.elements.isEmpty {
            rows.append(current)
        }

        return rows
    }

    private struct Row {
        var elements: [Element] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(subview: LayoutSubview, size: CGSize, spacing: CGFloat) {
            if !elements.isEmpty {
                width += spacing
            }
            elements.append(Element(subview: subview, size: size))
            width += size.width
            height = max(height, size.height)
        }
    }

    private struct Element {
        let subview: LayoutSubview
        let size: CGSize
    }
}

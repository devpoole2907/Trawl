import SwiftUI

// MARK: - Marquee text (auto-scrolling back and forth)

private struct MarqueeText: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var marqueeTask: Task<Void, Never>?

    var body: some View {
        // Hidden anchor text: fixes layout to the correct single-line height and
        // fills available width without leaking fixedSize ideal-width to the parent.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            GeometryReader { tg in
                                Color.clear
                                    .onAppear { textWidth = tg.size.width }
                                    .onChange(of: tg.size.width) { _, w in textWidth = w }
                            }
                        )
                        .offset(x: offset)
                        .frame(width: geo.size.width, alignment: .leading)
                        .clipped()
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in containerWidth = w }
                }
            }
            .onChange(of: textWidth) { _, _ in restartMarquee() }
            .onChange(of: containerWidth) { _, _ in restartMarquee() }
            .onChange(of: text) { _, _ in restartMarquee() }
            .onDisappear { marqueeTask?.cancel() }
    }

    private func restartMarquee() {
        marqueeTask?.cancel()
        offset = 0
        let overflow = textWidth - containerWidth
        guard overflow > 1 else { return }
        marqueeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                let duration = Double(overflow) / 35.0
                withAnimation(.linear(duration: duration)) { offset = -overflow }
                try? await Task.sleep(for: .seconds(duration + 1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: duration)) { offset = 0 }
                try? await Task.sleep(for: .seconds(duration + 2))
                guard !Task.isCancelled else { return }
            }
        }
    }
}

// MARK: - Flow layout (wraps chips to a new line)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Unified media file row

/// Single source of truth for episode and movie file rows throughout the app.
/// Build a `Config` via the `arrMediaFileConfig(...)` extensions on `SonarrEpisodeFile`
/// and `RadarrMovieFile`, then wrap it in `ArrMediaFileRow(config:)`.
struct ArrMediaFileRow: View {
    struct Config {
        var qualityBadge: String?
        /// Season badge ("S1", "Specials") — set this only at the series-level files card.
        var seasonBadge: String?
        var path: String?
        var size: Int64?
        var videoCodec: String?
        var resolution: String?
        var bitDepth: Int?
        var frameRate: Double?
        var dynamicRange: String?
        var edition: String?
        var audioCodec: String?
        var audioLanguages: String?
        var subtitles: [BazarrSubtitle]?
        var onDelete: (() -> Void)?
    }

    let config: Config

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                MarqueeText(text: config.path ?? "Unknown File", font: .subheadline.weight(.medium))

                if let onDelete = config.onDelete {
                    Menu {
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete File", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
                    .accessibilityLabel("File Actions")
                }
            }

            if config.seasonBadge != nil || config.qualityBadge != nil {
                HStack(spacing: 6) {
                    if let badge = config.seasonBadge {
                        fileBadge(badge)
                    }
                    if let quality = config.qualityBadge {
                        fileBadge(quality)
                    }
                }
            }

            FlowLayout(spacing: 6) {
                if let size = config.size, size > 0 {
                    techChip(ByteFormatter.format(bytes: size), icon: "externaldrive")
                }
                if let codec = config.videoCodec, !codec.isEmpty {
                    techChip(codec, icon: "video")
                }
                if let res = config.resolution, !res.isEmpty {
                    techChip(res, icon: "aspectratio")
                }
                if let depth = config.bitDepth {
                    techChip("\(depth)-bit", icon: "eyedropper")
                }
                if let fps = config.frameRate {
                    techChip(String(format: "%.1f fps", fps), icon: "timer")
                }
                if let hdr = config.dynamicRange, !hdr.isEmpty {
                    techChip(hdr, icon: "sun.max")
                }
                if let edition = config.edition, !edition.isEmpty {
                    techChip(edition, icon: "film")
                }
                if let codec = config.audioCodec, !codec.isEmpty {
                    techChip(codec, icon: "waveform")
                }
                if let langs = config.audioLanguages, !langs.isEmpty {
                    techChip(langs, icon: "globe")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitles = config.subtitles, !subtitles.isEmpty {
                BazarrSubtitleFilesView(subtitles: subtitles)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDelete = config.onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete File", systemImage: "trash")
                }
            }
        }
    }

    private func fileBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.18))
            .clipShape(Capsule())
    }

    private func techChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.tightIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - SonarrEpisodeFile → Config

extension SonarrEpisodeFile {
    /// - Parameter showSeasonBadge: Pass `true` at the series-level file list so the season pill renders.
    func arrMediaFileConfig(
        showSeasonBadge: Bool = false,
        subtitles: [BazarrSubtitle]? = nil,
        onDelete: (() -> Void)? = nil
    ) -> ArrMediaFileRow.Config {
        ArrMediaFileRow.Config(
            qualityBadge: quality?.quality?.name,
            seasonBadge: showSeasonBadge ? seasonNumber.map { $0 == 0 ? "Specials" : "S\($0)" } : nil,
            path: path ?? relativePath,
            size: size,
            videoCodec: mediaInfo?.videoCodec,
            resolution: mediaInfo?.resolution,
            bitDepth: mediaInfo?.videoBitDepth,
            frameRate: mediaInfo?.videoFps,
            dynamicRange: nil,
            edition: nil,
            audioCodec: mediaInfo?.audioCodec,
            audioLanguages: mediaInfo?.audioLanguages,
            subtitles: subtitles,
            onDelete: onDelete
        )
    }
}

// MARK: - RadarrMovieFile → Config

extension RadarrMovieFile {
    func arrMediaFileConfig(
        subtitles: [BazarrSubtitle]? = nil,
        onDelete: (() -> Void)? = nil
    ) -> ArrMediaFileRow.Config {
        ArrMediaFileRow.Config(
            qualityBadge: quality?.quality?.name,
            seasonBadge: nil,
            path: path ?? relativePath,
            size: size,
            videoCodec: mediaInfo?.videoCodec,
            resolution: mediaInfo?.resolution,
            bitDepth: mediaInfo?.videoBitDepth,
            frameRate: mediaInfo?.videoFps,
            dynamicRange: mediaInfo?.videoDynamicRangeType,
            edition: edition,
            audioCodec: mediaInfo?.audioCodec,
            audioLanguages: mediaInfo?.audioLanguages,
            subtitles: subtitles,
            onDelete: onDelete
        )
    }
}

import SwiftUI

struct ArrReleaseActionContent: View {
    let release: ArrRelease
    let artURL: URL?
    let accentColor: Color
    let isGrabbing: Bool
    let onGrab: () async -> Void

    @State private var grabInFlight = false

    private var canDownload: Bool {
        !isGrabbing && release.downloadAllowed != false
    }

    private var qualityScoreText: String? {
        guard let score = release.customFormatScore, score != 0 else { return nil }
        return score > 0 ? "+\(score)" : "\(score)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                heroHeader
                qualityBadgeRow
                statsGrid

                if let rejections = release.rejections, !rejections.isEmpty {
                    rejectionsCard(rejections)
                }

                downloadButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background {
            ArrArtworkView(url: artURL, contentMode: .fill) {
                Rectangle().fill(accentColor.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(1.4)
            .blur(radius: 60)
            .saturation(1.6)
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .navigationTitle("Release")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var heroHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.25))
                    .frame(width: 78, height: 78)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(spacing: 6) {
                Text(release.title ?? "Unknown Release")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                    Text(release.indexer ?? "Unknown Indexer")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var qualityBadgeRow: some View {
        HStack(spacing: 8) {
            badge(text: release.qualityName, systemImage: "sparkles", tint: accentColor)
            badge(text: release.protocolName, systemImage: "network", tint: .blue)
            if let score = qualityScoreText {
                badge(text: score, systemImage: "star.fill", tint: .yellow)
            }
            if release.approved == true {
                badge(text: "Approved", systemImage: "checkmark.seal.fill", tint: .green)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statsGrid: some View {
        let cells: [StatCell] = [
            release.size.map { StatCell(systemImage: "externaldrive.fill", label: "Size", value: ByteFormatter.format(bytes: $0), tint: .cyan) },
            release.ageDescription.map { StatCell(systemImage: "clock.fill", label: "Age", value: $0, tint: .pink) },
            release.seeders.map { StatCell(systemImage: "arrow.up.circle.fill", label: "Seeders", value: "\($0)", tint: seederColor(for: $0)) },
            release.leechers.map { StatCell(systemImage: "arrow.down.circle.fill", label: "Leechers", value: "\($0)", tint: .orange) }
        ].compactMap { $0 }

        if !cells.isEmpty {
            let columns = [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ]
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(cells) { cell in
                    statCellView(cell)
                }
            }
        }
    }

    private func statCellView(_ cell: StatCell) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(cell.tint.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: cell.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(cell.tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(cell.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(cell.value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private func rejectionsCard(_ rejections: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Alerts", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(rejections, id: \.self) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.orange.opacity(0.8))
                            .padding(.top, 5)
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var downloadButton: some View {
        Button {
            guard !grabInFlight else { return }
            Task {
                grabInFlight = true
                defer { grabInFlight = false }
                await onGrab()
            }
        } label: {
            ZStack {
                Label("Download Release", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .opacity(isGrabbing ? 0 : 1)
                ProgressView()
                    .tint(.white)
                    .opacity(isGrabbing ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
        }
        .buttonStyle(.borderedProminent)
        .tint(accentColor)
        .controlSize(.large)
        .disabled(!canDownload)
        .animation(.easeInOut(duration: 0.2), value: isGrabbing)
    }

    private func badge(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.18), in: Capsule())
        .overlay(
            Capsule().stroke(tint.opacity(0.4), lineWidth: 1)
        )
    }

    private func seederColor(for seeders: Int) -> Color {
        switch seeders {
        case 50...: .green
        case 10...: .mint
        case 1...: .orange
        default: .red
        }
    }

    private struct StatCell: Identifiable {
        let id = UUID()
        let systemImage: String
        let label: String
        let value: String
        let tint: Color
    }
}

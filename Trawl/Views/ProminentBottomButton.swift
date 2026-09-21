import SwiftUI

/// The single committing action of a screen, pinned below its content.
///
/// The two platforms disagree about what that looks like, and the disagreement is the
/// point of the `#if`s below. On iPhone this is a full-width capsule in thumb reach.
/// A Mac window is not held in a hand and has no thumb reach: the same capsule stretched
/// across 1400pt reads as a web banner, so macOS gets a normal-width default button,
/// bound to Return, with real margin under it.
///
/// Centred rather than bottom-trailing, because the full-screen flows that use this - the
/// welcome flow, the service picker, the lock screen - centre their content in a narrow
/// column. A button in the far corner of a 1440pt window would be nowhere near the thing
/// it acts on.
///
/// Sheets split by platform. On macOS a sheet's commit action belongs in the corner, and
/// it gets that from `.confirmationAction` instead; see `AppSheetShell`. On iPhone and
/// iPad a sheet can use this capsule too, when its action is the one thing the sheet is
/// for - the Missing sheet's Search All Missing is, and puts it here rather than in the
/// navigation bar.
///
/// iPad deliberately gets more margin below the capsule than iPhone (16pt against 8pt).
/// That applies everywhere this is used, not only in sheets - keep the two values apart
/// rather than unifying them.
struct ProminentBottomButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        #if os(macOS)
        button
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isDisabled || isLoading)
            .padding(.top, 4)
            .padding(.bottom, 24)
        #else
        button
            .controlSize(.large)
            .fontWeight(.medium)
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .buttonSizing(.flexible)
            .disabled(isDisabled || isLoading)
            .scenePadding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, UIDevice.current.userInterfaceIdiom == .pad ? 16 : 8)
        #endif
    }

    private var button: some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }
}

extension View {
    func prominentBottomButton(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        safeAreaInset(edge: .bottom) {
            ProminentBottomButton(title: title, systemImage: systemImage, isLoading: isLoading, isDisabled: isDisabled, action: action)
        }
    }
}

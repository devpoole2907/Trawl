//
//  TrawlInlineCallout.swift
//  Trawl
//
//  The small notice that sits above a screen's content and offers one thing to do.
//

import SwiftUI

/// A one-off notice at the top of a screen: an icon, a sentence, and at most one
/// action.
///
/// Deliberately not a `Tip`. The discovery tips in `Trawl/Tips` teach a gesture the
/// app already offers and are capped at a single appearance for the life of an
/// install. This is the other kind of notice: it is *about the user's own setup*, it
/// is true for exactly as long as that setup says so, and it should come back if the
/// condition does. Nothing here is persisted.
///
/// Extracted from the Bazarr language-profile banner, which was the first of these
/// and was private to `MoreView`. A second one - the Prowlarr nudge on Indexers -
/// would have been a copy of it, and two hand-kept copies of one notice style is how
/// they drift.
struct TrawlInlineCallout: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    /// The one thing this notice offers. Omitted for a notice that only informs.
    var actionTitle: String?
    var action: (() -> Void)?
    /// Omitted for a notice the user cannot wave away - one that describes a state
    /// rather than a suggestion.
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(tint)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

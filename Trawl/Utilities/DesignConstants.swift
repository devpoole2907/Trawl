import Foundation
import SwiftUI

enum DesignConstants {
    enum Spacing {
        /// Icon-to-text gap inside pills and chip labels
        static let iconText: CGFloat = 3
    }

    enum CornerRadius {
        /// Smallest chips, micro badges
        static let small: CGFloat = 4
        /// Artwork thumbnails, inner icon backgrounds
        static let medium: CGFloat = 8
        /// Cards, section containers, material surfaces
        static let large: CGFloat = 12
        /// Full-width tiles, prominent cards
        static let extraLarge: CGFloat = 16
    }
}

// MARK: - Shared label style

struct TightIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DesignConstants.Spacing.iconText) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == TightIconLabelStyle {
    static var tightIcon: TightIconLabelStyle { .init() }
}

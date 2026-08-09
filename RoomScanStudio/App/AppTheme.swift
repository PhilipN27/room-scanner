import SwiftUI
import UIKit

/// Semantic color roles keep the warm-paper library adaptive while preserving
/// the deliberately black field-instrument surfaces. Foreground roles used on
/// paper are selected for normal-text contrast; bright cyan/amber variants are
/// reserved for the fixed dark capture and viewer surfaces.
enum AppPalette {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let paper = adaptive(
        light: UIColor(red: 0.94, green: 0.91, blue: 0.84, alpha: 1),
        dark: UIColor(red: 0.12, green: 0.11, blue: 0.09, alpha: 1)
    )
    static let paperShadow = adaptive(
        light: UIColor(red: 0.84, green: 0.80, blue: 0.72, alpha: 1),
        dark: UIColor(red: 0.20, green: 0.18, blue: 0.15, alpha: 1)
    )
    static let raisedSurface = adaptive(
        light: UIColor(red: 0.99, green: 0.97, blue: 0.91, alpha: 1),
        dark: UIColor(red: 0.17, green: 0.16, blue: 0.13, alpha: 1)
    )
    static let ink = adaptive(
        light: UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1),
        dark: UIColor(red: 0.97, green: 0.94, blue: 0.88, alpha: 1)
    )
    static let mutedInk = adaptive(
        light: UIColor(red: 0.31, green: 0.30, blue: 0.27, alpha: 1),
        dark: UIColor(red: 0.78, green: 0.75, blue: 0.69, alpha: 1)
    )
    /// Dark cyan on paper; a lighter variant automatically appears in dark
    /// appearance. Use `blueprintOnDark` on a fixed black instrument surface.
    static let blueprint = adaptive(
        light: UIColor(red: 0.00, green: 0.34, blue: 0.42, alpha: 1),
        dark: UIColor(red: 0.39, green: 0.84, blue: 0.92, alpha: 1)
    )
    /// Dark amber on paper; use `amberOnDark` on fixed black surfaces.
    static let amber = adaptive(
        light: UIColor(red: 0.49, green: 0.25, blue: 0.02, alpha: 1),
        dark: UIColor(red: 0.98, green: 0.71, blue: 0.30, alpha: 1)
    )
    /// A dark, readable prominent-button fill in both paper appearances.
    /// Its white label remains normal-text contrast compliant in each mode.
    static let primaryAction = adaptive(
        light: UIColor(red: 0.00, green: 0.34, blue: 0.42, alpha: 1),
        dark: UIColor(red: 0.00, green: 0.45, blue: 0.54, alpha: 1)
    )

    static let graphite = Color(red: 0.10, green: 0.11, blue: 0.11)
    static let captureBlack = Color(red: 0.025, green: 0.03, blue: 0.03)
    static let primaryOnDark = Color(red: 1, green: 1, blue: 1)
    static let mutedOnDark = Color(red: 0.74, green: 0.74, blue: 0.74)
    static let blueprintOnDark = Color(red: 0.35, green: 0.84, blue: 0.93)
    static let amberOnDark = Color(red: 0.98, green: 0.69, blue: 0.27)
}

enum AppTypography {
    static let editorial = Font.system(.largeTitle, design: .serif, weight: .semibold)
    static let section = Font.system(.headline, design: .serif, weight: .semibold)
    static let measurement = Font.system(.caption, design: .monospaced, weight: .medium)
    static let body = Font.system(.body, design: .rounded, weight: .regular)
    static let bodyEmphasized = Font.system(.body, design: .rounded, weight: .semibold)
    static let callout = Font.system(.callout, design: .rounded, weight: .regular)
    static let calloutEmphasized = Font.system(.callout, design: .rounded, weight: .semibold)
    static let symbol = Font.system(.title3, design: .default, weight: .semibold)
}

/// Reuses the same actions in a horizontal layout when they fit and a
/// scroll-friendly vertical layout at accessibility Dynamic Type sizes. The
/// vertical variant gives each action the available row width.
struct AdaptiveActionRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let alignment: HorizontalAlignment
    private let spacing: CGFloat
    private let content: Content

    init(
        alignment: HorizontalAlignment = .leading,
        spacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact {
                VStack(alignment: alignment, spacing: spacing) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: spacing) {
                        content
                    }
                    VStack(alignment: alignment, spacing: spacing) {
                        content
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

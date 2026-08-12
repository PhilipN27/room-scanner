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

/// The four action roles of the redesigned instrument language. Exactly one
/// `.primary` should appear per screen region; `.destructive` is reserved for
/// permanent-loss actions and is never mixed into a row of peers.
enum InstrumentButtonRole {
    case primary
    case secondary
    case quiet
    case destructive
}

struct InstrumentButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var role: InstrumentButtonRole = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.bodyEmphasized)
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: Color.white
        case .secondary: AppPalette.ink
        case .quiet: AppPalette.blueprint
        case .destructive: Color(uiColor: .systemRed)
        }
    }

    @ViewBuilder private var background: some View {
        switch role {
        case .primary:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppPalette.primaryAction)
        case .secondary:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppPalette.raisedSurface)
        case .quiet, .destructive:
            Color.clear
        }
    }

    @ViewBuilder private var border: some View {
        switch role {
        case .secondary, .destructive:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppPalette.paperShadow, lineWidth: 1)
        case .primary, .quiet:
            EmptyView()
        }
    }
}

/// A compact mono rail of real facts (renderer kind, revision count, capture
/// date). Values are supplied by callers from live data — the rail never
/// invents or decorates.
struct StatusRailItem: Identifiable {
    let id: String
    let label: String
    var accent: Bool = false

    init(_ label: String, accent: Bool = false) {
        self.id = label
        self.label = label
        self.accent = accent
    }
}

struct StatusRail: View {
    let items: [StatusRailItem]

    // A fact rail is not an action row: it stays horizontal on iPhone
    // portrait (AdaptiveActionRow would stack it), overflowing to a plain
    // vertical list — without divider ticks — only when it truly cannot fit.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(AppPalette.paperShadow)
                            .frame(width: 1, height: 12)
                            .accessibilityHidden(true)
                    }
                    label(for: item)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    label(for: item)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func label(for item: StatusRailItem) -> some View {
        Text(item.label)
            .font(AppTypography.measurement)
            .textCase(.uppercase)
            .kerning(1.2)
            .foregroundStyle(item.accent ? AppPalette.blueprint : AppPalette.mutedInk)
    }
}

/// The "i" affordance: a titled, hairline-ruled disclosure that keeps
/// secondary detail out of the primary reading order until asked for.
struct MetadataDisclosure<Header: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isExpanded: Bool
    private let title: String
    private let headerAccessory: Header
    private let content: Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder headerAccessory: () -> Header = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.headerAccessory = headerAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(AppPalette.paperShadow)
                .frame(height: 1)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                Button {
                    if reduceMotion {
                        isExpanded.toggle()
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(AppTypography.measurement)
                            .textCase(.uppercase)
                            .kerning(1.2)
                            .foregroundStyle(AppPalette.mutedInk)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppPalette.blueprint)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityHint(isExpanded ? "Collapses the section" : "Expands the section")
                Spacer(minLength: 0)
                headerAccessory
            }
            if isExpanded {
                content
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
    }
}

/// Hero media for a room profile: a rendered mesh snapshot when one exists,
/// a real floor-plan projection otherwise — never the legacy fake pattern.
enum RoomHeroMediaState: Equatable {
    case loading
    case snapshot(UIImage)
    case floorPlan(UIImage)
    case unavailable
}

struct RoomHeroMedia: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: RoomHeroMediaState
    var accessibilityDescription: String

    var body: some View {
        ZStack {
            AppPalette.graphite
            switch state {
            case .loading:
                ProgressView()
                    .tint(AppPalette.blueprintOnDark)
            case let .snapshot(image), let .floorPlan(image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .unavailable:
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.largeTitle)
                        .foregroundStyle(AppPalette.mutedOnDark)
                    Text("No preview available")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedOnDark)
                }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
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

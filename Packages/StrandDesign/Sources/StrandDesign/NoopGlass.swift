import SwiftUI

// MARK: - Liquid Glass, the house way
//
// One place decides what "glass" is, so every screen asks for it the same way and the fallbacks stay in step.
//
//   • iOS 26 and later: the platform `glassEffect`. It samples what is behind it, adapts to light and dark,
//     honours Reduce Transparency by itself, and morphs between shapes inside a `NoopGlassGroup`.
//   • Older iOS: the system ultra-thin material with a hairline edge, the closest honest stand-in.
//   • macOS: the solid raised surface. Liquid Glass stays iOS-only, as `NoopLiquidGlassSearchField` already
//     decided, and the glass APIs never reach the macOS 13 target because they sit behind `#if os(iOS)`.
//
// Tints are washes, not paint: a tinted glass reads as the colour of what it is about (amber for a rest, green
// for the set being worked), never as a filled button. `NoopMetrics.glassTintOpacity` is the one strength.

public extension NoopMetrics {
    /// Corner radius of a glass card. The card radius, so glass and solid cards line up in one column.
    static let glassCardRadius: CGFloat = NoopVisualStyle.cardRadius
    /// Corner radius of a small glass tile (a stat, a tool).
    static let glassTileRadius: CGFloat = NoopVisualStyle.compactRadius
    /// How strongly a tint colours glass. One value for the whole app.
    static let glassTintOpacity: Double = 0.32
    /// Spacing under which neighbouring glass shapes in a `NoopGlassGroup` melt into one.
    static let glassMergeSpacing: CGFloat = 12
    /// Side of a round glass icon button: the 44 pt touch floor.
    static let glassIconButtonSize: CGFloat = 44
}

public extension View {
    /// Liquid Glass in `shape`, tinted with `tint` when given. `interactive` makes it respond to touch (a button
    /// or a control); leave it off for a card that only shows things.
    @ViewBuilder
    func noopGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(NoopMetrics.glassTintOpacity)).interactive(interactive),
                             in: shape)
        } else {
            self
                .background((tint ?? Color.clear).opacity(NoopMetrics.glassTintOpacity * 0.6), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(StrandPalette.hairline, lineWidth: 0.5))
        }
        #else
        self
            .background((tint ?? Color.clear).opacity(NoopMetrics.glassTintOpacity * 0.5), in: shape)
            .background(StrandPalette.surfaceRaised, in: shape)
            .overlay(shape.stroke(StrandPalette.hairline, lineWidth: 0.5))
        #endif
    }

    /// The glass button look on any `Button`. `prominent` is the one main action of a screen: on iOS 26 the
    /// system's prominent glass, tinted with `tint` (the accent by default).
    @ViewBuilder
    func noopGlassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint ?? StrandPalette.accent)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else {
            self.buttonStyle(NoopButtonStyle(prominent ? .primary : .secondary))
        }
        #else
        self.buttonStyle(NoopButtonStyle(prominent ? .primary : .secondary))
        #endif
    }
}

/// A card made of glass: the content padded, full width, on a glass rounded rectangle.
public struct NoopGlassCard<Content: View>: View {
    private let tint: Color?
    private let padding: CGFloat
    private let interactive: Bool
    private let content: Content

    public init(tint: Color? = nil, padding: CGFloat = NoopMetrics.cardPadding, interactive: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.padding = padding
        self.interactive = interactive
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .noopGlass(RoundedRectangle(cornerRadius: NoopMetrics.glassCardRadius, style: .continuous),
                       tint: tint, interactive: interactive)
    }
}

/// Groups glass shapes so iOS 26 renders them as one material: neighbours closer than `spacing` blend, and a
/// shape that appears or goes away morphs out of its neighbours instead of popping. Elsewhere it is a no-op.
public struct NoopGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = NoopMetrics.glassMergeSpacing, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A round glass button carrying one SF Symbol. The label is required: an icon alone says nothing to VoiceOver.
public struct NoopGlassIconButton: View {
    private let systemImage: String
    private let label: LocalizedStringKey
    private let tint: Color?
    private let action: () -> Void

    public init(systemImage: String, label: LocalizedStringKey, tint: Color? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint ?? StrandPalette.textPrimary)
                .frame(width: NoopMetrics.glassIconButtonSize, height: NoopMetrics.glassIconButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .noopGlass(Circle(), tint: tint, interactive: true)
        .accessibilityLabel(Text(label))
    }
}

/// The surface behind a glass screen. Glass needs something to refract: on the flat canvas it reads as a grey
/// card. This is the canvas with two soft glows of `tint` (the screen's domain colour), drawn once and never
/// animated, so it costs a layer and no frames.
public struct NoopGlassBackdrop: View {
    private let tint: Color
    private let secondary: Color
    private let intensity: Double

    public init(tint: Color, secondary: Color = StrandPalette.accent, intensity: Double = 1) {
        self.tint = tint
        self.secondary = secondary
        self.intensity = intensity
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                StrandPalette.surfaceBase
                RadialGradient(colors: [tint.opacity(0.55 * intensity), tint.opacity(0)],
                               center: UnitPoint(x: 0.15, y: 0.02), startRadius: 0, endRadius: w * 0.95)
                RadialGradient(colors: [secondary.opacity(0.30 * intensity), secondary.opacity(0)],
                               center: UnitPoint(x: 0.95, y: 0.30), startRadius: 0, endRadius: w * 0.80)
                RadialGradient(colors: [tint.opacity(0.22 * intensity), tint.opacity(0)],
                               center: UnitPoint(x: 0.30, y: 0.85), startRadius: 0, endRadius: w * 0.90)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - The backdrop a screen asks for

private struct NoopBackdropTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

public extension EnvironmentValues {
    /// The domain colour a screen's glass backdrop glows with. Nil leaves the app's default (the accent).
    var noopBackdropTint: Color? {
        get { self[NoopBackdropTintKey.self] }
        set { self[NoopBackdropTintKey.self] = newValue }
    }
}

public extension View {
    /// Put this view (a sheet, a pushed screen) on the glass backdrop in `tint`, and tell any `ScreenScaffold`
    /// inside to draw the same one.
    func noopBackdrop(_ tint: Color) -> some View {
        self
            .environment(\.noopBackdropTint, tint)
            .background(NoopGlassBackdrop(tint: tint).ignoresSafeArea())
    }
}

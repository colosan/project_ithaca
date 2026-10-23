// Tokens (design/tokens → IthacaDesign) as SwiftUI / AppKit values. Nothing here invents a value.
import AppKit
import IthacaDesign
import SwiftUI

typealias T = Tokens

extension NSColor {
    /// A dynamic color that follows the effective appearance (light/dark are separately chosen values, DESIGN.md).
    static func token(_ pair: ColorPair) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = dark ? pair.dark : pair.light
            return NSColor(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                           blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        }
    }
}

extension Color {
    static func token(_ pair: ColorPair) -> Color { Color(nsColor: .token(pair)) }

    static let surfaceCanvas = token(T.Color.surfaceCanvas)
    static let surfaceSidebar = token(T.Color.surfaceSidebar)
    static let surfaceList = token(T.Color.surfaceList)
    static let surfaceRaised = token(T.Color.surfaceRaised)
    static let surfaceSelected = token(T.Color.surfaceSelected)
    static let surfaceScrim = token(T.Color.surfaceScrim)
    static let inkPrimary = token(T.Color.inkPrimary)
    static let inkSecondary = token(T.Color.inkSecondary)
    static let inkTertiary = token(T.Color.inkTertiary)
    static let inkMarkup = token(T.Color.inkMarkup)
    static let inkOnAccent = token(T.Color.inkOnAccent)
    static let lineSubtle = token(T.Color.lineSubtle)
    static let lineStrong = token(T.Color.lineStrong)
    static let accentPrimary = token(T.Color.accentPrimary)
    static let accentSoft = token(T.Color.accentSoft)
    static let stateWarning = token(T.Color.stateWarning)
    static let stateDanger = token(T.Color.stateDanger)
    static let stateSuccess = token(T.Color.stateSuccess)
}

enum Fonts {
    /// Pretendard when installed or bundled, otherwise the system font (Apple SD Gothic Neo covers Korean).
    static func ns(_ style: TextStyleToken, weight override: Int? = nil) -> NSFont {
        let w = weight(override ?? style.weight)
        if let f = NSFont(name: "\(style.family)-\(faceName(override ?? style.weight))", size: style.size) { return f }
        return NSFont.systemFont(ofSize: style.size, weight: w)
    }

    static func swiftUI(_ style: TextStyleToken, weight override: Int? = nil) -> Font { Font(ns(style, weight: override)) }

    private static func weight(_ w: Int) -> NSFont.Weight {
        switch w {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }

    private static func faceName(_ w: Int) -> String {
        switch w {
        case ..<450: "Regular"
        case ..<550: "Medium"
        case ..<650: "SemiBold"
        default: "Bold"
        }
    }
}

extension View {
    /// Token text style: font + line height (as extra line spacing) + tracking.
    func textStyle(_ style: TextStyleToken, weight: Int? = nil) -> some View {
        let font = Fonts.ns(style, weight: weight)
        let natural = font.ascender - font.descender + font.leading
        return self.font(Font(font))
            .lineSpacing(max(0, style.lineHeight - natural))
            .tracking(style.tracking * style.size)
    }

    func hairline(_ edge: Edge, _ color: Color = .lineSubtle) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle().fill(color).frame(width: edge.isVertical ? nil : T.Size.strokeHairline, height: edge.isVertical ? T.Size.strokeHairline : nil)
        }
    }

    func tokenShadow(_ s: ShadowToken) -> some View {
        shadow(color: .black.opacity(s.opacity), radius: s.blur / 2, x: 0, y: s.y)
    }
}

private extension Edge {
    var isVertical: Bool { self == .top || self == .bottom }
    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

extension TextStyleToken {
    static let display = T.Typography.display
    static let title = T.Typography.title
    static let heading = T.Typography.heading
    static let body = T.Typography.body
    static let label = T.Typography.label
    static let caption = T.Typography.caption
}

// Native counterparts of the workbench kit (DESIGN.md: one kit for controls): Button variants, IconButton.
// Segmented · Switch · Checkbox · TextField use the native macOS controls, tinted with the accent token.
import IthacaDesign
import SwiftUI

enum KitVariant { case primary, secondary, ghost, danger }

struct KitButtonStyle: ButtonStyle {
    var variant: KitVariant = .secondary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.label)
            .lineLimit(1)
            .padding(.horizontal, T.Space.s150)
            .frame(minHeight: T.Size.controlSm)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(background(configuration.isPressed)))
            .overlay {
                if variant == .secondary { RoundedRectangle(cornerRadius: T.Radius.control).strokeBorder(Color.lineStrong, lineWidth: T.Size.strokeHairline) }
            }
            .modifier(RaisedShadow(on: variant == .secondary || variant == .primary))
            .opacity(enabled ? 1 : T.Opacity.disabled)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch variant {
        case .primary: .inkOnAccent
        case .secondary: .inkPrimary
        case .ghost: .inkSecondary
        case .danger: .stateDanger
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch variant {
        case .primary: pressed ? .accentPrimary.opacity(0.85) : .accentPrimary
        case .secondary: pressed ? .surfaceSelected : .surfaceRaised
        case .ghost, .danger: pressed ? .surfaceSelected : .clear
        }
    }
}

private struct RaisedShadow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.tokenShadow(T.Shadow.raised) } else { content }
    }
}

struct KitButton: View {
    let title: String
    var icon: IthacaIcon? = nil
    var variant: KitVariant = .secondary
    let action: () -> Void

    init(_ title: String, icon: IthacaIcon? = nil, variant: KitVariant = .secondary, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: T.Space.s50) {
                if let icon { Icon(icon, size: T.Size.iconSm) }
                Text(title)
            }
        }
        .buttonStyle(KitButtonStyle(variant: variant))
    }
}

struct IconButton: View {
    let icon: IthacaIcon
    let label: String
    var active = false
    let action: () -> Void
    @State private var hover = false

    init(_ icon: IthacaIcon, label: String, active: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(icon, size: T.Size.iconMd, color: active ? .accentPrimary : .inkSecondary)
                .frame(width: T.Size.controlSm, height: T.Size.controlSm)
                .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(active || hover ? Color.surfaceSelected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Section caption used in panes and dialogs.
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).textStyle(.caption).foregroundStyle(Color.inkTertiary)
    }
}

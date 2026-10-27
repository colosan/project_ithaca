// Native counterparts of the workbench kit (DESIGN.md: one kit for controls): Button variants, IconButton.
// Segmented · Switch · Checkbox · TextField use the native macOS controls, tinted with the accent token.
import AppKit
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
    @Environment(\.isEnabled) private var enabled

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
                .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(active || (hover && enabled) ? Color.surfaceSelected : .clear))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : T.Opacity.disabled)
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

/// The kit Switch: accent fill when on, also in an inactive window (the native NSSwitch turns grey there,
/// which read as "off"). Label on the leading side, switch trailing — same layout as the native one in a Form.
struct KitSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: T.Space.s150) {
            configuration.label
            Spacer(minLength: 0)
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.accentPrimary : Color.lineStrong)
                    Circle().fill(Color.white).padding(2).shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                }
                .frame(width: 32, height: 18)
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : T.Opacity.disabled)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "1" : "0")
        }
    }
}

/// Native segmented control that fills its width with equal segments (SwiftUI's segmented Picker sizes to its
/// labels, so short Korean labels gave a small control while English filled the bar).
struct FillSegmented<Value: Hashable>: NSViewRepresentable {
    let items: [(Value, String)]
    @Binding var selection: Value

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: items.map(\.1), trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fillEqually
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if c.segmentCount != items.count { c.segmentCount = items.count }
        for (i, item) in items.enumerated() where c.label(forSegment: i) != item.1 { c.setLabel(item.1, forSegment: i) }
        if let i = items.firstIndex(where: { $0.0 == selection }) { c.selectedSegment = i }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FillSegmented
        init(_ p: FillSegmented) { parent = p }
        @objc func changed(_ c: NSSegmentedControl) {
            guard parent.items.indices.contains(c.selectedSegment) else { return }
            parent.selection = parent.items[c.selectedSegment].0
        }
    }
}

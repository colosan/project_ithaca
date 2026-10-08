// Shared controls for prototypes. Each one has a native counterpart (SwiftUI / Compose) built to the same tokens,
// so screens stop hand-drawing their own buttons and checkboxes and look like one app.
// Only tokens here — no raw numbers — so a token change restyles every screen at once.
import { useState, type CSSProperties, type ReactNode } from "react";
import { color, motion, opacity, radius, shadow, size, space, type } from "../generated/tokens";
import { icons, iconStroke, type IconName } from "../generated/icons";

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const fast = `${motion.fast.duration} ${motion.fast.easing}`;
const ease = `background ${fast}, color ${fast}, border-color ${fast}, box-shadow ${fast}`;

/** Hover state for pointer platforms; touch frames simply never hover. */
function useHover() {
  const [hover, setHover] = useState(false);
  return { hover, bind: { onMouseEnter: () => setHover(true), onMouseLeave: () => setHover(false) } };
}

export type IconSize = "sm" | "md" | "lg";
const ICON: Record<IconSize, string> = { sm: size.iconSm, md: size.iconMd, lg: size.iconLg };

/** One icon from design/icons.json. Inherits the text color unless `color` is given. */
export function Icon({ name, size: s = "md", color: c, style }: { name: IconName; size?: IconSize; color?: string; style?: CSSProperties }) {
  const C = icons[name];
  return <C aria-hidden absoluteStrokeWidth={false} strokeWidth={iconStroke} style={{ flex: "none", width: ICON[s], height: ICON[s], color: c, ...style }} />;
}

export type ButtonVariant = "primary" | "secondary" | "ghost" | "danger";

/** Text button, optionally with a leading icon. Grows with text size (minHeight, never height). */
export function Button({
  variant = "secondary", icon, disabled, onClick, children, full, style,
}: { variant?: ButtonVariant; icon?: IconName; disabled?: boolean; onClick?: () => void; children: ReactNode; full?: boolean; style?: CSSProperties }) {
  const { hover, bind } = useHover();
  const on = hover && !disabled;
  const look: Record<ButtonVariant, CSSProperties> = {
    primary: { background: color.accentPrimary, color: color.inkOnAccent, border: hairline(color.accentPrimary), boxShadow: on ? shadow.raised : undefined },
    secondary: { background: on ? color.surfaceSelected : color.surfaceRaised, color: color.inkPrimary, border: hairline(color.lineStrong), boxShadow: shadow.raised },
    ghost: { background: on ? color.surfaceSelected : "transparent", color: color.inkSecondary, border: hairline("transparent") },
    danger: { background: on ? color.surfaceSelected : "transparent", color: color.stateDanger, border: hairline(color.lineStrong) },
  };
  return (
    <span
      {...bind}
      role="button"
      onClick={disabled ? undefined : onClick}
      style={{
        display: full ? "flex" : "inline-flex", alignItems: "center", justifyContent: "center", gap: space[100],
        minHeight: size.controlMd, padding: `${space[50]} ${space[200]}`, borderRadius: radius.control,
        ...type.label, fontWeight: type.heading.fontWeight, textAlign: "center",
        cursor: disabled ? "default" : "pointer", opacity: disabled ? opacity.disabled : undefined, transition: ease,
        ...look[variant], ...style,
      }}
    >
      {icon && <Icon name={icon} size="sm" />}
      {children}
    </span>
  );
}

/** Square icon-only button for toolbars. `label` is the tooltip / accessibility name. */
export function IconButton({ icon, label, onClick, active, tone }: { icon: IconName; label: string; onClick?: () => void; active?: boolean; tone?: string }) {
  const { hover, bind } = useHover();
  return (
    <span
      {...bind}
      role="button"
      title={label}
      aria-label={label}
      onClick={onClick}
      style={{
        flex: "none", display: "inline-grid", placeItems: "center", minWidth: size.controlSm, minHeight: size.controlSm, borderRadius: radius.control,
        background: active ? color.accentSoft : hover ? color.surfaceSelected : "transparent",
        color: active ? color.accentPrimary : tone ?? color.inkSecondary, cursor: onClick ? "pointer" : "default", transition: ease,
      }}
    >
      <Icon name={icon} size="md" />
    </span>
  );
}

/** Segmented control: a sunken track with the chosen item raised — the same shape on every platform. */
export function Segmented<T extends string | number>({ items, value, onChange, full }: { items: readonly (readonly [T, string])[]; value: T; onChange: (v: T) => void; full?: boolean }) {
  return (
    <div style={{ display: full ? "flex" : "inline-flex", maxWidth: "100%", gap: space[25], padding: space[25], borderRadius: radius.control, background: color.surfaceSelected, ...type.label }}>
      {items.map(([k, label]) => {
        const on = k === value;
        return (
          <span
            key={String(k)}
            role="button"
            onClick={() => onChange(k)}
            style={{
              flex: "1 1 auto", minWidth: 0, display: "flex", alignItems: "center", justifyContent: "center", textAlign: "center", padding: `${space[50]} ${space[150]}`, borderRadius: radius.piece,
              background: on ? color.surfaceRaised : "transparent", boxShadow: on ? shadow.raised : undefined,
              color: on ? color.inkPrimary : color.inkSecondary, fontWeight: on ? type.heading.fontWeight : undefined,
              cursor: "pointer", transition: ease,
            }}
          >
            {label}
          </span>
        );
      })}
    </div>
  );
}

/** Filter chip: a pill that is either on or off. */
export function Chip({ active, onClick, children }: { active: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <span
      role="button"
      onClick={onClick}
      style={{
        display: "inline-flex", alignItems: "center", gap: space[50], ...type.label, padding: `${space[50]} ${space[150]}`, borderRadius: radius.full,
        border: hairline(active ? "transparent" : color.lineStrong), background: active ? color.inkPrimary : "transparent",
        color: active ? color.surfaceCanvas : color.inkSecondary, cursor: "pointer", transition: ease,
      }}
    >
      {children}
    </span>
  );
}

/** Checkbox mark. The row around it handles the click so the whole line is a target. */
export function Checkbox({ on }: { on: boolean }) {
  return (
    <span
      style={{
        flex: "none", display: "grid", placeItems: "center", minWidth: size.iconMd, minHeight: size.iconMd, borderRadius: radius.piece,
        border: hairline(on ? color.accentPrimary : color.lineStrong), background: on ? color.accentPrimary : color.surfaceRaised,
        color: color.inkOnAccent, transition: ease,
      }}
    >
      {on && <Icon name="check" size="sm" />}
    </span>
  );
}

/** Radio mark: a ring, filled with a dot when chosen. */
export function Radio({ on }: { on: boolean }) {
  return (
    <span
      style={{
        flex: "none", width: size.iconMd, height: size.iconMd, borderRadius: radius.full, boxSizing: "border-box",
        border: hairline(on ? color.accentPrimary : color.lineStrong), background: on ? color.accentPrimary : color.surfaceRaised,
        boxShadow: on ? `inset 0 0 0 ${space[50]} ${color.surfaceRaised}` : undefined, transition: ease,
      }}
    />
  );
}

/** On/off switch. Fixed size: it holds no text. */
export function Switch({ on, onToggle }: { on: boolean; onToggle: () => void }) {
  return (
    <span
      role="switch"
      aria-checked={on}
      onClick={onToggle}
      style={{ position: "relative", flex: "none", width: size.toggleWidth, height: size.toggleHeight, borderRadius: radius.full, background: on ? color.accentPrimary : color.lineStrong, cursor: "pointer", transition: ease }}
    >
      <span
        style={{
          position: "absolute", top: space[25], left: space[25], width: size.toggleKnob, height: size.toggleKnob, borderRadius: radius.full,
          background: color.surfaceRaised, boxShadow: shadow.raised, transition: `transform ${fast}`,
          transform: on ? `translateX(calc(${size.toggleWidth} - ${size.toggleKnob} - ${space[25]} - ${space[25]}))` : undefined,
        }}
      />
    </span>
  );
}

/** Single-line text field with an optional leading icon and trailing slot. */
export function TextField({
  value, placeholder, onChange, icon, trailing, autoFocus, width, mono,
}: { value: string; placeholder?: string; onChange?: (v: string) => void; icon?: IconName; trailing?: ReactNode; autoFocus?: boolean; width?: string; mono?: boolean }) {
  const [focus, setFocus] = useState(false);
  return (
    <label
      style={{
        display: "flex", alignItems: "center", gap: space[100], flex: width ? "none" : 1, width, minWidth: 0,
        minHeight: size.controlMd, padding: `0 ${space[150]}`, borderRadius: radius.control, background: color.surfaceRaised,
        border: hairline(focus ? color.accentPrimary : color.lineStrong), boxShadow: focus ? `0 0 0 ${size.strokeFocus} ${color.accentSoft}` : undefined,
        transition: ease, cursor: "text",
      }}
    >
      {icon && <Icon name={icon} size="sm" color={color.inkTertiary} />}
      <input
        value={value}
        placeholder={placeholder}
        autoFocus={autoFocus}
        readOnly={!onChange}
        onFocus={() => setFocus(true)}
        onBlur={() => setFocus(false)}
        onChange={(e) => onChange?.(e.target.value)}
        style={{ flex: 1, minWidth: 0, ...(mono ? type.caption : type.body), color: color.inkPrimary, background: "transparent", border: "none", outline: "none", padding: 0 }}
      />
      {trailing}
    </label>
  );
}

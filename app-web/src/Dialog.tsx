// Modal frame shared by settings, export, project dialogs: centered card on medium+, full screen on compact.
import { useEffect, useRef, useState, type CSSProperties, type HTMLAttributes, type KeyboardEvent, type ReactNode } from "react";
import { color, pane, radius, shadow, size, space, type, IconButton } from "@ithaca/kit";
import { useApp, useT } from "./ctx";

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
const focusables = (root: HTMLElement) =>
  [...root.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => !el.hidden && el.getClientRects().length > 0);

/** Focus handling for a modal: move focus in on open, keep Tab inside, give focus back on close. */
function useModalFocus() {
  const card = useRef<HTMLDivElement>(null);
  // Read during the first render — before any child's autoFocus runs in the commit phase.
  const [opener] = useState(() => (typeof document === "undefined" ? null : (document.activeElement as HTMLElement | null)));
  useEffect(() => {
    const root = card.current;
    if (root && !root.contains(document.activeElement)) {
      const all = focusables(root);
      // Prefer the first control in the body over the header's close button.
      const header = root.querySelector("header");
      (all.find((el) => !header?.contains(el)) ?? all[0] ?? root).focus();
    }
    return () => {
      // Back to the manuscript when there is one — closing a dialog means "keep writing". Otherwise the opener.
      const editor = document.getElementById("ithaca-editor");
      const back = editor ?? (opener && opener !== document.body && opener.isConnected ? opener : null);
      // After React has removed the dialog. A StrictMode re-run keeps the same node mounted, so skip that case.
      requestAnimationFrame(() => { if (!root?.isConnected) back?.focus(); });
    };
  }, [opener]);
  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key !== "Tab" || !card.current) return;
    const all = focusables(card.current);
    if (!all.length) return e.preventDefault();
    const first = all[0], last = all[all.length - 1];
    const at = document.activeElement;
    if (e.shiftKey && (at === first || !card.current.contains(at))) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && (at === last || !card.current.contains(at))) {
      e.preventDefault();
      first.focus();
    }
  };
  return { card, onKeyDown };
}

// Keyboard focus ring for app-web's own clickable rows (the kit controls draw theirs). Same rule as the kit:
// a ring only when focus came from the keyboard.
let keyboardModality = false;
if (typeof window !== "undefined") {
  window.addEventListener("keydown", () => { keyboardModality = true; }, true);
  window.addEventListener("pointerdown", () => { keyboardModality = false; }, true);
}

/** Props that make a clickable div keyboard-operable: tab stop, Enter/Space, focus ring. Merge `style`. */
export function usePressable(onPress: () => void) {
  const [ring, setRing] = useState(false);
  return {
    tabIndex: 0,
    onClick: onPress,
    onFocus: () => setRing(keyboardModality),
    onBlur: () => setRing(false),
    onKeyDown: (e: KeyboardEvent) => {
      if ((e.key !== "Enter" && e.key !== " ") || e.nativeEvent.isComposing) return;
      e.preventDefault();
      e.stopPropagation();
      onPress();
    },
    ringStyle: (ring ? { outline: `${size.strokeFocus} solid ${color.accentPrimary}`, outlineOffset: `calc(-1 * ${size.strokeFocus})` } : { outline: "none" }) as CSSProperties,
  };
}

/** Scrolling dialog body. Children keep their natural height and the body scrolls, instead of squashing them. */
export function DialogBody({ children, style, ...rest }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div {...rest} style={{ flex: "1 1 auto", minHeight: 0, overflow: "auto", ...style }}>
      <div style={{ display: "flex", flexDirection: "column", gap: space[300], padding: space[300] }}>{children}</div>
    </div>
  );
}

export function Dialog({ title, children, footer, wide }: { title: string; children: ReactNode; footer?: ReactNode; wide?: boolean }) {
  const t = useT();
  const { sizeClass, setOverlay } = useApp();
  const compact = sizeClass === "compact";
  const close = () => setOverlay(null);
  const { card, onKeyDown } = useModalFocus();
  return (
    <div style={{ position: "absolute", inset: 0, zIndex: 20, display: "flex", alignItems: compact ? "stretch" : "center", justifyContent: "center", padding: compact ? 0 : space[300] }}>
      <div style={{ position: "absolute", inset: 0, background: color.surfaceScrim }} onClick={close} />
      <div
        ref={card}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        onKeyDown={onKeyDown}
        style={{
          outline: "none",
          position: "relative", display: "flex", flexDirection: "column", background: color.surfaceCanvas, overflow: "hidden",
          ...(compact ? { flex: 1 } : { width: wide ? `calc(${pane.dialog} + ${pane.library})` : pane.dialog, maxWidth: "100%", maxHeight: "100%", borderRadius: radius.sheet, boxShadow: shadow.dialog, border: hairline(color.lineSubtle) }),
        }}
      >
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[150]} 0 ${space[300]}`, borderBottom: hairline(color.lineSubtle) }}>
          <span style={{ ...type.heading, flex: 1, minWidth: 0 }}>{title}</span>
          <IconButton icon="close" label={t("action.close")} onClick={close} />
        </header>
        {children}
        {footer && (
          <footer style={{ flex: "none", display: "flex", gap: space[100], justifyContent: "flex-end", flexWrap: "wrap", padding: `${space[150]} ${space[300]}`, borderTop: hairline(color.lineSubtle) }}>{footer}</footer>
        )}
      </div>
    </div>
  );
}

/** Grouped settings rows (same look as the preferences prototype). */
export function Group({ children }: { children: ReactNode }) {
  return <div style={{ borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceRaised, overflow: "hidden" }}>{children}</div>;
}

export function Row({ label, hint, column, divided, children }: { label: string; hint?: string; column?: boolean; divided?: boolean; children?: ReactNode }) {
  return (
    <div style={{ display: "flex", flexDirection: column ? "column" : "row", alignItems: column ? "stretch" : "center", gap: space[150], padding: space[200], borderTop: divided ? hairline(color.lineSubtle) : undefined, flexWrap: column ? undefined : "wrap" }}>
      <div style={{ flex: "1 1 auto", minWidth: 0 }}>
        <div style={type.body}>{label}</div>
        {hint && <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[25] }}>{hint}</div>}
      </div>
      {children}
    </div>
  );
}

export function Label({ children }: { children: ReactNode }) {
  return <div style={{ ...type.label, color: color.inkTertiary, padding: `0 ${space[50]}`, marginBottom: space[100] }}>{children}</div>;
}

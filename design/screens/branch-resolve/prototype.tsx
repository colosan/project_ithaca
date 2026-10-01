// branch-resolve prototype — ADR-0002 §5: resolve an offline branch copy by editing both sides, not by picking one.
import type { ReactNode } from "react";
import { color, editor, radius, size, space, type, useFrame, useT } from "@ithaca/kit";

export const states = ["default"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

type Pair = { main: string | null; copy: string | null; same: boolean };

function pairsOf(main: (string | null)[], copy: (string | null)[]): Pair[] {
  return main.map((m, i) => ({ main: m, copy: copy[i], same: m === copy[i] }));
}

/** Character-level highlight: common prefix/suffix stay plain, the middle is marked. Enough for a prototype. */
function Highlighted({ text, other, tone }: { text: string; other: string | null; tone: string }) {
  if (other === null) return <>{text}</>;
  let start = 0;
  while (start < text.length && start < other.length && text[start] === other[start]) start++;
  let end = 0;
  while (end < text.length - start && end < other.length - start && text[text.length - 1 - end] === other[other.length - 1 - end]) end++;
  return (
    <>
      {text.slice(0, start)}
      <mark style={{ background: tone, color: "inherit", borderRadius: radius.piece }}>{text.slice(start, text.length - end)}</mark>
      {text.slice(text.length - end)}
    </>
  );
}

function Para({ text, heading }: { text: string; heading?: boolean }) {
  return heading ? (
    <span style={type.editorHeading}>
      <span style={{ color: color.inkMarkup }}># </span>
      {text.slice(2)}
    </span>
  ) : (
    <span style={type.editorBody}>{text}</span>
  );
}

export default function BranchResolve({ state: _state }: { state: State }) {
  const { sizeClass, sample } = useFrame();
  const pairs = pairsOf(sample.branch.main, sample.branch.copy);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body }}>
      <Header total={pairs.filter((p) => !p.same).length} />
      {sizeClass === "compact" ? <SwipeCards pairs={pairs} /> : <SideBySide pairs={pairs} />}
    </div>
  );
}

function Header({ total }: { total: number }) {
  const t = useT();
  const { sample, sizeClass } = useFrame();
  const b = sample.branch;
  return (
    <header style={{ flex: "none", padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle), display: "flex", flexWrap: "wrap", alignItems: "center", gap: space[150] }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={type.heading}>⚠ {t("branch.title")}</div>
        <div style={{ ...type.caption, color: color.inkSecondary }}>{t("branch.subtitle", { device: b.device, minutes: b.minutesAgo })}</div>
      </div>
      <span style={{ ...type.caption, color: color.inkTertiary }}>{t("branch.progress", { done: 0, total })}</span>
      <div style={{ display: "flex", gap: space[100], width: sizeClass === "compact" ? "100%" : undefined }}>
        <Button>{t("branch.later")}</Button>
        <Button primary>{t("branch.resolve")}</Button>
      </div>
    </header>
  );
}

function Button({ children, primary }: { children: ReactNode; primary?: boolean }) {
  return (
    <span
      style={{
        flex: 1, textAlign: "center", ...type.label, padding: `${space[100]} ${space[200]}`, borderRadius: radius.piece,
        background: primary ? color.accentPrimary : "transparent",
        color: primary ? color.inkOnAccent : color.inkSecondary,
        border: hairline(primary ? color.accentPrimary : color.lineStrong),
      }}
    >
      {children}
    </span>
  );
}

// ── medium+ : two editable columns, rows aligned by paragraph ────────────

function SideBySide({ pairs }: { pairs: Pair[] }) {
  const t = useT();
  const col = { flex: 1, minWidth: 0 };
  return (
    <div style={{ flex: 1, overflow: "hidden", padding: `${space[200]} ${space[300]}` }}>
      <div style={{ display: "flex", gap: space[300], ...type.label, color: color.inkTertiary, marginBottom: space[150] }}>
        <div style={col}>{t("branch.main")}</div>
        <div style={col}>{t("branch.copy")}</div>
      </div>
      {pairs.map((p, i) => {
        const heading = (p.main ?? p.copy ?? "").startsWith("# ");
        if (p.same) {
          return (
            <div key={i} style={{ display: "flex", gap: space[300], marginBottom: space[150], color: color.inkTertiary }}>
              <div style={col}><Para text={p.main!} heading={heading} /></div>
              <div style={col}><Para text={p.copy!} heading={heading} /></div>
            </div>
          );
        }
        return (
          <div key={i} style={{ display: "flex", gap: space[300], marginBottom: space[150] }}>
            <Cell present={p.main !== null}>
              {p.main !== null && <Highlighted text={p.main} other={p.copy} tone={color.accentSoft} />}
            </Cell>
            <Cell present={p.copy !== null} copySide>
              {p.copy !== null && <Highlighted text={p.copy} other={p.main} tone={color.accentSoft} />}
              <div style={{ display: "flex", gap: space[100], marginTop: space[100], ...type.label }}>
                <span style={{ color: color.accentPrimary }}>{t("branch.bringOver")}</span>
                <span style={{ color: color.inkTertiary }}>· {p.main === null ? t("branch.onlyHere") : t("branch.changed")}</span>
              </div>
            </Cell>
          </div>
        );
      })}
    </div>
  );
}

function Cell({ children, present, copySide }: { children: ReactNode; present: boolean; copySide?: boolean }) {
  return (
    <div
      style={{
        flex: 1, minWidth: 0, ...type.editorBody, padding: space[150], borderRadius: radius.panel,
        border: hairline(present ? color.stateWarning : color.lineSubtle),
        background: present ? (copySide ? color.surfaceList : color.surfaceRaised) : "transparent",
        maxWidth: editor.measure,
      }}
    >
      {children}
    </div>
  );
}

// ── compact : one changed paragraph per card, swipe between current/copy ─

function SwipeCards({ pairs }: { pairs: Pair[] }) {
  const t = useT();
  const changed = pairs.filter((p) => !p.same);
  const p = changed[0];
  return (
    <div style={{ flex: 1, overflow: "hidden", padding: space[200], display: "flex", flexDirection: "column", gap: space[200] }}>
      <div style={{ display: "flex", ...type.label, borderRadius: radius.piece, border: hairline(color.lineStrong), overflow: "hidden" }}>
        <span style={{ flex: 1, textAlign: "center", padding: space[100], background: color.surfaceSelected }}>{t("branch.main")}</span>
        <span style={{ flex: 1, textAlign: "center", padding: space[100], color: color.inkSecondary }}>{t("branch.copy")}</span>
      </div>
      <div style={{ padding: space[200], borderRadius: radius.panel, border: hairline(color.stateWarning), background: color.surfaceRaised, ...type.editorBody }}>
        {p.main !== null ? <Highlighted text={p.main} other={p.copy} tone={color.accentSoft} /> : <span style={{ color: color.inkTertiary }}>—</span>}
      </div>
      <div style={{ padding: space[200], borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceList, ...type.editorBody, color: color.inkSecondary }}>
        {p.copy !== null && <Highlighted text={p.copy} other={p.main} tone={color.accentSoft} />}
        <div style={{ marginTop: space[100], ...type.label, color: color.accentPrimary }}>{t("branch.bringOver")}</div>
      </div>
      <div style={{ display: "flex", justifyContent: "center", gap: space[100], color: color.inkTertiary }}>
        {changed.map((_, i) => (
          <span key={i} style={{ color: i === 0 ? color.accentPrimary : color.inkMarkup }}>●</span>
        ))}
      </div>
    </div>
  );
}

// branch-resolve prototype — ADR-0002 §5: resolve an offline branch copy by editing both sides, not by picking one.
// Interactive: bring a copy paragraph over or keep the current one; finishing is enabled once every pair is resolved.
import { useState, type ReactNode } from "react";
import { color, editor, opacity, radius, size, space, type, useFrame, useNavigate, useT } from "@ithaca/kit";

export const states = ["default"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const clickable = { cursor: "pointer" } as const;

type Pair = { main: string | null; copy: string | null };

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

function Para({ text }: { text: string }) {
  return text.startsWith("# ") ? (
    <span style={type.editorHeading}>
      <span style={{ color: color.inkMarkup }}># </span>
      {text.slice(2)}
    </span>
  ) : (
    <span style={type.editorBody}>{text}</span>
  );
}

/** Resolution state shared by both layouts. */
interface Resolver {
  pairs: Pair[];
  changed: number[]; // indices of pairs that differ
  resolved: Set<number>;
  bringOver: (i: number) => void;
  keepMain: (i: number) => void;
}

export default function BranchResolve({ state: _state }: { state: State }) {
  const { sizeClass, sample } = useFrame();
  const [main, setMain] = useState(sample.branch.main);
  const [resolved, setResolved] = useState<Set<number>>(new Set());
  const pairs: Pair[] = main.map((m, i) => ({ main: m, copy: sample.branch.copy[i] }));
  const changed = sample.branch.main.map((m, i) => i).filter((i) => sample.branch.main[i] !== sample.branch.copy[i]);
  const resolver: Resolver = {
    pairs,
    changed,
    resolved,
    bringOver: (i) => {
      setMain((m) => m.map((p, j) => (j === i ? sample.branch.copy[i] : p)));
      setResolved((r) => new Set(r).add(i));
    },
    keepMain: (i) => setResolved((r) => new Set(r).add(i)),
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body }}>
      <Header done={resolved.size} total={changed.length} />
      {sizeClass === "compact" ? <SwipeCards r={resolver} /> : <SideBySide r={resolver} />}
    </div>
  );
}

function Header({ done, total }: { done: number; total: number }) {
  const t = useT();
  const go = useNavigate();
  const { sample, sizeClass } = useFrame();
  const b = sample.branch;
  const complete = done === total;
  return (
    <header style={{ flex: "none", padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle), display: "flex", flexWrap: "wrap", alignItems: "center", gap: space[150] }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={type.heading}>⚠ {t("branch.title")}</div>
        <div style={{ ...type.caption, color: color.inkSecondary }}>{t("branch.subtitle", { device: b.device, minutes: b.minutesAgo })}</div>
      </div>
      <span style={{ ...type.caption, color: complete ? color.stateSuccess : color.inkTertiary }}>{t("branch.progress", { done, total })}</span>
      <div style={{ display: "flex", gap: space[100], width: sizeClass === "compact" ? "100%" : undefined }}>
        <Button onClick={() => go("app-shell")}>{t("branch.later")}</Button>
        <Button primary disabled={!complete} onClick={() => complete && go("app-shell")}>{t("branch.resolve")}</Button>
      </div>
    </header>
  );
}

function Button({ children, primary, disabled, onClick }: { children: ReactNode; primary?: boolean; disabled?: boolean; onClick?: () => void }) {
  return (
    <span
      onClick={onClick}
      style={{
        flex: 1, textAlign: "center", ...type.label, padding: `${space[100]} ${space[200]}`, borderRadius: radius.piece,
        background: primary ? color.accentPrimary : "transparent",
        color: primary ? color.inkOnAccent : color.inkSecondary,
        border: hairline(primary ? color.accentPrimary : color.lineStrong),
        opacity: disabled ? opacity.disabled : undefined,
        cursor: disabled ? "default" : "pointer",
      }}
    >
      {children}
    </span>
  );
}

/** "← Bring over · Keep current", or a resolved mark once decided. */
function Actions({ r, i }: { r: Resolver; i: number }) {
  const t = useT();
  if (r.resolved.has(i)) return <div style={{ marginTop: space[100], ...type.label, color: color.stateSuccess }}>✓ {t("branch.resolved")}</div>;
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: space[150], marginTop: space[100], ...type.label }}>
      <span style={{ color: color.accentPrimary, ...clickable }} onClick={() => r.bringOver(i)}>{t("branch.bringOver")}</span>
      <span style={{ color: color.inkSecondary, ...clickable }} onClick={() => r.keepMain(i)}>{t("branch.keepMain")}</span>
      <span style={{ color: color.inkTertiary }}>· {r.pairs[i].main === null ? t("branch.onlyHere") : t("branch.changed")}</span>
    </div>
  );
}

// ── medium+ : two editable columns, rows aligned by paragraph ────────────

function SideBySide({ r }: { r: Resolver }) {
  const t = useT();
  const col = { flex: 1, minWidth: 0 };
  return (
    <div style={{ flex: 1, overflow: "hidden", padding: `${space[200]} ${space[300]}` }}>
      <div style={{ display: "flex", gap: space[300], ...type.label, color: color.inkTertiary, marginBottom: space[150] }}>
        <div style={col}>{t("branch.main")}</div>
        <div style={col}>{t("branch.copy")}</div>
      </div>
      {r.pairs.map((p, i) => {
        if (!r.changed.includes(i)) {
          return (
            <div key={i} style={{ display: "flex", gap: space[300], marginBottom: space[150], color: color.inkTertiary }}>
              <div style={col}><Para text={p.main!} /></div>
              <div style={col}><Para text={p.copy!} /></div>
            </div>
          );
        }
        const done = r.resolved.has(i);
        return (
          <div key={i} style={{ display: "flex", gap: space[300], marginBottom: space[150] }}>
            <Cell present={p.main !== null} done={done}>
              {p.main !== null && (done ? p.main : <Highlighted text={p.main} other={p.copy} tone={color.accentSoft} />)}
            </Cell>
            <Cell present={p.copy !== null} done={done} copySide>
              {p.copy !== null && (done ? p.copy : <Highlighted text={p.copy} other={p.main} tone={color.accentSoft} />)}
              <Actions r={r} i={i} />
            </Cell>
          </div>
        );
      })}
    </div>
  );
}

function Cell({ children, present, done, copySide }: { children: ReactNode; present: boolean; done: boolean; copySide?: boolean }) {
  return (
    <div
      style={{
        flex: 1, minWidth: 0, ...type.editorBody, padding: space[150], borderRadius: radius.panel,
        border: hairline(done ? color.stateSuccess : present ? color.stateWarning : color.lineSubtle),
        background: present ? (copySide ? color.surfaceList : color.surfaceRaised) : "transparent",
        maxWidth: editor.measure,
      }}
    >
      {children}
    </div>
  );
}

// ── compact : one changed paragraph per card; tabs switch side, arrows/dots move ─

function SwipeCards({ r }: { r: Resolver }) {
  const t = useT();
  const [at, setAt] = useState(0);
  const [side, setSide] = useState<"main" | "copy">("main");
  const i = r.changed[at];
  const p = r.pairs[i];
  const shown = side === "main" ? p.main : p.copy;
  const other = side === "main" ? p.copy : p.main;
  const tab = (s: "main" | "copy", label: string) => (
    <span
      onClick={() => setSide(s)}
      style={{ flex: 1, textAlign: "center", padding: space[100], background: side === s ? color.surfaceSelected : "transparent", color: side === s ? color.inkPrimary : color.inkSecondary, ...clickable }}
    >
      {label}
    </span>
  );
  return (
    <div style={{ flex: 1, overflow: "hidden", padding: space[200], display: "flex", flexDirection: "column", gap: space[200] }}>
      <div style={{ display: "flex", ...type.label, borderRadius: radius.piece, border: hairline(color.lineStrong), overflow: "hidden" }}>
        {tab("main", t("branch.main"))}
        {tab("copy", t("branch.copy"))}
      </div>
      <div style={{ padding: space[200], borderRadius: radius.panel, border: hairline(r.resolved.has(i) ? color.stateSuccess : color.stateWarning), background: side === "main" ? color.surfaceRaised : color.surfaceList, ...type.editorBody }}>
        {shown !== null ? <Highlighted text={shown} other={r.resolved.has(i) ? shown : other} tone={color.accentSoft} /> : <span style={{ color: color.inkTertiary }}>—</span>}
        <Actions r={r} i={i} />
      </div>
      <div style={{ display: "flex", justifyContent: "center", alignItems: "center", gap: space[150], color: color.inkTertiary }}>
        <span style={{ ...clickable, opacity: at === 0 ? opacity.disabled : undefined }} onClick={() => setAt((a) => Math.max(0, a - 1))}>‹</span>
        {r.changed.map((ci, k) => (
          <span key={ci} style={{ color: k === at ? color.accentPrimary : r.resolved.has(ci) ? color.stateSuccess : color.inkMarkup, ...clickable }} onClick={() => setAt(k)}>
            ●
          </span>
        ))}
        <span style={{ ...clickable, opacity: at === r.changed.length - 1 ? opacity.disabled : undefined }} onClick={() => setAt((a) => Math.min(r.changed.length - 1, a + 1))}>›</span>
      </div>
    </div>
  );
}

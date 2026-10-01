// app-shell prototype. Rules: values from @ithaca/kit tokens only, copy via t() only (enforced by pnpm design:check).
import type { ReactNode } from "react";
import {
  color, editor, opacity, pane, radius, shadow, size, space, type,
  openContext, useFrame, useT, type SheetSummary, type SizeClass,
} from "@ithaca/kit";

export const states = ["default", "readonly", "reference"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

/** Which panes are docked at each size class (spec.md table). */
function panesFor(c: SizeClass) {
  return { library: c === "expanded" || c === "large", list: c !== "compact", dockedReference: c === "large" };
}

export default function AppShell({ state }: { state: State }) {
  const { sizeClass } = useFrame();
  const panes = panesFor(sizeClass);
  const showReference = state === "reference";
  return (
    <div style={{ position: "relative", display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body }}>
      {panes.library && <LibraryPane />}
      {panes.list && <SheetListPane />}
      <EditorPane readOnly={state === "readonly"} referenceOpen={showReference} />
      {showReference && panes.dockedReference && <ReferencePanel mode="docked" />}
      {showReference && !panes.dockedReference && <ReferencePanel mode={sizeClass === "compact" ? "sheet" : "overlay"} />}
    </div>
  );
}

// ── Library: projects → folders ─────────────────────────────────────────

function LibraryPane() {
  const t = useT();
  const { sample } = useFrame();
  const { project: open, folder: openFolder } = openContext(sample);
  return (
    <aside style={{ width: pane.library, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceSidebar, borderRight: hairline(color.lineSubtle) }}>
      <div style={{ ...type.label, color: color.inkTertiary, padding: `${space[200]} ${space[200]} ${space[100]}` }}>{t("library.title")}</div>
      <div style={{ flex: 1, overflow: "hidden", padding: `0 ${space[100]}` }}>
        {sample.projects.map((p) => (
          <div key={p.id} style={{ marginBottom: space[150] }}>
            <Row muted={p.id !== open.id}>
              <span style={{ color: color.inkTertiary }}>{p.id === open.id ? "▾" : "▸"}</span>
              <span style={{ ...type.label, flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{p.title}</span>
            </Row>
            {p.id === open.id &&
              p.folders.map((f) => (
                <Row key={f.id} active={f.id === openFolder.id} indent>
                  <span style={{ flex: 1 }}>{f.name}</span>
                  <span style={{ ...type.caption, color: color.inkTertiary }}>{f.sheets.length}</span>
                </Row>
              ))}
            {p.id === open.id && (
              <Row indent muted>
                <span style={type.caption}>＋ {t("folder.new")}</span>
              </Row>
            )}
          </div>
        ))}
      </div>
      <div style={{ ...type.label, color: color.inkSecondary, padding: space[200], borderTop: hairline(color.lineSubtle) }}>＋ {t("library.newProject")}</div>
    </aside>
  );
}

function Row({ children, active, muted, indent }: { children: ReactNode; active?: boolean; muted?: boolean; indent?: boolean }) {
  return (
    <div
      style={{
        display: "flex", alignItems: "center", gap: space[100],
        height: size.controlMd, padding: `0 ${space[100]}`, paddingLeft: indent ? space[300] : space[100],
        borderRadius: radius.piece,
        background: active ? color.surfaceSelected : "transparent",
        color: muted ? color.inkTertiary : active ? color.inkPrimary : color.inkSecondary,
      }}
    >
      {children}
    </div>
  );
}

// ── Sheet list ──────────────────────────────────────────────────────────

function SheetListPane() {
  const t = useT();
  const { sample } = useFrame();
  const { folder, sheet: openSheet } = openContext(sample);
  return (
    <section style={{ width: pane.sheetList, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceList, borderRight: hairline(color.lineSubtle) }}>
      <header style={{ height: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
        <span style={{ ...type.heading, flex: 1 }}>{folder.name}</span>
        <span style={{ ...type.caption, color: color.inkTertiary }}>{t("sheetList.count", { count: folder.sheets.length })}</span>
        <span style={{ ...type.label, color: color.inkSecondary }} title={t("sheet.new")}>＋</span>
      </header>
      <div style={{ flex: 1, overflow: "hidden" }}>
        {folder.sheets.map((s) => (
          <SheetRow key={s.id} sheet={s} active={s.id === openSheet.id} />
        ))}
      </div>
    </section>
  );
}

function SheetRow({ sheet, active }: { sheet: SheetSummary; active: boolean }) {
  const t = useT();
  return (
    <article style={{ minHeight: size.rowSheet, padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle), background: active ? color.surfaceSelected : "transparent" }}>
      <div style={{ ...type.body, fontWeight: type.heading.fontWeight, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{sheet.title}</div>
      <div style={{ ...type.caption, color: color.inkSecondary, marginTop: space[25], overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
        {sheet.excerpt}
      </div>
      <div style={{ display: "flex", gap: space[100], marginTop: space[50], ...type.caption, color: color.inkTertiary }}>
        <span>{t("count.withSpaces", { count: sheet.chars })}</span>
        {sheet.branched && <span style={{ color: color.stateWarning }}>⚠ {t("sheet.branched")}</span>}
      </div>
    </article>
  );
}

// ── Editor ──────────────────────────────────────────────────────────────

function EditorPane({ readOnly, referenceOpen }: { readOnly: boolean; referenceOpen: boolean }) {
  const t = useT();
  const { sizeClass, sample } = useFrame();
  const { folder } = openContext(sample);
  return (
    <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
      <header style={{ height: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[150], padding: `0 ${space[200]}`, color: color.inkSecondary, ...type.label }}>
        {sizeClass === "compact" && <span>‹ {folder.name}</span>}
        {sizeClass === "medium" && <span title={t("library.show")}>☰</span>}
        <span style={{ flex: 1 }} />
        <span
          style={{
            padding: `${space[25]} ${space[100]}`, borderRadius: radius.piece,
            background: referenceOpen ? color.accentSoft : "transparent",
            color: referenceOpen ? color.accentPrimary : color.inkSecondary,
          }}
        >
          ◫ {t("reference.open")}
        </span>
      </header>

      {readOnly && (
        <div style={{ display: "flex", alignItems: "center", gap: space[150], margin: `0 ${space[200]}`, padding: `${space[100]} ${space[150]}`, borderRadius: radius.panel, background: color.accentSoft, color: color.stateWarning, ...type.label }}>
          <span style={{ flex: 1 }}>⚠ {t("lease.banner", { device: "MacBook Air", minutes: 3 })}</span>
          <span style={{ padding: `${space[50]} ${space[150]}`, borderRadius: radius.piece, background: color.accentPrimary, color: color.inkOnAccent }}>
            {t("lease.takeOver")}
          </span>
        </div>
      )}

      <article style={{ flex: 1, overflow: "hidden", padding: `${space[300]} ${editor.paddingX[sizeClass]}`, opacity: readOnly ? opacity.readOnly : undefined }}>
        <Manuscript paragraphs={sample.openSheet.paragraphs} />
      </article>

      <EditorFooter readOnly={readOnly} />
    </main>
  );
}

function Manuscript({ paragraphs }: { paragraphs: string[] }) {
  return (
    <div style={{ maxWidth: editor.measure, margin: "0 auto" }}>
      {paragraphs.map((p, i) =>
        p.startsWith("# ") ? (
          <h1 key={i} style={{ ...type.editorHeading, margin: `0 0 ${space[300]}` }}>
            <span style={{ color: color.inkMarkup }}># </span>
            {p.slice(2)}
          </h1>
        ) : p.startsWith("- ") ? (
          <p key={i} style={{ ...type.editorBody, margin: `0 0 ${space[100]}` }}>
            <span style={{ color: color.inkMarkup }}>- </span>
            {p.slice(2)}
          </p>
        ) : (
          <p key={i} style={{ ...type.editorBody, margin: `0 0 ${space[200]}` }}>{p}</p>
        ),
      )}
    </div>
  );
}

/** Both character counts always; a goal bar only when the project sets a goal (project-settings). */
function EditorFooter({ readOnly }: { readOnly: boolean }) {
  const t = useT();
  const { sample } = useFrame();
  const { project, sheet } = openContext(sample);
  const goal = project.goal;
  const current = goal?.basis === "withoutSpaces" ? sheet.charsNoSpace : sheet.chars;
  const percent = goal ? Math.min(100, Math.round((current / goal.count) * 100)) : 0;
  return (
    <footer style={{ flex: "none", borderTop: hairline(color.lineSubtle), color: color.inkTertiary, ...type.caption }}>
      {goal && (
        <div style={{ height: size.strokeFocus, background: color.lineSubtle }}>
          <div style={{ height: "100%", width: `${percent}%`, background: percent >= 100 ? color.stateSuccess : color.accentPrimary }} />
        </div>
      )}
      <div style={{ height: size.controlMd, display: "flex", alignItems: "center", justifyContent: "center", gap: space[150], flexWrap: "wrap" }}>
        {readOnly && <span style={{ color: color.stateWarning }}>{t("lease.readOnly")}</span>}
        <span>{t("count.withSpaces", { count: sheet.chars })}</span>
        <span>{t("count.withoutSpaces", { count: sheet.charsNoSpace })}</span>
        {goal && <span style={{ color: color.inkSecondary }}>{t("goal.progress", { goal: goal.count, percent })}</span>}
      </div>
    </footer>
  );
}

// ── Reference panel: docked (large) · overlay (medium/expanded) · bottom sheet (compact) ──

function ReferencePanel({ mode }: { mode: "docked" | "overlay" | "sheet" }) {
  const t = useT();
  const { sample } = useFrame();
  const { reference } = openContext(sample);
  const frameStyle =
    mode === "docked"
      ? { width: pane.inspector, flex: "none", borderLeft: hairline(color.lineSubtle) }
      : mode === "overlay"
        ? { position: "absolute" as const, top: 0, right: 0, bottom: 0, width: pane.inspector, boxShadow: shadow.dialog, borderLeft: hairline(color.lineSubtle) }
        : { position: "absolute" as const, left: 0, right: 0, bottom: 0, height: "55%", boxShadow: shadow.dialog, borderTopLeftRadius: radius.sheet, borderTopRightRadius: radius.sheet };
  return (
    <>
      {mode === "sheet" && <div style={{ position: "absolute", inset: 0, background: color.surfaceScrim }} />}
      <aside style={{ ...frameStyle, display: "flex", flexDirection: "column", background: color.surfaceRaised, overflow: "hidden" }}>
        <header style={{ height: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
          <span style={{ ...type.label, color: color.inkTertiary }}>{t("reference.title")}</span>
          <span style={{ ...type.heading, flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{reference.title}</span>
          <span style={{ ...type.label, color: color.inkSecondary }} title={t("action.close")}>✕</span>
        </header>
        <div style={{ flex: 1, overflow: "hidden", padding: space[200] }}>
          {(reference.body ?? [reference.excerpt]).filter((p) => !p.startsWith("# ")).map((p, i) => (
            <p key={i} style={{ ...type.body, margin: `0 0 ${space[100]}`, color: color.inkPrimary }}>
              {p.startsWith("- ") ? <><span style={{ color: color.inkMarkup }}>- </span>{p.slice(2)}</> : p}
            </p>
          ))}
        </div>
      </aside>
    </>
  );
}

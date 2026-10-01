// app-shell prototype. Rules: values from @ithaca/kit tokens only, copy via t() only (enforced by pnpm design:check).
// Interactive: selection, panes and panels are local state; links to other screens go through useNavigate().
import { useState, type ReactNode } from "react";
import {
  color, editor, opacity, pane, radius, shadow, size, space, type,
  openContext, safePadding, useFrame, useNavigate, useT, type SheetSummary, type SizeClass,
} from "@ithaca/kit";

export const states = ["default", "readonly", "reference"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const clickable = { cursor: "pointer" } as const;

/** Which panes are docked at each size class (spec.md table). */
function panesFor(c: SizeClass) {
  return { library: c === "expanded" || c === "large", list: c !== "compact", dockedReference: c === "large" };
}

type CompactView = "editor" | "list" | "library";

/** Everything the panes share. Kept in one place so each pane stays a plain function of it. */
interface Shell {
  folderId: string;
  sheetId: string;
  readOnly: boolean;
  referenceOpen: boolean;
  selectFolder: (id: string) => void;
  selectSheet: (s: SheetSummary) => void;
  takeOver: () => void;
  toggleReference: () => void;
  toggleLibrary: () => void;
  showList: () => void;
  showLibrary: () => void;
}

export default function AppShell({ state }: { state: State }) {
  const { sizeClass, sample, safeArea } = useFrame();
  const go = useNavigate();
  const panes = panesFor(sizeClass);
  const start = openContext(sample);

  const [folderId, setFolderId] = useState(start.folder.id);
  const [sheetId, setSheetId] = useState(start.sheet.id);
  const [readOnly, setReadOnly] = useState(state === "readonly");
  const [referenceOpen, setReferenceOpen] = useState(state === "reference");
  const [libraryOverlay, setLibraryOverlay] = useState(false);
  const [compactView, setCompactView] = useState<CompactView>("editor");

  const shell: Shell = {
    folderId,
    sheetId,
    readOnly,
    referenceOpen,
    selectFolder: (id) => {
      setFolderId(id);
      const first = start.project.folders.find((f) => f.id === id)?.sheets[0];
      if (first) setSheetId(first.id);
      setLibraryOverlay(false);
      setCompactView("list");
    },
    selectSheet: (s) => {
      if (s.branched) return go("branch-resolve");
      setSheetId(s.id);
      setCompactView("editor");
    },
    takeOver: () => setReadOnly(false),
    toggleReference: () => setReferenceOpen((v) => !v),
    toggleLibrary: () => setLibraryOverlay((v) => !v),
    showList: () => setCompactView("list"),
    showLibrary: () => setCompactView("library"),
  };

  const root = { position: "relative" as const, display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) };

  if (sizeClass === "compact") {
    return (
      <div style={root}>
        {compactView === "library" && <LibraryPane shell={shell} full />}
        {compactView === "list" && <SheetListPane shell={shell} full />}
        {compactView === "editor" && <EditorPane shell={shell} />}
        {referenceOpen && compactView === "editor" && <ReferencePanel mode="sheet" onClose={shell.toggleReference} />}
      </div>
    );
  }
  return (
    <div style={root}>
      {panes.library && <LibraryPane shell={shell} />}
      {panes.list && <SheetListPane shell={shell} />}
      <EditorPane shell={shell} />
      {referenceOpen && <ReferencePanel mode={panes.dockedReference ? "docked" : "overlay"} onClose={shell.toggleReference} />}
      {libraryOverlay && !panes.library && (
        <>
          <div style={{ position: "absolute", inset: 0, background: color.surfaceScrim, ...clickable }} onClick={shell.toggleLibrary} />
          <div style={{ position: "absolute", top: safeArea.top, bottom: safeArea.bottom, left: safeArea.left, display: "flex", boxShadow: shadow.dialog }}>
            <LibraryPane shell={shell} />
          </div>
        </>
      )}
    </div>
  );
}

// ── Library: projects → folders ─────────────────────────────────────────

function LibraryPane({ shell, full }: { shell: Shell; full?: boolean }) {
  const t = useT();
  const go = useNavigate();
  const { sample } = useFrame();
  const { project: open } = openContext(sample);
  return (
    <aside style={{ width: full ? "100%" : pane.library, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceSidebar, borderRight: full ? undefined : hairline(color.lineSubtle) }}>
      <div style={{ ...type.label, color: color.inkTertiary, padding: `${space[200]} ${space[200]} ${space[100]}` }}>{t("library.title")}</div>
      <div style={{ flex: 1, overflow: "auto", padding: `0 ${space[100]}` }}>
        {sample.projects.map((p) => (
          <div key={p.id} style={{ marginBottom: space[150] }}>
            <Row muted={p.id !== open.id}>
              <span style={{ color: color.inkTertiary }}>{p.id === open.id ? "▾" : "▸"}</span>
              <span style={{ ...type.label, flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{p.title}</span>
              {p.id === open.id && (
                <span style={{ color: color.inkTertiary, ...clickable }} title={t("projectSettings.title")} onClick={() => go("project-settings")}>
                  ⋯
                </span>
              )}
            </Row>
            {p.id === open.id &&
              p.folders.map((f) => (
                <Row key={f.id} active={f.id === shell.folderId} indent onClick={() => shell.selectFolder(f.id)}>
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
      <div style={{ display: "flex", alignItems: "center", gap: space[100], ...type.label, color: color.inkSecondary, padding: space[200], borderTop: hairline(color.lineSubtle) }}>
        <span style={{ flex: 1, ...clickable }} onClick={() => go("new-project")}>＋ {t("library.newProject")}</span>
        <span style={clickable} title={t("prefs.title")} onClick={() => go("preferences#general")}>⚙</span>
      </div>
    </aside>
  );
}

function Row({ children, active, muted, indent, onClick }: { children: ReactNode; active?: boolean; muted?: boolean; indent?: boolean; onClick?: () => void }) {
  return (
    <div
      onClick={onClick}
      style={{
        display: "flex", alignItems: "center", gap: space[100],
        minHeight: size.controlMd, padding: `0 ${space[100]}`, paddingLeft: indent ? space[300] : space[100],
        borderRadius: radius.piece,
        background: active ? color.surfaceSelected : "transparent",
        color: muted ? color.inkTertiary : active ? color.inkPrimary : color.inkSecondary,
        cursor: onClick ? "pointer" : undefined,
      }}
    >
      {children}
    </div>
  );
}

// ── Sheet list ──────────────────────────────────────────────────────────

function SheetListPane({ shell, full }: { shell: Shell; full?: boolean }) {
  const t = useT();
  const { sample } = useFrame();
  const { project } = openContext(sample);
  const folder = project.folders.find((f) => f.id === shell.folderId)!;
  return (
    <section style={{ width: full ? "100%" : pane.sheetList, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceList, borderRight: full ? undefined : hairline(color.lineSubtle) }}>
      <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
        {full && <span style={{ ...type.label, color: color.inkSecondary, ...clickable }} onClick={shell.showLibrary}>‹</span>}
        <span style={{ ...type.heading, flex: 1 }}>{folder.name}</span>
        <span style={{ ...type.caption, color: color.inkTertiary }}>{t("sheetList.count", { count: folder.sheets.length })}</span>
        <span style={{ ...type.label, color: color.inkSecondary }} title={t("sheet.new")}>＋</span>
      </header>
      <div style={{ flex: 1, overflow: "auto" }}>
        {folder.sheets.map((s) => (
          <SheetRow key={s.id} sheet={s} active={s.id === shell.sheetId} onClick={() => shell.selectSheet(s)} />
        ))}
      </div>
    </section>
  );
}

function SheetRow({ sheet, active, onClick }: { sheet: SheetSummary; active: boolean; onClick: () => void }) {
  const t = useT();
  return (
    <article onClick={onClick} style={{ minHeight: size.rowSheet, padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle), background: active ? color.surfaceSelected : "transparent", ...clickable }}>
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

function EditorPane({ shell }: { shell: Shell }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, sample } = useFrame();
  const { project, sheet: openSheet } = openContext(sample);
  const folder = project.folders.find((f) => f.id === shell.folderId)!;
  const sheet = project.folders.flatMap((f) => f.sheets).find((s) => s.id === shell.sheetId) ?? openSheet;
  // Only the open sheet has full text in the fixture; other sheets show their title and first line.
  const paragraphs = sheet.id === openSheet.id ? sample.openSheet.paragraphs : sheet.body ?? [`# ${sheet.title}`, sheet.excerpt];
  return (
    <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
      <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[150], padding: `0 ${space[200]}`, color: color.inkSecondary, ...type.label }}>
        {sizeClass === "compact" && <span style={clickable} onClick={shell.showList}>‹ {folder.name}</span>}
        {sizeClass === "medium" && <span style={clickable} title={t("library.show")} onClick={shell.toggleLibrary}>☰</span>}
        <span style={{ flex: 1 }} />
        <span style={clickable} title={t("nav.history")} onClick={() => go("history")}>↺</span>
        <span
          onClick={shell.toggleReference}
          style={{
            padding: `${space[25]} ${space[100]}`, borderRadius: radius.piece, ...clickable,
            background: shell.referenceOpen ? color.accentSoft : "transparent",
            color: shell.referenceOpen ? color.accentPrimary : color.inkSecondary,
          }}
        >
          ◫ {t("reference.open")}
        </span>
      </header>

      {shell.readOnly && (
        <div style={{ display: "flex", alignItems: "center", gap: space[150], margin: `0 ${space[200]}`, padding: `${space[100]} ${space[150]}`, borderRadius: radius.panel, background: color.accentSoft, color: color.stateWarning, ...type.label }}>
          <span style={{ flex: 1 }}>⚠ {t("lease.banner", { device: "MacBook Air", minutes: 3 })}</span>
          <span onClick={shell.takeOver} style={{ padding: `${space[50]} ${space[150]}`, borderRadius: radius.piece, background: color.accentPrimary, color: color.inkOnAccent, ...clickable }}>
            {t("lease.takeOver")}
          </span>
        </div>
      )}

      <article style={{ flex: 1, overflow: "auto", padding: `${space[300]} ${editor.paddingX[sizeClass]}`, opacity: shell.readOnly ? opacity.readOnly : undefined }}>
        <Manuscript paragraphs={paragraphs} />
      </article>

      <EditorFooter sheet={sheet} readOnly={shell.readOnly} />
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
function EditorFooter({ sheet, readOnly }: { sheet: SheetSummary; readOnly: boolean }) {
  const t = useT();
  const { sample } = useFrame();
  const { project } = openContext(sample);
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
      <div style={{ minHeight: size.controlMd, display: "flex", alignItems: "center", justifyContent: "center", gap: space[150], flexWrap: "wrap" }}>
        {readOnly && <span style={{ color: color.stateWarning }}>{t("lease.readOnly")}</span>}
        <span>{t("count.withSpaces", { count: sheet.chars })}</span>
        <span>{t("count.withoutSpaces", { count: sheet.charsNoSpace })}</span>
        {goal && <span style={{ color: color.inkSecondary }}>{t("goal.progress", { goal: goal.count, percent })}</span>}
      </div>
    </footer>
  );
}

// ── Reference panel: docked (large) · overlay (medium/expanded) · bottom sheet (compact) ──

function ReferencePanel({ mode, onClose }: { mode: "docked" | "overlay" | "sheet"; onClose: () => void }) {
  const t = useT();
  const { sample, safeArea } = useFrame();
  const { reference } = openContext(sample);
  const frameStyle =
    mode === "docked"
      ? { width: pane.inspector, flex: "none", borderLeft: hairline(color.lineSubtle) }
      : mode === "overlay"
        ? { position: "absolute" as const, top: safeArea.top, right: safeArea.right, bottom: safeArea.bottom, width: pane.inspector, boxShadow: shadow.dialog, borderLeft: hairline(color.lineSubtle) }
        : { position: "absolute" as const, left: 0, right: 0, bottom: 0, height: "55%", paddingBottom: safeArea.bottom, boxShadow: shadow.dialog, borderTopLeftRadius: radius.sheet, borderTopRightRadius: radius.sheet };
  return (
    <>
      {mode === "sheet" && <div style={{ position: "absolute", inset: 0, background: color.surfaceScrim, ...clickable }} onClick={onClose} />}
      <aside style={{ ...frameStyle, display: "flex", flexDirection: "column", background: color.surfaceRaised, overflow: "hidden" }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
          <span style={{ ...type.label, color: color.inkTertiary }}>{t("reference.title")}</span>
          <span style={{ ...type.heading, flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{reference.title}</span>
          <span style={{ ...type.label, color: color.inkSecondary, ...clickable }} title={t("action.close")} onClick={onClose}>✕</span>
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>
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

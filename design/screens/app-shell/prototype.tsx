// app-shell prototype. Rules: values from @ithaca/kit tokens only, copy via t() only (enforced by pnpm design:check).
// Interactive: selection, panes, panels, focus mode and new sheets are local state; links to other screens go through useNavigate().
import { useState, type ReactNode } from "react";
import {
  color, editor, opacity, pane, radius, shadow, size, space, type,
  Button, Chip, Icon, IconButton,
  Segmented, isDesktop, openContext, safePadding, useFrame, useNavigate, useT, type SheetSummary, type SizeClass,
} from "@ithaca/kit";

export const states = ["default", "readonly", "reference", "info", "focus"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const clickable = { cursor: "pointer" } as const;

/** Which panes are docked at each size class (spec.md table). */
function panesFor(c: SizeClass) {
  return { library: c === "expanded" || c === "large", list: c !== "compact", dockedReference: c === "large" };
}

type CompactView = "editor" | "list" | "library";
/** The right-hand panel: lore reference, sheet statistics, or the sheet's outline. */
type InspectorTab = "reference" | "info" | "outline";

/** Everything the panes share. Kept in one place so each pane stays a plain function of it. */
interface Shell {
  folderId: string;
  sheetId: string;
  readOnly: boolean;
  inspector: InspectorTab | null;
  focus: boolean;
  sheets: (folderId: string) => SheetSummary[];
  selectFolder: (id: string) => void;
  selectSheet: (s: SheetSummary) => void;
  takeOver: () => void;
  toggleInspector: () => void;
  setInspectorTab: (tab: InspectorTab) => void;
  toggleFocus: () => void;
  newSheet: () => void;
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
  const [inspector, setInspector] = useState<InspectorTab | null>(state === "reference" ? "reference" : state === "info" ? "info" : null);
  const [focus, setFocus] = useState(state === "focus");
  const [added, setAdded] = useState<Record<string, SheetSummary[]>>({}); // sheets made in this session, per folder
  const [libraryOverlay, setLibraryOverlay] = useState(false);
  const [compactView, setCompactView] = useState<CompactView>("editor");

  const shell: Shell = {
    folderId,
    sheetId,
    readOnly,
    inspector,
    focus,
    sheets: (id) => [...(added[id] ?? []), ...(start.project.folders.find((f) => f.id === id)?.sheets ?? [])],
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
    toggleInspector: () => setInspector((v) => (v ? null : "reference")),
    setInspectorTab: setInspector,
    toggleFocus: () => setFocus((v) => !v),
    newSheet: () => {
      const id = `new-${folderId}-${(added[folderId]?.length ?? 0) + 1}`;
      setAdded((a) => ({ ...a, [folderId]: [{ id, title: "", excerpt: "", chars: 0, charsNoSpace: 0, body: [] }, ...(a[folderId] ?? [])] }));
      setSheetId(id);
      setCompactView("editor");
    },
    toggleLibrary: () => setLibraryOverlay((v) => !v),
    showList: () => setCompactView("list"),
    showLibrary: () => setCompactView("library"),
  };

  const root = { position: "relative" as const, display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) };

  // Focus mode: the editor alone at every size class, panels closed.
  if (focus) {
    return (
      <div style={root}>
        <EditorPane shell={shell} />
      </div>
    );
  }
  if (sizeClass === "compact") {
    return (
      <div style={root}>
        {compactView === "library" && <LibraryPane shell={shell} full />}
        {compactView === "list" && <SheetListPane shell={shell} full />}
        {compactView === "editor" && <EditorPane shell={shell} />}
        {inspector && compactView === "editor" && <Inspector mode="sheet" shell={shell} />}
      </div>
    );
  }
  return (
    <div style={root}>
      {panes.library && <LibraryPane shell={shell} />}
      {panes.list && <SheetListPane shell={shell} />}
      <EditorPane shell={shell} />
      {inspector && <Inspector mode={panes.dockedReference ? "docked" : "overlay"} shell={shell} />}
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
              <Icon name={p.id === open.id ? "expanded" : "collapsed"} size="sm" color={color.inkTertiary} />
              <span style={{ ...type.label, fontWeight: type.heading.fontWeight, flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{p.title}</span>
              {p.id === open.id && <IconButton icon="more" label={t("projectSettings.title")} onClick={() => go("project-settings")} />}
            </Row>
            {p.id === open.id &&
              p.folders.map((f) => (
                <Row key={f.id} active={f.id === shell.folderId} indent onClick={() => shell.selectFolder(f.id)}>
                  <Icon name="folder" size="sm" color={f.id === shell.folderId ? color.accentPrimary : color.inkTertiary} />
                  <span style={{ flex: 1 }}>{f.name}</span>
                  <span style={{ ...type.caption, color: color.inkTertiary }}>{f.sheets.length}</span>
                </Row>
              ))}
            {p.id === open.id && (
              <Row indent muted>
                <Icon name="add" size="sm" />
                <span style={type.caption}>{t("folder.new")}</span>
              </Row>
            )}
          </div>
        ))}
        <Row onClick={() => go("trash")} muted>
          <Icon name="trash" size="sm" />
          <span style={{ flex: 1 }}>{t("trash.title")}</span>
        </Row>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: space[100], padding: space[100], borderTop: hairline(color.lineSubtle) }}>
        <Button variant="ghost" icon="add" onClick={() => go("new-project#default")}>{t("library.newProject")}</Button>
        <span style={{ flex: 1 }} />
        <IconButton icon="settings" label={t("prefs.title")} onClick={() => go("preferences#general")} />
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
        borderRadius: radius.control,
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
  const go = useNavigate();
  const { sample } = useFrame();
  const { project } = openContext(sample);
  const folder = project.folders.find((f) => f.id === shell.folderId)!;
  const sheets = shell.sheets(folder.id);
  return (
    <section style={{ width: full ? "100%" : pane.sheetList, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceList, borderRight: full ? undefined : hairline(color.lineSubtle) }}>
      <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
        {full && <IconButton icon="back" label={t("library.title")} onClick={shell.showLibrary} />}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ ...type.heading, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{folder.name}</div>
          <div style={{ ...type.caption, color: color.inkTertiary }}>{t("sheetList.count", { count: sheets.length })}</div>
        </div>
        <IconButton icon="search" label={t("search.title")} onClick={() => go("search#empty")} />
        <IconButton icon="add" label={t("sheet.new")} onClick={shell.newSheet} />
      </header>
      <div style={{ flex: 1, overflow: "auto" }}>
        {sheets.length === 0 && <div style={{ padding: space[300], ...type.caption, color: color.inkTertiary, textAlign: "center" }}>{t("sheetList.empty")}</div>}
        {sheets.map((s) => (
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
      <div style={{ ...type.body, fontWeight: type.heading.fontWeight, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: sheet.title ? undefined : color.inkTertiary }}>{sheet.title || t("sheet.untitled")}</div>
      <div style={{ ...type.caption, color: color.inkSecondary, marginTop: space[25], overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
        {sheet.excerpt}
      </div>
      <div style={{ display: "flex", gap: space[100], marginTop: space[50], ...type.caption, color: color.inkTertiary }}>
        <span>{t("count.withSpaces", { count: sheet.chars })}</span>
        {sheet.branched && (
          <span style={{ display: "inline-flex", alignItems: "center", gap: space[50], color: color.stateWarning }}>
            <Icon name="warning" size="sm" />
            {t("sheet.branched")}
          </span>
        )}
      </div>
    </article>
  );
}

// ── Editor ──────────────────────────────────────────────────────────────

/** The paragraph the caret sits in — focus mode keeps it at full strength and dims the rest. */
const CARET_PARAGRAPH = 2;

function EditorPane({ shell }: { shell: Shell }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, sample, platform } = useFrame();
  const { project } = openContext(sample);
  const folder = project.folders.find((f) => f.id === shell.folderId)!;
  const sheet = sheetById(shell, sample);
  const paragraphs = paragraphsOf(sheet, sample);
  const bar = { minHeight: size.barTop, flex: "none" as const, display: "flex", alignItems: "center", gap: space[50], padding: `0 ${space[150]}` };
  return (
    <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
      {shell.focus ? (
        <header style={bar}>
          <span style={{ flex: 1 }} />
          <Button variant="ghost" icon="focus" onClick={shell.toggleFocus}>{t("focus.exit")}</Button>
        </header>
      ) : (
        <header style={bar}>
          {sizeClass === "compact" && (
            <span onClick={shell.showList} style={{ display: "inline-flex", alignItems: "center", gap: space[25], ...type.label, color: color.accentPrimary, whiteSpace: "nowrap", ...clickable }}>
              <Icon name="back" />
              {folder.name}
            </span>
          )}
          {sizeClass === "medium" && <IconButton icon="library" label={t("library.show")} onClick={shell.toggleLibrary} />}
          <span style={{ flex: 1 }} />
          {isDesktop(platform) && <IconButton icon="command" label={t("palette.title")} onClick={() => go("command-palette#default")} />}
          <IconButton icon="focus" label={t("focus.title")} onClick={shell.toggleFocus} />
          <IconButton icon="history" label={t("nav.history")} onClick={() => go("history#all")} />
          <IconButton icon="export" label={t("export.title")} onClick={() => go("export#paste")} />
          <IconButton icon="reference" label={t("inspector.title")} active={!!shell.inspector} onClick={shell.toggleInspector} />
        </header>
      )}

      {shell.readOnly && (
        <div style={{ display: "flex", flexDirection: "column", gap: space[100], margin: `0 ${space[200]}`, padding: space[150], borderRadius: radius.panel, background: color.accentSoft, color: color.stateWarning, ...type.label }}>
          <div style={{ display: "flex", alignItems: "flex-start", gap: space[100] }}>
            <Icon name="lease" size="sm" style={{ marginTop: space[25] }} />
            <span style={{ flex: 1, minWidth: 0 }}>{t("lease.banner", { device: "MacBook Air", minutes: 3 })}</span>
          </div>
          <Button variant="primary" onClick={shell.takeOver} style={{ alignSelf: "flex-end" }}>{t("lease.takeOver")}</Button>
        </div>
      )}

      <article style={{ flex: 1, overflow: "auto", padding: `${space[300]} ${editor.paddingX[sizeClass]}`, opacity: shell.readOnly ? opacity.readOnly : undefined }}>
        {paragraphs.length ? <Manuscript paragraphs={paragraphs} focus={shell.focus} /> : <EmptySheet />}
      </article>

      <EditorFooter sheet={sheet} readOnly={shell.readOnly} />
    </main>
  );
}

function sheetById(shell: Shell, sample: ReturnType<typeof useFrame>["sample"]) {
  const { project, sheet: openSheet } = openContext(sample);
  return [...shell.sheets(shell.folderId), ...project.folders.flatMap((f) => f.sheets)].find((s) => s.id === shell.sheetId) ?? openSheet;
}

/** Only the open sheet has full text in the fixture; other sheets show their title and first line. */
function paragraphsOf(sheet: SheetSummary, sample: ReturnType<typeof useFrame>["sample"]) {
  const { sheet: openSheet } = openContext(sample);
  if (sheet.id === openSheet.id) return sample.openSheet.paragraphs;
  return sheet.body ?? [`# ${sheet.title}`, sheet.excerpt];
}

function Manuscript({ paragraphs, focus }: { paragraphs: string[]; focus?: boolean }) {
  const dim = (i: number) => (focus && i !== CARET_PARAGRAPH ? { opacity: opacity.focusDim } : undefined);
  return (
    <div style={{ maxWidth: editor.measure, margin: "0 auto" }}>
      {paragraphs.map((p, i) =>
        p.startsWith("# ") ? (
          <h1 key={i} style={{ ...type.editorHeading, margin: `0 0 ${space[300]}`, ...dim(i) }}>
            <span style={{ color: color.inkMarkup }}># </span>
            {p.slice(2)}
          </h1>
        ) : p.startsWith("- ") ? (
          <p key={i} style={{ ...type.editorBody, margin: `0 0 ${space[100]}`, ...dim(i) }}>
            <span style={{ color: color.inkMarkup }}>- </span>
            {p.slice(2)}
          </p>
        ) : (
          <p key={i} style={{ ...type.editorBody, margin: `0 0 ${space[200]}`, ...dim(i) }}>{p}</p>
        ),
      )}
    </div>
  );
}

/** A new sheet: the first line becomes its title, as in the sheet list. */
function EmptySheet() {
  const t = useT();
  return (
    <div style={{ maxWidth: editor.measure, margin: "0 auto" }}>
      <div style={{ ...type.editorHeading, color: color.inkTertiary }}>
        <span style={{ color: color.inkMarkup }}># </span>
        {t("sheet.placeholderTitle")}
      </div>
      <p style={{ ...type.editorBody, color: color.inkTertiary, margin: `${space[300]} 0 0` }}>{t("sheet.placeholderBody")}</p>
    </div>
  );
}

/** Both character counts always; a goal bar only when the project sets a goal (project-settings); sync state on the side. */
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
      <div style={{ minHeight: size.controlMd, display: "flex", alignItems: "center", justifyContent: "center", columnGap: space[150], flexWrap: "wrap", padding: `0 ${space[150]}` }}>
        {readOnly && <span style={{ color: color.stateWarning }}>{t("lease.readOnly")}</span>}
        <span>{t("count.withSpaces", { count: sheet.chars })}</span>
        <span>{t("count.withoutSpaces", { count: sheet.charsNoSpace })}</span>
        {goal && <span style={{ color: color.inkSecondary }}>{t("goal.progress", { goal: goal.count, percent })}</span>}
        <span title={t("sync.upToDate")} style={{ display: "inline-flex", alignItems: "center", gap: space[50], color: color.stateSuccess }}>
          <Icon name="synced" size="sm" />
          {t("sync.saved")}
        </span>
      </div>
    </footer>
  );
}

// ── Inspector: docked (large) · overlay (medium/expanded) · bottom sheet (compact) ──
// Tabs: lore reference (the PRODUCT.md reference panel) · sheet info · outline.

function Inspector({ mode, shell }: { mode: "docked" | "overlay" | "sheet"; shell: Shell }) {
  const t = useT();
  const { safeArea, textScale } = useFrame();
  const tab = shell.inspector ?? "reference";
  const tabs = [["reference", t("inspector.reference")], ["info", t("inspector.info")], ["outline", t("inspector.outline")]] as const;
  const frameStyle =
    mode === "docked"
      ? { width: pane.inspector, flex: "none", borderLeft: hairline(color.lineSubtle) }
      : mode === "overlay"
        ? { position: "absolute" as const, top: safeArea.top, right: safeArea.right, bottom: safeArea.bottom, width: pane.inspector, boxShadow: shadow.dialog, borderLeft: hairline(color.lineSubtle) }
        : { position: "absolute" as const, left: 0, right: 0, bottom: 0, height: "55%", paddingBottom: safeArea.bottom, boxShadow: shadow.dialog, borderTopLeftRadius: radius.sheet, borderTopRightRadius: radius.sheet };
  return (
    <>
      {mode === "sheet" && <div style={{ position: "absolute", inset: 0, background: color.surfaceScrim, ...clickable }} onClick={shell.toggleInspector} />}
      <aside style={{ ...frameStyle, display: "flex", flexDirection: "column", background: color.surfaceRaised, overflow: "hidden" }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `${space[100]} ${space[150]} ${space[100]} ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
          <div style={{ flex: 1, minWidth: 0, display: textScale >= 1.5 ? "flex" : "block", flexWrap: "wrap", gap: space[50] }}>
            {/* Three segments do not fit the panel at very large text — fall back to wrapping chips there. */}
            {textScale >= 1.5 ? (
              tabs.map(([k, label]) => <Chip key={k} active={k === tab} onClick={() => shell.setInspectorTab(k)}>{label}</Chip>)
            ) : (
              <Segmented full items={tabs} value={tab} onChange={shell.setInspectorTab} />
            )}
          </div>
          <IconButton icon="close" label={t("action.close")} onClick={shell.toggleInspector} />
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>
          {tab === "reference" ? <ReferenceTab /> : tab === "info" ? <InfoTab shell={shell} /> : <OutlineTab shell={shell} />}
        </div>
      </aside>
    </>
  );
}

function ReferenceTab() {
  const t = useT();
  const { sample } = useFrame();
  const { reference } = openContext(sample);
  return (
    <>
      <div style={{ ...type.label, color: color.inkTertiary }}>{t("reference.title")}</div>
      <div style={{ ...type.heading, margin: `${space[25]} 0 ${space[150]}` }}>{reference.title}</div>
      {(reference.body ?? [reference.excerpt]).filter((p) => !p.startsWith("# ")).map((p, i) => (
        <p key={i} style={{ ...type.body, margin: `0 0 ${space[100]}`, color: color.inkPrimary }}>
          {p.startsWith("- ") ? <><span style={{ color: color.inkMarkup }}>- </span>{p.slice(2)}</> : p}
        </p>
      ))}
    </>
  );
}

/** Sheet statistics. Korean manuscripts also show wongoji pages (200-character manuscript sheets), which serial writers count in. */
function InfoTab({ shell }: { shell: Shell }) {
  const t = useT();
  const { sample, locale } = useFrame();
  const { project, sheet: openSheet } = openContext(sample);
  const sheet = sheetById(shell, sample);
  const paragraphs = paragraphsOf(sheet, sample).filter((p) => !p.startsWith("# "));
  const words = paragraphs.join(" ").split(/\s+/).filter(Boolean).length;
  const minutes = Math.max(1, Math.round(project.language === "ko" ? sheet.charsNoSpace / 500 : words / 230));
  const date = new Intl.DateTimeFormat(locale, { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  const rows: [string, string][] = [
    [t("info.withSpaces"), sheet.chars.toLocaleString(locale)],
    [t("info.withoutSpaces"), sheet.charsNoSpace.toLocaleString(locale)],
    project.language === "ko" ? [t("info.manuscriptPages"), t("info.pages", { count: Math.ceil(sheet.chars / 200) })] : [t("info.words"), words.toLocaleString(locale)],
    [t("info.paragraphs"), paragraphs.length.toLocaleString(locale)],
    [t("info.readingTime"), t("info.minutes", { count: minutes })],
  ];
  if (sheet.id === openSheet.id) {
    rows.push([t("info.created"), date.format(new Date(sample.openSheet.createdAt))], [t("info.modified"), date.format(new Date(sample.openSheet.modifiedAt))]);
  }
  return (
    <div style={{ display: "flex", flexDirection: "column" }}>
      {rows.map(([k, v], i) => (
        <div key={k} style={{ display: "flex", alignItems: "baseline", gap: space[150], padding: `${space[100]} 0`, borderTop: i ? hairline(color.lineSubtle) : undefined, flexWrap: "wrap" }}>
          <span style={{ flex: 1, color: color.inkSecondary }}>{k}</span>
          <span style={{ fontWeight: type.heading.fontWeight }}>{v}</span>
        </div>
      ))}
    </div>
  );
}

/** Headings and paragraphs of the open sheet, for jumping around long episodes. */
function OutlineTab({ shell }: { shell: Shell }) {
  const t = useT();
  const { sample } = useFrame();
  const paragraphs = paragraphsOf(sheetById(shell, sample), sample);
  const [at, setAt] = useState(CARET_PARAGRAPH);
  if (!paragraphs.length) return <div style={{ ...type.caption, color: color.inkTertiary }}>{t("outline.empty")}</div>;
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[25] }}>
      {paragraphs.map((p, i) => {
        const heading = p.startsWith("# ");
        return (
          <div
            key={i}
            onClick={() => setAt(i)}
            style={{
              display: "flex", gap: space[100], minHeight: size.controlSm, alignItems: "center", padding: `${space[50]} ${space[100]}`, paddingLeft: heading ? space[100] : space[300],
              borderRadius: radius.control, background: i === at ? color.surfaceSelected : "transparent", ...clickable,
            }}
          >
            <span style={{ ...(heading ? type.label : type.caption), fontWeight: heading ? type.heading.fontWeight : undefined, color: heading ? color.inkPrimary : color.inkSecondary, flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {heading ? p.slice(2) : p}
            </span>
          </div>
        );
      })}
    </div>
  );
}

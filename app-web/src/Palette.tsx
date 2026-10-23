// Command palette + search in one box (command-palette spec): sheets by title or text, then commands.
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { color, pane, radius, shadow, size, space, type, Icon, IconButton, TextField, type IconName, type StringKey } from "@ithaca/kit";
import { moveSheet, newSheet } from "./App";
import { revealCaret, setCaret } from "./Editor";
import { trashWithUndo } from "./SheetList";
import { useApp, useT, type App } from "./ctx";
import { foldersOf, liveProjects } from "./store";
import { titleOf } from "./text";

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

const COMMANDS: readonly { label: StringKey; icon: IconName; run: (app: App, t: (k: StringKey, p?: Record<string, string | number>) => string) => void }[] = [
  { label: "sheet.new", icon: "add", run: (a) => newSheet(a, a.state.ui.folderId) },
  { label: "library.newProject", icon: "folder", run: (a) => a.setOverlay("newProject") },
  { label: "focus.title", icon: "focus", run: (a) => a.setView({ focus: true }) },
  { label: "palette.sheetInfo", icon: "stats", run: (a) => a.setView({ inspector: true }) },
  { label: "export.title", icon: "export", run: (a) => a.setOverlay("export") },
  { label: "projectSettings.title", icon: "settings", run: (a) => a.setOverlay("projectSettings") },
  { label: "prefs.title", icon: "settings", run: (a) => a.setOverlay("settings") },
  // Reordering without a mouse or on a phone, where rows can't be dragged.
  { label: "sheet.moveUp", icon: "collapsed", run: (a) => moveSheet(a, -1) },
  { label: "sheet.moveDown", icon: "expanded", run: (a) => moveSheet(a, 1) },
  { label: "trash.title", icon: "trash", run: (a) => a.setView({ trash: true, compact: "list" }) },
  {
    label: "sheet.trash", icon: "delete",
    run: (a, t) => {
      const sheet = a.state.sheets.find((x) => x.id === a.state.ui.sheetId);
      if (sheet) trashWithUndo(a, sheet, t);
    },
  },
];

const GROUP_LABEL: Record<"sheet" | "folder" | "project" | "command", (searching: boolean) => StringKey> = {
  sheet: (searching) => (searching ? "palette.sheets" : "palette.recent"),
  folder: () => "palette.folders",
  project: () => "palette.projects",
  command: () => "palette.commands",
};

interface Hit { key: string; icon: IconName; title: string; detail?: ReactNode; meta?: string; run: () => void }

export function Palette() {
  const t = useT();
  const app = useApp();
  const { state, sizeClass, setOverlay, dispatch, setView } = app;
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);
  const q = query.trim().toLowerCase();
  const compact = sizeClass === "compact";

  const hits = useMemo<Hit[]>(() => {
    const folders = foldersOf(state, state.ui.projectId);
    const folderName = new Map(folders.map((f) => [f.id, f.name]));
    const live = state.sheets.filter((s) => !s.trashed && folderName.has(s.folderId));
    const open = (id: string, folderId: string, at?: number) => () => {
      // The editor opens a sheet at its remembered caret; point that at the match first.
      if (at !== undefined) setCaret(id, at);
      dispatch({ type: "selectFolder", id: folderId });
      dispatch({ type: "selectSheet", id });
      setView({ trash: false, compact: "editor", libraryOpen: false });
      setOverlay(null);
      if (at !== undefined) requestAnimationFrame(() => requestAnimationFrame(() => {
        const el = document.getElementById("ithaca-editor") as HTMLTextAreaElement | null;
        if (!el) return;
        el.focus({ preventScroll: true });
        el.setSelectionRange(at, at + q.length);
        revealCaret(el, "center");
      }));
    };
    const sheets: Hit[] = q
      ? live.flatMap((s) => {
          // Every match is its own result (up to 5 per sheet), so the second and third occurrences are reachable.
          const lower = s.body.toLowerCase();
          const ats: number[] = [];
          for (let i = lower.indexOf(q); i >= 0 && ats.length < 5; i = lower.indexOf(q, i + q.length)) ats.push(i);
          return ats.map((at, n) => {
          const from = Math.max(0, at - 24);
          const snippet = (
            <>
              {from > 0 && "…"}
              {s.body.slice(from, at).replace(/\n/g, " ")}
              <mark style={{ background: color.accentSoft, color: color.inkPrimary }}>{s.body.slice(at, at + q.length)}</mark>
              {s.body.slice(at + q.length, at + q.length + 48).replace(/\n/g, " ")}
            </>
          );
          return { key: `${s.id}:${at}`, icon: "sheet" as const, title: (titleOf(s.body) || t("sheet.untitled")) + (ats.length > 1 ? ` (${n + 1}/${ats.length})` : ""), detail: snippet, meta: folderName.get(s.folderId), run: open(s.id, s.folderId, at) };
          });
        }).slice(0, 30)
      : [...live].sort((a, b) => b.modified - a.modified).slice(0, 5).map((s) => ({ key: s.id, icon: "sheet" as const, title: titleOf(s.body) || t("sheet.untitled"), meta: folderName.get(s.folderId), run: open(s.id, s.folderId) }));
    // Folders and other projects are places to go, matched by name.
    const places: Hit[] = q
      ? [
          ...folders.filter((f) => f.name.toLowerCase().includes(q)).map((f) => ({
            key: f.id, icon: "folder" as const, title: f.name, meta: t("palette.folder"),
            run: () => { dispatch({ type: "selectFolder", id: f.id }); setView({ trash: false, compact: "list" }); setOverlay(null); },
          })),
          ...liveProjects(state).filter((p) => p.id !== state.ui.projectId && p.title.toLowerCase().includes(q)).map((p) => ({
            key: p.id, icon: "library" as const, title: p.title, meta: t("palette.project"),
            run: () => { dispatch({ type: "selectProject", id: p.id }); setView({ trash: false }); setOverlay(null); },
          })),
        ]
      : [];
    const commands: Hit[] = COMMANDS.filter((c) => !q || t(c.label).toLowerCase().includes(q)).map((c) => ({
      key: c.label, icon: c.icon, title: t(c.label), run: () => { setOverlay(null); c.run(app, t); },
    }));
    return [...sheets, ...places, ...commands];
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q, state]);
  // Each run of results (sheets, folders, projects, commands) gets its own heading.
  const groupOf = (h?: Hit) => (!h ? null : h.icon === "sheet" ? "sheet" : h.icon === "folder" && h.meta ? "folder" : h.icon === "library" && h.meta ? "project" : "command");

  useEffect(() => setIndex(0), [q]);
  useEffect(() => {
    listRef.current?.querySelector(`[data-i="${index}"]`)?.scrollIntoView({ block: "nearest" });
  }, [index]);

  const onKey = (e: React.KeyboardEvent) => {
    // Keep focus in the box: Tab moves through results like the arrows instead of leaving for the page behind.
    if (e.key === "Tab") { e.preventDefault(); setIndex((i) => (e.shiftKey ? Math.max(0, i - 1) : Math.min(hits.length - 1, i + 1))); }
    else if (e.key === "ArrowDown") { e.preventDefault(); setIndex((i) => Math.min(hits.length - 1, i + 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setIndex((i) => Math.max(0, i - 1)); }
    else if (e.key === "Enter" && !e.nativeEvent.isComposing) { e.preventDefault(); hits[index]?.run(); }
  };

  return (
    <div style={{ position: "absolute", inset: 0, zIndex: 20, display: "flex", justifyContent: "center", alignItems: compact ? "stretch" : "flex-start", padding: compact ? 0 : `${space[800]} ${space[200]} ${space[200]}` }}>
      <div style={{ position: "absolute", inset: 0, background: color.surfaceScrim }} onClick={() => setOverlay(null)} />
      <div
        onKeyDown={onKey}
        style={{
          position: "relative", display: "flex", flexDirection: "column", background: color.surfaceRaised, overflow: "hidden",
          ...(compact ? { flex: 1 } : { width: pane.dialog, maxWidth: "100%", maxHeight: "100%", borderRadius: radius.sheet, border: hairline(color.lineSubtle), boxShadow: shadow.dialog }),
        }}
      >
        <div style={{ flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: space[150], borderBottom: hairline(color.lineSubtle) }}>
          <TextField value={query} onChange={setQuery} placeholder={t("palette.placeholder")} icon="search" autoFocus />
          {compact && <IconButton icon="close" label={t("action.close")} onClick={() => setOverlay(null)} />}
        </div>
        <div ref={listRef} style={{ flex: 1, minHeight: 0, overflow: "auto", padding: space[100] }}>
          {hits.map((h, i) => (
            <div key={h.key}>
              {groupOf(hits[i - 1]) !== groupOf(h) && <Heading>{t(GROUP_LABEL[groupOf(h)!](!!q))}</Heading>}
              <div
                data-i={i}
                onClick={h.run}
                onMouseMove={() => setIndex(i)}
                style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlMd, padding: `${space[50]} ${space[100]}`, borderRadius: radius.control, background: i === index ? color.surfaceSelected : "transparent", cursor: "pointer" }}
              >
                <Icon name={h.icon} size="sm" color={color.inkTertiary} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{h.title}</div>
                  {h.detail && <div style={{ ...type.caption, color: color.inkSecondary, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{h.detail}</div>}
                </div>
                {h.meta && <span style={{ ...type.caption, color: color.inkTertiary, flex: "none" }}>{h.meta}</span>}
              </div>
            </div>
          ))}
          {!hits.length && <div style={{ padding: space[300], textAlign: "center", color: color.inkTertiary, ...type.caption }}>{t("palette.none", { query })}</div>}
        </div>
        {!compact && (
          <div style={{ flex: "none", display: "flex", gap: space[200], flexWrap: "wrap", padding: `${space[100]} ${space[200]}`, borderTop: hairline(color.lineSubtle), ...type.caption, color: color.inkTertiary }}>
            <span>{t("palette.hintOpen")}</span>
            <span>{t("palette.hintClose")}</span>
          </div>
        )}
      </div>
    </div>
  );
}

function Heading({ children }: { children: string }) {
  return <div style={{ ...type.caption, color: color.inkTertiary, padding: `${space[100]} ${space[100]} ${space[50]}` }}>{children}</div>;
}

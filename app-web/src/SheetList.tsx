// Sheet list: the open folder's sheets in serial order (drag to reorder), or the trash.
import { useMemo, useState } from "react";
import { color, pane, radius, shadow, size, space, type, Button, Icon, IconButton } from "@ithaca/kit";
import { newSheet } from "./App";
import { useApp, useT, type App } from "./ctx";
import { usePressable } from "./Dialog";
import { foldersOf, sheetsIn, trashOf, type Sheet } from "./store";
import { lengthOf, sheetMeta } from "./text";

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const dateFormats = new Map<string, Intl.DateTimeFormat>();
/** Formatters are expensive to build; a long list would build one per row per keystroke. */
const shortDate = (locale: string) => {
  let f = dateFormats.get(locale);
  if (!f) dateFormats.set(locale, (f = new Intl.DateTimeFormat(locale, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })));
  return f;
};

export function SheetList({ full }: { full?: boolean }) {
  const t = useT();
  const app = useApp();
  const { state, dispatch, view, setView, setOverlay, panes } = app;
  const folder = state.folders.find((f) => f.id === state.ui.folderId && !f.deleted);
  const project = state.projects.find((p) => p.id === state.ui.projectId)!;
  const trash = view.trash;
  const sheets = trash ? trashOf(state, state.ui.projectId) : folder ? sheetsIn(state, folder.id) : [];
  const title = trash ? t("trash.title") : folder?.name ?? "";
  const total = sheets.reduce((n, s) => n + lengthOf(sheetMeta(s).counts, project.language), 0);
  const unit = (n: number) => (project.language === "ko" ? t("count.withSpaces", { count: n }) : t("count.words", { count: n }));
  const [dragging, setDragging] = useState<string | null>(null);

  return (
    <section style={{ width: full ? "100%" : pane.sheetList, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceList, borderRight: full ? undefined : hairline(color.lineSubtle) }}>
      <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[50], padding: `0 ${space[100]} 0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
        {full && <IconButton icon="back" label={t("library.title")} onClick={() => setView({ compact: "library" })} />}
        {!full && !panes.library && !view.libraryOpen && <IconButton icon="library" label={t("library.show")} onClick={() => setView({ libraryOpen: true })} />}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ ...type.heading, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{title}</div>
          <div style={{ ...type.caption, color: color.inkTertiary }}>
            {t("sheetList.count", { count: sheets.length })}
            {!trash && sheets.length > 0 && ` · ${unit(total)}`}
          </div>
        </div>
        <IconButton icon="search" label={t("search.title")} onClick={() => setOverlay("palette")} />
        {!trash && folder && <IconButton icon="add" label={t("sheet.new")} onClick={() => newSheet(app, folder.id)} />}
      </header>
      {trash && sheets.length > 0 && (
        <div style={{ display: "flex", alignItems: "center", gap: space[100], padding: `${space[100]} ${space[200]}`, borderBottom: hairline(color.lineSubtle), ...type.caption, color: color.inkTertiary, flexWrap: "wrap" }}>
          <span style={{ flex: "1 1 auto" }}>{t("trash.hint")}</span>
          <Button variant="ghost" icon="restore" onClick={() => { sheets.forEach((s) => dispatch({ type: "restoreSheet", id: s.id })); setView({ trash: false, compact: "list" }); }}>{t("trash.restoreAll")}</Button>
          <Button variant="danger" onClick={() => app.confirm(t("trash.emptyConfirm")) && dispatch({ type: "emptyTrash", projectId: state.ui.projectId })}>{t("trash.empty")}</Button>
        </div>
      )}
      <div style={{ flex: 1, overflow: "auto" }} onDragOver={(e) => dragging && e.preventDefault()} onDrop={() => { if (dragging) dispatch({ type: "reorderSheet", id: dragging, before: null }); setDragging(null); }}>
        {sheets.length === 0 && (
          <div style={{ padding: space[300], ...type.caption, color: color.inkTertiary, textAlign: "center" }}>{trash ? t("trash.emptyState") : t("sheetList.empty")}</div>
        )}
        {sheets.map((s) => (
          <SheetRow key={s.id} sheet={s} trash={trash} active={!trash && s.id === state.ui.sheetId} dragging={dragging} setDragging={setDragging} />
        ))}
      </div>
    </section>
  );
}

export function trashWithUndo(app: App, sheet: Sheet, t: ReturnType<typeof useT>) {
  app.dispatch({ type: "trashSheet", id: sheet.id });
  app.toast({ message: t("sheet.trashed", { title: sheetMeta(sheet).title || t("sheet.untitled") }), undo: { label: t("action.undo"), run: () => app.dispatch({ type: "restoreSheet", id: sheet.id }) } });
}

function SheetRow({ sheet, active, trash, dragging, setDragging }: { sheet: Sheet; active: boolean; trash: boolean; dragging: string | null; setDragging: (id: string | null) => void }) {
  const t = useT();
  const app = useApp();
  const { dispatch, setView, state, locale, touch } = app;
  const [hover, setHover] = useState(false);
  const [drop, setDrop] = useState<"above" | "below" | null>(null);
  const { title, excerpt, counts } = sheetMeta(sheet);
  const project = state.projects.find((p) => p.id === state.ui.projectId)!;
  const length = project.language === "ko" ? t("count.withSpaces", { count: counts.chars }) : t("count.words", { count: counts.words });
  const when = shortDate(locale).format(sheet.modified);
  const folderName = state.folders.find((f) => f.id === sheet.folderId)?.name;
  const { ringStyle, ...press } = usePressable(() => {
    if (trash) return;
    dispatch({ type: "selectSheet", id: sheet.id });
    setView({ compact: "editor", libraryOpen: false });
  });
  const showActions = trash || touch || hover || active;
  // The row body only depends on these; with hundreds of sheets, rebuilding every body per keystroke is the cost.
  // Handlers inside read the latest app through `app` captured at build time, which is fine for dispatch.
  const content = useMemo(() => (
      <div style={{ display: "flex", alignItems: "flex-start", gap: space[100] }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ ...type.body, fontWeight: type.heading.fontWeight, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: title ? undefined : color.inkTertiary }}>{title || t("sheet.untitled")}</div>
          {excerpt && <div style={{ ...type.caption, color: color.inkSecondary, marginTop: space[25], overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{excerpt}</div>}
          <div style={{ display: "flex", gap: space[100], marginTop: space[50], ...type.caption, color: color.inkTertiary, flexWrap: "wrap" }}>
            <span>{length}</span>
            <span>{trash && folderName ? folderName : when}</span>
          </div>
        </div>
        {showActions && (
          // Floats over the row's corner so showing it never rewraps the text (rows keep their height).
          <span
            style={{ position: "absolute", top: space[100], right: space[100], display: "inline-flex", borderRadius: radius.control, background: active ? color.surfaceSelected : color.surfaceList, boxShadow: hover ? shadow.raised : undefined }}
            onClick={(e) => e.stopPropagation()}
            onKeyDown={(e) => e.stopPropagation()}
          >
            {trash ? (
              <>
                <IconButton
                  icon="restore"
                  label={t("trash.restore")}
                  onClick={() => { dispatch({ type: "restoreSheet", id: sheet.id }); setView({ trash: false, compact: "editor" }); }}
                />
                <IconButton icon="delete" label={t("trash.deleteForever")} onClick={() => app.confirm(t("trash.deleteForeverConfirm")) && dispatch({ type: "deleteSheet", id: sheet.id })} />
              </>
            ) : (
              <>
                <MoveMenu sheet={sheet} />
                <IconButton icon="delete" label={t("sheet.trash")} onClick={() => trashWithUndo(app, sheet, t)} />
              </>
            )}
          </span>
        )}
      </div>
  // eslint-disable-next-line react-hooks/exhaustive-deps
  ), [sheet, trash, showActions, hover, active, length, when, folderName, title, excerpt, locale]);
  return (
    <article
      {...press}
      draggable={!trash && !touch}
      onDragStart={(e) => { e.dataTransfer.effectAllowed = "move"; setDragging(sheet.id); }}
      onDragEnd={() => setDragging(null)}
      onDragOver={(e) => {
        if (!dragging || dragging === sheet.id) return;
        e.preventDefault();
        e.stopPropagation();
        // Upper half drops above this row, lower half below it.
        const r = e.currentTarget.getBoundingClientRect();
        setDrop(e.clientY < r.top + r.height / 2 ? "above" : "below");
      }}
      onDragLeave={() => setDrop(null)}
      onDrop={(e) => {
        e.stopPropagation();
        if (dragging) {
          const list = sheetsIn(state, sheet.folderId);
          const before = drop === "below" ? list[list.findIndex((x) => x.id === sheet.id) + 1]?.id ?? null : sheet.id;
          if (before !== dragging) dispatch({ type: "reorderSheet", id: dragging, before });
        }
        setDrop(null);
        setDragging(null);
      }}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      aria-current={active || undefined}
      style={{
        position: "relative", minHeight: size.rowSheet, padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle),
        boxShadow: drop ? `inset 0 ${drop === "above" ? "" : "-"}${size.strokeFocus} 0 ${color.accentPrimary}` : undefined,
        background: active ? color.surfaceSelected : "transparent", cursor: trash ? "default" : "pointer", opacity: dragging === sheet.id ? 0.5 : undefined, ...ringStyle,
      }}
    >
      {content}
    </article>
  );
}

/** Move to another folder of the same project — a native select keeps it accessible and small. */
function MoveMenu({ sheet }: { sheet: Sheet }) {
  const t = useT();
  const { state, dispatch } = useApp();
  const others = foldersOf(state, state.ui.projectId).filter((f) => f.id !== sheet.folderId);
  if (!others.length) return null;
  return (
    <label title={t("sheet.move")} style={{ position: "relative", display: "inline-grid", placeItems: "center", minWidth: size.controlSm, minHeight: size.controlSm, color: color.inkSecondary, cursor: "pointer" }}>
      <Icon name="folder" />
      <select
        aria-label={t("sheet.move")}
        value=""
        onChange={(e) => e.target.value && dispatch({ type: "moveSheet", id: sheet.id, folderId: e.target.value })}
        style={{ position: "absolute", inset: 0, opacity: 0, cursor: "pointer" }}
      >
        <option value="">{t("sheet.move")}</option>
        {others.map((f) => (
          <option key={f.id} value={f.id}>{f.name}</option>
        ))}
      </select>
    </label>
  );
}

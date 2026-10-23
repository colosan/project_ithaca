// Editor pane: toolbar, the manuscript, counts footer. Plain text with Markdown kept as typed.
import { useEffect, useLayoutEffect, useRef, type CSSProperties } from "react";
import { color, editor, opacity, radius, size, space, type, Button, Icon, IconButton } from "@ithaca/kit";
import { newSheet } from "./App";
import { useApp, useT } from "./ctx";
import { goalValue, sheetMeta } from "./text";
import { hold, release, useLease } from "./lease";

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const TEXT = { small: type.editorSmall, normal: type.editorBody, large: type.editorLarge } as const;
/** Korean wraps at word boundaries (keep-all), like printed Korean; very long tokens still break. */
const PROSE: CSSProperties = { wordBreak: "keep-all", overflowWrap: "anywhere", whiteSpace: "pre-wrap" };

/** Where the caret was in each sheet, so going back (even after a reload) resumes there. */
const CARETS_KEY = "ithaca.carets.v1";
const carets = new Map<string, number>(Object.entries((() => {
  try {
    return JSON.parse(localStorage.getItem(CARETS_KEY) ?? "{}") as Record<string, number>;
  } catch {
    return {};
  }
})()));
let caretSave: ReturnType<typeof setTimeout> | undefined;
/** Where a sheet should open next (search results use this to land on the match). */
export function setCaret(sheetId: string, pos: number) {
  carets.set(sheetId, pos);
  clearTimeout(caretSave);
  caretSave = setTimeout(() => {
    try {
      localStorage.setItem(CARETS_KEY, JSON.stringify(Object.fromEntries(carets)));
    } catch {
      // Losing a caret position is harmless.
    }
  }, 1000);
}

/**
 * Pixel offset of a caret position inside an auto-height textarea, measured with a mirror element
 * that copies the textarea's typography and width.
 */
function caretTop(el: HTMLTextAreaElement, pos: number) {
  const mirror = document.createElement("div");
  const cs = getComputedStyle(el);
  for (const p of ["font", "letterSpacing", "lineHeight", "wordBreak", "overflowWrap", "whiteSpace", "padding", "border", "boxSizing", "textIndent"] as const) mirror.style[p] = cs[p];
  Object.assign(mirror.style, { position: "absolute", visibility: "hidden", width: `${el.clientWidth}px`, left: "-9999px", top: "0" });
  mirror.textContent = el.value.slice(0, pos);
  const mark = document.createElement("span");
  mark.textContent = "​";
  mirror.appendChild(mark);
  document.body.appendChild(mirror);
  const top = mark.offsetTop;
  document.body.removeChild(mirror);
  return top;
}

/** Scroll the article so the caret line sits in the comfortable band (a third from the top, never at the bottom edge). */
export function revealCaret(el: HTMLTextAreaElement, mode: "center" | "keep" = "keep") {
  const article = el.parentElement!;
  const y = el.offsetTop + caretTop(el, el.selectionEnd);
  const view = article.clientHeight;
  const line = parseFloat(getComputedStyle(el).lineHeight) || 32;
  if (mode === "center") article.scrollTop = y - view / 3;
  else if (y + line * 3 > article.scrollTop + view) article.scrollTop = y + line * 3 - view;
  else if (y < article.scrollTop) article.scrollTop = y - line;
}

export function Editor() {
  const t = useT();
  const app = useApp();
  const { state, dispatch, sizeClass, panes, view, setView, setOverlay } = app;
  const sheet = state.sheets.find((s) => s.id === state.ui.sheetId && !s.trashed) ?? null;
  const folder = state.folders.find((f) => f.id === state.ui.folderId);
  const ref = useRef<HTMLTextAreaElement>(null);
  const lease = useLease(sheet?.id ?? null);
  useEffect(() => {
    const id = sheet?.id;
    return () => {
      if (id) release(id);
    };
  }, [sheet?.id]);

  // Grow the textarea with its content so the article scrolls, not the field.
  // Re-measure on width changes too: opening a panel rewraps every line.
  const grow = () => {
    const el = ref.current;
    if (!el) return;
    const article = el.parentElement!;
    const keep = article.scrollTop;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
    article.scrollTop = keep;
  };
  useLayoutEffect(grow, [sheet?.body, sheet?.id, state.prefs.textSize, sizeClass]);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let width = el.clientWidth;
    const ro = new ResizeObserver(() => {
      if (el.clientWidth !== width) {
        width = el.clientWidth;
        grow();
      }
    });
    ro.observe(el.parentElement!);
    return () => ro.disconnect();
  }, [sheet?.id]);

  // Opening a sheet resumes where the caret was (end of text the first time) and scrolls it into view.
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || !sheet) return;
    const at = Math.min(carets.get(sheet.id) ?? el.value.length, el.value.length);
    el.setSelectionRange(at, at);
    if (!panes.compact && !app.overlay) el.focus({ preventScroll: true });
    revealCaret(el, "center");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sheet?.id]);

  const remember = () => {
    const el = ref.current;
    if (el && sheet) setCaret(sheet.id, el.selectionEnd);
  };

  const bar = { minHeight: size.barTop, flex: "none" as const, display: "flex", alignItems: "center", gap: space[50], padding: `0 ${space[150]}` };
  return (
    <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
      {view.focus ? (
        <header style={bar}>
          <span style={{ flex: 1 }} />
          <Button variant="ghost" icon="focus" onClick={() => setView({ focus: false })}>{t("focus.exit")}</Button>
        </header>
      ) : (
        <header style={bar}>
          {panes.compact && (
            <Button variant="ghost" icon="back" onClick={() => setView({ compact: "list" })} style={{ color: color.accentPrimary, paddingLeft: space[50], minWidth: 0, flexShrink: 1 }}>
              <span style={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{view.trash ? t("trash.title") : folder?.name}</span>
            </Button>
          )}
          {/* The sheet list carries this button when it is docked; only one of them shows. */}
          {!panes.compact && !panes.list && <IconButton icon="library" label={t("library.show")} onClick={() => setView({ libraryOpen: true })} />}
          <span style={{ flex: 1 }} />
          <IconButton icon={panes.compact ? "search" : "command"} label={t("palette.title")} onClick={() => setOverlay("palette")} />
          <IconButton icon="focus" label={t("focus.title")} onClick={() => setView({ focus: true })} />
          <IconButton icon="export" label={t("export.title")} onClick={() => setOverlay("export")} />
          <IconButton icon="reference" label={t("inspector.title")} active={view.inspector} onClick={() => setView({ inspector: !view.inspector })} />
        </header>
      )}

      {sheet && lease.locked && (
        <div role="status" style={{ display: "flex", alignItems: "center", gap: space[150], flexWrap: "wrap", margin: `0 ${space[200]}`, padding: space[150], borderRadius: radius.panel, background: color.accentSoft, color: color.stateWarning, ...type.label }}>
          <Icon name="lease" size="sm" />
          <span style={{ flex: "1 1 auto", minWidth: 0 }}>{t("lease.otherTab")}</span>
          <Button variant="primary" onClick={() => { lease.takeOver(); ref.current?.focus(); }}>{t("lease.takeOver")}</Button>
        </div>
      )}

      {sheet ? (
        <article style={{ flex: 1, overflow: "auto", padding: `${space[300]} ${editor.paddingX[sizeClass]} 40vh` }} onClick={(e) => e.target === e.currentTarget && ref.current?.focus()}>
          <textarea
            id="ithaca-editor"
            ref={ref}
            value={sheet.body}
            aria-label={t("editor.label")}
            readOnly={lease.locked}
            onChange={(e) => {
              hold(sheet.id);
              dispatch({ type: "editSheet", id: sheet.id, body: e.target.value });
              const el = e.target;
              requestAnimationFrame(() => revealCaret(el));
            }}
            onSelect={remember}
            onBlur={remember}
            placeholder={`${t("sheet.placeholderTitle")}\n${t("sheet.placeholderBody")}`}
            // Browser spellcheckers flag ordinary Korean; check only English manuscripts.
            spellCheck={state.projects.find((p) => p.id === state.ui.projectId)?.language === "en"}
            style={{
              display: "block", width: "100%", maxWidth: editor.measure, margin: "0 auto", resize: "none", overflow: "hidden",
              border: "none", outline: "none", background: "transparent", padding: 0, opacity: lease.locked ? opacity.readOnly : undefined, ...TEXT[state.prefs.textSize], ...PROSE, color: color.inkPrimary,
            }}
          />
        </article>
      ) : (
        <div style={{ flex: 1, display: "grid", placeItems: "center", padding: space[300] }}>
          <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: space[200], color: color.inkTertiary, textAlign: "center" }}>
            <Icon name="sheet" size="lg" />
            <span>{t("editor.noSheet")}</span>
            {folder && !view.trash && <Button variant="primary" icon="add" onClick={() => newSheet(app, folder.id)}>{t("sheet.new")}</Button>}
          </div>
        </div>
      )}

      {sheet && <Footer sheet={sheet} />}
    </main>
  );
}

/** Both counts always (or words for English manuscripts); goal bar when the project sets one; honest save state. */
function Footer({ sheet }: { sheet: { body: string } }) {
  const t = useT();
  const { state, saveStatus } = useApp();
  const project = state.projects.find((p) => p.id === state.ui.projectId)!;
  const c = sheetMeta(sheet).counts;
  const goal = project.goal;
  const percent = goal ? Math.min(100, Math.round((goalValue(c, goal.basis) / goal.count) * 100)) : 0;
  const saved = {
    saved: { icon: "synced" as const, tone: color.stateSuccess, label: t("sync.savedLocal") },
    pending: { icon: "synced" as const, tone: color.inkTertiary, label: t("sync.saving") },
    failed: { icon: "warning" as const, tone: color.stateDanger, label: t("sync.saveFailed") },
  }[saveStatus];
  return (
    <footer style={{ flex: "none", borderTop: hairline(color.lineSubtle), color: color.inkTertiary, ...type.caption }}>
      {goal && (
        <div style={{ height: size.strokeFocus, background: color.lineSubtle }}>
          <div style={{ height: "100%", width: `${percent}%`, background: percent >= 100 ? color.stateSuccess : color.accentPrimary }} />
        </div>
      )}
      <div style={{ minHeight: size.controlMd, display: "flex", alignItems: "center", justifyContent: "center", columnGap: space[150], flexWrap: "wrap", padding: `0 ${space[150]}` }}>
        {project.language === "ko" ? (
          <>
            <span>{t("count.withSpaces", { count: c.chars })}</span>
            <span>{t("count.withoutSpaces", { count: c.charsNoSpace })}</span>
          </>
        ) : (
          <>
            <span>{t("count.words", { count: c.words })}</span>
            <span>{t("count.withSpaces", { count: c.chars })}</span>
          </>
        )}
        {goal && <span style={{ color: color.inkSecondary }}>{t("goal.progress", { goal: goal.count, percent })}</span>}
        <span role="status" style={{ display: "inline-flex", alignItems: "center", gap: space[50], color: saved.tone, fontWeight: saveStatus === "failed" ? type.heading.fontWeight : undefined }}>
          <Icon name={saved.icon} size="sm" />
          {saved.label}
        </span>
      </div>
    </footer>
  );
}

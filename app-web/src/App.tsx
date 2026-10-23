// The usable Ithaca app (ADR-0007): the app-shell prototype made real, stored in this browser.
// Layout follows design/screens/app-shell/spec.md, with one rule from daily use on top: a pane only docks
// if the editor keeps at least EDITOR_MIN of width — otherwise it opens as an overlay. An open inspector
// outranks the library and the list: reading lore beside the manuscript is the point of opening it.
import { useEffect, useMemo, useRef, useState } from "react";
import { color, format, radius, shadow, size, space, type, Button, FrameContext, sample, sizeClassFor, type FrameInfo } from "@ithaca/kit";
import layout from "../../design/tokens/layout.json";
import { AppContext, type App as AppT, type Overlay, type Toast } from "./ctx";
import { foldersOf, resolveLocale, setAside, sheetsIn, useAppState } from "./store";
import { usePressable } from "./Dialog";
import { Library } from "./Library";
import { SheetList } from "./SheetList";
import { Editor } from "./Editor";
import { Inspector } from "./Inspector";
import { Settings } from "./Settings";
import { Palette } from "./Palette";
import { NewProject, ProjectSettings } from "./Project";
import { Export } from "./Export";

/** Narrowest editor pane worth writing in (about 460 of text after padding): the manuscript needs room, panes don't. */
const EDITOR_MIN = 600;
const W = { library: layout.panes.library.default, list: layout.panes.sheetList.default, inspector: layout.panes.inspector.default };

/** Which panes dock at this width. Priority: editor, (inspector if open), sheet list, library. */
export function panesFor(width: number, inspectorOpen: boolean) {
  if (sizeClassFor(width) === "compact") return { compact: true, list: false, library: false, inspector: false };
  let room = width - EDITOR_MIN;
  const take = (w: number) => (room >= w ? ((room -= w), true) : false);
  // Lore beside the manuscript is worth a slightly narrower editor (580) — better than an overlay over it.
  room += 20;
  const inspector = inspectorOpen && take(W.inspector);
  room -= 20;
  const list = take(W.list);
  const library = list && take(W.library);
  return { compact: false, list, library, inspector };
}

function useWindowSize() {
  const [size, setSize] = useState({ w: window.innerWidth, h: window.innerHeight });
  useEffect(() => {
    const on = () => setSize({ w: window.innerWidth, h: window.innerHeight });
    window.addEventListener("resize", on);
    return () => window.removeEventListener("resize", on);
  }, []);
  return size;
}

function useSystemDark() {
  const q = useMemo(() => window.matchMedia("(prefers-color-scheme: dark)"), []);
  const [dark, setDark] = useState(q.matches);
  useEffect(() => {
    const on = () => setDark(q.matches);
    q.addEventListener("change", on);
    return () => q.removeEventListener("change", on);
  }, [q]);
  return dark;
}

export function App() {
  const [state, dispatch, saveStatus] = useAppState();
  const { w, h } = useWindowSize();
  const systemDark = useSystemDark();
  const sizeClass = sizeClassFor(w);
  const locale = resolveLocale(state.prefs);
  const theme = state.prefs.theme === "system" ? (systemDark ? "dark" : "light") : state.prefs.theme;
  const mac = /Mac|iPhone|iPad/.test(navigator.platform);
  const touch = useMemo(() => window.matchMedia("(hover: none)").matches, []);
  const [overlay, setOverlay] = useState<Overlay>(null);
  const [view, setViewState] = useState<AppT["view"]>({ inspector: false, focus: false, libraryOpen: false, trash: false, compact: "editor" });
  const setView = (patch: Partial<AppT["view"]>) => setViewState((v) => ({ ...v, ...patch }));
  const panes = panesFor(w, view.inspector);
  const [toast, setToast] = useState<Toast | null>(null);
  const toastTimer = useRef<ReturnType<typeof setTimeout>>(undefined);

  // Saved data this version couldn't read was copied aside, not overwritten — say so once.
  useEffect(() => {
    if (setAside) app.toast({ message: format(locale, "app.setAside", { key: setAside }), sticky: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.lang = locale;
  }, [theme, locale]);

  const app: AppT = {
    state, dispatch, locale, sizeClass, panes, mac, touch, saveStatus, overlay, view, setView,
    setOverlay: (o) => {
      setOverlay(o);
      // Back to the manuscript when a dialog closes, so typing can resume without a click.
      if (!o) requestAnimationFrame(() => document.getElementById("ithaca-editor")?.focus({ preventScroll: true }));
    },
    confirm: (message) => !state.prefs.confirmDelete || window.confirm(message),
    toast: (t) => {
      clearTimeout(toastTimer.current);
      setToast(t);
      if (!t.sticky) toastTimer.current = setTimeout(() => setToast(null), 6000);
    },
  };
  useShortcuts(app);

  // The kit reads its frame from context; give it the real window.
  const frame: FrameInfo = {
    sizeClass, width: w, height: h, platform: mac ? "macos" : "windows", theme, locale, sample, textScale: 1,
    safeArea: { top: 0, right: 0, bottom: 0, left: 0 },
  };

  const root = { position: "relative" as const, display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body };
  const scrim = (onClick: () => void, zIndex: number) => <div style={{ position: "absolute", inset: 0, background: color.surfaceScrim, cursor: "pointer", zIndex }} onClick={onClick} />;
  let body;
  if (view.focus) {
    body = <Editor />;
  } else if (panes.compact) {
    body = view.compact === "library" ? <Library full /> : view.compact === "list" ? <SheetList full /> : <Editor />;
  } else {
    body = (
      <>
        {panes.library && <Library />}
        {panes.list && <SheetList />}
        <Editor />
        {view.inspector && panes.inspector && <Inspector mode="docked" />}
        {view.inspector && !panes.inspector && (
          <>
            {scrim(() => setView({ inspector: false }), 3)}
            <Inspector mode="overlay" />
          </>
        )}
        {view.libraryOpen && !panes.library && (
          <>
            {scrim(() => setView({ libraryOpen: false }), 5)}
            <div style={{ position: "absolute", top: 0, bottom: 0, left: 0, maxWidth: "100%", display: "flex", boxShadow: shadow.dialog, zIndex: 6 }}>
              <Library />
              {!panes.list && <SheetList />}
            </div>
          </>
        )}
      </>
    );
  }

  return (
    <AppContext.Provider value={app}>
      <FrameContext.Provider value={frame}>
        <div style={root}>
          {body}
          {panes.compact && view.inspector && view.compact === "editor" && !view.focus && <Inspector mode="sheet" />}
          {overlay === "settings" && <Settings />}
          {overlay === "palette" && <Palette />}
          {overlay === "newProject" && <NewProject />}
          {overlay === "projectSettings" && <ProjectSettings />}
          {overlay === "export" && <Export />}
          {toast && (
            <ToastBar
              toast={toast}
              closeLabel={format(locale, "action.close")}
              onClose={() => setToast(null)}
              onHold={(hold) => {
                clearTimeout(toastTimer.current);
                if (!hold && !toast.sticky) toastTimer.current = setTimeout(() => setToast(null), 3000);
              }}
            />
          )}
        </div>
      </FrameContext.Provider>
    </AppContext.Provider>
  );
}

function ToastBar({ toast, onClose, onHold, closeLabel }: { toast: Toast; onClose: () => void; onHold: (hold: boolean) => void; closeLabel: string }) {
  const { ringStyle, ...undo } = usePressable(() => { toast.undo?.run(); onClose(); });
  return (
    <div
      role="status"
      onMouseEnter={() => onHold(true)}
      onMouseLeave={() => onHold(false)}
      style={{ position: "absolute", left: "50%", bottom: space[600], transform: "translateX(-50%)", zIndex: 30, width: "max-content", maxWidth: `calc(100% - ${space[400]})`, display: "flex", alignItems: "center", gap: space[150], padding: `${space[100]} ${space[100]} ${space[100]} ${space[200]}`, borderRadius: radius.panel, background: color.inkPrimary, color: color.surfaceCanvas, boxShadow: shadow.popover, ...type.label }}
    >
      <span style={{ flex: "1 1 auto", minWidth: 0 }}>{toast.message}</span>
      {toast.undo && (
        <span {...undo} role="button" style={{ flex: "none", padding: `${space[50]} ${space[100]}`, borderRadius: radius.control, fontWeight: type.heading.fontWeight, cursor: "pointer", color: color.accentSoft, minHeight: size.controlSm, display: "inline-flex", alignItems: "center", ...ringStyle }}>
          {toast.undo.label}
        </span>
      )}
      {toast.sticky && <Button variant="ghost" onClick={onClose} style={{ color: color.surfaceCanvas }}>{closeLabel}</Button>}
    </div>
  );
}

/**
 * Keyboard shortcuts from preferences → Shortcuts. `mod` is ⌘ on Apple, Ctrl elsewhere.
 * Browsers keep ⌘N / ⌘⇧N for themselves, so the web build also answers to mod+Alt+N / mod+Alt+Shift+N.
 * While a dialog is open only Esc and the palette toggle apply.
 */
function useShortcuts(app: AppT) {
  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      if (e.isComposing) return;
      if (e.key === "Escape") {
        if (app.overlay) app.setOverlay(null);
        else if (app.view.inspector) {
          app.setView({ inspector: false });
          document.getElementById("ithaca-editor")?.focus({ preventScroll: true });
        }
        else if (app.view.libraryOpen) {
          app.setView({ libraryOpen: false });
          document.getElementById("ithaca-editor")?.focus({ preventScroll: true });
        }
        else if (app.view.focus) app.setView({ focus: false });
        return;
      }
      const mod = app.mac ? e.metaKey : e.ctrlKey;
      if (!mod) return;
      const run = (f: () => void) => {
        e.preventDefault();
        f();
      };
      if (e.code === "KeyK") return run(() => app.setOverlay(app.overlay === "palette" ? null : "palette"));
      if (app.overlay) return;
      const { ui } = app.state;
      if (e.code === "KeyN" && e.shiftKey) run(() => app.setOverlay("newProject"));
      else if (e.code === "KeyN") run(() => newSheet(app, ui.folderId));
      else if (e.code === "KeyF" && e.shiftKey) run(() => app.setOverlay("palette"));
      else if (e.code === "Comma") run(() => app.setOverlay("settings"));
      else if (e.code === "KeyD" && e.shiftKey) run(() => app.setView({ focus: !app.view.focus }));
      else if (e.code === "KeyI" && e.altKey) run(() => app.setView({ inspector: !app.view.inspector }));
      else if (e.code === "KeyE" && e.shiftKey) run(() => app.setOverlay("export"));
      else if (e.code === "Digit1") run(() => app.setView({ focus: false, libraryOpen: !app.panes.library, compact: "library" }));
      else if (e.code === "Digit2") run(() => app.setView({ focus: false, libraryOpen: !app.panes.list, compact: "list" }));
      else if (e.code === "Digit3") run(() => app.setView({ focus: true }));
      else if (e.altKey && (e.key === "ArrowUp" || e.key === "ArrowDown")) run(() => moveSheet(app, e.key === "ArrowUp" ? -1 : 1));
    };
    window.addEventListener("keydown", on);
    return () => window.removeEventListener("keydown", on);
  });
}

/** mod+Alt+↑/↓: move the open sheet up or down the folder's order. */
export function moveSheet(app: AppT, delta: -1 | 1) {
  const { ui } = app.state;
  const list = sheetsIn(app.state, ui.folderId);
  const i = list.findIndex((s) => s.id === ui.sheetId);
  if (i < 0) return;
  const j = i + delta;
  if (j < 0 || j >= list.length) return;
  // Insert before the sheet that will follow it.
  const before = delta < 0 ? list[j].id : list[j + 1]?.id ?? null;
  app.dispatch({ type: "reorderSheet", id: list[i].id, before });
}

export function newSheet(app: AppT, folderId: string) {
  const folder = folderId || foldersOf(app.state, app.state.ui.projectId)[0]?.id;
  if (!folder) return;
  // Reuse an untouched empty sheet at the end instead of piling up blanks (one mid-list stays where it is).
  const last = sheetsIn(app.state, folder).at(-1);
  if (last && !last.body.trim()) app.dispatch({ type: "selectSheet", id: last.id });
  else app.dispatch({ type: "newSheet", folderId: folder });
  app.setView({ trash: false, compact: "editor", libraryOpen: false });
  requestAnimationFrame(() => document.getElementById("ithaca-editor")?.focus());
}

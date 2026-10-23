// App state: projects → folders → sheets (PRODUCT.md), UI selection and preferences.
// Persisted to localStorage for now. The shape mirrors what the Rust core will own later, so
// moving to the core is a storage swap, not a redesign.
import { useEffect, useReducer, useRef, useState } from "react";
import { format, type Locale } from "@ithaca/kit";

export type ManuscriptLanguage = "ko" | "en";
export type GoalBasis = "withSpaces" | "withoutSpaces" | "words";

export interface Project {
  id: string;
  title: string;
  language: ManuscriptLanguage;
  goal: { count: number; basis: GoalBasis } | null;
  created: number;
  /** Deleted projects are kept 30 days (undo, backup) before they are dropped. */
  deleted?: number;
}

export interface Folder {
  id: string;
  projectId: string;
  name: string;
  order: number;
  /** Deleted folders stay (hidden) while the trash still holds their sheets, so restore can bring them back. */
  deleted?: number;
}

export interface Sheet {
  id: string;
  folderId: string;
  body: string;
  /** Position in the folder — serial order, set by the writer (ADR-0002: the table of contents is the writer's). */
  order: number;
  created: number;
  modified: number;
  /** Set when moved to the trash; emptied after 30 days. */
  trashed?: number;
}

export interface Prefs {
  locale: "system" | Locale;
  theme: "system" | "light" | "dark";
  textSize: "small" | "normal" | "large";
  confirmDelete: boolean;
  /** When the last backup file was downloaded — drives the backup reminder. */
  lastBackup?: number;
}

export interface UI {
  projectId: string;
  folderId: string;
  sheetId: string | null;
  /** Where each project was left, so switching back returns to the same sheet. */
  last?: Record<string, { folderId: string; sheetId: string | null }>;
}

export interface State {
  version: 1;
  projects: Project[];
  folders: Folder[];
  sheets: Sheet[];
  ui: UI;
  prefs: Prefs;
}

const KEY = "ithaca.state.v1";
/** The selection is per tab and saved apart from the data, so tabs share manuscripts but not where they are. */
const UI_KEY = "ithaca.ui.v1";
const TRASH_DAYS = 30;
const DAY = 86_400_000;
const DEFAULT_PREFS: Prefs = { locale: "system", theme: "system", textSize: "normal", confirmDelete: true };

export const uid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);

export function systemLocale(): Locale {
  return navigator.language.toLowerCase().startsWith("ko") ? "ko" : "en";
}

/** A new project with the given (or default) folders and one empty sheet in the first. */
export function makeProject(title: string, language: ManuscriptLanguage, folderNames?: string[]) {
  const now = Date.now();
  const project: Project = { id: uid(), title, language, goal: null, created: now };
  const names = folderNames?.length ? folderNames : [format(language, "folder.defaultSerial"), format(language, "folder.defaultLore"), format(language, "folder.defaultMaterial")];
  const folders: Folder[] = names.map((name, order) => ({ id: uid(), projectId: project.id, name, order }));
  const sheet: Sheet = { id: uid(), folderId: folders[0].id, body: "", order: 0, created: now, modified: now };
  return { project, folders, sheet };
}

function initial(): State {
  const locale = systemLocale();
  const { project, folders, sheet } = makeProject(format(locale, "app.firstProject"), locale);
  return {
    version: 1,
    projects: [project],
    folders,
    sheets: [sheet],
    ui: { projectId: project.id, folderId: folders[0].id, sheetId: sheet.id },
    prefs: { ...DEFAULT_PREFS },
  };
}

// ── Queries ───────────────────────────────────────────────────────────

export const liveProjects = (s: State) => s.projects.filter((p) => !p.deleted);

/** Live folders of a project, in the writer's order. */
export function foldersOf(s: State, projectId: string) {
  return s.folders.filter((f) => f.projectId === projectId && !f.deleted).sort((a, b) => a.order - b.order);
}

/** Live sheets of a folder in serial order. */
export function sheetsIn(s: State, folderId: string) {
  return s.sheets.filter((x) => x.folderId === folderId && !x.trashed).sort((a, b) => a.order - b.order || a.created - b.created);
}

/** Trashed sheets of a project, including those whose folder was deleted. */
export function trashOf(s: State, projectId: string) {
  const ids = new Set(s.folders.filter((f) => f.projectId === projectId).map((f) => f.id));
  return s.sheets.filter((x) => x.trashed && ids.has(x.folderId)).sort((a, b) => b.trashed! - a.trashed!);
}

export const liveSheets = (s: State) => {
  const live = new Set(s.folders.filter((f) => !f.deleted).map((f) => f.id));
  return s.sheets.filter((x) => !x.trashed && live.has(x.folderId));
};

// ── Integrity ─────────────────────────────────────────────────────────

/**
 * Makes any loaded or restored state safe to render: fills defaults, drops orphans, assigns missing orders,
 * empties expired trash, removes deleted folders nothing refers to, and points the UI at something that exists.
 * Returns null when the input isn't recognisably ours.
 */
export function normalize(input: unknown): State | null {
  const raw = input as Partial<State> | null;
  if (!raw || raw.version !== 1 || !Array.isArray(raw.projects) || !Array.isArray(raw.folders) || !Array.isArray(raw.sheets)) return null;
  const projects = raw.projects.filter((p): p is Project => !!p && typeof p.id === "string").map((p) => ({
    ...p,
    title: typeof p.title === "string" ? p.title : "",
    language: p.language === "en" ? "en" : "ko",
    created: Number(p.created) || Date.now(),
    goal: p.goal && p.goal.count > 0 ? p.goal : null,
  }) as Project);
  if (!projects.length) return null;
  const expired = (p: Project) => !!p.deleted && p.deleted <= Date.now() - TRASH_DAYS * DAY;
  projects.splice(0, projects.length, ...projects.filter((p) => !expired(p)));
  if (!projects.some((p) => !p.deleted) && projects.length) projects[0] = { ...projects[0], deleted: undefined };
  if (!projects.length) return null;
  const projectIds = new Set(projects.map((p) => p.id));
  let folders = raw.folders.filter((f): f is Folder => !!f && typeof f.id === "string" && projectIds.has(f.projectId));
  const folderIds = new Set(folders.map((f) => f.id));
  const cutoff = Date.now() - TRASH_DAYS * DAY;
  let sheets = raw.sheets
    .filter((x): x is Sheet => !!x && typeof x.id === "string" && typeof x.body === "string" && folderIds.has(x.folderId))
    .filter((x) => !x.trashed || x.trashed > cutoff);
  // A sheet in a deleted folder that isn't in the trash would be invisible: put it in the trash.
  const deleted = new Set(folders.filter((f) => f.deleted).map((f) => f.id));
  sheets = sheets.map((x) => (deleted.has(x.folderId) && !x.trashed ? { ...x, trashed: Date.now() } : x));
  // Older saves have no order: keep their creation order.
  if (sheets.some((x) => typeof x.order !== "number")) {
    const byFolder = new Map<string, Sheet[]>();
    for (const x of sheets) byFolder.set(x.folderId, [...(byFolder.get(x.folderId) ?? []), x]);
    const order = new Map<string, number>();
    for (const list of byFolder.values()) list.sort((a, b) => a.created - b.created).forEach((x, i) => order.set(x.id, i));
    sheets = sheets.map((x) => (typeof x.order === "number" ? x : { ...x, order: order.get(x.id)! }));
  }
  const used = new Set(sheets.map((x) => x.folderId));
  folders = folders.filter((f) => !f.deleted || used.has(f.id));
  // Every project keeps at least one live folder, so there is always somewhere to write.
  for (const p of projects) {
    if (!folders.some((f) => f.projectId === p.id && !f.deleted)) folders.push({ id: uid(), projectId: p.id, name: format(p.language, "folder.defaultSerial"), order: 0 });
  }
  folders = folders.map((f) => ({ ...f, name: typeof f.name === "string" ? f.name : String(f.name ?? ""), order: Number(f.order) || 0 }));
  const p = (raw.prefs ?? {}) as Partial<Prefs>;
  const pick = <T,>(v: unknown, ok: readonly T[], d: T) => (ok.includes(v as T) ? (v as T) : d);
  const prefs: Prefs = {
    locale: pick(p.locale, ["system", "ko", "en"] as const, "system"),
    theme: pick(p.theme, ["system", "light", "dark"] as const, "system"),
    textSize: pick(p.textSize, ["small", "normal", "large"] as const, "normal"),
    confirmDelete: p.confirmDelete !== false,
    lastBackup: typeof p.lastBackup === "number" ? p.lastBackup : undefined,
  };
  const rawUI = raw.ui && typeof raw.ui === "object" ? raw.ui : { projectId: "", folderId: "", sheetId: null };
  const s: State = { version: 1, projects, folders, sheets, prefs, ui: rawUI };
  return { ...s, ui: fixUI(s, s.ui) };
}

/** Keeps the selection pointing at things that exist. */
function fixUI(s: State, ui: UI): UI {
  const live = liveProjects(s);
  const projectId = live.some((p) => p.id === ui.projectId) ? ui.projectId : (live[0] ?? s.projects[0]).id;
  const folders = foldersOf(s, projectId);
  const folderId = folders.some((f) => f.id === ui.folderId) ? ui.folderId : folders[0]?.id ?? "";
  const sheets = sheetsIn(s, folderId);
  const sheetId = ui.sheetId && sheets.some((x) => x.id === ui.sheetId) ? ui.sheetId : sheets[sheets.length - 1]?.id ?? null;
  return { ...ui, projectId, folderId, sheetId, last: { ...ui.last, [projectId]: { folderId, sheetId } } };
}

/** Drops deleted folders whose last trashed sheet is gone. */
function dropEmptyDeletedFolders(s: State): State {
  const used = new Set(s.sheets.map((x) => x.folderId));
  return { ...s, folders: s.folders.filter((f) => !f.deleted || used.has(f.id)) };
}

// ── Actions ───────────────────────────────────────────────────────────

export type Action =
  | { type: "selectProject"; id: string }
  | { type: "selectFolder"; id: string }
  | { type: "selectSheet"; id: string | null }
  | { type: "newSheet"; folderId: string; body?: string }
  | { type: "editSheet"; id: string; body: string }
  | { type: "trashSheet"; id: string }
  | { type: "restoreSheet"; id: string }
  | { type: "deleteSheet"; id: string }
  | { type: "emptyTrash"; projectId: string }
  | { type: "moveSheet"; id: string; folderId: string }
  | { type: "reorderSheet"; id: string; before: string | null }
  | { type: "newFolder"; projectId: string; name: string }
  | { type: "renameFolder"; id: string; name: string }
  | { type: "deleteFolder"; id: string }
  | { type: "newProject"; title: string; language: ManuscriptLanguage; folders: string[] }
  | { type: "updateProject"; id: string; patch: Partial<Omit<Project, "id">> }
  | { type: "deleteProject"; id: string }
  | { type: "undeleteProject"; id: string }
  | { type: "undeleteFolder"; id: string }
  /** Add a backup's projects as copies next to the current ones (nothing is overwritten). */
  | { type: "importCopies"; state: State; suffix: string }
  | { type: "prefs"; patch: Partial<Prefs> }
  | { type: "replace"; state: State }
  /** Another tab saved: take its data, keep this tab's selection and anything edited here since our last save. */
  | { type: "external"; state: State; since: number };

const nextOrder = (s: State, folderId: string) => Math.max(-1, ...s.sheets.filter((x) => x.folderId === folderId && !x.trashed).map((x) => x.order)) + 1;

function reduce(s: State, a: Action): State {
  const now = Date.now();
  const withUI = (next: State, ui: Partial<UI>) => ({ ...next, ui: fixUI(next, { ...next.ui, ...ui }) });
  switch (a.type) {
    case "selectProject": {
      const last = s.ui.last?.[a.id];
      return withUI(s, { projectId: a.id, folderId: last?.folderId ?? "", sheetId: last?.sheetId ?? null });
    }
    case "selectFolder": {
      const sheets = sheetsIn(s, a.id);
      // Reopen the folder at the sheet last written in.
      const recent = [...sheets].sort((x, y) => y.modified - x.modified)[0];
      return withUI(s, { folderId: a.id, sheetId: recent?.id ?? null });
    }
    case "selectSheet":
      return withUI(s, { sheetId: a.id });
    case "newSheet": {
      const sheet: Sheet = { id: uid(), folderId: a.folderId, body: a.body ?? "", order: nextOrder(s, a.folderId), created: now, modified: now };
      return withUI({ ...s, sheets: [...s.sheets, sheet] }, { folderId: a.folderId, sheetId: sheet.id });
    }
    case "editSheet":
      return { ...s, sheets: s.sheets.map((x) => (x.id === a.id ? { ...x, body: a.body, modified: now } : x)) };
    case "trashSheet": {
      const sheet = s.sheets.find((x) => x.id === a.id);
      if (!sheet) return s;
      const next = { ...s, sheets: s.sheets.map((x) => (x.id === a.id ? { ...x, trashed: now } : x)) };
      if (s.ui.sheetId !== a.id) return next;
      // Open the neighbour, as a list does after a delete.
      const list = sheetsIn(s, sheet.folderId);
      const i = list.findIndex((x) => x.id === a.id);
      return withUI(next, { sheetId: (list[i + 1] ?? list[i - 1])?.id ?? null });
    }
    case "restoreSheet": {
      const sheet = s.sheets.find((x) => x.id === a.id);
      if (!sheet) return s;
      // Bring the folder back too if it was deleted with the sheet.
      const folders = s.folders.map((f) => (f.id === sheet.folderId ? { ...f, deleted: undefined } : f));
      // It keeps its old order, so an undone trash puts the episode back where it was.
      const next = { ...s, folders, sheets: s.sheets.map((x) => (x.id === a.id ? { ...x, trashed: undefined } : x)) };
      return withUI(next, { folderId: sheet.folderId, sheetId: a.id });
    }
    case "deleteSheet":
      return withUI(dropEmptyDeletedFolders({ ...s, sheets: s.sheets.filter((x) => x.id !== a.id) }), {});
    case "emptyTrash": {
      const trash = new Set(trashOf(s, a.projectId).map((x) => x.id));
      return withUI(dropEmptyDeletedFolders({ ...s, sheets: s.sheets.filter((x) => !trash.has(x.id)) }), {});
    }
    case "moveSheet":
      return withUI({ ...s, sheets: s.sheets.map((x) => (x.id === a.id ? { ...x, folderId: a.folderId, order: nextOrder(s, a.folderId) } : x)) }, {});
    case "reorderSheet": {
      const sheet = s.sheets.find((x) => x.id === a.id);
      if (!sheet || a.id === a.before) return s;
      const list = sheetsIn(s, sheet.folderId).filter((x) => x.id !== a.id);
      const at = a.before ? list.findIndex((x) => x.id === a.before) : list.length;
      list.splice(at < 0 ? list.length : at, 0, sheet);
      const order = new Map(list.map((x, i) => [x.id, i]));
      return { ...s, sheets: s.sheets.map((x) => (order.has(x.id) ? { ...x, order: order.get(x.id)! } : x)) };
    }
    case "newFolder": {
      const order = Math.max(-1, ...foldersOf(s, a.projectId).map((f) => f.order)) + 1;
      const folder: Folder = { id: uid(), projectId: a.projectId, name: a.name, order };
      return withUI({ ...s, folders: [...s.folders, folder] }, { folderId: folder.id, sheetId: null });
    }
    case "renameFolder":
      return { ...s, folders: s.folders.map((f) => (f.id === a.id ? { ...f, name: a.name } : f)) };
    case "deleteFolder": {
      const folders = s.folders.map((f) => (f.id === a.id ? { ...f, deleted: now } : f));
      const sheets = s.sheets.map((x) => (x.folderId === a.id && !x.trashed ? { ...x, trashed: now } : x));
      const next = dropEmptyDeletedFolders({ ...s, folders, sheets });
      // normalize() guarantees a live folder per project; do the same here.
      const projectId = s.folders.find((f) => f.id === a.id)?.projectId ?? s.ui.projectId;
      const project = s.projects.find((p) => p.id === projectId)!;
      const withFolder = foldersOf(next, projectId).length ? next : { ...next, folders: [...next.folders, { id: uid(), projectId, name: format(project.language, "folder.defaultSerial"), order: 0 }] };
      return withUI(withFolder, s.ui.folderId === a.id ? { folderId: "", sheetId: null } : {});
    }
    case "newProject": {
      const { project, folders, sheet } = makeProject(a.title, a.language, a.folders);
      return withUI({ ...s, projects: [...s.projects, project], folders: [...s.folders, ...folders], sheets: [...s.sheets, sheet] }, { projectId: project.id, folderId: folders[0].id, sheetId: sheet.id });
    }
    case "updateProject":
      return { ...s, projects: s.projects.map((p) => (p.id === a.id ? { ...p, ...a.patch } : p)) };
    case "deleteProject": {
      if (liveProjects(s).length <= 1) return s;
      const next = { ...s, projects: s.projects.map((p) => (p.id === a.id ? { ...p, deleted: now } : p)) };
      return withUI(next, s.ui.projectId === a.id ? { projectId: "" } : {});
    }
    case "undeleteProject": {
      const next = { ...s, projects: s.projects.map((p) => (p.id === a.id ? { ...p, deleted: undefined } : p)) };
      return withUI(next, { projectId: a.id, folderId: s.ui.last?.[a.id]?.folderId ?? "", sheetId: s.ui.last?.[a.id]?.sheetId ?? null });
    }
    case "undeleteFolder": {
      // Undo a folder delete: the folder and the sheets trashed with it (same moment) come back.
      const folder = s.folders.find((f) => f.id === a.id);
      if (!folder?.deleted) return s;
      const at = folder.deleted;
      return withUI({
        ...s,
        folders: s.folders.map((f) => (f.id === a.id ? { ...f, deleted: undefined } : f)),
        sheets: s.sheets.map((x) => (x.folderId === a.id && x.trashed === at ? { ...x, trashed: undefined } : x)),
      }, { folderId: a.id, sheetId: null });
    }
    case "importCopies": {
      // New ids everywhere so the copies never collide with what is here.
      const ids = new Map<string, string>();
      const id = (old: string) => ids.get(old) ?? (ids.set(old, uid()), ids.get(old)!);
      const projects = liveProjects(a.state).map((p) => ({ ...p, id: id(p.id), title: `${p.title} ${a.suffix}` }));
      const keep = new Set(liveProjects(a.state).map((p) => p.id));
      const folders = a.state.folders.filter((f) => keep.has(f.projectId) && !f.deleted).map((f) => ({ ...f, id: id(f.id), projectId: id(f.projectId) }));
      const folderIds = new Set(a.state.folders.filter((f) => keep.has(f.projectId) && !f.deleted).map((f) => f.id));
      const sheets = a.state.sheets.filter((x) => folderIds.has(x.folderId) && !x.trashed).map((x) => ({ ...x, id: id(x.id), folderId: id(x.folderId) }));
      if (!projects.length) return s;
      return withUI({ ...s, projects: [...s.projects, ...projects], folders: [...s.folders, ...folders], sheets: [...s.sheets, ...sheets] }, { projectId: projects[0].id, folderId: "", sheetId: null });
    }
    case "prefs":
      return { ...s, prefs: { ...s.prefs, ...a.patch } };
    case "replace":
      return a.state;
    case "external": {
      // Sheets touched here after our last save win over the other tab's copy, so neither tab's typing is lost.
      const mine = new Map(s.sheets.filter((x) => x.modified > a.since || x.created > a.since).map((x) => [x.id, x]));
      const sheets = [...a.state.sheets.map((x) => mine.get(x.id) ?? x), ...[...mine.values()].filter((x) => !a.state.sheets.some((y) => y.id === x.id))];
      const folderIds = new Set(a.state.folders.map((f) => f.id));
      const folders = [...a.state.folders, ...s.folders.filter((f) => !folderIds.has(f.id) && sheets.some((x) => x.folderId === f.id))];
      const next = { ...a.state, folders, sheets };
      return { ...next, ui: fixUI(next, s.ui) };
    }
  }
}

export function resolveLocale(p: Prefs): Locale {
  return p.locale === "system" ? systemLocale() : p.locale;
}

/** Set when saved data couldn't be read and was set aside instead of overwritten. */
export let setAside: string | null = null;

function load(): State {
  const raw = localStorage.getItem(KEY);
  if (!raw) return initial();
  try {
    const ui = JSON.parse(localStorage.getItem(UI_KEY) ?? "null");
    const s = normalize({ ...JSON.parse(raw), ...(ui ? { ui } : {}) });
    if (s) return s;
  } catch {
    // fall through
  }
  // Unreadable (newer version, damaged): keep a copy rather than overwrite someone's manuscripts.
  setAside = `${KEY}.unreadable.${Date.now()}`;
  try {
    localStorage.setItem(setAside, raw);
  } catch {
    setAside = null;
  }
  return initial();
}

export type SaveStatus = "saved" | "pending" | "failed";

/**
 * The whole app state. Saves shortly after each change, immediately when the tab hides or closes,
 * and follows saves from other tabs so two open tabs don't overwrite each other.
 */
export function useAppState() {
  const [state, dispatch] = useReducer(reduce, undefined, load);
  const [status, setStatus] = useState<SaveStatus>("saved");
  const latest = useRef(state);
  const written = useRef<string | null>(null);
  const savedAt = useRef(Date.now());
  latest.current = state;

  const save = () => {
    const { ui, ...data } = latest.current;
    const text = JSON.stringify(data);
    try {
      if (text !== written.current) localStorage.setItem(KEY, text);
      written.current = text;
      localStorage.setItem(UI_KEY, JSON.stringify(ui));
      savedAt.current = Date.now();
      setStatus("saved");
    } catch {
      setStatus("failed");
    }
  };

  useEffect(() => {
    setStatus("pending");
    const t = setTimeout(save, 300);
    return () => clearTimeout(t);
  }, [state]);

  useEffect(() => {
    const flush = () => save();
    const onHide = () => document.visibilityState === "hidden" && save();
    const onStorage = (e: StorageEvent) => {
      if (e.key !== KEY || !e.newValue || e.newValue === written.current) return;
      try {
        const next = normalize({ ...JSON.parse(e.newValue), ui: latest.current.ui });
        if (!next) return;
        written.current = e.newValue;
        dispatch({ type: "external", state: next, since: savedAt.current });
      } catch {
        // A half-written value from another tab; its next save will arrive.
      }
    };
    window.addEventListener("pagehide", flush);
    window.addEventListener("beforeunload", flush);
    document.addEventListener("visibilitychange", onHide);
    window.addEventListener("storage", onStorage);
    return () => {
      window.removeEventListener("pagehide", flush);
      window.removeEventListener("beforeunload", flush);
      document.removeEventListener("visibilitychange", onHide);
      window.removeEventListener("storage", onStorage);
    };
  }, []);

  return [state, dispatch, status] as const;
}

/** For a JSON backup file: the full state as text, and back. */
export const exportState = (s: State) => JSON.stringify(s, null, 2);
export function parseState(text: string): State | null {
  try {
    return normalize(JSON.parse(text));
  } catch {
    return null;
  }
}

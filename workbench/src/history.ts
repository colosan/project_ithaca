import { useSyncExternalStore } from "react";

/** One undoable edit. `undo`/`redo` restore whole snapshots, so they work even if the view that made the edit is gone. */
export interface Entry {
  label: string;
  undo: () => void;
  redo: () => void;
  /** Edits with the same key within COALESCE_MS merge into one step (typing a number digit by digit). */
  key?: string;
  at: number;
}

export interface HistoryState {
  undoLabel: string | null;
  redoLabel: string | null;
  /** Last undo/redo, for the toast. */
  flash: { text: string; at: number } | null;
}

const LIMIT = 100;
const COALESCE_MS = 1000;
const past: Entry[] = [];
const future: Entry[] = [];
let state: HistoryState = { undoLabel: null, redoLabel: null, flash: null };
const listeners = new Set<() => void>();

function emit(flash: HistoryState["flash"] = state.flash) {
  state = { undoLabel: past.at(-1)?.label ?? null, redoLabel: future.at(-1)?.label ?? null, flash };
  listeners.forEach((l) => l());
}

export function record(entry: Omit<Entry, "at">) {
  const at = Date.now();
  const last = past.at(-1);
  if (entry.key && last?.key === entry.key && at - last.at < COALESCE_MS) {
    // Keep the oldest undo, take the newest redo.
    last.redo = entry.redo;
    last.label = entry.label;
    last.at = at;
  } else {
    past.push({ ...entry, at });
    if (past.length > LIMIT) past.shift();
  }
  future.length = 0;
  emit();
}

export function undo() {
  const e = past.pop();
  if (!e) return;
  e.undo();
  future.push(e);
  emit({ text: `↶ 되돌림 · ${e.label}`, at: Date.now() });
}

export function redo() {
  const e = future.pop();
  if (!e) return;
  e.redo();
  past.push({ ...e, at: 0 }); // at 0: a redone step never coalesces with the next edit
  emit({ text: `↷ 다시 실행 · ${e.label}`, at: Date.now() });
}

export function useHistory(): HistoryState {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => state,
  );
}

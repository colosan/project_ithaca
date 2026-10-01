import { useCallback } from "react";
import { createStore, useStore, type Store } from "./store";

const PREFIX = "ithaca.workbench.";

/**
 * Per-viewer settings (theme, zoom, panels…) in localStorage, backed by shared stores so every component using
 * the same key stays in sync and "reset to initial state" can change them live. Storage can be unavailable;
 * the viewer must still work.
 */
const prefs = new Map<string, { store: Store<unknown>; initial: unknown }>();

function prefStore<T>(key: string, initial: T): Store<T> {
  let entry = prefs.get(key);
  if (!entry) {
    let value: unknown = initial;
    try {
      const raw = localStorage.getItem(PREFIX + key);
      if (raw !== null) value = JSON.parse(raw);
    } catch {
      /* fall back to the default */
    }
    const store = createStore<unknown>(value, (v) => {
      try {
        localStorage.setItem(PREFIX + key, JSON.stringify(v));
      } catch {
        /* ignore */
      }
    });
    entry = { store, initial };
    prefs.set(key, entry);
  }
  return entry.store as Store<T>;
}

export function usePref<T>(key: string, initial: T): [T, (v: T | ((prev: T) => T)) => void] {
  const store = prefStore(key, initial);
  const value = useStore(store);
  const set = useCallback(
    (v: T | ((prev: T) => T)) => store.set(typeof v === "function" ? (v as (p: T) => T)(store.get()) : v),
    [store],
  );
  return [value, set];
}

/** Every workbench key in localStorage (prefs and anything else under the prefix). */
export function snapshotPrefs(): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i)!;
      if (k.startsWith(PREFIX)) out[k] = localStorage.getItem(k)!;
    }
  } catch {
    /* ignore */
  }
  return out;
}

function clearStorage() {
  try {
    Object.keys(snapshotPrefs()).forEach((k) => localStorage.removeItem(k));
  } catch {
    /* ignore */
  }
}

/** Back to defaults: storage cleared, live stores set to their initial values. */
export function resetPrefs() {
  clearStorage();
  prefs.forEach(({ store, initial }) => store.set(initial, { persist: false }));
}

export function restorePrefs(snapshot: Record<string, string>) {
  clearStorage();
  try {
    Object.entries(snapshot).forEach(([k, v]) => localStorage.setItem(k, v));
  } catch {
    /* ignore */
  }
  prefs.forEach(({ store, initial }, key) => {
    const raw = snapshot[PREFIX + key];
    store.set(raw === undefined ? initial : JSON.parse(raw), { persist: false });
  });
}

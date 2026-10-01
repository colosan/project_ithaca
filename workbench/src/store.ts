import { useSyncExternalStore } from "react";
import { record } from "./history";

/**
 * A tiny external store. Edits live outside components so undo/redo can restore them from any view.
 * `persist` runs on every committed value (not on gesture previews).
 */
export interface Store<T> {
  get(): T;
  set(next: T, opts?: { persist?: boolean }): void;
  subscribe(listener: () => void): () => void;
}

export function createStore<T>(initial: T, persist?: (value: T) => void): Store<T> {
  let value = initial;
  const listeners = new Set<() => void>();
  return {
    get: () => value,
    set(next, opts) {
      value = next;
      if (opts?.persist !== false) persist?.(next);
      listeners.forEach((l) => l());
    },
    subscribe(l) {
      listeners.add(l);
      return () => listeners.delete(l);
    },
  };
}

export function useStore<T>(store: Store<T>): T {
  return useSyncExternalStore(store.subscribe, store.get);
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/** A single undoable edit. Pass `key` to merge rapid repeats (e.g. typing into a number field). */
export function commit<T>(store: Store<T>, next: T, label: string, key?: string) {
  const prev = store.get();
  if (same(prev, next)) return;
  store.set(next);
  record({ label, key, undo: () => store.set(prev), redo: () => store.set(next) });
}

/** A drag: many previews, one history step. `end` records nothing if the value did not change. */
export function gesture<T>(store: Store<T>) {
  const start = store.get();
  return {
    move(next: T) {
      store.set(next, { persist: false });
    },
    end(label: string) {
      const end = store.get();
      store.set(end); // persist the final value once
      if (same(start, end)) return;
      record({ label, undo: () => store.set(start), redo: () => store.set(end) });
    },
  };
}

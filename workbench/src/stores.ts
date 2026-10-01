// Undoable workbench state: the detail view's frames and the canvas card positions.
import type { FrameSpec } from "./Frame";
import { record } from "./history";
import { resetPrefs, restorePrefs, snapshotPrefs } from "./prefs";
import { detailDefaults, viewportById } from "./registry";
import { createStore } from "./store";

// ── Detail frames (per viewer, localStorage) ─────────────────────────────

const FRAMES_KEY = "ithaca.workbench.detail.frames";

let frameSeq = 0;
export const newFrame = (presetId: string): FrameSpec => {
  const v = viewportById[presetId];
  return { id: `f${Date.now()}-${frameSeq++}`, preset: v.id, platform: v.os, w: v.width, h: v.height };
};
export const defaultFrames = () => detailDefaults.filter((id) => viewportById[id]).map(newFrame);

function loadFrames(): FrameSpec[] {
  try {
    const raw = localStorage.getItem(FRAMES_KEY);
    if (!raw) return defaultFrames();
    // Frames saved before `platform` existed get it back from their preset.
    return (JSON.parse(raw) as FrameSpec[]).map((f) => (f.platform ? f : { ...f, platform: viewportById[f.preset ?? ""]?.os ?? "ios" }));
  } catch {
    return defaultFrames();
  }
}

export const framesStore = createStore<FrameSpec[]>(loadFrames(), (v) => {
  try {
    localStorage.setItem(FRAMES_KEY, JSON.stringify(v));
  } catch {
    /* storage unavailable — frames still work for this session */
  }
});

// ── Canvas positions (shared, design/canvas.json via the dev server) ─────

export type Positions = Record<string, { x: number; y: number }>;

/** null until the first load from the server finishes. */
export const positionsStore = createStore<Positions | null>(null, (positions) => {
  if (!positions) return;
  fetch("/__canvas", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ positions }) });
});

// ── Reset everything (one undoable step) ─────────────────────────────────

/** Frames, canvas positions and every view setting back to their defaults. Undo restores all of it. */
export function resetAll() {
  const before = { prefs: snapshotPrefs(), frames: framesStore.get(), positions: positionsStore.get() };
  const frames = defaultFrames();
  const apply = () => {
    resetPrefs();
    framesStore.set(frames);
    positionsStore.set({});
  };
  apply();
  record({
    label: "처음 상태로",
    undo: () => {
      restorePrefs(before.prefs);
      framesStore.set(before.frames);
      if (before.positions) positionsStore.set(before.positions);
    },
    redo: apply,
  });
}

let loading = false;
export function loadPositions() {
  if (loading) return;
  loading = true;
  fetch("/__canvas")
    .then((r) => r.json())
    .then((j) => positionsStore.set(j.positions ?? {}, { persist: false }))
    .catch(() => positionsStore.set({}, { persist: false }));
}

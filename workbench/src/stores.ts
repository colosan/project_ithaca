// Undoable workbench state: the detail view's frames and the canvas card positions.
import { SECTORS, type FrameSpec } from "./Frame";
import { record } from "./history";
import { resetPrefs, restorePrefs, snapshotPrefs } from "./prefs";
import { detailDefaults, viewportById } from "./registry";
import { createStore } from "./store";

// ── Detail frames (per viewer, localStorage) ─────────────────────────────

const FRAMES_KEY = "ithaca.workbench.detail.frames";

let frameSeq = 0;
/** "ipad-pro-11-m4" or "ipad-pro-11-m4:landscape". */
export const newFrame = (spec: string): FrameSpec => {
  const [presetId, orientation] = spec.split(":");
  const v = viewportById[presetId];
  const rotate = orientation === "landscape" ? v.width < v.height : orientation === "portrait" ? v.width > v.height : false;
  return { id: `f${Date.now()}-${frameSeq++}`, preset: v.id, platform: v.os, w: rotate ? v.height : v.width, h: rotate ? v.width : v.height };
};
export const defaultFrames = () => detailDefaults.filter((spec) => viewportById[spec.split(":")[0]]).map(newFrame);

/** The device row holds exactly one frame per platform, in sector order; missing platforms get their default. */
export function normalizeDevices(list: FrameSpec[]): FrameSpec[] {
  const defaults = defaultFrames();
  return SECTORS.map((s) => list.find((f) => f.platform === s.os) ?? defaults.find((f) => f.platform === s.os)).filter(
    (f): f is FrameSpec => !!f,
  );
}

function loadFrames(): FrameSpec[] {
  try {
    const raw = localStorage.getItem(FRAMES_KEY);
    if (!raw) return normalizeDevices([]);
    // Frames saved before `platform` existed get it back from their preset.
    return normalizeDevices((JSON.parse(raw) as FrameSpec[]).map((f) => (f.platform ? f : { ...f, platform: viewportById[f.preset ?? ""]?.os ?? "ios" })));
  } catch {
    return normalizeDevices([]);
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
  const frames = normalizeDevices([]);
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

import type { ComponentType } from "react";
import type { Platform } from "@ithaca/kit";
import viewportsJson from "../../design/viewports.json";

// ── Screens ──────────────────────────────────────────────────────────────

export type Bilingual = { ko: string; en: string };

export interface ScreenLink {
  /** State of this screen the link starts from. */
  from: string;
  /** Target: "<slug>" (its first state, or a planned screen) or "<slug>#<state>". */
  to: string;
  label: Bilingual;
}

export interface ScreenMeta {
  title: Bilingual;
  description?: string;
  version: string;
  /** Spec only, no prototype yet — shown as a dashed placeholder. */
  planned?: boolean;
  links?: ScreenLink[];
}

interface PrototypeModule {
  default: ComponentType<{ state: string }>;
  states: readonly string[];
}

export interface Screen {
  slug: string;
  meta: ScreenMeta;
  spec: string;
  Prototype: ComponentType<{ state: string }>;
  states: readonly string[];
}

export interface PlannedScreen {
  slug: string;
  meta: ScreenMeta;
  spec: string;
}

const protos = import.meta.glob<PrototypeModule>("../../design/screens/*/prototype.tsx", { eager: true });
const metas = import.meta.glob<ScreenMeta>("../../design/screens/*/meta.json", { eager: true, import: "default" });
const specs = import.meta.glob<string>("../../design/screens/*/spec.md", { eager: true, query: "?raw", import: "default" });

const slugOf = (path: string) => path.split("/").at(-2)!;
const bySlug = <T,>(mods: Record<string, T>) => Object.fromEntries(Object.entries(mods).map(([p, m]) => [slugOf(p), m]));

const protoBySlug = bySlug(protos);
const metaBySlug = bySlug(metas);
const specBySlug = bySlug(specs);

export const screens: Screen[] = Object.entries(protoBySlug)
  .filter(([slug]) => metaBySlug[slug])
  .map(([slug, mod]) => ({
    slug,
    meta: metaBySlug[slug],
    spec: specBySlug[slug] ?? "",
    Prototype: mod.default,
    states: mod.states,
  }))
  .sort((a, b) => a.slug.localeCompare(b.slug));

export const planned: PlannedScreen[] = Object.entries(metaBySlug)
  .filter(([slug, meta]) => meta.planned && !protoBySlug[slug])
  .map(([slug, meta]) => ({ slug, meta, spec: specBySlug[slug] ?? "" }))
  .sort((a, b) => a.slug.localeCompare(b.slug));

export const screenBySlug = Object.fromEntries(screens.map((s) => [s.slug, s]));
export const plannedBySlug = Object.fromEntries(planned.map((s) => [s.slug, s]));

/** First "# …" heading and first plain paragraph of a spec — used on placeholder cards. */
export function specSummary(spec: string): string {
  return (
    spec
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l && !l.startsWith("#") && !l.startsWith("|") && !l.startsWith(">") && !l.startsWith("-")) ?? ""
  );
}

// ── Navigation graph ─────────────────────────────────────────────────────

/** A card: one state of one screen, or a planned screen (state = null). */
export interface GraphNode {
  id: string;
  slug: string;
  state: string | null;
  title: Bilingual;
  screen: Screen | null;
  planned: PlannedScreen | null;
}

export interface GraphEdge {
  from: string;
  to: string;
  label: Bilingual;
}

export const nodeId = (slug: string, state: string | null) => (state ? `${slug}#${state}` : slug);

function resolveTarget(to: string): string | null {
  const [slug, state] = to.split("#");
  const screen = screenBySlug[slug];
  if (screen) {
    const s = state ?? screen.states[0];
    return screen.states.includes(s) ? nodeId(slug, s) : null;
  }
  return plannedBySlug[slug] && !state ? slug : null;
}

/**
 * Nodes = every declared state of every screen + every planned screen.
 * Unresolvable links are dropped here; `pnpm design:check` reports them.
 */
export function buildGraph(): { nodes: GraphNode[]; edges: GraphEdge[] } {
  const nodes: GraphNode[] = [
    ...screens.flatMap((screen) =>
      screen.states.map((state) => ({ id: nodeId(screen.slug, state), slug: screen.slug, state, title: screen.meta.title, screen, planned: null })),
    ),
    ...planned.map((p) => ({ id: p.slug, slug: p.slug, state: null, title: p.meta.title, screen: null, planned: p })),
  ];
  const edges: GraphEdge[] = [];
  for (const screen of screens) {
    for (const link of screen.meta.links ?? []) {
      const to = resolveTarget(link.to);
      if (!to || !screen.states.includes(link.from)) continue;
      edges.push({ from: nodeId(screen.slug, link.from), to, label: link.label });
    }
  }
  return { nodes, edges };
}

// ── Viewport presets ─────────────────────────────────────────────────────

export interface Viewport {
  id: string;
  /** Display name from viewports.json ("iOS", "Windows", …). */
  platform: string;
  os: Platform;
  /** Family heading in pickers ("iPhone 17", "QHD 2560×1440", …). */
  group: string;
  label: string;
  /** Logical size (pt · dp · CSS px). For Windows presets this is physical ÷ scale. */
  width: number;
  height: number;
  physical?: readonly [number, number];
  scale?: number;
  /** Sources disagree on this size; shown with "≈". */
  approx?: boolean;
}

const OS: Record<string, Platform> = { iOS: "ios", iPadOS: "ipados", Android: "android", macOS: "macos", Windows: "windows" };

type RawPreset = { id: string; platform: string; group?: string; label: string; logical?: number[]; physical?: number[]; scale?: number; approx?: boolean };

export const viewports: Viewport[] = (viewportsJson.presets as RawPreset[]).map((p) => {
  const scale = p.scale ?? 1;
  const [w, h] = p.logical ?? [Math.round(p.physical![0] / scale), Math.round(p.physical![1] / scale)];
  return {
    id: p.id,
    platform: p.platform,
    os: OS[p.platform] ?? "ios",
    group: p.group ?? p.platform,
    label: p.label,
    width: w,
    height: h,
    physical: p.physical ? [p.physical[0], p.physical[1]] : undefined,
    scale: p.scale,
    approx: p.approx,
  };
});

/** Picker label: "Galaxy S25 Ultra ≈" when the size is an estimate. */
export const presetLabel = (v: Viewport) => (v.approx ? `${v.label} ≈` : v.label);

/** Every preset grouped as "<platform> · <family>", for preview pickers. */
export function viewportGroups(): [string, Viewport[]][] {
  const out: [string, Viewport[]][] = [];
  for (const v of viewports) {
    const name = `${v.platform} · ${v.group}`;
    const g = out.find(([n]) => n === name);
    if (g) g[1].push(v);
    else out.push([name, [v]]);
  }
  return out;
}

export const viewportById = Object.fromEntries(viewports.map((v) => [v.id, v]));
/** Default frames: preset ids, optionally suffixed ":landscape". */
export const detailDefaults: string[] = viewportsJson.detailDefaults;

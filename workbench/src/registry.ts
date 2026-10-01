import type { ComponentType } from "react";
import type { Platform } from "@ithaca/kit";
import viewportsJson from "../../design/viewports.json";

// ── Screens ──────────────────────────────────────────────────────────────

export interface ScreenLink {
  /** State of this screen the link starts from. */
  from: string;
  /** Target node: "<slug>" (its first state) or "<slug>#<state>". */
  to: string;
  label: { ko: string; en: string };
}

export interface ScreenMeta {
  title: { ko: string; en: string };
  description?: string;
  version: string;
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

const protos = import.meta.glob<PrototypeModule>("../../design/screens/*/prototype.tsx", { eager: true });
const metas = import.meta.glob<ScreenMeta>("../../design/screens/*/meta.json", { eager: true, import: "default" });
const specs = import.meta.glob<string>("../../design/screens/*/spec.md", { eager: true, query: "?raw", import: "default" });

const slugOf = (path: string) => path.split("/").at(-2)!;
const bySlug = <T,>(mods: Record<string, T>) => Object.fromEntries(Object.entries(mods).map(([p, m]) => [slugOf(p), m]));

const metaBySlug = bySlug(metas);
const specBySlug = bySlug(specs);

export const screens: Screen[] = Object.entries(bySlug(protos))
  .filter(([slug]) => metaBySlug[slug])
  .map(([slug, mod]) => ({
    slug,
    meta: metaBySlug[slug],
    spec: specBySlug[slug] ?? "",
    Prototype: mod.default,
    states: mod.states,
  }))
  .sort((a, b) => a.slug.localeCompare(b.slug));

export const screenBySlug = Object.fromEntries(screens.map((s) => [s.slug, s]));

// ── Navigation graph ─────────────────────────────────────────────────────

/** A card on the canvas: one state of one screen. */
export interface GraphNode {
  id: string; // "<slug>#<state>"
  screen: Screen;
  state: string;
}

export interface GraphEdge {
  from: string;
  to: string;
  label: { ko: string; en: string };
}

export const nodeId = (slug: string, state: string) => `${slug}#${state}`;

function resolveTarget(to: string): string | null {
  const [slug, state] = to.split("#");
  const screen = screenBySlug[slug];
  if (!screen) return null;
  const s = state ?? screen.states[0];
  return screen.states.includes(s) ? nodeId(slug, s) : null;
}

/** Nodes = each screen's first state + every state that a link touches. Unresolvable links are dropped (design:check reports them). */
export function buildGraph(): { nodes: GraphNode[]; edges: GraphEdge[] } {
  const ids = new Set<string>();
  const edges: GraphEdge[] = [];
  for (const screen of screens) {
    ids.add(nodeId(screen.slug, screen.states[0]));
    for (const link of screen.meta.links ?? []) {
      const to = resolveTarget(link.to);
      if (!to || !screen.states.includes(link.from)) continue;
      const from = nodeId(screen.slug, link.from);
      ids.add(from);
      ids.add(to);
      edges.push({ from, to, label: link.label });
    }
  }
  const nodes = [...ids].map((id) => {
    const [slug, state] = id.split("#");
    return { id, screen: screenBySlug[slug], state };
  });
  return { nodes, edges };
}

// ── Viewport presets ─────────────────────────────────────────────────────

export interface Viewport {
  id: string;
  /** Display name from viewports.json ("iOS", "Windows", …). */
  platform: string;
  os: Platform;
  label: string;
  /** Logical size (pt · dp · CSS px). For Windows presets this is physical ÷ scale. */
  width: number;
  height: number;
  physical?: readonly [number, number];
  scale?: number;
}

const OS: Record<string, Platform> = { iOS: "ios", iPadOS: "ipados", Android: "android", macOS: "macos", Windows: "windows" };

type RawPreset = { id: string; platform: string; label: string; logical?: number[]; physical?: number[]; scale?: number };

export const viewports: Viewport[] = (viewportsJson.presets as RawPreset[]).map((p) => {
  const scale = p.scale ?? 1;
  const [w, h] = p.logical ?? [Math.round(p.physical![0] / scale), Math.round(p.physical![1] / scale)];
  return {
    id: p.id,
    platform: p.platform,
    os: OS[p.platform] ?? "ios",
    label: p.label,
    width: w,
    height: h,
    physical: p.physical ? [p.physical[0], p.physical[1]] : undefined,
    scale: p.scale,
  };
});

export const viewportById = Object.fromEntries(viewports.map((v) => [v.id, v]));
export const detailDefaults: string[] = viewportsJson.detailDefaults;

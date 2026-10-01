// One mixed Korean/English sample so both scripts are typeset side by side in every frame.
import data from "../../../fixtures/sample-project.json";

export type ManuscriptLanguage = "ko" | "en";

export interface SheetSummary {
  id: string;
  title: string;
  excerpt: string;
  /** Character count including spaces. */
  chars: number;
  /** Character count excluding whitespace. */
  charsNoSpace: number;
  /** Has an unresolved offline branch copy (ADR-0002). */
  branched?: boolean;
  body?: string[];
}

export interface Folder {
  id: string;
  name: string;
  sheets: SheetSummary[];
}

export interface Project {
  id: string;
  title: string;
  /** Manuscript language decides the length unit (ADR-0005): ko → characters, en → words. */
  language: ManuscriptLanguage;
  /** Per-sheet length goal set in project settings; null = no goal. */
  goal: { count: number; basis: "withSpaces" | "withoutSpaces" | "words" } | null;
  folders: Folder[];
}

export interface Sample {
  projects: Project[];
  open: { project: string; folder: string; sheet: string; reference: string };
  openSheet: { paragraphs: string[] };
  /** An offline branch: `main` and `copy` are paragraph-aligned; null = paragraph absent on that side. */
  branch: { sheet: string; device: string; minutesAgo: number; main: (string | null)[]; copy: (string | null)[] };
  devices: { name: string; platform: Platform; minutesAgo: number }[];
  sync: { relay: string; icloud: boolean; p2p: boolean };
  mcp: { enabled: boolean; address: string; token: string };
}

export type Platform = "ios" | "ipados" | "android" | "macos" | "windows";

/** MCP and other desktop-only features key off the platform, not the window width. */
export const isDesktop = (p: Platform) => p === "macos" || p === "windows";

export const sample = data as Sample;

/** Convenience lookups for prototypes. */
export function openContext(s: Sample = sample) {
  const project = s.projects.find((p) => p.id === s.open.project)!;
  const folder = project.folders.find((f) => f.id === s.open.folder)!;
  const sheet = folder.sheets.find((x) => x.id === s.open.sheet)!;
  const reference = project.folders.flatMap((f) => f.sheets).find((x) => x.id === s.open.reference)!;
  return { project, folder, sheet, reference };
}

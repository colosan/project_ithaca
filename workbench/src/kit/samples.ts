// One mixed Korean/English sample so both scripts are typeset side by side in every frame.
import project from "../../../fixtures/sample-project.json";

export type ManuscriptLanguage = "ko" | "en";

export interface Sample {
  /** Manuscript language decides the length unit (ADR-0005): ko → characters, en → words. */
  language: ManuscriptLanguage;
  title: string;
  lore: { id: string; kind: string; title: string; summary: string }[];
  episodes: { id: string; number: number; title: string; status: "draft" | "ready" | "published"; excerpt: string }[];
  ideas: { id: string; title: string; summary: string }[];
  openEpisode: { id: string; paragraphs: string[]; charCount?: number; wordCount?: number };
}

export const sample = project as Sample;

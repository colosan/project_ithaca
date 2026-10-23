// Manuscript text helpers: title, excerpt, counts. Length units follow the manuscript language (ADR-0005).
import type { GoalBasis, ManuscriptLanguage } from "./store";

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const wordSeg = new Intl.Segmenter(undefined, { granularity: "word" });

/** Markdown marks that aren't part of the prose: heading #, list/quote markers, emphasis. */
const stripMarks = (s: string) =>
  s.replace(/^[ \t]*(#{1,6}|[-*+>]|\d+\.)[ \t]+/gm, "").replace(/(\*\*|__|\*|_|~~|`)(?=\S)(.+?)(?<=\S)\1/g, "$2");

/** A scene break such as `* * *`, `---` or `＊＊＊` — kept as is, never counted as a paragraph. */
export const isSceneBreak = (line: string) => /^\s*([-*_＊])(\s*\1){2,}\s*$/.test(line);

/** First non-empty line without a leading Markdown heading mark. */
export function titleOf(body: string) {
  const line = body.split("\n").find((l) => l.trim()) ?? "";
  return line.replace(/^#+\s*/, "").trim();
}

/** The line after the title, for the sheet list. */
export function excerptOf(body: string) {
  const lines = body.split("\n").filter((l) => l.trim() && !isSceneBreak(l));
  return stripMarks(lines[1] ?? "").trim();
}

const countLen = (s: string) => {
  let n = 0;
  for (const _ of graphemes.segment(s)) n++;
  return n;
};

/** Characters as people see them (grapheme clusters, line breaks excluded); words without Markdown marks. */
export function counts(body: string) {
  const chars = countLen(body.replace(/\n/g, ""));
  const charsNoSpace = countLen(body.replace(/\s/g, ""));
  let words = 0;
  for (const w of wordSeg.segment(stripMarks(body))) if (w.isWordLike) words++;
  const paragraphs = body.split(/\n+/).filter((l) => l.trim() && !/^#+\s/.test(l) && !isSceneBreak(l)).length;
  return { chars, charsNoSpace, words, paragraphs };
}

export type Counts = ReturnType<typeof counts>;

/** Sheets are immutable objects, so their derived text can be cached by identity. */
const cache = new WeakMap<object, { title: string; excerpt: string; counts: Counts }>();
export function sheetMeta(sheet: { body: string }) {
  let m = cache.get(sheet);
  if (!m) cache.set(sheet, (m = { title: titleOf(sheet.body), excerpt: excerptOf(sheet.body), counts: counts(sheet.body) }));
  return m;
}

export function goalValue(c: Counts, basis: GoalBasis) {
  return basis === "withSpaces" ? c.chars : basis === "withoutSpaces" ? c.charsNoSpace : c.words;
}

/** The manuscript's own length unit: characters (with spaces) for Korean, words for English. */
export const lengthOf = (c: Counts, language: ManuscriptLanguage) => (language === "ko" ? c.chars : c.words);

/** Reading time in minutes: 500 Korean characters or 230 English words per minute. */
export function readingMinutes(c: Counts, language: ManuscriptLanguage) {
  return Math.max(1, Math.round(language === "ko" ? c.charsNoSpace / 500 : c.words / 230));
}

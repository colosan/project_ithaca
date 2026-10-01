// pnpm design:check — exits 1 if there is even a single BLOCK (ADR-0006).
//   1. token shape   2. string locale parity (ADR-0005)   3. generated-file drift   4. screen folders · prototype lint
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { ROOT, buildOutputs, loadDesign, placeholders } from "./lib.mjs";

const blocks = [];
const warns = [];
const block = (where, msg) => blocks.push(`BLOCK ${where}: ${msg}`);
const warn = (where, msg) => warns.push(`WARN  ${where}: ${msg}`);

let design;
try {
  design = loadDesign();
} catch (e) {
  console.error(`BLOCK design/: JSON 을 읽지 못함 — ${e.message}`);
  process.exit(1);
}
const { tokens, locales, strings } = design;

// 1. Tokens ──────────────────────────────────────────────────────────────
const HEX = /^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$/;
for (const [k, v] of Object.entries(tokens.color.tokens)) {
  for (const mode of tokens.color.modes) {
    if (!(mode in v)) block("tokens/color", `${k} 에 ${mode} 값이 없다`);
    else if (!HEX.test(v[mode])) block("tokens/color", `${k}.${mode} = ${v[mode]} 은 #RRGGBB(AA) 가 아니다`);
  }
}
for (const [k, s] of Object.entries(tokens.typography.styles)) {
  if (!(s.family in tokens.typography.families)) block("tokens/typography", `${k}.family '${s.family}' 가 families 에 없다`);
  for (const f of ["size", "lineHeight", "tracking", "weight"])
    if (typeof s[f] !== "number") block("tokens/typography", `${k}.${f} 가 숫자가 아니다`);
}
{
  const classes = Object.entries(tokens.layout.sizeClasses);
  if (classes[0][1].min !== 0) block("tokens/layout", `첫 size class 의 min 은 0 이어야 한다`);
  for (let i = 1; i < classes.length; i++) {
    const [pk, prev] = classes[i - 1];
    const [k, cur] = classes[i];
    if (prev.max === null || prev.max + 1 !== cur.min) block("tokens/layout", `${pk}.max(${prev.max}) + 1 ≠ ${k}.min(${cur.min}) — 구간이 끊기거나 겹친다`);
  }
  if (classes.at(-1)[1].max !== null) block("tokens/layout", `마지막 size class 의 max 는 null 이어야 한다`);
  for (const [k] of classes)
    if (!(k in tokens.layout.editor.paddingX)) block("tokens/layout", `editor.paddingX 에 ${k} 가 없다`);
}

// 2. Strings ─────────────────────────────────────────────────────────────
const allKeys = new Set(locales.flatMap((l) => Object.keys(strings[l])));
for (const key of allKeys) {
  const present = locales.filter((l) => key in strings[l]);
  if (present.length !== locales.length) {
    block("strings", `'${key}' 가 ${locales.filter((l) => !present.includes(l)).join(", ")} 에 없다`);
    continue;
  }
  const sigs = locales.map((l) => {
    const v = strings[l][key];
    if (typeof v === "object") {
      if (typeof v.one !== "string" || typeof v.other !== "string") block(`strings/${l}`, `'${key}' 복수형은 one·other 둘 다 문자열이어야 한다`);
      if (!placeholders(v).includes("count")) block(`strings/${l}`, `'${key}' 복수형인데 {count} 가 없다`);
    } else if (typeof v !== "string") {
      block(`strings/${l}`, `'${key}' 값이 문자열도 복수형 객체도 아니다`);
      return "";
    }
    if ((typeof v === "string" ? [v] : Object.values(v)).some((t) => !String(t).trim())) block(`strings/${l}`, `'${key}' 가 비어 있다`);
    return placeholders(v).join(",");
  });
  if (new Set(sigs).size > 1)
    block("strings", `'${key}' 자리표시자가 locale 마다 다르다 — ${locales.map((l, i) => `${l}{${sigs[i]}}`).join(" · ")}`);
}

// 3. Drift ───────────────────────────────────────────────────────────────
// If tokens or strings are already broken, generating is meaningless — keep only the root-cause BLOCKs and skip.
const norm = (s) => s.replace(/\r\n/g, "\n");
if (blocks.length) {
  warn("generated", `위 BLOCK 때문에 드리프트 검사를 건너뜀`);
} else {
  try {
    for (const [rel, content] of Object.entries(buildOutputs(design))) {
      const abs = join(ROOT, rel);
      if (!existsSync(abs)) block(rel, `생성물이 없다 — pnpm design:gen`);
      else if (norm(readFileSync(abs, "utf8")) !== norm(content)) block(rel, `원본과 어긋났다(손으로 고쳤거나 gen 을 안 돌림) — pnpm design:gen`);
    }
  } catch (e) {
    block("generated", `생성 실패 — ${e.message}`);
  }
}

// 4. Screens ─────────────────────────────────────────────────────────────
const screensDir = join(ROOT, "design/screens");
const slugs = existsSync(screensDir)
  ? readdirSync(screensDir).filter((d) => statSync(join(screensDir, d)).isDirectory())
  : [];

// Prototypes may only use token names. Block numeric/color literals and hard-coded copy.
const LINT = [
  [/#[0-9A-Fa-f]{3,8}\b/, "hex 색 리터럴 — color.* 토큰을 쓴다"],
  [/\b(?:rgba?|hsla?|oklch)\(/, "색 함수 리터럴 — color.* 토큰을 쓴다"],
  [/\b\d+(?:\.\d+)?(?:px|rem|em|pt|dp)\b/, "단위 리터럴 — space · size · radius · type 토큰을 쓴다"],
  [
    /\b(?:padding|margin|gap|rowGap|columnGap|width|height|top|left|right|bottom|inset|fontSize|lineHeight|letterSpacing|borderRadius|min[A-Z]\w*|max[A-Z]\w*|padding[A-Z]\w*|margin[A-Z]\w*|border[A-Z]?\w*Width)\s*:\s*-?(?:[1-9]|0\.\d)/,
    "숫자 스타일 값 — 토큰을 쓴다 (0 은 허용)",
  ],
  [/(?<![=\-])>(?!=)\s*([^<>{}();=\n]*[A-Za-z가-힣][^<>{}();=\n]*)<\/?[A-Za-z]/, "JSX 안 하드코딩 문구 — t('key') 를 쓴다"],
];

// Pass 1: collect each screen's declared states (parsed from `export const states = [...]`) so links can be resolved.
// A screen with "planned": true in meta.json is spec-only: no prototype, no states, no outgoing links.
const statesBySlug = {};
const metaBySlug = {};
const plannedSlugs = new Set();
for (const slug of slugs) {
  const dir = join(screensDir, slug);
  const where = `design/screens/${slug}`;
  if (!/^[a-z0-9-]+$/.test(slug)) block(where, `slug 는 소문자·숫자·하이픈만`);

  let meta = null;
  if (existsSync(join(dir, "meta.json"))) {
    try {
      meta = JSON.parse(readFileSync(join(dir, "meta.json"), "utf8"));
      metaBySlug[slug] = meta;
      for (const l of locales) if (!meta.title?.[l]) block(`${where}/meta.json`, `title.${l} 가 없다`);
      if (typeof meta.version !== "string") block(`${where}/meta.json`, `version 이 문자열이 아니다`);
    } catch (e) {
      block(`${where}/meta.json`, `JSON 오류 — ${e.message}`);
    }
  }
  const isPlanned = meta?.planned === true;
  if (isPlanned) plannedSlugs.add(slug);

  const required = isPlanned ? ["spec.md", "meta.json"] : ["spec.md", "meta.json", "prototype.tsx"];
  for (const file of required) if (!existsSync(join(dir, file))) block(where, `${file} 가 없다`);
  if (isPlanned && existsSync(join(dir, "prototype.tsx")))
    block(where, `prototype.tsx 가 있는데 meta 가 planned — planned 를 지운다`);
  if (isPlanned && meta.links?.length) block(`${where}/meta.json`, `계획된 화면은 상태가 없어 links 를 가질 수 없다`);

  if (!isPlanned && existsSync(join(dir, "prototype.tsx"))) {
    const src = readFileSync(join(dir, "prototype.tsx"), "utf8");
    const m = src.match(/export\s+const\s+states\s*=\s*\[([^\]]*)\]/);
    if (!m) block(`${where}/prototype.tsx`, `export const states = [...] 가 없다`);
    else statesBySlug[slug] = [...m[1].matchAll(/["']([a-z0-9-]+)["']/g)].map((x) => x[1]);
    if (!/export\s+default\s+function\b/.test(src)) block(`${where}/prototype.tsx`, `export default function 이 없다`);
    src.split("\n").forEach((line, i) => {
      if (/^\s*(\/\/|\*|\/\*)/.test(line)) return; // comment line
      for (const [re, msg] of LINT) {
        const hit = line.match(re);
        if (hit) block(`${where}/prototype.tsx:${i + 1}`, `${msg} → ${hit[0].trim().slice(0, 40)}`);
      }
    });
  }
}

// Pass 2: every link must start from a declared state and land on an existing screen/state (or a planned screen).
for (const [slug, meta] of Object.entries(metaBySlug)) {
  if (plannedSlugs.has(slug)) continue;
  const where = `design/screens/${slug}/meta.json`;
  if (meta.links !== undefined && !Array.isArray(meta.links)) {
    block(where, `links 가 배열이 아니다`);
    continue;
  }
  for (const [i, link] of (meta.links ?? []).entries()) {
    const at = `${where} links[${i}]`;
    if (!statesBySlug[slug]?.includes(link.from)) block(at, `from '${link.from}' 은 이 화면의 state 가 아니다 (${statesBySlug[slug]?.join(", ")})`);
    const [toSlug, toState] = String(link.to ?? "").split("#");
    if (plannedSlugs.has(toSlug)) {
      if (toState) block(at, `to '${link.to}' — 계획된 화면에는 state 를 붙이지 않는다`);
    } else if (!statesBySlug[toSlug]) block(at, `to '${link.to}' — 그런 화면이 없다`);
    else if (toState && !statesBySlug[toSlug].includes(toState)) block(at, `to '${link.to}' — ${toSlug} 에 그런 state 가 없다`);
    for (const l of locales) if (!link.label?.[l]) block(at, `label.${l} 가 없다`);
  }
}
if (plannedSlugs.size) warn("design/screens", `계획만 있는 화면 ${plannedSlugs.size}개 — ${[...plannedSlugs].join(", ")}`);

// 5. Viewport presets · canvas ─────────────────────────────────────────────
try {
  const vp = JSON.parse(readFileSync(join(ROOT, "design/viewports.json"), "utf8"));
  const ids = new Set();
  for (const p of vp.presets) {
    const at = `design/viewports.json ${p.id}`;
    if (ids.has(p.id)) block(at, `id 중복`);
    ids.add(p.id);
    const hasLogical = Array.isArray(p.logical) && p.logical.length === 2;
    const hasPhysical = Array.isArray(p.physical) && p.physical.length === 2 && typeof p.scale === "number" && p.scale > 0;
    if (hasLogical === hasPhysical) block(at, `logical 또는 (physical + scale) 중 정확히 하나`);
    if (p.group !== undefined && typeof p.group !== "string") block(at, `group 은 문자열`);
  }
  for (const spec of vp.detailDefaults ?? []) {
    const [id, orientation] = spec.split(":");
    if (!ids.has(id)) block("design/viewports.json detailDefaults", `'${id}' 프리셋이 없다`);
    if (orientation && !["landscape", "portrait"].includes(orientation)) block("design/viewports.json detailDefaults", `'${spec}' — 방향은 landscape | portrait`);
  }
} catch (e) {
  block("design/viewports.json", `읽기 실패 — ${e.message}`);
}
try {
  const canvas = JSON.parse(readFileSync(join(ROOT, "design/canvas.json"), "utf8"));
  for (const id of Object.keys(canvas.positions ?? {})) {
    const [slug, state] = id.split("#");
    if (!(state ? statesBySlug[slug]?.includes(state) : plannedSlugs.has(slug))) warn("design/canvas.json", `'${id}' 는 더 이상 없는 카드 — 자동 정렬로 정리 가능`);
  }
} catch (e) {
  block("design/canvas.json", `읽기 실패 — ${e.message}`);
}

// 6. Code comments are English (open-source repo) ───────────────────────────
const CODE_DIRS = ["tools", "workbench", "design/screens", "swift", "kotlin", "core"];
const CODE_EXT = /\.(mjs|js|ts|tsx|css|swift|kt|rs)$/;
const HANGUL = /[가-힣]/;
const walk = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    if (d.name === "node_modules" || d.name === "dist" || d.name.startsWith(".")) return [];
    const p = join(dir, d.name);
    return d.isDirectory() ? walk(p) : CODE_EXT.test(d.name) ? [p] : [];
  });
for (const top of CODE_DIRS) {
  const abs = join(ROOT, top);
  if (!existsSync(abs)) continue;
  for (const file of walk(abs)) {
    readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      // Comment part of the line: after //, a block-comment line (/*, *), or an inline /* … */. Strings containing "//" (URLs) are rare enough here.
      const c =
        line.match(/(?:^|\s)\/\/(.*)$/)?.[1] ??
        line.match(/^\s*(?:\/\*|\*)(.*)$/)?.[1] ??
        line.match(/\/\*(.*?)\*\//)?.[1];
      if (c && HANGUL.test(c)) block(`${file.slice(ROOT.length + 1).replace(/\\/g, "/")}:${i + 1}`, `코드 주석은 영어로 → ${c.trim().slice(0, 40)}`);
    });
  }
}

// Output ─────────────────────────────────────────────────────────────────
for (const line of [...blocks, ...warns]) console.log(line);
console.log(`\ndesign:check — screens ${slugs.length} · BLOCK ${blocks.length} · WARN ${warns.length}`);
process.exit(blocks.length ? 1 : 0);

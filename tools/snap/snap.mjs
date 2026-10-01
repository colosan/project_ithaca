// pnpm design:snap — screenshot every screen × state over a fixed matrix, compare with the baseline, list defects.
//
//   pnpm design:snap                    capture all, compare with design/snapshots/baseline, write report
//   pnpm design:snap --only app-shell   limit to screens whose slug contains the text (repeatable)
//   pnpm design:snap --update           accept this run as the new baseline
//
// Output (git-ignored): design/snapshots/{baseline,current,diff}/<slug>/<state>/<shot>.png and report.{md,json}.
// Exit 1 when any shot has a layout defect (clip, spill, offscreen, unsafe) or differs from its baseline.
// Agents: read design/snapshots/report.md, open the listed PNGs, fix or run --update when the change is intended.
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, copyFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
import { createServer } from "vite";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const OUT = join(ROOT, "design", "snapshots");
const args = process.argv.slice(2);
const update = args.includes("--update");
const only = args.flatMap((a, i) => (args[i - 1] === "--only" ? [a] : []));

// ── What to capture ──────────────────────────────────────────────────────

const matrix = JSON.parse(readFileSync(join(ROOT, "design/snapshot-matrix.json"), "utf8"));

/** Built screens and their states (planned screens have no prototype). Same parse as design:check. */
function screens() {
  const dir = join(ROOT, "design/screens");
  return readdirSync(dir)
    .filter((slug) => statSync(join(dir, slug)).isDirectory() && existsSync(join(dir, slug, "prototype.tsx")))
    .filter((slug) => only.length === 0 || only.some((o) => slug.includes(o)))
    .map((slug) => {
      const src = readFileSync(join(dir, slug, "prototype.tsx"), "utf8");
      const m = src.match(/export\s+const\s+states\s*=\s*\[([^\]]*)\]/);
      return { slug, states: m ? [...m[1].matchAll(/["']([a-z0-9-]+)["']/g)].map((x) => x[1]) : [] };
    });
}

function shots() {
  const list = [];
  for (const { slug, states } of screens())
    for (const state of states)
      for (const vp of matrix.viewports) {
        for (const theme of matrix.themes)
          for (const locale of matrix.locales) list.push({ slug, state, vp, theme, locale, scale: 1 });
        for (const theme of matrix.largeText.themes)
          for (const locale of matrix.locales) list.push({ slug, state, vp, theme, locale, scale: matrix.largeText.scale });
      }
  return list;
}

const shotName = (s) => `${s.vp.id}-${s.theme}-${s.locale}${s.scale !== 1 ? `-text${Math.round(s.scale * 100)}` : ""}.png`;
const shotPath = (kind, s) => join(OUT, kind, s.slug, s.state, shotName(s));
const hashOf = (s) => {
  const q = new URLSearchParams({ w: s.vp.w, h: s.vp.h, p: s.vp.platform, t: s.theme, l: s.locale, x: s.scale });
  if (s.vp.preset) q.set("v", s.vp.preset);
  return `#/capture/${s.slug}/${s.state}?${q}`;
};

// ── Browser: the one already installed (Edge on Windows, Chrome elsewhere) ─

async function launch() {
  for (const channel of ["msedge", "chrome"]) {
    try {
      return await chromium.launch({ channel });
    } catch {
      /* try the next one */
    }
  }
  throw new Error("No Edge or Chrome found. Install one, or run `npx playwright install chromium` and edit tools/snap/snap.mjs.");
}

// ── Compare ──────────────────────────────────────────────────────────────

function compare(currentFile, baselineFile, diffFile) {
  if (!existsSync(baselineFile)) return { status: "new" };
  const a = PNG.sync.read(readFileSync(baselineFile));
  const b = PNG.sync.read(readFileSync(currentFile));
  if (a.width !== b.width || a.height !== b.height) return { status: "changed", ratio: 1, note: `size ${a.width}×${a.height} → ${b.width}×${b.height}` };
  const diff = new PNG({ width: a.width, height: a.height });
  const n = pixelmatch(a.data, b.data, diff.data, a.width, a.height, { threshold: matrix.diff.threshold });
  const ratio = n / (a.width * a.height);
  if (ratio <= matrix.diff.maxChangedRatio) return { status: "same", ratio };
  mkdirSync(dirname(diffFile), { recursive: true });
  writeFileSync(diffFile, PNG.sync.write(diff));
  return { status: "changed", ratio };
}

// ── Run ──────────────────────────────────────────────────────────────────

const list = shots();
if (list.length === 0) {
  console.log("design:snap — nothing to capture" + (only.length ? ` for --only ${only.join(", ")}` : ""));
  process.exit(0);
}
rmSync(join(OUT, "current"), { recursive: true, force: true });
rmSync(join(OUT, "diff"), { recursive: true, force: true });

const server = await createServer({
  configFile: join(ROOT, "workbench/vite.config.ts"),
  logLevel: "error",
  server: { port: 9161, strictPort: false },
});
await server.listen();
const base = server.resolvedUrls.local[0];
const browser = await launch();
const page = await browser.newPage({ viewport: { width: 2000, height: 1200 }, deviceScaleFactor: 1 });
await page.goto(base);
await page.evaluate(() => document.fonts.ready);

const results = [];
const started = Date.now();
for (const [i, s] of list.entries()) {
  const hash = hashOf(s);
  await page.evaluate((h) => {
    window.__capture = undefined;
    location.hash = h;
  }, hash);
  await page.waitForFunction((h) => window.__capture?.key === h, hash, { timeout: 15000 });
  await page.evaluate(() => document.fonts.ready);
  const capture = await page.evaluate(() => window.__capture);
  const file = shotPath("current", s);
  mkdirSync(dirname(file), { recursive: true });
  await page.locator(".wb-capture .wb-device").screenshot({ path: file, animations: "disabled" });
  const defects = capture.marks.filter((m) => m.kind !== "ellipsis");
  const cmp = update ? { status: "updated" } : compare(file, shotPath("baseline", s), shotPath("diff", s));
  results.push({ ...s, vp: s.vp.id, file, defects, ...cmp });
  if ((i + 1) % 50 === 0) process.stdout.write(`  ${i + 1}/${list.length}\n`);
}
await browser.close();
await server.close();

if (update) {
  for (const r of results) {
    const dest = shotPath("baseline", { ...r, vp: matrix.viewports.find((v) => v.id === r.vp) });
    mkdirSync(dirname(dest), { recursive: true });
    copyFileSync(r.file, dest);
  }
}

// ── Report ───────────────────────────────────────────────────────────────

const rel = (f) => relative(join(ROOT, "design"), f).replace(/\\/g, "/");
const label = (r) => `${r.slug}#${r.state} · ${r.vp} ${r.theme} ${r.locale}${r.scale !== 1 ? ` text ${Math.round(r.scale * 100)}%` : ""}`;
const withDefects = results.filter((r) => r.defects.length);
const changed = results.filter((r) => r.status === "changed");
const fresh = results.filter((r) => r.status === "new");
const secs = ((Date.now() - started) / 1000).toFixed(0);

const md = [
  `# design:snap — ${new Date().toISOString().slice(0, 16).replace("T", " ")}`,
  ``,
  `${results.length} shots · **${withDefects.length} with defects** · **${changed.length} changed** · ${fresh.length} new (no baseline)${update ? " · baseline updated" : ""} · ${secs}s`,
  ``,
  `Paths are relative to \`design/\`. Matrix: \`design/snapshot-matrix.json\`.`,
  ``,
  `## Defects`,
  withDefects.length ? "" : "_none_",
  ...withDefects.map((r) => `- ${label(r)} — ${r.defects.map((d) => `${d.kind}: "${d.text}"`).join("; ")} → \`${rel(r.file)}\``),
  ``,
  `## Changed vs baseline`,
  changed.length ? "" : "_none_",
  ...changed.map((r) => `- ${label(r)} — ${r.note ?? `${(r.ratio * 100).toFixed(2)}% pixels`} → now \`${rel(r.file)}\`, diff \`${rel(shotPath("diff", { ...r, vp: matrix.viewports.find((v) => v.id === r.vp) }))}\``),
  ``,
  fresh.length && !update ? `## New\n\n${fresh.length} shots have no baseline yet — run \`pnpm design:snap --update\` once the screens look right.` : "",
  ``,
].join("\n");
mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, "report.md"), md);
writeFileSync(join(OUT, "report.json"), JSON.stringify({ results: results.map(({ file, ...r }) => ({ ...r, file: rel(file) })) }, null, 2));

console.log(md.split("\n").slice(0, 3).join("\n"));
console.log(`report: design/snapshots/report.md`);
process.exit(withDefects.length || changed.length ? 1 : 0);

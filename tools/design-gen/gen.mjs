// pnpm design:gen — writes Swift · Kotlin · workbench outputs from design/.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { ROOT, buildOutputs } from "./lib.mjs";

export function generate() {
  const outputs = buildOutputs();
  for (const [rel, content] of Object.entries(outputs)) {
    const abs = join(ROOT, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  }
  return Object.keys(outputs);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    for (const rel of generate()) console.log(`wrote ${rel}`);
  } catch (e) {
    console.error(`design:gen 실패 — ${e.message}`);
    process.exit(1);
  }
}

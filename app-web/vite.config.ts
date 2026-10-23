import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const root = fileURLToPath(new URL(".", import.meta.url));
const repo = resolve(root, "..");

// The usable web app (ADR-0007). It shares tokens, copy, icons and kit controls with the workbench —
// the same generated files, so a design change shows up here too.
export default defineConfig({
  root,
  plugins: [react()],
  resolve: { alias: { "@ithaca/kit": join(repo, "workbench/src/kit/index.ts") } },
  server: { port: 9152, strictPort: true, fs: { allow: [repo] } },
  build: { outDir: join(root, "dist"), emptyOutDir: true },
});

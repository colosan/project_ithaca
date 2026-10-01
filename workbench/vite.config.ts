import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

const root = fileURLToPath(new URL(".", import.meta.url));
const repo = resolve(root, "..");
const slash = (p: string) => p.replace(/\\/g, "/");

/**
 * GET  /__canvas                 → design/canvas.json
 * POST /__canvas { id, x, y }    → store one card position
 * POST /__canvas { reset: true } → drop all positions (back to auto layout)
 * POST /__canvas { positions }   → replace all positions (undo/redo)
 * The only file the workbench writes.
 */
function canvasStore(): Plugin {
  const file = join(repo, "design", "canvas.json");
  return {
    name: "ithaca-canvas",
    configureServer(server) {
      server.middlewares.use("/__canvas", (req, res) => {
        const send = (status: number, body: string) => {
          res.statusCode = status;
          res.setHeader("content-type", "application/json");
          res.end(body);
        };
        if (req.method === "GET") return send(200, readFileSync(file, "utf8"));
        if (req.method !== "POST") return send(405, "{}");
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => {
          try {
            const msg = JSON.parse(body) as { id?: string; x?: number; y?: number; reset?: boolean; positions?: Record<string, { x: number; y: number }> };
            const doc = JSON.parse(readFileSync(file, "utf8"));
            if (msg.reset) {
              doc.positions = {};
            } else if (msg.positions) {
              // Replace-all, used by undo/redo.
              const next: Record<string, { x: number; y: number }> = {};
              for (const [id, p] of Object.entries(msg.positions)) {
                if (!/^[a-z0-9-]+(#[a-z0-9-]+)?$/.test(id) || !Number.isFinite(p?.x) || !Number.isFinite(p?.y)) throw new Error(`bad position: ${id}`);
                next[id] = { x: Math.round(p.x), y: Math.round(p.y) };
              }
              doc.positions = next;
            } else {
              if (!msg.id || !/^[a-z0-9-]+(#[a-z0-9-]+)?$/.test(msg.id)) throw new Error(`bad id: ${msg.id}`);
              if (!Number.isFinite(msg.x) || !Number.isFinite(msg.y)) throw new Error("x/y must be numbers");
              doc.positions = { ...doc.positions, [msg.id]: { x: Math.round(msg.x!), y: Math.round(msg.y!) } };
            }
            writeFileSync(file, JSON.stringify(doc, null, 2) + "\n");
            send(200, JSON.stringify(doc));
          } catch (e) {
            send(400, JSON.stringify({ error: String(e) }));
          }
        });
      });
    },
  };
}

/** Regenerates outputs when design/tokens or design/strings change → HMR refreshes the view. */
function designGen(): Plugin {
  const dirs = ["design/tokens", "design/strings"].map((d) => slash(join(repo, d)));
  return {
    name: "ithaca-design-gen",
    async configureServer(server) {
      const { generate } = await import("../tools/design-gen/gen.mjs");
      server.watcher.add(dirs);
      server.watcher.on("change", (file) => {
        if (!dirs.some((d) => slash(file).startsWith(d))) return;
        try {
          generate();
          server.config.logger.info(`design-gen: ${slash(file).slice(slash(repo).length + 1)} → regenerated`);
        } catch (e) {
          server.config.logger.error(`design-gen failed: ${String(e)}`);
        }
      });
    },
  };
}

export default defineConfig({
  root,
  plugins: [react(), canvasStore(), designGen()],
  resolve: { alias: { "@ithaca/kit": join(root, "src/kit/index.ts") } },
  server: {
    port: 9151,
    strictPort: true,
    fs: { allow: [repo] },
    // Card drags rewrite canvas.json; the canvas reads it over HTTP, so no reload is needed.
    watch: { ignored: [slash(join(repo, "design/canvas.json"))] },
  },
});

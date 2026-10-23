// Export (design/screens/export): paste-ready text for serial platforms, or a .txt / .md file.
import { useEffect, useMemo, useState, type CSSProperties } from "react";
import { color, radius, size, space, type, Button, Checkbox, Segmented } from "@ithaca/kit";
import { Dialog, DialogBody, Group, usePressable } from "./Dialog";
import { useApp, useT } from "./ctx";
import { foldersOf, sheetsIn } from "./store";
import { counts, titleOf } from "./text";

type Scope = "sheet" | "folder" | "project";
type Target = "paste" | "file";
type Ext = "txt" | "md";
type Opts = { blankLine: boolean; indent: boolean; strip: boolean; title: boolean };
const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

/** Scene-break lines: `* * *`, `***`, `---`, `- - -`, `___`, `＊＊＊`, … (three or more of one mark, spaces allowed). */
const SCENE_BREAK = /^\s*(?:(?:[*＊]\s*){3,}|(?:[-－]\s*){3,}|(?:[_＿]\s*){3,})$/;
const SCENE_MARK = "* * *";

/** Paste rules (PRODUCT.md proposal): blank line between paragraphs, first-line indent, strip Markdown, include title. */
function render(body: string, o: Opts) {
  let lines = body.split("\n");
  if (!o.title) {
    const i = lines.findIndex((l) => l.trim());
    if (i >= 0) lines = lines.slice(i + 1);
  }
  const paragraphs = lines.filter((l) => l.trim()).map((l) => {
    // A scene break is content, not Markdown: keep it, in one plain spelling, and never indent it.
    if (SCENE_BREAK.test(l)) return SCENE_MARK;
    let s = l;
    if (o.strip) s = s.replace(/^#+\s*/, "").replace(/^[-*>]\s+/, "").replace(/(\*\*|__|\*|_|~~|`)(.+?)\1/g, "$2");
    const heading = /^#+\s/.test(l);
    return o.indent && !heading ? `　${s.trimStart()}` : s;
  });
  return paragraphs.join(o.blankLine ? "\n\n" : "\n");
}

// The last choices, so a writer who exports every episode the same way sets it once.
const STORE_KEY = "ithaca.export.v1";
type Saved = { scope: Scope; target: Target; ext: Ext; opts: Opts };
const DEFAULTS: Saved = { scope: "sheet", target: "paste", ext: "txt", opts: { blankLine: true, indent: false, strip: true, title: true } };
function loadSaved(): Saved {
  try {
    const raw = JSON.parse(localStorage.getItem(STORE_KEY) ?? "null") as Partial<Saved> | null;
    if (!raw || typeof raw !== "object") return DEFAULTS;
    const pick = <T,>(v: unknown, ok: readonly T[], d: T) => (ok.includes(v as T) ? (v as T) : d);
    const o = (raw.opts ?? {}) as Partial<Record<keyof Opts, unknown>>;
    const bool = (k: keyof Opts) => (typeof o[k] === "boolean" ? (o[k] as boolean) : DEFAULTS.opts[k]);
    return {
      scope: pick(raw.scope, ["sheet", "folder", "project"] as const, DEFAULTS.scope),
      target: pick(raw.target, ["paste", "file"] as const, DEFAULTS.target),
      ext: pick(raw.ext, ["txt", "md"] as const, DEFAULTS.ext),
      opts: { blankLine: bool("blankLine"), indent: bool("indent"), strip: bool("strip"), title: bool("title") },
    };
  } catch {
    return DEFAULTS;
  }
}

/** Reading order inside a folder: the manual order when sheets carry one, otherwise oldest first. */
const readingOrder = (s: { created: number }) => (s as { order?: number }).order ?? s.created;

export function Export() {
  const t = useT();
  const { state, sizeClass } = useApp();
  const [saved] = useState(loadSaved);
  const [scope, setScope] = useState<Scope>(saved.scope);
  const [target, setTarget] = useState<Target>(saved.target);
  const [ext, setExt] = useState<Ext>(saved.ext);
  const [opts, setOpts] = useState<Opts>(saved.opts);
  const [done, setDone] = useState(false);
  const stacked = sizeClass === "compact";

  useEffect(() => {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify({ scope, target, ext, opts } satisfies Saved));
    } catch {
      // Storage blocked or full: the dialog still works, it just forgets.
    }
  }, [scope, target, ext, opts]);

  const sheets = useMemo(() => {
    if (scope === "sheet") return state.sheets.filter((s) => s.id === state.ui.sheetId);
    const folders = scope === "folder" ? [state.ui.folderId] : foldersOf(state, state.ui.projectId).map((f) => f.id);
    return folders.flatMap((id) => [...sheetsIn(state, id)].sort((a, b) => readingOrder(a) - readingOrder(b)));
  }, [scope, state]);
  const text = target === "file" && ext === "md" ? sheets.map((s) => s.body.trim()).join("\n\n---\n\n") : sheets.map((s) => render(s.body, opts)).join("\n\n\n");
  const name = scope === "sheet" ? titleOf(sheets[0]?.body ?? "") : scope === "folder" ? state.folders.find((f) => f.id === state.ui.folderId)?.name : state.projects.find((p) => p.id === state.ui.projectId)?.title;

  const go = async () => {
    if (target === "paste") {
      await navigator.clipboard.writeText(text);
    } else {
      const url = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
      const a = Object.assign(document.createElement("a"), { href: url, download: `${(name || t("sheet.untitled")).replace(/[\\/:*?"<>|]/g, "_")}.${ext}` });
      a.click();
      URL.revokeObjectURL(url);
    }
    setDone(true);
    setTimeout(() => setDone(false), 1600);
  };
  const toggle = (k: keyof Opts) => setOpts((o) => ({ ...o, [k]: !o[k] }));

  const options = (
    <>
      <Segmented full label={t("export.scope")} items={[["sheet", t("export.scope.sheet")], ["folder", t("export.scope.folder")], ["project", t("export.scope.project")]]} value={scope} onChange={setScope} />
      <Segmented full items={[["paste", t("export.target.paste")], ["file", t("export.target.file")]]} value={target} onChange={setTarget} />
      {target === "file" && <Segmented full label={t("export.format")} items={[["txt", t("export.format.txt")], ["md", t("export.format.md")]]} value={ext} onChange={setExt} />}
      {!(target === "file" && ext === "md") && (
        <Group>
          <Opt on={opts.blankLine} first onToggle={() => toggle("blankLine")} label={t("export.opt.blankLine")} />
          <Opt on={opts.indent} onToggle={() => toggle("indent")} label={t("export.opt.indent")} />
          <Opt on={opts.strip} onToggle={() => toggle("strip")} label={t("export.opt.stripMarkdown")} />
          <Opt on={opts.title} onToggle={() => toggle("title")} label={t("export.opt.includeTitle")} />
        </Group>
      )}
    </>
  );
  const previewLabel = <div style={{ ...type.label, color: color.inkTertiary }}>{t("export.preview")} · {t("export.count", { count: counts(text).chars })}</div>;
  const pre = (extra: CSSProperties) => (
    <pre style={{ margin: 0, padding: space[200], borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceRaised, ...type.body, whiteSpace: "pre-wrap", wordBreak: "keep-all", overflowWrap: "anywhere", overflow: "auto", ...extra }}>{text}</pre>
  );

  return (
    <Dialog
      title={t("export.title")}
      wide
      footer={
        <Button variant="primary" icon={done ? "check" : target === "paste" ? "copy" : "save"} disabled={!sheets.length} onClick={go}>
          {done ? (target === "paste" ? t("export.copied") : t("export.saved")) : target === "paste" ? t("export.copy") : t("export.save")}
        </Button>
      }
    >
      {stacked ? (
        // Phone: one scrolling column — options, then the preview at a readable height.
        <DialogBody>
          <div style={{ display: "flex", flexDirection: "column", gap: space[200] }}>{options}</div>
          <div style={{ display: "flex", flexDirection: "column", gap: space[100] }}>
            {previewLabel}
            {pre({ minHeight: `calc(${size.controlLg} * 6)` })}
          </div>
        </DialogBody>
      ) : (
        <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "row" }}>
          {/* Options scroll on their own when the window is short; the preview scrolls inside itself. */}
          <div style={{ flex: "none", width: `calc(${size.controlLg} * 7)`, minHeight: 0, overflow: "auto" }}>
            <div style={{ padding: space[300], display: "flex", flexDirection: "column", gap: space[200] }}>{options}</div>
          </div>
          <div style={{ flex: 1, minWidth: 0, minHeight: 0, padding: space[300], paddingLeft: 0, display: "flex", flexDirection: "column", gap: space[100] }}>
            {previewLabel}
            {pre({ flex: 1, minHeight: 0 })}
          </div>
        </div>
      )}
    </Dialog>
  );
}

function Opt({ on, onToggle, label, first }: { on: boolean; onToggle: () => void; label: string; first?: boolean }) {
  const { ringStyle, ...press } = usePressable(onToggle);
  return (
    <div {...press} role="checkbox" aria-checked={on} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[50]} ${space[200]}`, cursor: "pointer", borderTop: first ? undefined : hairline(color.lineSubtle), ...ringStyle }}>
      <Checkbox on={on} />
      <span>{label}</span>
    </div>
  );
}

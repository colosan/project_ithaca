// export prototype — a sheet, a folder or the whole project, as text to paste into a serial platform or as a file.
// Interactive: scope and target switch, paste rules and file format change the live preview, the action button confirms.
import { useState, type ReactNode } from "react";
import {
  color, editor, opacity, pane, radius, safePadding, shadow, size, space, type,
  Button, Checkbox, IconButton, Radio, Segmented,
  openContext, useFrame, useNavigate, useT, type Sample, type SheetSummary, type StringKey,
} from "@ithaca/kit";

export const states = ["paste", "file"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

type Scope = "sheet" | "folder" | "project";
type Format = "txt" | "md" | "docx" | "epub";
type Rules = { blankLine: boolean; indent: boolean; stripMarkdown: boolean; includeTitle: boolean };

const SCOPES: [Scope, StringKey][] = [["sheet", "export.scope.sheet"], ["folder", "export.scope.folder"], ["project", "export.scope.project"]];
const RULES: [keyof Rules, StringKey][] = [["blankLine", "export.opt.blankLine"], ["indent", "export.opt.indent"], ["stripMarkdown", "export.opt.stripMarkdown"], ["includeTitle", "export.opt.includeTitle"]];
const FORMATS: [Format, StringKey][] = [["txt", "export.format.txt"], ["md", "export.format.md"], ["docx", "export.format.docx"], ["epub", "export.format.epub"]];
/** Formats a file can take today; the rest are listed so the plan is visible. */
const READY: Format[] = ["txt", "md", "docx"];

type Block = { heading: boolean; text: string };

function bodyOf(s: Sample, sheet: SheetSummary) {
  return sheet.id === s.open.sheet ? s.openSheet.paragraphs : sheet.body ?? [sheet.excerpt];
}

/** The sheets in scope, in list order, turned into heading/paragraph blocks under the given rules. */
function blocks(s: Sample, scope: Scope, rules: Rules): Block[] {
  const { project, folder, sheet } = openContext(s);
  const sheets = scope === "sheet" ? [sheet] : scope === "folder" ? folder.sheets : project.folders.flatMap((f) => f.sheets);
  const out: Block[] = [];
  for (const sh of sheets) {
    let body = bodyOf(s, sh);
    // A leading heading that repeats the sheet title is the title itself.
    if (body[0]?.replace(/^#+\s/, "") === sh.title) body = body.slice(1);
    if (rules.includeTitle) out.push({ heading: true, text: rules.stripMarkdown ? sh.title : `# ${sh.title}` });
    for (const p of body) {
      const heading = /^#+\s/.test(p);
      let text = rules.stripMarkdown ? p.replace(/^#+\s|^-\s/, "").replace(/\*\*|__/g, "") : p;
      if (rules.indent && !heading) text = `　${text}`;
      out.push({ heading, text });
    }
  }
  return out;
}

export default function Export({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, sample, safeArea } = useFrame();
  const [target, setTarget] = useState<State>(state);
  const [scope, setScope] = useState<Scope>("sheet");
  const [rules, setRules] = useState<Rules>({ blankLine: true, indent: false, stripMarkdown: true, includeTitle: false });
  const [format, setFormat] = useState<Format>("txt");
  const [done, setDone] = useState(false);
  const compact = sizeClass === "compact";
  const changed = <T,>(set: (v: T) => void) => (v: T) => { set(v); setDone(false); };

  // A file keeps its own structure: md and docx keep headings, txt follows the paste rules without indentation tricks.
  const effective: Rules = target === "paste" ? rules : { blankLine: true, indent: false, stripMarkdown: format !== "md", includeTitle: true };
  const out = blocks(sample, scope, effective);

  const paste = target === "paste";
  const action = done ? (
    <Button icon="check" style={{ color: color.stateSuccess }} full={compact}>{t(paste ? "export.copied" : "export.saved")}</Button>
  ) : (
    <Button variant="primary" icon={paste ? "copy" : "save"} onClick={() => setDone(true)} full={compact}>{t(paste ? "export.copy" : "export.save")}</Button>
  );

  const options = (
    <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>
      <Segmented items={[["paste", t("export.target.paste")], ["file", t("export.target.file")]] as const} value={target} onChange={changed(setTarget)} full />
      <Section label={t("export.scope")}>
        <Segmented items={SCOPES.map(([k, s]) => [k, t(s)] as const)} value={scope} onChange={changed(setScope)} full />
      </Section>
      <Section label={t(target === "paste" ? "export.options" : "export.format")}>
        {target === "paste" ? (
          <Box>
            {RULES.map(([k, s], i) => (
              <Row key={k} first={i === 0} onClick={() => changed(setRules)({ ...rules, [k]: !rules[k] })}>
                <Checkbox on={rules[k]} />
                <span style={{ flex: 1, minWidth: 0 }}>{t(s)}</span>
              </Row>
            ))}
          </Box>
        ) : (
          <Box>
            {FORMATS.map(([f, s], i) => {
              const ready = READY.includes(f);
              return (
                <Row key={f} first={i === 0} disabled={!ready} onClick={() => ready && changed(setFormat)(f)}>
                  <Radio on={format === f} />
                  <span style={{ flex: 1, minWidth: 0 }}>{t(s)}</span>
                </Row>
              );
            })}
          </Box>
        )}
      </Section>
    </div>
  );

  const preview = <Preview blocks={out} blankLine={effective.blankLine} rich={target === "file" && format === "docx"} />;

  if (compact) {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
        <header style={{ flex: "none", display: "flex", alignItems: "center", gap: space[100], minHeight: size.barTop, padding: `0 ${space[100]}`, borderBottom: hairline(color.lineSubtle) }}>
          <IconButton icon="close" label={t("action.cancel")} onClick={() => go("app-shell")} />
          <span style={{ ...type.heading, flex: 1 }}>{t("export.title")}</span>
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200], display: "flex", flexDirection: "column", gap: space[300] }}>
          {options}
          <Section label={t("export.preview")}>{preview}</Section>
        </div>
        <footer style={{ flex: "none", padding: space[200], borderTop: hairline(color.lineSubtle), background: color.surfaceList }}>{action}</footer>
      </div>
    );
  }
  return (
    <div style={{ display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
      <section style={{ width: pane.sheetList, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceList, borderRight: hairline(color.lineSubtle) }}>
        <header style={{ flex: "none", display: "flex", alignItems: "center", gap: space[100], minHeight: size.barTop, padding: `0 ${space[100]} 0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
          <span style={{ ...type.heading, flex: 1 }}>{t("export.title")}</span>
          <IconButton icon="close" label={t("action.close")} onClick={() => go("app-shell")} />
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>{options}</div>
        <footer style={{ flex: "none", display: "flex", justifyContent: "flex-end", padding: space[200], borderTop: hairline(color.lineSubtle) }}>{action}</footer>
      </section>
      <main style={{ flex: 1, minWidth: 0, overflow: "auto", padding: `${space[300]} ${space[400]}`, background: color.surfaceSidebar }}>
        <div style={{ maxWidth: editor.measure, margin: "0 auto" }}>
          <div style={{ ...type.label, color: color.inkTertiary, marginBottom: space[100] }}>{t("export.preview")}</div>
          {preview}
        </div>
      </main>
    </div>
  );
}

function Preview({ blocks, blankLine, rich }: { blocks: Block[]; blankLine: boolean; rich: boolean }) {
  return (
    <div style={{ padding: space[300], borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceRaised, boxShadow: shadow.raised }}>
      {blocks.map((b, i) => (
        <p key={i} style={{ ...(rich && b.heading ? type.editorHeading : type.editorBody), margin: `0 0 ${blankLine ? space[200] : 0}`, whiteSpace: "pre-wrap" }}>
          {b.text}
        </p>
      ))}
    </div>
  );
}

// ── Local building blocks (become native components later) ──────────────

function Section({ label, children }: { label: string; children: ReactNode }) {
  return (
    <section>
      <div style={{ ...type.label, color: color.inkSecondary, marginBottom: space[100] }}>{label}</div>
      {children}
    </section>
  );
}

function Box({ children }: { children: ReactNode }) {
  return <div style={{ border: hairline(color.lineSubtle), borderRadius: radius.panel, overflow: "hidden", background: color.surfaceRaised }}>{children}</div>;
}

function Row({ first, disabled, onClick, children }: { first: boolean; disabled?: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <div
      onClick={onClick}
      style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[50]} ${space[150]}`, borderTop: first ? undefined : hairline(color.lineSubtle), opacity: disabled ? opacity.disabled : undefined, cursor: disabled ? "default" : "pointer" }}
    >
      {children}
    </div>
  );
}

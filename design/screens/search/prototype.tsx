// search prototype — find sheets and passages across a folder, a project or every project.
// Interactive: typing searches live, scope switches, recent searches refill the field, results open a preview (wide)
// or the sheet (compact).
import { useState, type ReactNode } from "react";
import {
  color, pane, radius, safePadding, size, space, type,
  Button, Chip, Icon, IconButton, TextField,
  openContext, useFrame, useNavigate, useT, type Sample, type SheetSummary,
} from "@ithaca/kit";

export const states = ["empty", "results", "none"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

type Scope = "folder" | "project" | "all";
type Hit = { sheet: SheetSummary; folder: string; texts: string[]; snippets: string[] };

/** Every searchable text of a sheet: title, first line, body (the open sheet has its full text in the fixture). */
function textsOf(s: Sample, sheet: SheetSummary) {
  const body = sheet.id === s.open.sheet ? s.openSheet.paragraphs : sheet.body ?? [];
  return [sheet.title, sheet.excerpt, ...body.map((p) => p.replace(/^#\s|^-\s/, ""))];
}

function search(s: Sample, query: string, scope: Scope): Hit[] {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  const { project, folder } = openContext(s);
  const projects = scope === "all" ? s.projects : [project];
  const hits: Hit[] = [];
  for (const p of projects)
    for (const f of p.folders) {
      if (scope === "folder" && f.id !== folder.id) continue;
      for (const sheet of f.sheets) {
        const texts = textsOf(s, sheet);
        const snippets = [...new Set(texts.filter((x) => x.toLowerCase().includes(q)))];
        if (snippets.length) hits.push({ sheet, folder: f.name, texts, snippets: snippets.slice(0, 2) });
      }
    }
  return hits;
}

/** Marks every occurrence of the query. */
function Marked({ text, query }: { text: string; query: string }) {
  const q = query.trim();
  if (!q) return <>{text}</>;
  const parts = text.split(new RegExp(`(${q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "gi"));
  return <>{parts.map((p, i) => (p.toLowerCase() === q.toLowerCase() ? <mark key={i} style={{ background: color.accentSoft, color: "inherit", borderRadius: radius.piece }}>{p}</mark> : p))}</>;
}

export default function Search({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, sample, safeArea } = useFrame();
  const initial = state === "results" ? sample.search.sampleQuery : state === "none" ? sample.search.emptyQuery : "";
  const [query, setQuery] = useState(initial);
  const [scope, setScope] = useState<Scope>("project");
  const hits = search(sample, query, scope);
  const [picked, setPicked] = useState<string | null>(null);
  const current = hits.find((h) => h.sheet.id === picked) ?? (sizeClass === "compact" ? null : hits[0] ?? null);
  const compact = sizeClass === "compact";

  const list = (
    <div style={{ flex: 1, overflow: "auto" }}>
      {!query.trim() && <Recent onPick={setQuery} />}
      {query.trim() && hits.length === 0 && (
        <div style={{ padding: `${space[600]} ${space[300]}`, display: "flex", flexDirection: "column", alignItems: "center", gap: space[50], textAlign: "center" }}>
          <span style={{ display: "grid", placeItems: "center", minWidth: size.touchMin, minHeight: size.touchMin, borderRadius: radius.full, background: color.surfaceSelected, color: color.inkTertiary, marginBottom: space[100] }}>
            <Icon name="search" size="lg" />
          </span>
          <div style={type.heading}>{t("search.none")}</div>
          <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[50] }}>{t("search.noneHint")}</div>
        </div>
      )}
      {hits.length > 0 && <div style={{ ...type.caption, color: color.inkTertiary, padding: `${space[150]} ${space[200]} ${space[50]}` }}>{t("search.results", { count: hits.length })}</div>}
      {hits.map((h) => (
        <article
          key={h.sheet.id}
          onClick={() => (compact ? go("app-shell") : setPicked(h.sheet.id))}
          style={{ padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle), background: current?.sheet.id === h.sheet.id ? color.surfaceSelected : "transparent", cursor: "pointer" }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: space[100] }}>
            <Icon name="sheet" size="sm" color={color.inkTertiary} />
            <span style={{ ...type.body, fontWeight: type.heading.fontWeight, flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{h.sheet.title}</span>
            <span style={{ ...type.caption, color: color.inkTertiary, flex: "none", padding: `0 ${space[100]}`, borderRadius: radius.full, background: color.surfaceSelected }}>{h.folder}</span>
          </div>
          {h.snippets.map((sn, i) => (
            <div key={i} style={{ ...type.caption, color: color.inkSecondary, marginTop: space[50] }}>
              <Marked text={sn} query={query} />
            </div>
          ))}
        </article>
      ))}
    </div>
  );

  const header = (
    <header style={{ flex: "none", display: "flex", flexDirection: "column", gap: space[100], padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
      <div style={{ display: "flex", alignItems: "center", gap: space[100] }}>
        <TextField
          value={query}
          icon="search"
          placeholder={t("search.placeholder")}
          autoFocus
          onChange={(v) => {
            setQuery(v);
            setPicked(null);
          }}
          trailing={query ? <IconButton icon="close" label={t("action.close")} onClick={() => setQuery("")} /> : undefined}
        />
        <Button variant="ghost" onClick={() => go("app-shell")}>{t("action.cancel")}</Button>
      </div>
      <ScopePicker scope={scope} onChange={setScope} />
    </header>
  );

  if (compact) {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceList, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
        {header}
        {list}
      </div>
    );
  }
  // Wide: results take the sheet list's place (Ulysses-style); the preview sits where the editor is.
  return (
    <div style={{ display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
      <section style={{ width: pane.sheetList, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceList, borderRight: hairline(color.lineSubtle) }}>
        {header}
        {list}
      </section>
      <Preview hit={current} query={query} />
    </div>
  );
}

function ScopePicker({ scope, onChange }: { scope: Scope; onChange: (s: Scope) => void }) {
  const t = useT();
  const items: [Scope, string][] = [["folder", t("search.scope.folder")], ["project", t("search.scope.project")], ["all", t("search.scope.all")]];
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: space[50] }}>
      {items.map(([s, label]) => (
        <Chip key={s} active={s === scope} onClick={() => onChange(s)}>{label}</Chip>
      ))}
    </div>
  );
}

function Recent({ onPick }: { onPick: (q: string) => void }) {
  const t = useT();
  const { sample } = useFrame();
  return (
    <div style={{ padding: `${space[150]} ${space[100]}` }}>
      <div style={{ ...type.label, color: color.inkTertiary, marginBottom: space[50], padding: `0 ${space[100]}` }}>{t("search.recent")}</div>
      {sample.search.recent.map((q) => (
        <div key={q} onClick={() => onPick(q)} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlMd, padding: `0 ${space[100]}`, borderRadius: radius.control, color: color.inkSecondary, cursor: "pointer" }}>
          <Icon name="recent" size="sm" color={color.inkTertiary} />
          {q}
        </div>
      ))}
    </div>
  );
}

function Preview({ hit, query }: { hit: Hit | null; query: string }) {
  const t = useT();
  const go = useNavigate();
  if (!hit) {
    return <Centered>{query.trim() ? null : t("search.pick")}</Centered>;
  }
  return (
    <main style={{ flex: 1, minWidth: 0, overflow: "auto", padding: `${space[300]} ${space[400]}` }}>
      <div style={{ display: "flex", alignItems: "flex-start", gap: space[150], marginBottom: space[300] }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ ...type.caption, color: color.inkTertiary }}>{hit.folder}</div>
          <div style={type.title}>{hit.sheet.title}</div>
        </div>
        <Button icon="open" onClick={() => go("app-shell")}>{t("search.open")}</Button>
      </div>
      {hit.texts.slice(2).length === 0 && <p style={{ ...type.editorBody, color: color.inkSecondary }}><Marked text={hit.sheet.excerpt} query={query} /></p>}
      {hit.texts.slice(2).map((p, i) => (
        <p key={i} style={{ ...type.editorBody, margin: `0 0 ${space[200]}` }}>
          <Marked text={p} query={query} />
        </p>
      ))}
    </main>
  );
}

function Centered({ children }: { children: ReactNode }) {
  return <main style={{ flex: 1, display: "grid", placeItems: "center", color: color.inkTertiary, ...type.body }}>{children}</main>;
}

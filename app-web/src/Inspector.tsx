// Inspector: sheet info and outline (app-shell spec). Reference shows a sheet from another folder beside the manuscript.
import { useState } from "react";
import { color, pane, radius, shadow, size, space, type, IconButton, Segmented } from "@ithaca/kit";
import { useApp, useT } from "./ctx";
import { foldersOf, sheetsIn } from "./store";
import { counts, readingMinutes, titleOf } from "./text";

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
type Tab = "reference" | "info" | "outline";
/** The inspector reopens where it was left: same tab, same reference sheet. */
let lastTab: Tab = "reference";
let lastReference = "";

export function Inspector({ mode }: { mode: "docked" | "overlay" | "sheet" }) {
  const t = useT();
  const { setView } = useApp();
  const [tab, setTabState] = useState<Tab>(lastTab);
  const setTab = (t: Tab) => setTabState((lastTab = t));
  const close = () => setView({ inspector: false });
  const frame =
    mode === "docked"
      ? { width: pane.inspector, flex: "none", borderLeft: hairline(color.lineSubtle) }
      : mode === "overlay"
        ? { position: "absolute" as const, top: 0, right: 0, bottom: 0, width: pane.inspector, boxShadow: shadow.dialog, borderLeft: hairline(color.lineSubtle), zIndex: 4 }
        : { position: "absolute" as const, left: 0, right: 0, bottom: 0, height: "55%", boxShadow: shadow.dialog, borderTopLeftRadius: radius.sheet, borderTopRightRadius: radius.sheet, zIndex: 4 };
  return (
    <>
      {mode === "sheet" && <div style={{ position: "absolute", inset: 0, background: color.surfaceScrim, cursor: "pointer", zIndex: 3 }} onClick={close} />}
      <aside style={{ ...frame, display: "flex", flexDirection: "column", background: color.surfaceRaised, overflow: "hidden" }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `${space[100]} ${space[150]} ${space[100]} ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <Segmented full items={[["reference", t("inspector.reference")], ["info", t("inspector.info")], ["outline", t("inspector.outline")]]} value={tab} onChange={setTab} />
          </div>
          <IconButton icon="close" label={t("action.close")} onClick={close} />
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>{tab === "reference" ? <Reference /> : tab === "info" ? <Info /> : <Outline />}</div>
      </aside>
    </>
  );
}

/** Pick any sheet of the project (lore by default) and read it while writing. */
function Reference() {
  const t = useT();
  const { state } = useApp();
  const folders = foldersOf(state, state.ui.projectId);
  const candidates = folders.flatMap((f) => sheetsIn(state, f.id).filter((s) => s.id !== state.ui.sheetId).map((s) => ({ s, f })));
  const [id, setIdState] = useState<string>(
    candidates.some((c) => c.s.id === lastReference) ? lastReference : candidates.find((c) => c.f.order === 1)?.s.id ?? candidates[0]?.s.id ?? "",
  );
  const setId = (v: string) => setIdState((lastReference = v));
  const pick = candidates.find((c) => c.s.id === id);
  if (!candidates.length) return <Empty>{t("reference.none")}</Empty>;
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[150] }}>
      <select
        value={id}
        onChange={(e) => setId(e.target.value)}
        aria-label={t("reference.title")}
        style={{ minHeight: size.controlMd, borderRadius: radius.control, border: hairline(color.lineStrong), background: color.surfaceRaised, color: color.inkPrimary, padding: `0 ${space[100]}`, ...type.body }}
      >
        {folders.map((f) => (
          <optgroup key={f.id} label={f.name}>
            {candidates.filter((c) => c.f.id === f.id).map(({ s }) => (
              <option key={s.id} value={s.id}>{titleOf(s.body) || t("sheet.untitled")}</option>
            ))}
          </optgroup>
        ))}
      </select>
      {pick && (
        <div style={{ ...type.body, color: color.inkPrimary, wordBreak: "keep-all", overflowWrap: "anywhere" }}>
          {pick.s.body.split("\n").map((line, i) =>
            /^#+\s/.test(line) ? (
              <div key={i} style={{ ...type.heading, margin: `${space[100]} 0 ${space[50]}` }}>
                <span style={{ color: color.inkMarkup }}>{line.match(/^#+\s/)![0]}</span>
                {line.replace(/^#+\s/, "")}
              </div>
            ) : (
              <div key={i} style={{ minHeight: line.trim() ? undefined : space[150], whiteSpace: "pre-wrap" }}>{line}</div>
            ),
          )}
        </div>
      )}
    </div>
  );
}

function Info() {
  const t = useT();
  const { state, locale } = useApp();
  const sheet = state.sheets.find((s) => s.id === state.ui.sheetId);
  const project = state.projects.find((p) => p.id === state.ui.projectId)!;
  if (!sheet) return <Empty>{t("editor.noSheet")}</Empty>;
  const c = counts(sheet.body);
  const n = (v: number) => v.toLocaleString(locale);
  const date = new Intl.DateTimeFormat(locale, { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  const rows: [string, string][] = [
    [t("info.withSpaces"), n(c.chars)],
    [t("info.withoutSpaces"), n(c.charsNoSpace)],
    project.language === "ko" ? [t("info.manuscriptPages"), t("info.pages", { count: Math.ceil(c.chars / 200) })] : [t("info.words"), n(c.words)],
    [t("info.paragraphs"), n(c.paragraphs)],
    [t("info.readingTime"), t("info.minutes", { count: readingMinutes(c, project.language) })],
    [t("info.created"), date.format(sheet.created)],
    [t("info.modified"), date.format(sheet.modified)],
  ];
  return (
    <div>
      {rows.map(([k, v], i) => (
        <div key={k} style={{ display: "flex", alignItems: "baseline", gap: space[150], padding: `${space[100]} 0`, borderTop: i ? hairline(color.lineSubtle) : undefined, flexWrap: "wrap" }}>
          <span style={{ flex: "1 1 auto", color: color.inkSecondary }}>{k}</span>
          <span style={{ fontWeight: type.heading.fontWeight }}>{v}</span>
        </div>
      ))}
    </div>
  );
}

/** Headings and paragraph first lines; clicking moves the caret there. */
function Outline() {
  const t = useT();
  const { state } = useApp();
  const sheet = state.sheets.find((s) => s.id === state.ui.sheetId);
  if (!sheet?.body.trim()) return <Empty>{t("outline.empty")}</Empty>;
  let offset = 0;
  const items = sheet.body.split("\n").map((line) => {
    const at = offset;
    offset += line.length + 1;
    return { line, at };
  }).filter((x) => x.line.trim());
  const jump = (at: number) => {
    const el = document.getElementById("ithaca-editor") as HTMLTextAreaElement | null;
    if (!el) return;
    el.focus();
    el.setSelectionRange(at, at);
    // Scroll the caret line into view: measure with a mirror is overkill here; proportional is close enough.
    const article = el.parentElement!;
    article.scrollTop = (at / Math.max(1, el.value.length)) * el.scrollHeight - article.clientHeight / 3;
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[25] }}>
      {items.map(({ line, at }) => {
        const heading = /^#+\s/.test(line);
        return (
          <div
            key={at}
            onClick={() => jump(at)}
            style={{ minHeight: size.controlSm, display: "flex", alignItems: "center", padding: `${space[50]} ${space[100]}`, paddingLeft: heading ? space[100] : space[300], borderRadius: radius.control, cursor: "pointer" }}
          >
            <span style={{ ...(heading ? type.label : type.caption), fontWeight: heading ? type.heading.fontWeight : undefined, color: heading ? color.inkPrimary : color.inkSecondary, flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {heading ? line.replace(/^#+\s*/, "") : line}
            </span>
          </div>
        );
      })}
    </div>
  );
}

function Empty({ children }: { children: string }) {
  return <div style={{ ...type.caption, color: color.inkTertiary }}>{children}</div>;
}

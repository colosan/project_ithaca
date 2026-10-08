// project-settings prototype — title, manuscript language, per-sheet length goal, folders.
import { useState, type ReactNode } from "react";
import {
  color, pane, radius, shadow, size, space, type,
  Button, Icon, IconButton, Radio, Segmented, TextField,
  openContext, safePadding, useFrame, useNavigate, useT, type StringKey,
} from "@ithaca/kit";

export const states = ["default"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

type Basis = "withSpaces" | "withoutSpaces" | "words";
const BASIS: [Basis, StringKey][] = [["withSpaces", "goal.basis.withSpaces"], ["withoutSpaces", "goal.basis.withoutSpaces"], ["words", "goal.basis.words"]];

/** compact: full-screen page with a nav bar. medium+: centered dialog over a scrim. */
export default function ProjectSettings({ state: _state }: { state: State }) {
  const { sizeClass, safeArea } = useFrame();
  const t = useT();
  const go = useNavigate();
  const body = <Body />;
  const done = <Button variant="primary" onClick={() => go("app-shell")}>{t("action.done")}</Button>;
  if (sizeClass === "compact") {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[100]}`, borderBottom: hairline(color.lineSubtle) }}>
          <IconButton icon="back" label={t("nav.back")} onClick={() => go("app-shell")} />
          <span style={{ flex: 1, ...type.heading }}>{t("projectSettings.title")}</span>
          {done}
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>{body}</div>
      </div>
    );
  }
  return (
    <div style={{ position: "relative", height: "100%", background: color.surfaceScrim, display: "flex", alignItems: "center", justifyContent: "center", ...safePadding(safeArea), color: color.inkPrimary, ...type.body }}>
      <div style={{ width: pane.dialog, maxWidth: "90%", maxHeight: "90%", overflow: "hidden", display: "flex", flexDirection: "column", background: color.surfaceCanvas, borderRadius: radius.sheet, boxShadow: shadow.dialog }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[150]} 0 ${space[300]}`, borderBottom: hairline(color.lineSubtle) }}>
          <span style={{ ...type.heading, flex: 1 }}>{t("projectSettings.title")}</span>
          {done}
        </header>
        <div style={{ overflow: "auto", padding: space[300] }}>{body}</div>
      </div>
    </div>
  );
}

function Body() {
  const t = useT();
  const { sample, locale, sizeClass } = useFrame();
  const { project } = openContext(sample);
  const [title, setTitle] = useState(project.title);
  const [lang, setLang] = useState(project.language);
  const [goal, setGoal] = useState(project.goal ? project.goal.count.toLocaleString(locale) : "");
  const [basis, setBasis] = useState<Basis>(project.goal?.basis ?? "withSpaces");
  const [folders, setFolders] = useState(project.folders.map((f) => ({ id: f.id, name: f.name, count: f.sheets.length })));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>
      <Section label={t("projectSettings.name")}>
        <TextField value={title} onChange={setTitle} />
      </Section>

      <Section label={t("projectSettings.language")}>
        <Segmented items={[["ko", t("language.ko")], ["en", t("language.en")]] as const} value={lang} onChange={setLang} />
      </Section>

      <Section label={t("projectSettings.goal")} hint={t("projectSettings.goalHint")}>
        <div style={{ display: "flex", gap: space[100], flexWrap: "wrap", alignItems: "flex-start" }}>
          <TextField value={goal} placeholder={t("projectSettings.goalNone")} onChange={setGoal} width={size.rowSheet} />
          {/* Three long options do not fit a segmented control on a phone — stack them as a radio list there. */}
          {sizeClass === "compact" ? (
            <div style={{ width: "100%", borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceRaised, overflow: "hidden" }}>
              {BASIS.map(([k, s], i) => (
                <div key={k} onClick={() => setBasis(k)} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[50]} ${space[150]}`, borderTop: i ? hairline(color.lineSubtle) : undefined, cursor: "pointer" }}>
                  <Radio on={basis === k} />
                  <span>{t(s)}</span>
                </div>
              ))}
            </div>
          ) : (
            <Segmented items={BASIS.map(([k, s]) => [k, t(s)] as const)} value={basis} onChange={setBasis} />
          )}
        </div>
      </Section>

      <Section label={t("projectSettings.folders")} hint={t("projectSettings.folderHint")}>
        <div style={{ borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceRaised, overflow: "hidden" }}>
          {folders.map((f, i) => (
            <div key={f.id} style={{ display: "flex", alignItems: "center", gap: space[100], minHeight: size.controlLg, padding: `${space[50]} ${space[100]}`, borderTop: i ? hairline(color.lineSubtle) : undefined }}>
              <span style={{ display: "grid", placeItems: "center", color: color.inkMarkup, cursor: "grab" }}><Icon name="reorder" size="sm" /></span>
              <Icon name="folder" size="sm" color={color.inkTertiary} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div>{f.name}</div>
                <div style={{ ...type.caption, color: color.inkTertiary }}>{t("sheetList.count", { count: f.count })}</div>
              </div>
              {/* Phones keep the name readable: icon-only actions (labels stay as tooltips / accessibility names). */}
              {sizeClass === "compact" ? (
                <>
                  <IconButton icon="rename" label={t("folder.rename")} />
                  <IconButton icon="delete" label={t("folder.delete")} tone={color.stateDanger} onClick={() => setFolders((l) => l.filter((x) => x.id !== f.id))} />
                </>
              ) : (
                <>
                  <Button variant="ghost">{t("folder.rename")}</Button>
                  <Button variant="ghost" style={{ color: color.stateDanger }} onClick={() => setFolders((l) => l.filter((x) => x.id !== f.id))}>{t("folder.delete")}</Button>
                </>
              )}
            </div>
          ))}
          <div
            onClick={() => setFolders((l) => [...l, { id: `new-${l.length}`, name: t("folder.new"), count: 0 }])}
            style={{ display: "flex", alignItems: "center", gap: space[100], minHeight: size.controlLg, padding: `0 ${space[150]}`, borderTop: hairline(color.lineSubtle), ...type.label, fontWeight: type.heading.fontWeight, color: color.accentPrimary, cursor: "pointer" }}
          >
            <Icon name="add" size="sm" />
            {t("folder.new")}
          </div>
        </div>
      </Section>
    </div>
  );
}

function Section({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <section>
      <div style={{ ...type.label, color: color.inkSecondary, marginBottom: space[100] }}>{label}</div>
      {children}
      {hint && <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[100] }}>{hint}</div>}
    </section>
  );
}

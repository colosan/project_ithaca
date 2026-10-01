// project-settings prototype — title, manuscript language, per-sheet length goal, folders.
import { useState, type ReactNode } from "react";
import { color, pane, radius, shadow, size, space, type, openContext, useFrame, useNavigate, useT, type StringKey } from "@ithaca/kit";

export const states = ["default"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const clickable = { cursor: "pointer" } as const;

/** compact: full-screen page with a nav bar. medium+: centered dialog over a scrim. */
export default function ProjectSettings({ state: _state }: { state: State }) {
  const { sizeClass } = useFrame();
  const t = useT();
  const go = useNavigate();
  const body = <Body />;
  if (sizeClass === "compact") {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body }}>
        <header style={{ height: size.barTop, flex: "none", display: "flex", alignItems: "center", padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle), ...type.label }}>
          <span style={{ color: color.inkSecondary, ...clickable }} onClick={() => go("app-shell")}>‹ {t("nav.back")}</span>
          <span style={{ flex: 1, textAlign: "center", ...type.heading }}>{t("projectSettings.title")}</span>
          <span style={{ color: color.accentPrimary, ...clickable }} onClick={() => go("app-shell")}>{t("action.done")}</span>
        </header>
        <div style={{ flex: 1, overflow: "hidden", padding: space[200] }}>{body}</div>
      </div>
    );
  }
  return (
    <div style={{ position: "relative", height: "100%", background: color.surfaceScrim, display: "flex", alignItems: "center", justifyContent: "center", color: color.inkPrimary, ...type.body }}>
      <div style={{ width: pane.dialog, maxWidth: "90%", maxHeight: "90%", overflow: "hidden", display: "flex", flexDirection: "column", background: color.surfaceRaised, borderRadius: radius.sheet, boxShadow: shadow.dialog }}>
        <header style={{ height: size.barTop, flex: "none", display: "flex", alignItems: "center", padding: `0 ${space[300]}`, borderBottom: hairline(color.lineSubtle) }}>
          <span style={{ ...type.heading, flex: 1 }}>{t("projectSettings.title")}</span>
          <span style={{ ...type.label, color: color.accentPrimary, ...clickable }} onClick={() => go("app-shell")}>{t("action.done")}</span>
        </header>
        <div style={{ overflow: "hidden", padding: space[300] }}>{body}</div>
      </div>
    </div>
  );
}

function Body() {
  const t = useT();
  const { sample, locale, sizeClass } = useFrame();
  const { project } = openContext(sample);
  const [folders, setFolders] = useState(project.folders.map((f) => ({ id: f.id, name: f.name, count: f.sheets.length })));
  const basisKey: Record<string, StringKey> = {
    withSpaces: "goal.basis.withSpaces",
    withoutSpaces: "goal.basis.withoutSpaces",
    words: "goal.basis.words",
  };
  const basisIndex = Object.keys(basisKey).indexOf(project.goal?.basis ?? "withSpaces");
  const basisLabels = Object.values(basisKey).map((k) => t(k));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>
      <Section label={t("projectSettings.name")}>
        <Field>{project.title}</Field>
      </Section>

      <Section label={t("projectSettings.language")}>
        <Segmented options={[t("language.ko"), t("language.en")]} active={project.language === "ko" ? 0 : 1} />
      </Section>

      <Section label={t("projectSettings.goal")} hint={t("projectSettings.goalHint")}>
        <div style={{ display: "flex", gap: space[100], flexWrap: "wrap" }}>
          <Field narrow>{project.goal ? project.goal.count.toLocaleString(locale) : t("projectSettings.goalNone")}</Field>
          {/* Three long options do not fit a segmented control on a phone — stack them as a radio list there. */}
          {sizeClass === "compact" ? <RadioList options={basisLabels} active={basisIndex} /> : <Segmented options={basisLabels} active={basisIndex} />}
        </div>
      </Section>

      <Section label={t("projectSettings.folders")} hint={t("projectSettings.folderHint")}>
        <div style={{ border: hairline(color.lineSubtle), borderRadius: radius.panel, overflow: "hidden" }}>
          {folders.map((f) => (
            <div key={f.id} style={{ display: "flex", alignItems: "center", gap: space[150], height: size.controlLg, padding: `0 ${space[150]}`, borderBottom: hairline(color.lineSubtle) }}>
              <span style={{ color: color.inkMarkup }}>≡</span>
              <span style={{ flex: 1 }}>{f.name}</span>
              <span style={{ ...type.caption, color: color.inkTertiary }}>{t("sheetList.count", { count: f.count })}</span>
              <span style={{ ...type.label, color: color.inkSecondary }}>{t("folder.rename")}</span>
              <span style={{ ...type.label, color: color.stateDanger, ...clickable }} onClick={() => setFolders((l) => l.filter((x) => x.id !== f.id))}>{t("folder.delete")}</span>
            </div>
          ))}
          <div
            onClick={() => setFolders((l) => [...l, { id: `new-${l.length}`, name: t("folder.new"), count: 0 }])}
            style={{ display: "flex", alignItems: "center", height: size.controlLg, padding: `0 ${space[150]}`, ...type.label, color: color.accentPrimary, ...clickable }}
          >
            ＋ {t("folder.new")}
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
      {hint && <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[50] }}>{hint}</div>}
    </section>
  );
}

/** Grows with its content (long titles wrap) instead of a fixed height the text could spill out of. */
function Field({ children, narrow }: { children: ReactNode; narrow?: boolean }) {
  return (
    <div style={{ display: "flex", alignItems: "center", minHeight: size.controlMd, padding: `${space[100]} ${space[150]}`, border: hairline(color.lineStrong), borderRadius: radius.piece, background: color.surfaceCanvas, flex: narrow ? "none" : 1, minWidth: narrow ? size.rowSheet : 0 }}>
      {children}
    </div>
  );
}

function RadioList({ options, active: initial }: { options: string[]; active: number }) {
  const [active, setActive] = useState(initial);
  return (
    <div style={{ width: "100%", border: hairline(color.lineStrong), borderRadius: radius.piece, overflow: "hidden" }}>
      {options.map((o, i) => (
        <div key={o} onClick={() => setActive(i)} style={{ cursor: "pointer", display: "flex", alignItems: "center", gap: space[100], minHeight: size.controlMd, padding: `0 ${space[150]}`, borderTop: i ? hairline(color.lineSubtle) : undefined, background: i === active ? color.surfaceSelected : "transparent" }}>
          <span style={{ color: i === active ? color.accentPrimary : color.inkMarkup }}>{i === active ? "●" : "○"}</span>
          <span style={type.label}>{o}</span>
        </div>
      ))}
    </div>
  );
}

function Segmented({ options, active: initial }: { options: string[]; active: number }) {
  const [active, setActive] = useState(initial);
  return (
    <div style={{ display: "inline-flex", border: hairline(color.lineStrong), borderRadius: radius.piece, overflow: "hidden", ...type.label }}>
      {options.map((o, i) => (
        <span key={o} onClick={() => setActive(i)} style={{ cursor: "pointer", whiteSpace: "nowrap", padding: `${space[100]} ${space[150]}`, background: i === active ? color.surfaceSelected : "transparent", color: i === active ? color.inkPrimary : color.inkSecondary, borderLeft: i ? hairline(color.lineStrong) : undefined }}>
          {o}
        </span>
      ))}
    </div>
  );
}

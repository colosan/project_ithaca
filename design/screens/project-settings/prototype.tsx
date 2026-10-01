// project-settings prototype — title, manuscript language, per-sheet length goal, folders.
import type { ReactNode } from "react";
import { color, pane, radius, shadow, size, space, type, openContext, useFrame, useT, type StringKey } from "@ithaca/kit";

export const states = ["default"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

/** compact: full-screen page with a nav bar. medium+: centered dialog over a scrim. */
export default function ProjectSettings({ state: _state }: { state: State }) {
  const { sizeClass } = useFrame();
  const t = useT();
  const body = <Body />;
  if (sizeClass === "compact") {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body }}>
        <header style={{ height: size.barTop, flex: "none", display: "flex", alignItems: "center", padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle), ...type.label }}>
          <span style={{ color: color.inkSecondary }}>‹ {t("nav.back")}</span>
          <span style={{ flex: 1, textAlign: "center", ...type.heading }}>{t("projectSettings.title")}</span>
          <span style={{ color: color.accentPrimary }}>{t("action.done")}</span>
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
          <span style={{ ...type.label, color: color.accentPrimary }}>{t("action.done")}</span>
        </header>
        <div style={{ overflow: "hidden", padding: space[300] }}>{body}</div>
      </div>
    </div>
  );
}

function Body() {
  const t = useT();
  const { sample, locale } = useFrame();
  const { project } = openContext(sample);
  const basisKey: Record<string, StringKey> = {
    withSpaces: "goal.basis.withSpaces",
    withoutSpaces: "goal.basis.withoutSpaces",
    words: "goal.basis.words",
  };
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
          <Segmented
            options={Object.values(basisKey).map((k) => t(k))}
            active={Object.keys(basisKey).indexOf(project.goal?.basis ?? "withSpaces")}
          />
        </div>
      </Section>

      <Section label={t("projectSettings.folders")} hint={t("projectSettings.folderHint")}>
        <div style={{ border: hairline(color.lineSubtle), borderRadius: radius.panel, overflow: "hidden" }}>
          {project.folders.map((f) => (
            <div key={f.id} style={{ display: "flex", alignItems: "center", gap: space[150], height: size.controlLg, padding: `0 ${space[150]}`, borderBottom: hairline(color.lineSubtle) }}>
              <span style={{ color: color.inkMarkup }}>≡</span>
              <span style={{ flex: 1 }}>{f.name}</span>
              <span style={{ ...type.caption, color: color.inkTertiary }}>{t("sheetList.count", { count: f.sheets.length })}</span>
              <span style={{ ...type.label, color: color.inkSecondary }}>{t("folder.rename")}</span>
              <span style={{ ...type.label, color: color.stateDanger }}>{t("folder.delete")}</span>
            </div>
          ))}
          <div style={{ display: "flex", alignItems: "center", height: size.controlLg, padding: `0 ${space[150]}`, ...type.label, color: color.accentPrimary }}>
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

function Field({ children, narrow }: { children: ReactNode; narrow?: boolean }) {
  return (
    <div style={{ display: "flex", alignItems: "center", height: size.controlMd, padding: `0 ${space[150]}`, border: hairline(color.lineStrong), borderRadius: radius.piece, background: color.surfaceCanvas, flex: narrow ? "none" : 1, minWidth: narrow ? size.rowSheet : 0 }}>
      {children}
    </div>
  );
}

function Segmented({ options, active }: { options: string[]; active: number }) {
  return (
    <div style={{ display: "inline-flex", border: hairline(color.lineStrong), borderRadius: radius.piece, overflow: "hidden", ...type.label }}>
      {options.map((o, i) => (
        <span key={o} style={{ padding: `${space[100]} ${space[150]}`, background: i === active ? color.surfaceSelected : "transparent", color: i === active ? color.inkPrimary : color.inkSecondary, borderLeft: i ? hairline(color.lineStrong) : undefined }}>
          {o}
        </span>
      ))}
    </div>
  );
}

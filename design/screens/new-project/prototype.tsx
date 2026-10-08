// new-project prototype — create a project: title, manuscript language, length goal, starting folders.
// Interactive: typing a title enables Create; folders can be unchecked and renamed; Create opens the app shell.
import { useState, type ReactNode } from "react";
import {
  color, pane, radius, safePadding, shadow, size, space, type,
  Button, Checkbox, Icon, IconButton, Radio, Segmented, TextField,
  useFrame, useNavigate, useT, type StringKey,
} from "@ithaca/kit";

export const states = ["default", "first-run"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

const FOLDER_KEYS: StringKey[] = ["folder.defaultSerial", "folder.defaultLore", "folder.defaultMaterial"];
type Basis = "withSpaces" | "withoutSpaces" | "words";
const BASIS: [Basis, StringKey][] = [["withSpaces", "goal.basis.withSpaces"], ["withoutSpaces", "goal.basis.withoutSpaces"], ["words", "goal.basis.words"]];

export default function NewProject({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, safeArea } = useFrame();
  const firstRun = state === "first-run";
  const [title, setTitle] = useState("");
  const ready = title.trim().length > 0;

  const createButton = <Button variant="primary" disabled={!ready} onClick={() => go("app-shell")}>{t("newProject.create")}</Button>;
  const body = <Form title={title} setTitle={setTitle} firstRun={firstRun} />;

  if (sizeClass === "compact") {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: `0 ${space[100]} 0 ${firstRun ? space[200] : space[100]}`, borderBottom: hairline(color.lineSubtle) }}>
          {!firstRun && <IconButton icon="close" label={t("action.cancel")} onClick={() => go("app-shell")} />}
          <span style={{ ...type.heading, flex: 1 }}>{t("newProject.title")}</span>
          {createButton}
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>{body}</div>
      </div>
    );
  }

  // Wide: a dialog over the app, or a centered card on the empty first-run screen.
  return (
    <div style={{ height: "100%", display: "flex", alignItems: "center", justifyContent: "center", background: firstRun ? color.surfaceSidebar : color.surfaceScrim, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
      <div style={{ width: pane.dialog, maxWidth: "90%", maxHeight: "90%", display: "flex", flexDirection: "column", overflow: "hidden", background: color.surfaceCanvas, borderRadius: radius.sheet, boxShadow: shadow.dialog }}>
        <div style={{ flex: 1, overflow: "auto", padding: space[400] }}>{body}</div>
        <footer style={{ flex: "none", display: "flex", justifyContent: "flex-end", gap: space[100], padding: `${space[200]} ${space[300]}`, borderTop: hairline(color.lineSubtle), background: color.surfaceList }}>
          {!firstRun && <Button onClick={() => go("app-shell")}>{t("action.cancel")}</Button>}
          {createButton}
        </footer>
      </div>
    </div>
  );
}

function Form({ title, setTitle, firstRun }: { title: string; setTitle: (v: string) => void; firstRun: boolean }) {
  const t = useT();
  const { locale, sizeClass } = useFrame();
  const [lang, setLang] = useState(locale);
  const [goal, setGoal] = useState("");
  const [basis, setBasis] = useState<Basis>("withSpaces");
  const [folders, setFolders] = useState(FOLDER_KEYS.map((k) => ({ key: k, on: true, name: t(k) })));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>
      {(firstRun || sizeClass !== "compact") && (
        <div style={{ display: "flex", flexDirection: "column", gap: space[100] }}>
          {firstRun && (
            <span style={{ display: "grid", placeItems: "center", minWidth: size.touchMin, minHeight: size.touchMin, alignSelf: "flex-start", borderRadius: radius.panel, background: color.accentSoft, color: color.accentPrimary }}>
              <Icon name="edit" size="lg" />
            </span>
          )}
          <div style={sizeClass === "compact" ? type.title : type.display}>{firstRun ? t("welcome.title") : t("newProject.title")}</div>
          {firstRun && <div style={{ color: color.inkSecondary }}>{t("welcome.subtitle")}</div>}
        </div>
      )}

      <Section label={t("projectSettings.name")}>
        <TextField value={title} placeholder={t("newProject.titlePlaceholder")} onChange={setTitle} autoFocus />
      </Section>

      <Section label={t("projectSettings.language")}>
        <Segmented items={[["ko", t("language.ko")], ["en", t("language.en")]] as const} value={lang} onChange={setLang} />
      </Section>

      <Section label={t("projectSettings.goal")} hint={t("projectSettings.goalHint")}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: space[100] }}>
          <TextField value={goal} placeholder={t("projectSettings.goalNone")} onChange={setGoal} width={size.rowSheet} />
          {/* Same as project settings: three long options become a radio list on a phone. */}
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

      <Section label={t("newProject.folders")} hint={t("newProject.foldersHint")}>
        <div style={{ border: hairline(color.lineSubtle), borderRadius: radius.panel, background: color.surfaceRaised, overflow: "hidden" }}>
          {folders.map((f, i) => (
            <div key={f.key} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[50]} ${space[150]}`, borderTop: i ? hairline(color.lineSubtle) : undefined }}>
              <span style={{ display: "grid", cursor: "pointer" }} onClick={() => setFolders((l) => l.map((x, j) => (j === i ? { ...x, on: !x.on } : x)))}>
                <Checkbox on={f.on} />
              </span>
              <Icon name="folder" size="sm" color={f.on ? color.inkTertiary : color.inkMarkup} />
              <input
                value={f.name}
                onChange={(e) => setFolders((l) => l.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)))}
                style={{ flex: 1, minWidth: 0, ...type.body, color: f.on ? color.inkPrimary : color.inkTertiary, textDecoration: f.on ? undefined : "line-through", background: "transparent", border: "none", outline: "none", padding: 0 }}
              />
            </div>
          ))}
        </div>
      </Section>

      {firstRun && <div style={{ ...type.caption, color: color.inkTertiary }}>{t("welcome.import")}</div>}
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

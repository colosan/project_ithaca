// new-project prototype — create a project: title, manuscript language, length goal, starting folders.
// Interactive: typing a title enables Create; folders can be unchecked and renamed; Create opens the app shell.
import { useState, type ReactNode } from "react";
import { color, opacity, pane, radius, safePadding, shadow, size, space, type, useFrame, useNavigate, useT, type StringKey } from "@ithaca/kit";

export const states = ["default", "first-run"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const clickable = { cursor: "pointer" } as const;

const FOLDER_KEYS: StringKey[] = ["folder.defaultSerial", "folder.defaultLore", "folder.defaultMaterial"];
const BASIS_KEYS: StringKey[] = ["goal.basis.withSpaces", "goal.basis.withoutSpaces", "goal.basis.words"];

export default function NewProject({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, safeArea } = useFrame();
  const firstRun = state === "first-run";
  const [title, setTitle] = useState("");
  const ready = title.trim().length > 0;

  const create = () => ready && go("app-shell");
  const createButton = (
    <span
      onClick={create}
      style={{ ...type.label, padding: `${space[100]} ${space[200]}`, borderRadius: radius.piece, background: color.accentPrimary, color: color.inkOnAccent, opacity: ready ? undefined : opacity.disabled, cursor: ready ? "pointer" : "default", whiteSpace: "nowrap" }}
    >
      {t("newProject.create")}
    </span>
  );
  const body = <Form title={title} setTitle={setTitle} firstRun={firstRun} />;

  if (sizeClass === "compact") {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[150], padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
          {!firstRun && <span style={{ ...type.label, color: color.inkSecondary, ...clickable }} onClick={() => go("app-shell")}>{t("action.cancel")}</span>}
          <span style={{ ...type.heading, flex: 1, textAlign: firstRun ? "left" : "center" }}>{t("newProject.title")}</span>
          {createButton}
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>{body}</div>
      </div>
    );
  }

  // Wide: a dialog over the app, or a centered card on the empty first-run screen.
  return (
    <div style={{ height: "100%", display: "flex", alignItems: "center", justifyContent: "center", background: firstRun ? color.surfaceSidebar : color.surfaceScrim, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
      <div style={{ width: pane.dialog, maxWidth: "90%", maxHeight: "90%", display: "flex", flexDirection: "column", overflow: "hidden", background: color.surfaceRaised, borderRadius: radius.sheet, boxShadow: shadow.dialog }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[150], padding: `0 ${space[300]}`, borderBottom: hairline(color.lineSubtle) }}>
          <span style={{ ...type.heading, flex: 1 }}>{t("newProject.title")}</span>
          {!firstRun && <span style={{ ...type.label, color: color.inkSecondary, ...clickable }} onClick={() => go("app-shell")}>{t("action.cancel")}</span>}
          {createButton}
        </header>
        <div style={{ overflow: "auto", padding: space[300] }}>{body}</div>
      </div>
    </div>
  );
}

function Form({ title, setTitle, firstRun }: { title: string; setTitle: (v: string) => void; firstRun: boolean }) {
  const t = useT();
  const { locale } = useFrame();
  const [folders, setFolders] = useState(FOLDER_KEYS.map((k) => ({ key: k, on: true, name: t(k) })));
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>
      {firstRun && (
        <div>
          <div style={{ ...type.title }}>{t("welcome.title")}</div>
          <div style={{ ...type.body, color: color.inkSecondary, marginTop: space[50] }}>{t("welcome.subtitle")}</div>
        </div>
      )}

      <Section label={t("projectSettings.name")}>
        <TextInput value={title} placeholder={t("newProject.titlePlaceholder")} onChange={setTitle} autoFocus />
      </Section>

      <Section label={t("projectSettings.language")}>
        <Segmented options={[t("language.ko"), t("language.en")]} initial={locale === "ko" ? 0 : 1} />
      </Section>

      <Section label={t("projectSettings.goal")} hint={t("projectSettings.goalHint")}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: space[100] }}>
          <TextInput value="" placeholder={t("projectSettings.goalNone")} onChange={() => {}} narrow />
          <Segmented options={BASIS_KEYS.map((k) => t(k))} initial={0} />
        </div>
      </Section>

      <Section label={t("newProject.folders")} hint={t("newProject.foldersHint")}>
        <div style={{ border: hairline(color.lineSubtle), borderRadius: radius.panel, overflow: "hidden" }}>
          {folders.map((f, i) => (
            <div key={f.key} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[50]} ${space[150]}`, borderTop: i ? hairline(color.lineSubtle) : undefined }}>
              <Check on={f.on} onToggle={() => setFolders((l) => l.map((x, j) => (j === i ? { ...x, on: !x.on } : x)))} />
              <input
                value={f.name}
                onChange={(e) => setFolders((l) => l.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)))}
                style={{ flex: 1, minWidth: 0, ...type.body, color: f.on ? color.inkPrimary : color.inkTertiary, background: "transparent", border: "none", outline: "none", padding: 0 }}
              />
            </div>
          ))}
        </div>
      </Section>

      {firstRun && <div style={{ ...type.caption, color: color.inkTertiary }}>{t("welcome.import")}</div>}
    </div>
  );
}

// ── Local building blocks (become native components later) ──────────────

function Section({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <section>
      <div style={{ ...type.label, color: color.inkSecondary, marginBottom: space[100] }}>{label}</div>
      {children}
      {hint && <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[50] }}>{hint}</div>}
    </section>
  );
}

function TextInput({ value, placeholder, onChange, narrow, autoFocus }: { value: string; placeholder: string; onChange: (v: string) => void; narrow?: boolean; autoFocus?: boolean }) {
  return (
    <input
      value={value}
      placeholder={placeholder}
      autoFocus={autoFocus}
      onChange={(e) => onChange(e.target.value)}
      style={{
        ...type.body, color: color.inkPrimary, background: color.surfaceCanvas,
        minHeight: size.controlMd, padding: `0 ${space[150]}`, border: hairline(color.lineStrong), borderRadius: radius.piece,
        width: narrow ? size.rowSheet : "100%", flex: narrow ? "none" : undefined, outline: "none",
      }}
    />
  );
}

function Check({ on, onToggle }: { on: boolean; onToggle: () => void }) {
  return (
    <span
      onClick={onToggle}
      style={{ flex: "none", display: "grid", placeItems: "center", minWidth: size.iconMd, minHeight: size.iconMd, borderRadius: radius.piece, border: hairline(on ? color.accentPrimary : color.lineStrong), background: on ? color.accentPrimary : "transparent", color: color.inkOnAccent, ...type.caption, ...clickable }}
    >
      {on ? "✓" : ""}
    </span>
  );
}

function Segmented({ options, initial }: { options: string[]; initial: number }) {
  const [active, setActive] = useState(initial);
  return (
    <div style={{ display: "inline-flex", flexWrap: "wrap", border: hairline(color.lineStrong), borderRadius: radius.piece, overflow: "hidden", ...type.label }}>
      {options.map((o, i) => (
        <span key={o} onClick={() => setActive(i)} style={{ flex: "1 1 auto", textAlign: "center", padding: `${space[100]} ${space[150]}`, background: i === active ? color.surfaceSelected : "transparent", color: i === active ? color.inkPrimary : color.inkSecondary, ...clickable }}>
          {o}
        </span>
      ))}
    </div>
  );
}

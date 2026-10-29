// Preferences that work today. Sections follow design/screens/preferences; ones that need the native core
// (sync, Claude, shortcuts editing) say so instead of pretending.
import { useRef, useState } from "react";
import { color, radius, size, space, type, Button, Icon, Segmented, Switch } from "@ithaca/kit";
import { Dialog, DialogBody, Group, Label, Row, usePressable } from "./Dialog";
import { useApp, useT } from "./ctx";
import { exportState, parseState, type Prefs } from "./store";

type Section = "general" | "editor" | "backup" | "about";
const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

let nextSection: Section = "general";
/** Open Settings on a given section (the backup reminder opens Backup). */
export function openSettings(app: { setOverlay: (o: "settings") => void }, section: Section) {
  nextSection = section;
  app.setOverlay("settings");
}

export function Settings() {
  const t = useT();
  const { sizeClass } = useApp();
  const [section, setSection] = useState<Section>(() => {
    const s = nextSection;
    nextSection = "general";
    return s;
  });
  const stacked = sizeClass === "compact" || sizeClass === "medium";
  const sections: [Section, string, Parameters<typeof Icon>[0]["name"]][] = [
    ["general", t("prefs.general"), "settings"],
    ["editor", t("prefs.editor"), "editorText"],
    ["backup", t("prefs.backup"), "backup"],
    ["about", t("prefs.about"), "info"],
  ];
  return (
    <Dialog title={t("prefs.title")} wide>
      <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: stacked ? "column" : "row" }}>
        {/* Stacked: the tabs wrap onto a second line rather than clipping the last one on a phone. */}
        <nav role="tablist" aria-orientation={stacked ? "horizontal" : "vertical"} style={{ flex: "none", display: "flex", flexDirection: stacked ? "row" : "column", flexWrap: stacked ? "wrap" : undefined, gap: space[25], padding: space[150], overflow: "auto", borderRight: stacked ? undefined : hairline(color.lineSubtle), borderBottom: stacked ? hairline(color.lineSubtle) : undefined, background: color.surfaceSidebar }}>
          {sections.map(([k, label, icon]) => (
            <SectionTab key={k} label={label} icon={icon} on={k === section} onPress={() => setSection(k)} />
          ))}
        </nav>
        <DialogBody role="tabpanel" aria-label={sections.find(([k]) => k === section)?.[1]} style={{ minWidth: 0 }}>
          {section === "general" && <General stacked={stacked} />}
          {section === "editor" && <EditorPrefs stacked={stacked} />}
          {section === "backup" && <Backup />}
          {section === "about" && <About />}
        </DialogBody>
      </div>
    </Dialog>
  );
}

function SectionTab({ label, icon, on, onPress }: { label: string; icon: Parameters<typeof Icon>[0]["name"]; on: boolean; onPress: () => void }) {
  const { ringStyle, ...press } = usePressable(onPress);
  return (
    <div
      {...press}
      role="tab"
      aria-selected={on}
      style={{
        display: "flex", alignItems: "center", gap: space[100], minHeight: size.controlMd, padding: `${space[50]} ${space[150]}`, borderRadius: radius.control, whiteSpace: "nowrap", cursor: "pointer",
        background: on ? color.surfaceSelected : "transparent", color: on ? color.inkPrimary : color.inkSecondary, fontWeight: on ? type.heading.fontWeight : undefined, ...ringStyle,
      }}
    >
      <Icon name={icon} size="sm" color={on ? color.accentPrimary : color.inkTertiary} />
      {label}
    </div>
  );
}

function usePrefs() {
  const { state, dispatch } = useApp();
  return [state.prefs, (patch: Partial<Prefs>) => dispatch({ type: "prefs", patch })] as const;
}

function General({ stacked }: { stacked: boolean }) {
  const t = useT();
  const [p, set] = usePrefs();
  return (
    <>
      <Group>
        <Row label={t("prefs.uiLanguage")} column={stacked}>
          <Segmented label={t("prefs.uiLanguage")} items={[["system", t("prefs.languageSystem")], ["ko", t("uiLanguage.ko")]]} value={p.locale} onChange={(locale) => set({ locale })} full={stacked} />
        </Row>
        <Row label={t("prefs.theme")} column={stacked} divided>
          <Segmented label={t("prefs.theme")} items={[["system", t("theme.system")], ["light", t("theme.light")], ["dark", t("theme.dark")]]} value={p.theme} onChange={(theme) => set({ theme })} full={stacked} />
        </Row>
      </Group>
      <Group>
        <Row label={t("prefs.confirmDelete")} hint={t("prefs.trashHint")}>
          <Switch label={t("prefs.confirmDelete")} on={p.confirmDelete} onToggle={() => set({ confirmDelete: !p.confirmDelete })} />
        </Row>
      </Group>
    </>
  );
}

function EditorPrefs({ stacked }: { stacked: boolean }) {
  const t = useT();
  const [p, set] = usePrefs();
  return (
    <Group>
      <Row label={t("prefs.editor.textSize")} column={stacked}>
        <Segmented label={t("prefs.editor.textSize")} items={[["small", t("prefs.editor.small")], ["normal", t("prefs.editor.normal")], ["large", t("prefs.editor.large")]]} value={p.textSize} onChange={(textSize) => set({ textSize })} full={stacked} />
      </Row>
    </Group>
  );
}

/** Until the core's automatic backups exist: the whole library as one JSON file, and back. */
function Backup() {
  const t = useT();
  const { state, dispatch, locale } = useApp();
  const input = useRef<HTMLInputElement>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const download = () => {
    const stamp = new Date().toISOString().slice(0, 10);
    const url = URL.createObjectURL(new Blob([exportState(state)], { type: "application/json" }));
    const a = Object.assign(document.createElement("a"), { href: url, download: `ithaca-backup-${stamp}.json` });
    a.click();
    URL.revokeObjectURL(url);
    dispatch({ type: "prefs", patch: { lastBackup: Date.now() } });
    setMsg(t("backup.done"));
  };
  const restore = async (file: File) => {
    const next = parseState(await file.text());
    if (!next) return setMsg(t("backup.invalid"));
    // Restore never overwrites (PRODUCT.md): the backup's projects are added as copies.
    const stamp = new Date(next.projects.reduce((m, p) => Math.max(m, p.created), 0) || Date.now()).toLocaleDateString(locale);
    dispatch({ type: "importCopies", state: next, suffix: t("backup.copySuffix", { date: stamp }) });
    setMsg(t("backup.importedCopies", { count: next.projects.filter((p) => !p.deleted).length }));
  };
  return (
    <>
      <div style={{ display: "flex", gap: space[150], padding: space[200], borderRadius: radius.panel, background: color.surfaceList, border: hairline(color.lineSubtle), color: color.inkSecondary }}>
        <Icon name="info" color={color.stateInfo} />
        <span style={{ flex: 1, minWidth: 0 }}>{t("backup.webHint")}</span>
      </div>
      <Group>
        <Row label={t("backup.download")} hint={t("backup.downloadHint", { count: state.sheets.filter((s) => !s.trashed).length, date: new Date().toLocaleDateString(locale) })}>
          <Button icon="save" onClick={download}>{t("backup.now")}</Button>
        </Row>
        <Row label={t("backup.fromFile")} hint={t("backup.fromFileHint")} divided>
          <Button icon="restore" onClick={() => input.current?.click()}>{t("backup.restore")}</Button>
          <input ref={input} type="file" accept="application/json,.json" hidden onChange={(e) => {
            const file = e.target.files?.[0];
            // Reset so picking the same file again (after cancelling) still fires.
            e.target.value = "";
            if (file) restore(file);
          }} />
        </Row>
      </Group>
      {msg && <div style={{ ...type.caption, color: color.inkSecondary }}>{msg}</div>}
    </>
  );
}

function About() {
  const t = useT();
  return (
    <>
      <div>
        <div style={type.title}>{t("app.name")}</div>
        <div style={{ ...type.caption, color: color.inkTertiary }}>{t("about.webBuild")}</div>
      </div>
      <Group>
        <Row label={t("about.license")}>
          <span style={{ color: color.inkSecondary }}>MIT OR Apache-2.0</span>
        </Row>
      </Group>
      <Label>{t("about.localFirst")}</Label>
    </>
  );
}

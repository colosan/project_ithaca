// preferences prototype — General · Editor · Sync · Backup · Shortcuts · Claude (MCP) · About.
// Desktop-only items (MCP, update check, data folder) key off the platform, not the width (ADR-0001).
// Interactive: sections, switches and segmented controls are local state; "pair a device", history and close navigate.
import { useState, type ReactNode } from "react";
import {
  color, pane, radius, safePadding, size, space, type,
  Button, Checkbox, Icon, IconButton, Segmented, Switch, TextField,
  isDesktop, useFrame, useNavigate, useT, type IconName, type Platform, type StringKey,
} from "@ithaca/kit";

export const states = ["general", "editor", "sync", "backup", "shortcuts", "claude", "about"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const SECTION_KEY: Record<State, StringKey> = {
  general: "prefs.general", editor: "prefs.editor", sync: "prefs.sync", backup: "prefs.backup",
  shortcuts: "prefs.shortcuts", claude: "prefs.claude", about: "prefs.about",
};
const SECTION_ICON: Record<State, IconName> = {
  general: "settings", editor: "editorText", sync: "sync", backup: "backup", shortcuts: "keyboard", claude: "claude", about: "info",
};
/** Sidebar groups: writing, data, connections, the app itself. */
const SECTION_GROUPS: readonly (readonly State[])[] = [["general", "editor"], ["sync", "backup"], ["shortcuts", "claude"], ["about"]];
const PLATFORM_KEY: Record<Platform, StringKey> = { ios: "platform.ios", ipados: "platform.ipados", android: "platform.android", macos: "platform.macos", windows: "platform.windows" };
const PLATFORM_ICON: Record<Platform, IconName> = { ios: "devicePhone", android: "devicePhone", ipados: "deviceTablet", macos: "deviceLaptop", windows: "deviceDesktop" };
const isApple = (p: Platform) => p === "ios" || p === "ipados" || p === "macos";

/** compact: one section per page with a back bar. medium+: section list on the left, content on the right. */
export default function Preferences({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, safeArea } = useFrame();
  const [section, setSection] = useState<State>(state);
  const [compactList, setCompactList] = useState(false); // compact: showing the section list instead of a section
  const content = <Section id={section} />;
  const root = { display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) };
  const sectionRow = (s: State, onClick: () => void, chevron?: boolean) => {
    const on = s === section && !compactList;
    return (
      <div
        key={s}
        onClick={onClick}
        style={{
          minHeight: size.controlMd, display: "flex", alignItems: "center", gap: space[100], padding: `${space[50]} ${space[100]}`, borderRadius: radius.control,
          background: on ? color.surfaceSelected : "transparent", color: on ? color.inkPrimary : color.inkSecondary, fontWeight: on ? type.heading.fontWeight : undefined, cursor: "pointer",
        }}
      >
        <Icon name={SECTION_ICON[s]} size="sm" color={on ? color.accentPrimary : color.inkTertiary} />
        <span style={{ flex: 1 }}>{t(SECTION_KEY[s])}</span>
        {chevron && <Icon name="forward" size="sm" color={color.inkTertiary} />}
      </div>
    );
  };
  const groupGap = (i: number) => (i ? { borderTop: hairline(color.lineSubtle), marginTop: space[100], paddingTop: space[100] } : undefined);

  if (sizeClass === "compact") {
    return (
      <div style={{ ...root, flexDirection: "column" }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "grid", gridTemplateColumns: "1fr auto 1fr", alignItems: "center", padding: `0 ${space[100]}`, borderBottom: hairline(color.lineSubtle) }}>
          <span style={{ justifySelf: "start" }}>
            {compactList ? (
              <IconButton icon="close" label={t("action.close")} onClick={() => go("app-shell")} />
            ) : (
              <Button variant="ghost" icon="back" onClick={() => setCompactList(true)}>{t("prefs.title")}</Button>
            )}
          </span>
          <span style={{ ...type.heading, textAlign: "center" }}>{compactList ? t("prefs.title") : t(SECTION_KEY[section])}</span>
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>
          {compactList
            ? SECTION_GROUPS.map((g, i) => (
                <div key={i} style={groupGap(i)}>{g.map((s) => sectionRow(s, () => { setSection(s); setCompactList(false); }, true))}</div>
              ))
            : content}
        </div>
      </div>
    );
  }
  return (
    <div style={root}>
      <nav style={{ width: pane.library, flex: "none", display: "flex", flexDirection: "column", gap: space[25], overflow: "auto", background: color.surfaceSidebar, borderRight: hairline(color.lineSubtle), padding: `${space[300]} ${space[150]}` }}>
        <div style={{ ...type.title, padding: `0 ${space[100]}`, marginBottom: space[200] }}>{t("prefs.title")}</div>
        {SECTION_GROUPS.map((g, i) => (
          <div key={i} style={groupGap(i)}>{g.map((s) => sectionRow(s, () => setSection(s)))}</div>
        ))}
      </nav>
      <div style={{ flex: 1, minWidth: 0, overflow: "auto", padding: `${space[300]} ${space[400]}` }}>
        <div style={{ display: "flex", alignItems: "center", marginBottom: space[300] }}>
          <span style={{ ...type.title, flex: 1 }}>{t(SECTION_KEY[section])}</span>
          <IconButton icon="close" label={t("action.close")} onClick={() => go("app-shell")} />
        </div>
        <div style={{ maxWidth: pane.dialog }}>{content}</div>
      </div>
    </div>
  );
}

function Section({ id }: { id: State }) {
  if (id === "general") return <General />;
  if (id === "editor") return <Editor />;
  if (id === "sync") return <Sync />;
  if (id === "backup") return <Backup />;
  if (id === "shortcuts") return <Shortcuts />;
  if (id === "claude") return <Claude />;
  return <About />;
}

/** A segmented control leaves no room for its label on narrow widths or very large text — stack them there. */
function useStacked() {
  const { sizeClass, textScale } = useFrame();
  return sizeClass === "compact" || sizeClass === "medium" || textScale >= 1.5;
}

// ── General ─────────────────────────────────────────────────────────────

function General() {
  const t = useT();
  const { locale, theme } = useFrame();
  const stacked = useStacked();
  const [lang, setLang] = useState(locale === "ko" ? 1 : 2);
  const [look, setLook] = useState(theme === "light" ? 1 : 2);
  const [launch, setLaunch] = useState<"last" | "library">("last");
  const [trashDays, setTrashDays] = useState<"30" | "never">("30");
  const [confirmDelete, setConfirmDelete] = useState(true);
  return (
    <Stack>
      <Group>
        <Row label={t("prefs.uiLanguage")} column={stacked}>
          <Segmented items={[[0, t("prefs.languageSystem")], [1, t("uiLanguage.ko")], [2, t("uiLanguage.en")]]} value={lang} onChange={setLang} full={stacked} />
        </Row>
        <Row label={t("prefs.theme")} column={stacked} divided>
          <Segmented items={[[0, t("theme.system")], [1, t("theme.light")], [2, t("theme.dark")]]} value={look} onChange={setLook} full={stacked} />
        </Row>
      </Group>
      <Group>
        <Row label={t("prefs.launch")} hint={t("prefs.launchHint")} column={stacked}>
          <Segmented items={[["last", t("prefs.launch.last")], ["library", t("prefs.launch.library")]]} value={launch} onChange={setLaunch} full={stacked} />
        </Row>
        <Row label={t("prefs.trash")} hint={t("prefs.trashHint")} column={stacked} divided>
          <Segmented items={[["30", t("prefs.trash.days30")], ["never", t("prefs.trash.never")]]} value={trashDays} onChange={setTrashDays} full={stacked} />
        </Row>
        <Row label={t("prefs.confirmDelete")} divided>
          <Switch on={confirmDelete} onToggle={() => setConfirmDelete((v) => !v)} />
        </Row>
      </Group>
    </Stack>
  );
}

// ── Editor ──────────────────────────────────────────────────────────────

type TextSize = "small" | "normal" | "large";
type Markup = "show" | "dim" | "hide";
const TEXT_STYLE = { small: type.editorSmall, normal: type.editorBody, large: type.editorLarge } as const;

function Editor() {
  const t = useT();
  const stacked = useStacked();
  const [textSize, setTextSize] = useState<TextSize>("normal");
  const [markup, setMarkup] = useState<Markup>("dim");
  const [indent, setIndent] = useState(false);
  const [paragraphGap, setParagraphGap] = useState(true);
  const [focusScope, setFocusScope] = useState<"sentence" | "paragraph">("paragraph");
  const [typewriter, setTypewriter] = useState(false);
  const [spell, setSpell] = useState(true);
  const [smartQuotes, setSmartQuotes] = useState(true);
  const [pairs, setPairs] = useState(true);
  return (
    <Stack>
      <EditorPreview textSize={textSize} markup={markup} indent={indent} paragraphGap={paragraphGap} />
      <Group>
        <Row label={t("prefs.editor.textSize")} column={stacked}>
          <Segmented items={[["small", t("prefs.editor.small")], ["normal", t("prefs.editor.normal")], ["large", t("prefs.editor.large")]]} value={textSize} onChange={setTextSize} full={stacked} />
        </Row>
        <Row label={t("prefs.editor.markup")} hint={t("prefs.editor.markupHint")} column={stacked} divided>
          <Segmented items={[["show", t("prefs.editor.markup.show")], ["dim", t("prefs.editor.markup.dim")], ["hide", t("prefs.editor.markup.hide")]]} value={markup} onChange={setMarkup} full={stacked} />
        </Row>
        <Row label={t("prefs.editor.indent")} divided>
          <Switch on={indent} onToggle={() => setIndent((v) => !v)} />
        </Row>
        <Row label={t("prefs.editor.paragraphGap")} divided>
          <Switch on={paragraphGap} onToggle={() => setParagraphGap((v) => !v)} />
        </Row>
      </Group>
      <Group>
        <Row label={t("prefs.editor.focusScope")} hint={t("prefs.editor.focusScopeHint")} column={stacked}>
          <Segmented items={[["sentence", t("prefs.editor.focus.sentence")], ["paragraph", t("prefs.editor.focus.paragraph")]]} value={focusScope} onChange={setFocusScope} full={stacked} />
        </Row>
        <Row label={t("prefs.editor.typewriter")} hint={t("prefs.editor.typewriterHint")} divided>
          <Switch on={typewriter} onToggle={() => setTypewriter((v) => !v)} />
        </Row>
      </Group>
      <Group>
        <Row label={t("prefs.editor.spell")} hint={t("prefs.editor.spellHint")}>
          <Switch on={spell} onToggle={() => setSpell((v) => !v)} />
        </Row>
        <Row label={t("prefs.editor.smartQuotes")} divided>
          <Switch on={smartQuotes} onToggle={() => setSmartQuotes((v) => !v)} />
        </Row>
        <Row label={t("prefs.editor.pairs")} divided>
          <Switch on={pairs} onToggle={() => setPairs((v) => !v)} />
        </Row>
      </Group>
    </Stack>
  );
}

/** Live preview of the open sheet's first lines with the chosen settings — the same rendering as the editor. */
function EditorPreview({ textSize, markup, indent, paragraphGap }: { textSize: TextSize; markup: Markup; indent: boolean; paragraphGap: boolean }) {
  const t = useT();
  const { sample } = useFrame();
  const [heading, ...rest] = sample.openSheet.paragraphs;
  const body = TEXT_STYLE[textSize];
  const mark = (s: string) => (markup === "hide" ? null : <span style={{ color: markup === "dim" ? color.inkMarkup : color.inkPrimary }}>{s}</span>);
  return (
    <div>
      <GroupLabel>{t("prefs.editor.preview")}</GroupLabel>
      <div style={{ borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceCanvas, padding: `${space[200]} ${space[300]}`, overflow: "auto" }}>
        <div style={{ ...type.editorHeading, marginBottom: space[150] }}>
          {mark("# ")}
          {heading.replace(/^# /, "")}
        </div>
        {rest.slice(0, 2).map((p, i) => (
          <p key={i} style={{ ...body, margin: `0 0 ${paragraphGap ? space[200] : space[0]}`, textIndent: indent ? space[300] : undefined }}>{p}</p>
        ))}
      </div>
    </div>
  );
}

// ── Sync ────────────────────────────────────────────────────────────────

function Sync() {
  const t = useT();
  const go = useNavigate();
  const { sample, platform } = useFrame();
  const [relay, setRelay] = useState(true);
  const [icloud, setIcloud] = useState(sample.sync.icloud);
  const [p2p, setP2p] = useState(sample.sync.p2p);
  const [syncing, setSyncing] = useState(false);
  const ago = useAgo();
  return (
    <Stack>
      <Group>
        <div style={{ display: "flex", alignItems: "center", gap: space[150], padding: space[200], flexWrap: "wrap" }}>
          <Icon name="synced" color={color.stateSuccess} />
          <div style={{ flex: "1 1 auto", minWidth: 0 }}>
            <div>{syncing ? t("sync.inProgress") : t("sync.upToDate")}</div>
            <div style={{ ...type.caption, color: color.inkTertiary }}>{ago(0)}</div>
          </div>
          <Button icon="sync" disabled={syncing} onClick={() => setSyncing(true)}>{t("sync.now")}</Button>
        </div>
      </Group>
      <Group>
        <Row label={t("sync.relay")} hint={t("sync.relayHint")}>
          <Switch on={relay} onToggle={() => setRelay((v) => !v)} />
        </Row>
        {relay && (
          <div style={{ padding: `0 ${space[200]} ${space[200]}` }}>
            <TextField value={sample.sync.relay} onChange={() => {}} />
          </div>
        )}
        {isApple(platform) && (
          <Row label={t("sync.icloud")} hint={t("sync.icloudHint")} divided>
            <Switch on={icloud} onToggle={() => setIcloud((v) => !v)} />
          </Row>
        )}
        <Row label={t("sync.p2p")} hint={t("sync.p2pHint")} divided>
          <Switch on={p2p} onToggle={() => setP2p((v) => !v)} />
        </Row>
      </Group>

      <div>
        <GroupLabel>{t("sync.devices")}</GroupLabel>
        <Group>
          {sample.devices.map((d, i) => (
            <div key={d.name} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[100]} ${space[200]}`, borderTop: i ? hairline(color.lineSubtle) : undefined }}>
              <Tile icon={PLATFORM_ICON[d.platform]} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div>{d.name}</div>
                <div style={{ ...type.caption, color: color.inkTertiary }}>
                  {t(PLATFORM_KEY[d.platform])}
                  {" · "}
                  <span style={{ color: d.minutesAgo === 0 ? color.stateSuccess : undefined }}>{ago(d.minutesAgo)}</span>
                </div>
              </div>
            </div>
          ))}
          <ActionRow icon="add" onClick={() => go("pair-device#show-code")}>{t("sync.pair")}</ActionRow>
        </Group>
      </div>
    </Stack>
  );
}

function useAgo() {
  const t = useT();
  return (m: number) =>
    m === 0 ? t("sync.justNow") : m < 60 ? t("sync.minutesAgo", { minutes: m }) : m < 1440 ? t("sync.hoursAgo", { hours: Math.round(m / 60) }) : t("sync.daysAgo", { count: Math.round(m / 1440) });
}

// ── Backup ──────────────────────────────────────────────────────────────

function Backup() {
  const t = useT();
  const { sample, platform, locale } = useFrame();
  const stacked = useStacked();
  const [auto, setAuto] = useState(sample.backup.auto);
  const [every, setEvery] = useState<"hour" | "day" | "week">("day");
  const [keep, setKeep] = useState<"10" | "30" | "all">("30");
  const [backedUp, setBackedUp] = useState(false);
  const [restored, setRestored] = useState<string | null>(null);
  const when = new Intl.DateTimeFormat(locale, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  return (
    <Stack>
      <Group>
        <Row label={t("backup.auto")} hint={t("backup.autoHint")}>
          <Switch on={auto} onToggle={() => setAuto((v) => !v)} />
        </Row>
        {auto && (
          <>
            <Row label={t("backup.every")} column={stacked} divided>
              <Segmented items={[["hour", t("backup.every.hour")], ["day", t("backup.every.day")], ["week", t("backup.every.week")]]} value={every} onChange={setEvery} full={stacked} />
            </Row>
            <Row label={t("backup.keep")} column={stacked} divided>
              <Segmented items={[["10", t("backup.keep.n", { count: 10 })], ["30", t("backup.keep.n", { count: 30 })], ["all", t("backup.keep.all")]]} value={keep} onChange={setKeep} full={stacked} />
            </Row>
          </>
        )}
      </Group>
      <Group>
        <div style={{ display: "flex", flexDirection: "column", gap: space[100], padding: space[200] }}>
          <div style={type.body}>{t("backup.location")}</div>
          <div style={{ display: "flex", gap: space[100], flexWrap: stacked ? "wrap" : undefined }}>
            <TextField value={sample.backup.path} mono />
            {isDesktop(platform) && <Button icon="folderOpen">{t("backup.change")}</Button>}
          </div>
          {!isDesktop(platform) && <div style={{ ...type.caption, color: color.inkTertiary }}>{t("backup.locationMobileHint")}</div>}
        </div>
      </Group>
      <div>
        <div style={{ display: "flex", alignItems: "center", gap: space[100], marginBottom: space[100], flexWrap: "wrap" }}>
          <span style={{ flex: 1 }}><GroupLabel flush>{t("backup.recent")}</GroupLabel></span>
          <Button variant="ghost" icon={backedUp ? "check" : "backup"} onClick={() => setBackedUp(true)}>{backedUp ? t("backup.done") : t("backup.now")}</Button>
        </div>
        <Group>
          {sample.backup.records.map((b, i) => (
            <div key={b.at} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[100]} ${space[200]}`, borderTop: i ? hairline(color.lineSubtle) : undefined, flexWrap: "wrap" }}>
              <Tile icon="backup" />
              <div style={{ flex: "1 1 auto", minWidth: 0 }}>
                <div>{when.format(new Date(b.at))}</div>
                <div style={{ ...type.caption, color: color.inkTertiary }}>{t("backup.meta", { size: b.size, count: b.sheets })}</div>
              </div>
              {restored === b.at ? (
                <span style={{ display: "inline-flex", alignItems: "center", gap: space[50], ...type.label, color: color.stateSuccess }}>
                  <Icon name="success" size="sm" />
                  {t("backup.restored")}
                </span>
              ) : (
                <Button variant="ghost" icon="restore" onClick={() => setRestored(b.at)}>{t("backup.restore")}</Button>
              )}
            </div>
          ))}
        </Group>
        <Note>{t("backup.restoreHint")}</Note>
      </div>
    </Stack>
  );
}

// ── Shortcuts ───────────────────────────────────────────────────────────

/** `mod` is ⌘ on Apple and Ctrl elsewhere. Letters are key caps, not copy. */
type Key = "mod" | "shift" | "alt" | string;
const SHORTCUTS: readonly { group: StringKey; items: readonly { label: StringKey; keys: readonly Key[] }[] }[] = [
  {
    group: "shortcuts.group.general",
    items: [
      { label: "palette.title", keys: ["mod", "K"] },
      { label: "sheet.new", keys: ["mod", "N"] },
      { label: "library.newProject", keys: ["mod", "shift", "N"] },
      { label: "search.title", keys: ["mod", "shift", "F"] },
      { label: "prefs.title", keys: ["mod", ","] },
    ],
  },
  {
    group: "shortcuts.group.view",
    items: [
      { label: "shortcuts.showLibrary", keys: ["mod", "1"] },
      { label: "shortcuts.showList", keys: ["mod", "2"] },
      { label: "shortcuts.editorOnly", keys: ["mod", "3"] },
      { label: "inspector.title", keys: ["mod", "alt", "I"] },
      { label: "focus.title", keys: ["mod", "shift", "D"] },
    ],
  },
  {
    group: "shortcuts.group.format",
    items: [
      { label: "shortcuts.bold", keys: ["mod", "B"] },
      { label: "shortcuts.italic", keys: ["mod", "I"] },
      { label: "shortcuts.heading", keys: ["mod", "alt", "1"] },
    ],
  },
  {
    group: "shortcuts.group.sheet",
    items: [
      { label: "nav.history", keys: ["mod", "shift", "H"] },
      { label: "export.title", keys: ["mod", "shift", "E"] },
    ],
  },
];

function Shortcuts() {
  const t = useT();
  const { platform } = useFrame();
  return (
    <Stack>
      {!isDesktop(platform) && <Note boxed>{t("shortcuts.keyboardHint")}</Note>}
      {SHORTCUTS.map((g) => (
        <div key={g.group}>
          <GroupLabel>{t(g.group)}</GroupLabel>
          <Group>
            {g.items.map((s, i) => (
              <div key={s.label} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[100]} ${space[200]}`, borderTop: i ? hairline(color.lineSubtle) : undefined, flexWrap: "wrap" }}>
                <span style={{ flex: "1 1 auto", minWidth: 0 }}>{t(s.label)}</span>
                <KeyCombo keys={s.keys} />
              </div>
            ))}
          </Group>
        </div>
      ))}
      <Note>{t("shortcuts.customizeLater")}</Note>
    </Stack>
  );
}

/** Apple shows modifier glyphs (as icons, never text glyphs); Windows and Android spell them out. */
function KeyCombo({ keys }: { keys: readonly Key[] }) {
  const { platform } = useFrame();
  const apple = isApple(platform);
  const APPLE: Record<string, IconName> = { mod: "command", shift: "keyShift", alt: "keyOption" };
  const OTHER: Record<string, string> = { mod: "Ctrl", shift: "Shift", alt: "Alt" };
  return (
    <span style={{ display: "inline-flex", gap: space[50], flex: "none" }}>
      {keys.map((k, i) => (
        <span
          key={i}
          style={{
            display: "inline-grid", placeItems: "center", minWidth: size.controlSm, minHeight: size.controlSm, padding: `0 ${space[100]}`, boxSizing: "border-box",
            borderRadius: radius.piece, border: hairline(color.lineStrong), background: color.surfaceList, ...type.label, color: color.inkSecondary,
          }}
        >
          {apple && APPLE[k] ? <Icon name={APPLE[k]} size="sm" /> : OTHER[k] ?? k}
        </span>
      ))}
    </span>
  );
}

// ── Claude (MCP) ────────────────────────────────────────────────────────

function Claude() {
  const t = useT();
  const go = useNavigate();
  const { sample, platform } = useFrame();
  const stacked = useStacked();
  const [enabled, setEnabled] = useState(sample.mcp.enabled);
  const [permission, setPermission] = useState(sample.mcp.permission);
  const [askFirst, setAskFirst] = useState(true);
  const [exposed, setExposed] = useState<string[]>(sample.mcp.exposed);
  const claudeEdits = sample.history.records.filter((r) => r.actor === "claude").length;
  if (!isDesktop(platform)) return <Note boxed>{t("mcp.desktopOnly")}</Note>;
  const config = JSON.stringify({ mcpServers: { ithaca: { url: sample.mcp.address, headers: { Authorization: `Bearer ${sample.mcp.token}` } } } }, null, 2);
  return (
    <Stack>
      <Group>
        <Row label={t("mcp.toggle")} hint={t("mcp.hint")}>
          <Switch on={enabled} onToggle={() => setEnabled((v) => !v)} />
        </Row>
      </Group>
      {enabled && (
        <>
          <Group>
            <Row label={t("mcp.permission")} hint={permission === "read" ? t("mcp.permission.readHint") : t("mcp.permission.writeHint")} column={stacked}>
              <Segmented items={[["read", t("mcp.permission.read")], ["write", t("mcp.permission.write")]]} value={permission} onChange={setPermission} full={stacked} />
            </Row>
            {permission === "write" && (
              <Row label={t("mcp.askFirst")} hint={t("mcp.askFirstHint")} divided>
                <Switch on={askFirst} onToggle={() => setAskFirst((v) => !v)} />
              </Row>
            )}
          </Group>
          <div>
            <GroupLabel>{t("mcp.projects")}</GroupLabel>
            <Group>
              {sample.projects.map((p, i) => {
                const on = exposed.includes(p.id);
                return (
                  <div
                    key={p.id}
                    onClick={() => setExposed((xs) => (on ? xs.filter((x) => x !== p.id) : [...xs, p.id]))}
                    style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[100]} ${space[200]}`, borderTop: i ? hairline(color.lineSubtle) : undefined, cursor: "pointer" }}
                  >
                    <Checkbox on={on} />
                    <span style={{ flex: 1, minWidth: 0 }}>{p.title}</span>
                  </div>
                );
              })}
            </Group>
          </div>
          <Group>
            <Copyable label={t("mcp.address")} value={sample.mcp.address} />
            <Copyable label={t("mcp.token")} value={sample.mcp.token} divided extra={<Button variant="ghost" icon="sync">{t("mcp.rotate")}</Button>} />
          </Group>
          <div>
            <GroupLabel>{t("mcp.connect")}</GroupLabel>
            <Group>
              <pre style={{ margin: 0, padding: space[200], ...type.caption, color: color.inkSecondary, whiteSpace: "pre-wrap", wordBreak: "break-all", overflow: "auto" }}>{config}</pre>
              <ActionRow icon="copy">{t("mcp.copyConfig")}</ActionRow>
            </Group>
            <Note>{t("mcp.connectHint")}</Note>
          </div>
          <Group>
            <ActionRow first icon="history" onClick={() => go("history#claude")}>{t("mcp.recentEdits", { count: claudeEdits })}</ActionRow>
          </Group>
        </>
      )}
    </Stack>
  );
}

function Copyable({ label, value, divided, extra }: { label: string; value: string; divided?: boolean; extra?: ReactNode }) {
  const t = useT();
  const stacked = useStacked();
  const [copied, setCopied] = useState(false);
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[100], padding: space[200], borderTop: divided ? hairline(color.lineSubtle) : undefined }}>
      <div style={type.label}>{label}</div>
      <div style={{ display: "flex", gap: space[100], flexWrap: stacked ? "wrap" : undefined }}>
        <TextField value={value} mono />
        <Button icon={copied ? "check" : "copy"} onClick={() => setCopied(true)}>{t("mcp.copy")}</Button>
        {extra}
      </div>
    </div>
  );
}

// ── About ───────────────────────────────────────────────────────────────

function About() {
  const t = useT();
  const { sample, platform } = useFrame();
  const [checked, setChecked] = useState(false);
  const { app } = sample;
  return (
    <Stack>
      <div style={{ display: "flex", alignItems: "center", gap: space[200], flexWrap: "wrap" }}>
        <span style={{ flex: "none", display: "grid", placeItems: "center", minWidth: size.touchMin, minHeight: size.touchMin, borderRadius: radius.panel, background: color.accentSoft, color: color.accentPrimary }}>
          <Icon name="sheet" size="lg" />
        </span>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={type.title}>{t("app.name")}</div>
          <div style={{ ...type.caption, color: color.inkTertiary }}>{t("about.version", { version: app.version, channel: app.channel, build: app.build })}</div>
        </div>
        {/* Store builds (iOS · Android) update through the store; only desktop downloads check themselves. */}
        {isDesktop(platform) && (
          <Button icon={checked ? "check" : "sync"} onClick={() => setChecked(true)}>{checked ? t("about.upToDate") : t("about.checkUpdate")}</Button>
        )}
      </div>
      <Group>
        <InfoRow icon="license" label={t("about.license")} value={app.license} />
        <ActionRow icon="code" trailing="open">{t("about.source")}</ActionRow>
        <ActionRow icon="bug" trailing="open">{t("about.report")}</ActionRow>
        <ActionRow icon="sheet" trailing="forward">{t("about.thirdParty")}</ActionRow>
      </Group>
      {isDesktop(platform) && (
        <Group>
          <InfoRow icon="folder" label={t("about.dataFolder")} value={app.dataPath} mono />
          <ActionRow icon="folderOpen">{t("about.openDataFolder")}</ActionRow>
        </Group>
      )}
      <Note>{t("about.localFirst")}</Note>
    </Stack>
  );
}

// ── Local layout (grouped settings, like iOS inset groups and macOS forms) ──

function Stack({ children }: { children: ReactNode }) {
  return <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>{children}</div>;
}

function Group({ children }: { children: ReactNode }) {
  return <div style={{ borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceRaised, overflow: "hidden" }}>{children}</div>;
}

function GroupLabel({ children, flush }: { children: ReactNode; flush?: boolean }) {
  return <div style={{ ...type.label, color: color.inkTertiary, padding: `0 ${space[50]}`, marginBottom: flush ? space[0] : space[100] }}>{children}</div>;
}

function Note({ children, boxed }: { children: ReactNode; boxed?: boolean }) {
  if (boxed) {
    return (
      <div style={{ display: "flex", gap: space[150], padding: space[200], borderRadius: radius.panel, background: color.surfaceList, border: hairline(color.lineSubtle), color: color.inkSecondary }}>
        <Icon name="info" color={color.stateInfo} />
        <span style={{ flex: 1, minWidth: 0 }}>{children}</span>
      </div>
    );
  }
  return <div style={{ ...type.caption, color: color.inkTertiary, padding: `0 ${space[50]}`, marginTop: space[100] }}>{children}</div>;
}

function Tile({ icon }: { icon: IconName }) {
  return (
    <span style={{ flex: "none", display: "grid", placeItems: "center", minWidth: size.controlMd, minHeight: size.controlMd, borderRadius: radius.control, background: color.surfaceList, color: color.inkSecondary }}>
      <Icon name={icon} />
    </span>
  );
}

function Row({ label, hint, column, divided, children }: { label: string; hint?: string; column?: boolean; divided?: boolean; children: ReactNode }) {
  return (
    <div style={{ display: "flex", flexDirection: column ? "column" : "row", alignItems: column ? "stretch" : "center", gap: space[150], padding: space[200], borderTop: divided ? hairline(color.lineSubtle) : undefined }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={type.body}>{label}</div>
        {hint && <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[25] }}>{hint}</div>}
      </div>
      {children}
    </div>
  );
}

/** A label and a read-only value, e.g. the license. */
function InfoRow({ icon, label, value, mono }: { icon: IconName; label: string; value: string; mono?: boolean }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[100]} ${space[200]}`, flexWrap: "wrap" }}>
      <Icon name={icon} size="sm" color={color.inkTertiary} />
      <span style={{ flex: "1 1 auto", minWidth: 0 }}>{label}</span>
      <span style={{ ...(mono ? type.caption : type.body), color: color.inkSecondary, minWidth: 0, overflowWrap: "anywhere" }}>{value}</span>
    </div>
  );
}

/** A full-width tappable row in accent color. Rows after the first in a group draw their own divider. */
function ActionRow({ icon, trailing, first, onClick, children }: { icon: IconName; trailing?: IconName; first?: boolean; onClick?: () => void; children: ReactNode }) {
  return (
    <div
      onClick={onClick ?? (() => {})}
      style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[100]} ${space[200]}`, borderTop: first ? undefined : hairline(color.lineSubtle), ...type.label, fontWeight: type.heading.fontWeight, color: color.accentPrimary, cursor: "pointer" }}
    >
      <Icon name={icon} size="sm" />
      <span style={{ flex: 1, minWidth: 0 }}>{children}</span>
      {trailing && <Icon name={trailing} size="sm" color={color.inkTertiary} />}
    </div>
  );
}

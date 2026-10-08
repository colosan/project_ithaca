// preferences prototype — General · Sync · Claude (MCP). MCP is desktop-only by platform, not by width (ADR-0001).
// Interactive: sections, switches and segmented controls are local state; "pair a device" and close navigate.
import { useState, type ReactNode } from "react";
import {
  color, pane, radius, safePadding, size, space, type,
  Button, Icon, IconButton, Segmented, Switch, TextField,
  isDesktop, useFrame, useNavigate, useT, type IconName, type Platform, type StringKey,
} from "@ithaca/kit";

export const states = ["general", "sync", "claude"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const SECTION_KEY: Record<State, StringKey> = { general: "prefs.general", sync: "prefs.sync", claude: "prefs.claude" };
const SECTION_ICON: Record<State, IconName> = { general: "settings", sync: "deviceLaptop", claude: "claude" };
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
  const content = section === "general" ? <General /> : section === "sync" ? <Sync /> : <Claude />;
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
          {compactList ? states.map((s) => sectionRow(s, () => { setSection(s); setCompactList(false); }, true)) : content}
        </div>
      </div>
    );
  }
  return (
    <div style={root}>
      <nav style={{ width: pane.library, flex: "none", display: "flex", flexDirection: "column", gap: space[25], background: color.surfaceSidebar, borderRight: hairline(color.lineSubtle), padding: `${space[300]} ${space[150]}` }}>
        <div style={{ ...type.title, padding: `0 ${space[100]}`, marginBottom: space[200] }}>{t("prefs.title")}</div>
        {states.map((s) => sectionRow(s, () => setSection(s)))}
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

function General() {
  const t = useT();
  const { locale, theme, sizeClass, textScale } = useFrame();
  const [lang, setLang] = useState(locale === "ko" ? 1 : 2);
  const [look, setLook] = useState(theme === "light" ? 1 : 2);
  // A three-way segmented control leaves no room for the label on a phone — stack them there.
  // Like iOS accessibility text sizes: very large text stacks label and control too.
  const stacked = sizeClass === "compact" || sizeClass === "medium" || textScale >= 1.5;
  return (
    <Group>
      <Row label={t("prefs.uiLanguage")} column={stacked}>
        <Segmented items={[[0, t("prefs.languageSystem")], [1, t("uiLanguage.ko")], [2, t("uiLanguage.en")]]} value={lang} onChange={setLang} full={stacked} />
      </Row>
      <Row label={t("prefs.theme")} column={stacked}>
        <Segmented items={[[0, t("theme.system")], [1, t("theme.light")], [2, t("theme.dark")]]} value={look} onChange={setLook} full={stacked} />
      </Row>
    </Group>
  );
}

function Sync() {
  const t = useT();
  const go = useNavigate();
  const { sample, platform } = useFrame();
  const [relay, setRelay] = useState(true);
  const [icloud, setIcloud] = useState(sample.sync.icloud);
  const [p2p, setP2p] = useState(sample.sync.p2p);
  const ago = (m: number) =>
    m === 0 ? t("sync.justNow") : m < 60 ? t("sync.minutesAgo", { minutes: m }) : m < 1440 ? t("sync.hoursAgo", { hours: Math.round(m / 60) }) : t("sync.daysAgo", { count: Math.round(m / 1440) });
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>
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
              <span style={{ flex: "none", display: "grid", placeItems: "center", minWidth: size.controlMd, minHeight: size.controlMd, borderRadius: radius.control, background: color.surfaceList, color: color.inkSecondary }}>
                <Icon name={PLATFORM_ICON[d.platform]} />
              </span>
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
          <div
            onClick={() => go("pair-device#show-code")}
            style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `${space[100]} ${space[200]}`, borderTop: hairline(color.lineSubtle), ...type.label, fontWeight: type.heading.fontWeight, color: color.accentPrimary, cursor: "pointer" }}
          >
            <span style={{ flex: "none", display: "grid", placeItems: "center", minWidth: size.controlMd, minHeight: size.controlMd, borderRadius: radius.control, background: color.accentSoft }}>
              <Icon name="add" />
            </span>
            {t("sync.pair")}
          </div>
        </Group>
      </div>
    </div>
  );
}

function Claude() {
  const t = useT();
  const { sample, platform } = useFrame();
  const [enabled, setEnabled] = useState(sample.mcp.enabled);
  if (!isDesktop(platform)) {
    return (
      <div style={{ display: "flex", gap: space[150], padding: space[200], borderRadius: radius.panel, background: color.surfaceList, border: hairline(color.lineSubtle), color: color.inkSecondary }}>
        <Icon name="info" color={color.stateInfo} />
        <span style={{ flex: 1, minWidth: 0 }}>{t("mcp.desktopOnly")}</span>
      </div>
    );
  }
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>
      <Group>
        <Row label={t("mcp.toggle")} hint={t("mcp.hint")}>
          <Switch on={enabled} onToggle={() => setEnabled((v) => !v)} />
        </Row>
      </Group>
      {enabled && (
        <Group>
          <Copyable label={t("mcp.address")} value={sample.mcp.address} />
          <Copyable label={t("mcp.token")} value={sample.mcp.token} divided />
        </Group>
      )}
    </div>
  );
}

function Copyable({ label, value, divided }: { label: string; value: string; divided?: boolean }) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: space[100], padding: space[200], borderTop: divided ? hairline(color.lineSubtle) : undefined }}>
      <div style={type.label}>{label}</div>
      <div style={{ display: "flex", gap: space[100] }}>
        <TextField value={value} mono />
        <Button icon={copied ? "check" : "copy"} onClick={() => setCopied(true)}>{t("mcp.copy")}</Button>
      </div>
    </div>
  );
}

// ── Local layout (grouped settings, like iOS inset groups and macOS forms) ──

function Group({ children }: { children: ReactNode }) {
  return <div style={{ borderRadius: radius.panel, border: hairline(color.lineSubtle), background: color.surfaceRaised, overflow: "hidden" }}>{children}</div>;
}

function GroupLabel({ children }: { children: ReactNode }) {
  return <div style={{ ...type.label, color: color.inkTertiary, padding: `0 ${space[50]}`, marginBottom: space[100] }}>{children}</div>;
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

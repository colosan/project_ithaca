// preferences prototype — General · Sync · Claude (MCP). MCP is desktop-only by platform, not by width (ADR-0001).
// Interactive: sections, toggles and segmented controls are local state; "pair a device" and close navigate.
import { useState, type ReactNode } from "react";
import { color, pane, radius, safePadding, size, space, type, isDesktop, useFrame, useNavigate, useT, type Platform, type StringKey } from "@ithaca/kit";

export const states = ["general", "sync", "claude"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;
const SECTION_KEY: Record<State, StringKey> = { general: "prefs.general", sync: "prefs.sync", claude: "prefs.claude" };
const isApple = (p: Platform) => p === "ios" || p === "ipados" || p === "macos";
const clickable = { cursor: "pointer" } as const;

/** compact: one section per page with a back bar. medium+: section list on the left, content on the right. */
export default function Preferences({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, safeArea } = useFrame();
  const [section, setSection] = useState<State>(state);
  const [compactList, setCompactList] = useState(false); // compact: showing the section list instead of a section
  const content = section === "general" ? <General /> : section === "sync" ? <Sync /> : <Claude />;
  const root = { display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) };
  const sectionRow = (s: State, onClick: () => void) => (
    <div key={s} onClick={onClick} style={{ minHeight: size.controlMd, display: "flex", alignItems: "center", padding: `0 ${space[100]}`, borderRadius: radius.piece, background: s === section && !compactList ? color.surfaceSelected : "transparent", color: s === section ? color.inkPrimary : color.inkSecondary, ...clickable }}>
      {t(SECTION_KEY[s])}
    </div>
  );

  if (sizeClass === "compact") {
    return (
      <div style={{ ...root, flexDirection: "column" }}>
        <header style={{ minHeight: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[150], padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
          {compactList ? (
            <span style={{ ...type.label, color: color.inkSecondary, ...clickable }} onClick={() => go("app-shell")}>✕</span>
          ) : (
            <span style={{ ...type.label, color: color.inkSecondary, ...clickable }} onClick={() => setCompactList(true)}>‹ {t("prefs.title")}</span>
          )}
          <span style={{ ...type.heading, flex: 1, textAlign: "center" }}>{compactList ? t("prefs.title") : t(SECTION_KEY[section])}</span>
          <span style={{ ...type.label, visibility: "hidden" }}>‹ {t("prefs.title")}</span>
        </header>
        <div style={{ flex: 1, overflow: "auto", padding: space[200] }}>
          {compactList ? states.map((s) => sectionRow(s, () => { setSection(s); setCompactList(false); })) : content}
        </div>
      </div>
    );
  }
  return (
    <div style={root}>
      <nav style={{ width: pane.library, flex: "none", background: color.surfaceSidebar, borderRight: hairline(color.lineSubtle), padding: space[200] }}>
        <div style={{ ...type.title, marginBottom: space[200] }}>{t("prefs.title")}</div>
        {states.map((s) => sectionRow(s, () => setSection(s)))}
      </nav>
      <div style={{ flex: 1, minWidth: 0, overflow: "auto", padding: `${space[300]} ${space[400]}` }}>
        <div style={{ display: "flex", alignItems: "center", marginBottom: space[300] }}>
          <span style={{ ...type.title, flex: 1 }}>{t(SECTION_KEY[section])}</span>
          <span style={{ ...type.label, color: color.inkSecondary, ...clickable }} title={t("action.close")} onClick={() => go("app-shell")}>✕</span>
        </div>
        <div style={{ maxWidth: pane.dialog }}>{content}</div>
      </div>
    </div>
  );
}

function General() {
  const t = useT();
  const { locale, theme, sizeClass, textScale } = useFrame();
  // A three-way segmented control leaves no room for the label on a phone — stack them there.
  // Like iOS accessibility text sizes: very large text stacks label and control too.
  const stacked = sizeClass === "compact" || textScale >= 1.5;
  return (
    <Stack>
      <Row label={t("prefs.uiLanguage")} column={stacked}>
        <Segmented options={[t("prefs.languageSystem"), t("uiLanguage.ko"), t("uiLanguage.en")]} active={locale === "ko" ? 1 : 2} />
      </Row>
      <Row label={t("prefs.theme")} column={stacked}>
        <Segmented options={[t("theme.system"), t("theme.light"), t("theme.dark")]} active={theme === "light" ? 1 : 2} />
      </Row>
    </Stack>
  );
}

function Sync() {
  const t = useT();
  const go = useNavigate();
  const { sample, platform } = useFrame();
  return (
    <Stack>
      <Row label={t("sync.relay")} hint={t("sync.relayHint")} column>
        <div style={{ display: "flex", gap: space[100], alignItems: "center" }}>
          <Field>{sample.sync.relay}</Field>
          <Toggle on />
        </div>
      </Row>
      {isApple(platform) && (
        <Row label={t("sync.icloud")} hint={t("sync.icloudHint")}>
          <Toggle on={sample.sync.icloud} />
        </Row>
      )}
      <Row label={t("sync.p2p")} hint={t("sync.p2pHint")}>
        <Toggle on={sample.sync.p2p} />
      </Row>
      <div>
        <div style={{ ...type.label, color: color.inkSecondary, marginBottom: space[100] }}>{t("sync.devices")}</div>
        <div style={{ border: hairline(color.lineSubtle), borderRadius: radius.panel, overflow: "hidden" }}>
          {sample.devices.map((d) => (
            <div key={d.name} style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlLg, padding: `0 ${space[150]}`, borderBottom: hairline(color.lineSubtle) }}>
              <span style={{ flex: 1 }}>{d.name}</span>
              <span style={{ ...type.caption, color: color.inkTertiary }}>{d.platform}</span>
              <span style={{ ...type.caption, color: d.minutesAgo === 0 ? color.stateSuccess : color.inkTertiary }}>
                {d.minutesAgo === 0 ? t("sync.justNow") : t("sync.minutesAgo", { minutes: d.minutesAgo })}
              </span>
            </div>
          ))}
          <div onClick={() => go("pair-device")} style={{ display: "flex", alignItems: "center", minHeight: size.controlLg, padding: `0 ${space[150]}`, ...type.label, color: color.accentPrimary, ...clickable }}>＋ {t("sync.pair")}</div>
        </div>
      </div>
    </Stack>
  );
}

function Claude() {
  const t = useT();
  const { sample, platform } = useFrame();
  if (!isDesktop(platform)) {
    return (
      <div style={{ padding: space[200], borderRadius: radius.panel, background: color.surfaceList, border: hairline(color.lineSubtle), color: color.inkSecondary }}>
        ⓘ {t("mcp.desktopOnly")}
      </div>
    );
  }
  return (
    <Stack>
      <Row label={t("mcp.toggle")} hint={t("mcp.hint")}>
        <Toggle on={sample.mcp.enabled} />
      </Row>
      <Row label={t("mcp.address")} column>
        <div style={{ display: "flex", gap: space[100] }}>
          <Field mono>{sample.mcp.address}</Field>
          <SmallButton>{t("mcp.copy")}</SmallButton>
        </div>
      </Row>
      <Row label={t("mcp.token")} column>
        <div style={{ display: "flex", gap: space[100] }}>
          <Field mono>{sample.mcp.token}</Field>
          <SmallButton>{t("mcp.copy")}</SmallButton>
        </div>
      </Row>
    </Stack>
  );
}

// ── Local building blocks (become native components later) ──────────────

function Stack({ children }: { children: ReactNode }) {
  return <div style={{ display: "flex", flexDirection: "column", gap: space[300] }}>{children}</div>;
}

function Row({ label, hint, column, children }: { label: string; hint?: string; column?: boolean; children: ReactNode }) {
  return (
    <div style={{ display: "flex", flexDirection: column ? "column" : "row", alignItems: column ? "stretch" : "center", gap: space[100] }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={type.body}>{label}</div>
        {hint && <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[25] }}>{hint}</div>}
      </div>
      {children}
    </div>
  );
}

function Toggle({ on: initial }: { on?: boolean }) {
  const [on, setOn] = useState(!!initial);
  return (
    <span onClick={() => setOn((v) => !v)} style={{ position: "relative", flex: "none", width: size.toggleWidth, height: size.toggleHeight, borderRadius: radius.full, background: on ? color.accentPrimary : color.lineStrong, ...clickable }}>
      <span style={{ position: "absolute", top: space[25], left: on ? undefined : space[25], right: on ? space[25] : undefined, width: size.toggleKnob, height: size.toggleKnob, borderRadius: radius.full, background: color.surfaceRaised }} />
    </span>
  );
}

function Field({ children, mono }: { children: ReactNode; mono?: boolean }) {
  return (
    <div style={{ flex: 1, minWidth: 0, display: "flex", alignItems: "center", minHeight: size.controlMd, padding: `0 ${space[150]}`, border: hairline(color.lineStrong), borderRadius: radius.piece, background: color.surfaceCanvas, overflow: "hidden", whiteSpace: "nowrap", textOverflow: "ellipsis", ...(mono ? type.caption : {}) }}>
      {children}
    </div>
  );
}

function SmallButton({ children }: { children: ReactNode }) {
  return (
    <span style={{ flex: "none", display: "flex", alignItems: "center", minHeight: size.controlMd, padding: `0 ${space[150]}`, border: hairline(color.lineStrong), borderRadius: radius.piece, ...type.label, color: color.inkSecondary }}>
      {children}
    </span>
  );
}

function Segmented({ options, active: initial }: { options: string[]; active: number }) {
  const [active, setActive] = useState(initial);
  return (
    <div style={{ display: "inline-flex", flex: "none", border: hairline(color.lineStrong), borderRadius: radius.piece, overflow: "hidden", ...type.label }}>
      {options.map((o, i) => (
        <span key={o + i} onClick={() => setActive(i)} style={{ cursor: "pointer", padding: `${space[100]} ${space[150]}`, background: i === active ? color.surfaceSelected : "transparent", color: i === active ? color.inkPrimary : color.inkSecondary, borderLeft: i ? hairline(color.lineStrong) : undefined }}>
          {o}
        </span>
      ))}
    </div>
  );
}

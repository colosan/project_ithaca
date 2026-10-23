// command-palette prototype — one box to jump to a sheet or run a command (⌘K / Ctrl+K).
// Interactive: typing filters sheets and commands; a click runs one; scrim or close returns to the app.
import { useState, type ReactNode } from "react";
import {
  color, pane, radius, safePadding, shadow, size, space, type,
  Icon, IconButton, TextField,
  openContext, useFrame, useNavigate, useT, type IconName, type StringKey,
} from "@ithaca/kit";

export const states = ["default", "query"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

/** Commands and where each one goes. The same list backs the app menu bar on desktop. */
const COMMANDS: readonly { label: StringKey; icon: IconName; to: string }[] = [
  { label: "sheet.new", icon: "add", to: "app-shell#default" },
  { label: "library.newProject", icon: "folder", to: "new-project#default" },
  { label: "search.title", icon: "search", to: "search#empty" },
  { label: "focus.title", icon: "focus", to: "app-shell#focus" },
  { label: "palette.sheetInfo", icon: "stats", to: "app-shell#info" },
  { label: "nav.history", icon: "history", to: "history#all" },
  { label: "export.title", icon: "export", to: "export#paste" },
  { label: "projectSettings.title", icon: "settings", to: "project-settings" },
  { label: "prefs.title", icon: "settings", to: "preferences#general" },
  { label: "prefs.backup", icon: "backup", to: "preferences#backup" },
  { label: "prefs.shortcuts", icon: "keyboard", to: "preferences#shortcuts" },
];

export default function CommandPalette({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sample, sizeClass, safeArea } = useFrame();
  const { project } = openContext(sample);
  const [query, setQuery] = useState(state === "query" ? sample.search.sampleQuery : "");
  const q = query.trim().toLowerCase();
  const match = (s: string) => !q || s.toLowerCase().includes(q);
  const sheets = project.folders
    .flatMap((f) => f.sheets.map((s) => ({ ...s, folder: f.name })))
    .filter((s) => match(s.title) || match(s.excerpt) || match(s.folder))
    .slice(0, q ? 6 : 3);
  const commands = COMMANDS.filter((c) => match(t(c.label)));
  const compact = sizeClass === "compact";
  const close = () => go("app-shell#default");

  const box = (
    <div
      style={{
        display: "flex", flexDirection: "column", background: color.surfaceRaised, overflow: "hidden",
        ...(compact
          ? { flex: 1, minHeight: 0 }
          : { width: pane.dialog, maxWidth: "100%", maxHeight: "70%", borderRadius: radius.sheet, border: hairline(color.lineSubtle), boxShadow: shadow.dialog }),
      }}
    >
      <div style={{ flex: "none", display: "flex", alignItems: "center", gap: space[100], padding: space[150], borderBottom: hairline(color.lineSubtle) }}>
        <TextField value={query} onChange={setQuery} placeholder={t("palette.placeholder")} icon="search" autoFocus />
        {compact && <IconButton icon="close" label={t("action.close")} onClick={close} />}
      </div>
      <div style={{ flex: 1, minHeight: 0, overflow: "auto", padding: space[100] }}>
        {sheets.length > 0 && <Heading>{q ? t("palette.sheets") : t("palette.recent")}</Heading>}
        {sheets.map((s) => (
          <Item key={s.id} icon="sheet" onClick={() => go(s.branched ? "branch-resolve" : "app-shell#default")}>
            <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{s.title}</span>
            <span style={{ ...type.caption, color: color.inkTertiary, flex: "none" }}>{s.folder}</span>
          </Item>
        ))}
        {commands.length > 0 && <Heading>{t("palette.commands")}</Heading>}
        {commands.map((c) => (
          <Item key={c.label} icon={c.icon} onClick={() => go(c.to)}>
            <span style={{ flex: 1, minWidth: 0 }}>{t(c.label)}</span>
          </Item>
        ))}
        {!sheets.length && !commands.length && (
          <div style={{ padding: space[300], textAlign: "center", color: color.inkTertiary, ...type.caption }}>{t("palette.none", { query })}</div>
        )}
      </div>
      {!compact && (
        <div style={{ flex: "none", display: "flex", gap: space[200], flexWrap: "wrap", padding: `${space[100]} ${space[200]}`, borderTop: hairline(color.lineSubtle), ...type.caption, color: color.inkTertiary }}>
          <span>{t("palette.hintOpen")}</span>
          <span>{t("palette.hintClose")}</span>
        </div>
      )}
    </div>
  );

  if (compact) {
    return <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceRaised, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>{box}</div>;
  }
  return (
    <div style={{ position: "relative", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
      <div onClick={close} style={{ position: "absolute", inset: 0, background: color.surfaceScrim, cursor: "pointer" }} />
      <div style={{ position: "relative", display: "flex", justifyContent: "center", alignItems: "flex-start", height: "100%", padding: `${space[800]} ${space[200]} ${space[200]}`, boxSizing: "border-box", pointerEvents: "none" }}>
        <div style={{ display: "flex", justifyContent: "center", width: "100%", maxHeight: "100%", pointerEvents: "auto" }}>{box}</div>
      </div>
    </div>
  );
}

function Heading({ children }: { children: string }) {
  return <div style={{ ...type.caption, color: color.inkTertiary, padding: `${space[100]} ${space[100]} ${space[50]}` }}>{children}</div>;
}

function Item({ icon, onClick, children }: { icon: IconName; onClick: () => void; children: ReactNode }) {
  const [hover, setHover] = useState(false);
  return (
    <div
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{ display: "flex", alignItems: "center", gap: space[150], minHeight: size.controlMd, padding: `${space[50]} ${space[100]}`, borderRadius: radius.control, background: hover ? color.surfaceSelected : "transparent", cursor: "pointer" }}
    >
      <Icon name={icon} size="sm" color={color.inkTertiary} />
      {children}
    </div>
  );
}

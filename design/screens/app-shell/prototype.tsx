// app-shell prototype. Rules: values from @ithaca/kit tokens only, copy via t() only (enforced by pnpm design:check).
import type { CSSProperties } from "react";
import {
  color, editor, opacity, pane, radius, size, space, type,
  useFrame, useT, type Sample, type SizeClass,
} from "@ithaca/kit";

export const states = ["default", "readonly"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

function panesFor(c: SizeClass) {
  return { library: c === "expanded" || c === "large", list: c !== "compact" };
}

export default function AppShell({ state }: { state: State }) {
  const { sizeClass } = useFrame();
  const panes = panesFor(sizeClass);
  return (
    <div style={{ display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body }}>
      {panes.library && <LibraryPane />}
      {panes.list && <SheetListPane />}
      <EditorPane readOnly={state === "readonly"} />
    </div>
  );
}

function LibraryPane() {
  const t = useT();
  const { sample } = useFrame();
  const sections: { key: "section.lore" | "section.episodes" | "section.ideas"; count: number; active?: boolean }[] = [
    { key: "section.lore", count: sample.lore.length },
    { key: "section.episodes", count: sample.episodes.length, active: true },
    { key: "section.ideas", count: sample.ideas.length },
  ];
  return (
    <aside style={{ width: pane.library, flex: "none", background: color.surfaceSidebar, borderRight: hairline(color.lineSubtle), padding: space[200] }}>
      <div style={{ ...type.label, color: color.inkTertiary, marginBottom: space[150] }}>{t("library.title")}</div>
      <div style={{ ...type.heading, marginBottom: space[100] }}>{sample.title}</div>
      {sections.map((s) => (
        <div
          key={s.key}
          style={{
            display: "flex", justifyContent: "space-between", alignItems: "center",
            height: size.controlMd, padding: `0 ${space[100]}`, borderRadius: radius.piece,
            background: s.active ? color.surfaceSelected : "transparent",
            color: s.active ? color.inkPrimary : color.inkSecondary,
          }}
        >
          <span>{t(s.key)}</span>
          <span style={{ ...type.caption, color: color.inkTertiary }}>{s.count}</span>
        </div>
      ))}
    </aside>
  );
}

const STATUS_STYLE: Record<Sample["episodes"][number]["status"], CSSProperties> = {
  draft: { color: color.inkTertiary, border: hairline(color.lineStrong) },
  ready: { color: color.accentPrimary, border: hairline(color.accentPrimary) },
  published: { color: color.stateSuccess, border: hairline(color.stateSuccess) },
};

function SheetListPane() {
  const t = useT();
  const { sample } = useFrame();
  return (
    <section style={{ width: pane.sheetList, flex: "none", background: color.surfaceList, borderRight: hairline(color.lineSubtle), overflow: "hidden" }}>
      <header style={{ height: size.barTop, display: "flex", alignItems: "center", justifyContent: "space-between", padding: `0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
        <span style={type.heading}>{t("section.episodes")}</span>
        <span style={{ ...type.caption, color: color.inkTertiary }}>{t("sheetList.count", { count: sample.episodes.length })}</span>
      </header>
      {sample.episodes.map((ep) => (
        <article
          key={ep.id}
          style={{
            minHeight: size.rowSheet, padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle),
            background: ep.id === sample.openEpisode.id ? color.surfaceSelected : "transparent",
          }}
        >
          <div style={{ display: "flex", alignItems: "center", gap: space[100] }}>
            <span style={{ ...type.caption, color: color.inkTertiary }}>{t("episode.number", { n: ep.number })}</span>
            <span style={{ ...type.caption, padding: `0 ${space[50]}`, borderRadius: radius.piece, ...STATUS_STYLE[ep.status] }}>
              {t(`episode.status.${ep.status}`)}
            </span>
          </div>
          <div style={{ ...type.body, fontWeight: type.heading.fontWeight, marginTop: space[25] }}>{ep.title}</div>
          <div style={{ ...type.caption, color: color.inkSecondary, marginTop: space[25], whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            {ep.excerpt}
          </div>
        </article>
      ))}
    </section>
  );
}

function EditorPane({ readOnly }: { readOnly: boolean }) {
  const t = useT();
  const { sizeClass, sample } = useFrame();
  const ep = sample.openEpisode;
  const meta = sample.episodes.find((e) => e.id === ep.id);
  const count =
    sample.language === "ko"
      ? t("editor.charCount", { count: ep.charCount ?? 0 })
      : t("editor.wordCount", { count: ep.wordCount ?? 0 });

  return (
    <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
      <header style={{ height: size.barTop, flex: "none", display: "flex", alignItems: "center", gap: space[150], padding: `0 ${space[200]}`, color: color.inkSecondary }}>
        {sizeClass === "compact" && <span style={type.label}>‹ {t("section.episodes")}</span>}
        {sizeClass === "medium" && <span style={type.label} title={t("library.show")}>☰</span>}
        <span style={{ ...type.label, color: color.inkTertiary }}>{meta ? t("episode.number", { n: meta.number }) : null}</span>
      </header>

      {readOnly && (
        <div style={{ display: "flex", alignItems: "center", gap: space[150], margin: `0 ${space[200]}`, padding: `${space[100]} ${space[150]}`, borderRadius: radius.panel, background: color.accentSoft, color: color.stateWarning, ...type.label }}>
          <span style={{ flex: 1 }}>⚠ {t("lease.banner", { device: "MacBook", minutes: 3 })}</span>
          <span style={{ padding: `${space[50]} ${space[150]}`, borderRadius: radius.piece, background: color.accentPrimary, color: color.inkOnAccent }}>
            {t("lease.takeOver")}
          </span>
        </div>
      )}

      <article style={{ flex: 1, overflow: "hidden", padding: `${space[300]} ${editor.paddingX[sizeClass]}`, opacity: readOnly ? opacity.readOnly : undefined }}>
        <div style={{ maxWidth: editor.measure, margin: "0 auto" }}>
          {ep.paragraphs.map((p, i) =>
            p.startsWith("# ") ? (
              <h1 key={i} style={{ ...type.editorHeading, margin: `0 0 ${space[300]}` }}>
                <span style={{ color: color.inkMarkup }}># </span>
                {p.slice(2)}
              </h1>
            ) : (
              <p key={i} style={{ ...type.editorBody, margin: `0 0 ${space[200]}` }}>{p}</p>
            ),
          )}
        </div>
      </article>

      <footer style={{ height: size.controlMd, flex: "none", display: "flex", alignItems: "center", justifyContent: "center", gap: space[100], borderTop: hairline(color.lineSubtle), color: color.inkTertiary, ...type.caption }}>
        {readOnly && <span style={{ color: color.stateWarning }}>{t("lease.readOnly")} ·</span>}
        {count}
      </footer>
    </main>
  );
}

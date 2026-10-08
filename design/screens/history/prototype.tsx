// history prototype — one sheet's hash chain (ADR-0002): who changed what, compare, restore without deleting.
// Interactive: filter by actor/device, pick a record to compare, restore adds a new record (shown as a notice).
import { useState, type ReactNode } from "react";
import {
  color, pane, radius, safePadding, size, space, type,
  Button, Chip, Icon, IconButton,
  openContext, useFrame, useNavigate, useT, type HistoryRecord, type IconName, type StringKey,
} from "@ithaca/kit";

export const states = ["all", "claude"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

type Filter = "all" | "claude" | "device";
const KIND: Record<HistoryRecord["kind"], StringKey> = { edit: "history.kind.edit", lease: "history.kind.lease", merge: "history.kind.merge" };
const KIND_ICON: Record<HistoryRecord["kind"], IconName> = { edit: "edit", lease: "lease", merge: "merge" };

/** Character-level highlight: common prefix/suffix plain, the changed middle marked. */
function Highlighted({ text, other, tone }: { text: string; other: string | null; tone: string }) {
  if (other === null) return <mark style={{ background: tone, color: "inherit", borderRadius: radius.piece }}>{text}</mark>;
  let start = 0;
  while (start < text.length && start < other.length && text[start] === other[start]) start++;
  let end = 0;
  while (end < text.length - start && end < other.length - start && text[text.length - 1 - end] === other[other.length - 1 - end]) end++;
  return (
    <>
      {text.slice(0, start)}
      <mark style={{ background: tone, color: "inherit", borderRadius: radius.piece }}>{text.slice(start, text.length - end)}</mark>
      {text.slice(text.length - end)}
    </>
  );
}

export default function History({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, sample, safeArea } = useFrame();
  const { sheet } = openContext(sample);
  const h = sample.history;
  const [filter, setFilter] = useState<Filter>(state === "claude" ? "claude" : "all");
  const records = h.records.filter((r) => (filter === "claude" ? r.actor === "claude" : filter === "device" ? r.device === h.thisDevice : true));
  const compact = sizeClass === "compact";
  const [picked, setPicked] = useState<string | null>(compact ? null : records[0]?.id ?? null);
  const [restored, setRestored] = useState<string | null>(null);
  const current = records.find((r) => r.id === picked) ?? null;

  const header = (
    <header style={{ flex: "none", display: "flex", flexDirection: "column", gap: space[100], padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
      <div style={{ display: "flex", alignItems: "center", gap: space[100] }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={type.heading}>{t("history.title")}</div>
          <div style={{ ...type.caption, color: color.inkSecondary, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{sheet.title}</div>
        </div>
        <IconButton icon="close" label={t("action.close")} onClick={() => go("app-shell")} />
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: space[50], ...type.caption, color: color.stateSuccess }}>
        <Icon name="verified" size="sm" />
        {t("history.integrity", { count: h.total })}
      </div>
      <FilterPicker filter={filter} onChange={(f) => { setFilter(f); setPicked(null); }} />
    </header>
  );

  const list = (
    <div style={{ flex: 1, overflow: "auto" }}>
      {records.map((r) => (
        <Row key={r.id} r={r} active={current?.id === r.id} onClick={() => { setPicked(r.id); setRestored(null); }} />
      ))}
    </div>
  );

  if (compact) {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceList, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
        {current ? (
          <>
            <header style={{ flex: "none", display: "flex", alignItems: "center", minHeight: size.barTop, padding: `0 ${space[100]}`, borderBottom: hairline(color.lineSubtle) }}>
              <Button variant="ghost" icon="back" onClick={() => setPicked(null)}>{t("history.title")}</Button>
            </header>
            <Detail r={current} restored={restored === current.id} onRestore={() => setRestored(current.id)} />
          </>
        ) : (
          <>
            {header}
            {list}
          </>
        )}
      </div>
    );
  }
  return (
    <div style={{ display: "flex", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
      <section style={{ width: pane.sheetList, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceList, borderRight: hairline(color.lineSubtle) }}>
        {header}
        {list}
      </section>
      {current ? (
        <Detail r={current} restored={restored === current.id} onRestore={() => setRestored(current.id)} />
      ) : (
        <main style={{ flex: 1, display: "grid", placeItems: "center", color: color.inkTertiary }}>{t("history.pick")}</main>
      )}
    </div>
  );
}

function FilterPicker({ filter, onChange }: { filter: Filter; onChange: (f: Filter) => void }) {
  const t = useT();
  const items: [Filter, string][] = [["all", t("history.filter.all")], ["claude", t("history.filter.claude")], ["device", t("history.filter.device")]];
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: space[50] }}>
      {items.map(([f, label]) => (
        <Chip key={f} active={f === filter} onClick={() => onChange(f)}>{label}</Chip>
      ))}
    </div>
  );
}

function Row({ r, active, onClick }: { r: HistoryRecord; active: boolean; onClick: () => void }) {
  const t = useT();
  const { locale } = useFrame();
  const when = new Date(r.at).toLocaleString(locale, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  const claude = r.actor === "claude";
  return (
    <article onClick={onClick} style={{ display: "flex", gap: space[150], padding: `${space[150]} ${space[200]}`, borderBottom: hairline(color.lineSubtle), background: active ? color.surfaceSelected : "transparent", cursor: "pointer" }}>
      <span style={{ flex: "none", alignSelf: "flex-start", display: "grid", placeItems: "center", minWidth: size.controlSm, minHeight: size.controlSm, borderRadius: radius.full, background: claude ? color.accentSoft : color.surfaceRaised, border: hairline(claude ? "transparent" : color.lineSubtle), color: claude ? color.accentPrimary : color.inkSecondary }}>
        <Icon name={claude ? "claude" : KIND_ICON[r.kind]} size="sm" />
      </span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: `0 ${space[100]}`, alignItems: "baseline" }}>
          <span style={{ ...type.body, fontWeight: type.heading.fontWeight }}>{t(claude ? "history.actor.claude" : "history.actor.me")}</span>
          <span style={{ ...type.caption, color: color.inkTertiary }}>{t(KIND[r.kind])}</span>
          <span style={{ ...type.caption, color: color.inkTertiary }}>{r.device}</span>
        </div>
        <div style={{ display: "flex", flexWrap: "wrap", gap: `0 ${space[100]}`, ...type.caption, color: color.inkSecondary }}>
          <span>{when}</span>
          {(r.added > 0 || r.removed > 0) && (
            <span>
              <span style={{ color: color.stateSuccess }}>+{r.added}</span> <span style={{ color: color.stateDanger }}>−{r.removed}</span>
            </span>
          )}
        </div>
      </div>
    </article>
  );
}

function Detail({ r, restored, onRestore }: { r: HistoryRecord; restored: boolean; onRestore: () => void }) {
  const t = useT();
  const hasText = r.before !== null || r.after !== null;
  return (
    <main style={{ flex: 1, minWidth: 0, overflow: "auto", padding: space[300], display: "flex", flexDirection: "column", gap: space[200] }}>
      {!hasText && <div style={{ color: color.inkTertiary }}>{t("history.noText")}</div>}
      {r.before !== null && (
        <Block label={t("history.before")} tone={color.surfaceList}>
          <Highlighted text={r.before} other={r.after} tone={color.surfaceSelected} />
        </Block>
      )}
      {r.after !== null && (
        <Block label={t("history.after")} tone={color.surfaceRaised}>
          <Highlighted text={r.after} other={r.before} tone={color.accentSoft} />
        </Block>
      )}
      {hasText && (
        <div style={{ flex: "none" }}>
          {restored ? (
            <div style={{ display: "flex", alignItems: "center", gap: space[50], ...type.label, color: color.stateSuccess }}>
              <Icon name="success" size="sm" />
              {t("history.restored")}
            </div>
          ) : (
            <Button variant="primary" icon="restore" onClick={onRestore}>{t("history.restore")}</Button>
          )}
          <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[100] }}>{t("history.restoreHint")}</div>
        </div>
      )}
    </main>
  );
}

function Block({ label, tone, children }: { label: string; tone: string; children: ReactNode }) {
  return (
    <section style={{ flex: "none" }}>
      <div style={{ ...type.label, color: color.inkTertiary, marginBottom: space[50] }}>{label}</div>
      <div style={{ ...type.editorBody, padding: space[200], borderRadius: radius.panel, border: hairline(color.lineSubtle), background: tone }}>{children}</div>
    </section>
  );
}

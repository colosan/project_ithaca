// pair-device prototype — add a device to the set and share the E2E key (ADR-0003): code, word check, first sync.
// Interactive: the existing device shows a QR + code, the new one types or scans it, both confirm four words, then sync.
import { useState, type ReactNode } from "react";
import {
  color, isDesktop, opacity, pane, radius, safePadding, shadow, size, space, type,
  Button, Icon, IconButton,
  useFrame, useNavigate, useT, type StringKey,
} from "@ithaca/kit";

export const states = ["show-code", "enter-code", "confirm", "syncing"] as const;
type State = (typeof states)[number];

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

const WORDS: StringKey[] = ["pair.word1", "pair.word2", "pair.word3", "pair.word4"];
const STEPS: StringKey[] = ["pair.step1", "pair.step2", "pair.step3"];
const QR_CELLS = 21;

export default function PairDevice({ state }: { state: State }) {
  const t = useT();
  const go = useNavigate();
  const { sizeClass, safeArea } = useFrame();
  const [step, setStep] = useState<State>(state);
  const close = () => go("preferences#sync");

  const body =
    step === "show-code" ? <ShowCode onScanned={() => setStep("confirm")} />
    : step === "enter-code" ? <EnterCode onEntered={() => setStep("confirm")} />
    : step === "confirm" ? <Confirm onMatch={() => setStep("syncing")} onRetry={() => setStep("show-code")} />
    : <Syncing onDone={close} />;

  const header = (
    <header style={{ flex: "none", display: "flex", alignItems: "center", gap: space[150], minHeight: size.barTop, padding: `0 ${space[100]} 0 ${space[200]}`, borderBottom: hairline(color.lineSubtle) }}>
      <span style={{ ...type.heading, flex: 1 }}>{t("pair.title")}</span>
      <IconButton icon="close" label={t("action.close")} onClick={close} />
    </header>
  );

  if (sizeClass === "compact") {
    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", background: color.surfaceCanvas, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
        {header}
        <div style={{ flex: 1, overflow: "auto", padding: space[300] }}>{body}</div>
      </div>
    );
  }
  // Wide: a dialog over Settings.
  return (
    <div style={{ height: "100%", display: "flex", alignItems: "center", justifyContent: "center", background: color.surfaceScrim, color: color.inkPrimary, ...type.body, ...safePadding(safeArea) }}>
      <div style={{ width: pane.dialog, maxWidth: "90%", maxHeight: "90%", display: "flex", flexDirection: "column", overflow: "hidden", background: color.surfaceRaised, borderRadius: radius.sheet, boxShadow: shadow.dialog }}>
        {header}
        <div style={{ overflow: "auto", padding: space[300] }}>{body}</div>
      </div>
    </div>
  );
}

/** Existing device: QR + 6-digit code with a countdown, and how to start on the new device. */
function ShowCode({ onScanned }: { onScanned: () => void }) {
  const t = useT();
  const { sample } = useFrame();
  const { code, expiresIn } = sample.pair;
  return (
    <Stack>
      <div style={{ color: color.inkSecondary, textAlign: "center" }}>{t("pair.showHint")}</div>
      <div style={{ display: "flex", justifyContent: "center" }}>
        <Qr seed={code} />
      </div>
      <div style={{ textAlign: "center" }}>
        <div style={{ ...type.display, letterSpacing: space[50], fontVariantNumeric: "tabular-nums" }}>{`${code.slice(0, 3)} ${code.slice(3)}`}</div>
        <div style={{ ...type.caption, color: color.inkTertiary }}>{t("pair.expires", { time: expiresIn })}</div>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: space[100], padding: space[200], borderRadius: radius.panel, background: color.surfaceList }}>
        {STEPS.map((k, i) => (
          <div key={k} style={{ display: "flex", alignItems: "flex-start", gap: space[150], color: color.inkSecondary }}>
            <span style={{ flex: "none", display: "grid", placeItems: "center", minWidth: size.iconLg, minHeight: size.iconLg, borderRadius: radius.full, background: color.surfaceRaised, border: hairline(color.lineSubtle), ...type.caption, fontWeight: type.heading.fontWeight, color: color.inkPrimary }}>
              {i + 1}
            </span>
            <span style={{ flex: 1, minWidth: 0 }}>{t(k)}</span>
          </div>
        ))}
      </div>
      <Button variant="ghost" style={{ alignSelf: "center" }} onClick={onScanned}>{t("pair.simulate")}</Button>
    </Stack>
  );
}

/** A stand-in QR: finder squares in three corners, the rest a deterministic pattern from the code. */
function Qr({ seed }: { seed: string }) {
  let x = [...seed].reduce((a, c) => a * 31 + c.charCodeAt(0), 7) >>> 0;
  const finder = (r: number, c: number) => {
    for (const [r0, c0] of [[0, 0], [0, QR_CELLS - 7], [QR_CELLS - 7, 0]]) {
      const dr = r - r0, dc = c - c0;
      if (dr >= 0 && dr < 7 && dc >= 0 && dc < 7) return dr === 0 || dr === 6 || dc === 0 || dc === 6 || (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4);
      if (dr >= -1 && dr <= 7 && dc >= -1 && dc <= 7) return false;
    }
    return null;
  };
  const cells: boolean[] = [];
  for (let r = 0; r < QR_CELLS; r++)
    for (let c = 0; c < QR_CELLS; c++) {
      const f = finder(r, c);
      x = (x * 1103515245 + 12345) >>> 0;
      cells.push(f ?? (x >>> 16) % 2 === 0);
    }
  // A real QR is always dark on light, whatever the theme; the native screen draws it on a fixed light plate.
  return (
    <div style={{ width: size.pairQr, height: size.pairQr, padding: space[150], borderRadius: radius.panel, background: color.surfaceRaised, border: hairline(color.lineSubtle), boxSizing: "border-box", display: "grid", gridTemplateColumns: `repeat(${QR_CELLS}, 1fr)` }}>
      {cells.map((on, i) => <span key={i} style={{ background: on ? color.inkPrimary : "transparent" }} />)}
    </div>
  );
}

/** New device: six digit cells over one real input; phones can scan instead. */
function EnterCode({ onEntered }: { onEntered: () => void }) {
  const t = useT();
  const { platform } = useFrame();
  const [code, setCode] = useState("");
  return (
    <Stack>
      <div style={{ textAlign: "center" }}>
        <div style={type.title}>{t("pair.enterTitle")}</div>
        <div style={{ ...type.caption, color: color.inkSecondary, marginTop: space[50] }}>{t("pair.enterHint")}</div>
      </div>
      <label style={{ position: "relative", display: "flex", justifyContent: "center", gap: space[100], cursor: "text" }}>
        {Array.from({ length: 6 }, (_, i) => (
          <span
            key={i}
            style={{
              flex: "1 1 0", maxWidth: size.pairCodeCell, minHeight: size.pairCodeCell, display: "grid", placeItems: "center",
              ...type.title, fontVariantNumeric: "tabular-nums", borderRadius: radius.control, background: color.surfaceRaised,
              border: hairline(i === code.length ? color.accentPrimary : color.lineStrong),
            }}
          >
            {code[i] ?? ""}
          </span>
        ))}
        <input
          value={code}
          inputMode="numeric"
          autoFocus
          onChange={(e) => {
            const v = e.target.value.replace(/\D/g, "").slice(0, 6);
            setCode(v);
            if (v.length === 6) onEntered();
          }}
          style={{ position: "absolute", inset: 0, opacity: 0, border: "none", padding: 0 }}
        />
      </label>
      {!isDesktop(platform) && <Button icon="scan" style={{ alignSelf: "center" }} onClick={onEntered}>{t("pair.scan")}</Button>}
    </Stack>
  );
}

/** Both devices show four words derived from the shared key; a mismatch means someone is in between. */
function Confirm({ onMatch, onRetry }: { onMatch: () => void; onRetry: () => void }) {
  const t = useT();
  const [refused, setRefused] = useState(false);
  return (
    <Stack>
      <div style={{ textAlign: "center" }}>
        <div style={type.title}>{t("pair.confirmTitle")}</div>
        <div style={{ ...type.caption, color: color.inkSecondary, marginTop: space[50] }}>{t("pair.confirmHint")}</div>
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", gap: space[100], opacity: refused ? opacity.disabled : undefined }}>
        {WORDS.map((k) => (
          <span key={k} style={{ ...type.heading, padding: `${space[100]} ${space[200]}`, borderRadius: radius.control, background: color.surfaceRaised, border: hairline(color.lineStrong), boxShadow: shadow.raised }}>
            {t(k)}
          </span>
        ))}
      </div>
      {refused ? (
        <>
          <div style={{ display: "flex", alignItems: "flex-start", gap: space[100], padding: space[150], borderRadius: radius.panel, background: color.surfaceList, ...type.label, color: color.stateDanger }}>
            <Icon name="warning" size="sm" />
            <span style={{ flex: 1, minWidth: 0 }}>{t("pair.mismatchNote")}</span>
          </div>
          <Button style={{ alignSelf: "center" }} onClick={onRetry}>{t("pair.title")}</Button>
        </>
      ) : (
        <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", gap: space[100] }}>
          <Button onClick={() => setRefused(true)}>{t("pair.mismatch")}</Button>
          <Button variant="primary" icon="check" onClick={onMatch}>{t("pair.match")}</Button>
        </div>
      )}
    </Stack>
  );
}

/** First sync: sheet count and size; it continues in the background if closed. */
function Syncing({ onDone }: { onDone: () => void }) {
  const t = useT();
  const { sample } = useFrame();
  const { done, total, size: bytes } = sample.pair;
  return (
    <Stack>
      <div style={{ textAlign: "center" }}>
        <div style={type.title}>{t("pair.syncing")}</div>
        <div style={{ ...type.caption, color: color.inkSecondary, marginTop: space[50], fontVariantNumeric: "tabular-nums" }}>{t("pair.syncProgress", { done, total, size: bytes })}</div>
      </div>
      <div style={{ height: space[100], borderRadius: radius.full, background: color.surfaceSelected, overflow: "hidden" }}>
        <div style={{ width: `${Math.round((done / total) * 100)}%`, height: "100%", background: color.accentPrimary }} />
      </div>
      <div style={{ ...type.caption, color: color.inkTertiary, textAlign: "center" }}>{t("pair.syncHint")}</div>
      <Button variant="primary" style={{ alignSelf: "center" }} onClick={onDone}>{t("action.done")}</Button>
    </Stack>
  );
}

// ── Local building blocks (become native components later) ──────────────

function Stack({ children }: { children: ReactNode }) {
  return <div style={{ display: "flex", flexDirection: "column", alignItems: "stretch", gap: space[300] }}>{children}</div>;
}

// Sheet lease between tabs of this browser (ADR-0002, in miniature): one place writes a sheet at a time.
// The tab that typed in a sheet most recently holds it; others see it read-only until they take it over.
// Holds lapse after a minute without typing, so a forgotten tab doesn't lock a sheet forever.
import { useEffect, useState } from "react";
import { uid } from "./store";

const HOLD_MS = 60_000;
const me = uid();
type Msg = { type: "hold" | "release" | "ask"; tab: string; sheet: string; at: number };

const channel = typeof BroadcastChannel !== "undefined" ? new BroadcastChannel("ithaca-lease") : null;
/** Latest hold per sheet, from any tab including this one. */
const holds = new Map<string, { tab: string; at: number }>();
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((f) => f());

channel?.addEventListener("message", (e: MessageEvent<Msg>) => {
  const m = e.data;
  if (m.type === "ask") {
    // A tab just opened: tell it what this tab is writing.
    for (const [sheet, h] of holds) if (h.tab === me) channel?.postMessage({ type: "hold", tab: me, sheet, at: h.at } satisfies Msg);
    return;
  }
  if (m.type === "hold") holds.set(m.sheet, { tab: m.tab, at: m.at });
  else if (holds.get(m.sheet)?.tab === m.tab) holds.delete(m.sheet);
  notify();
});

channel?.postMessage({ type: "ask", tab: me, sheet: "", at: Date.now() } satisfies Msg);

let lastSent = new Map<string, number>();
/** Called on every edit; announces at most every few seconds. */
export function hold(sheet: string) {
  const now = Date.now();
  const mine = holds.get(sheet)?.tab === me;
  holds.set(sheet, { tab: me, at: now });
  if (!mine || now - (lastSent.get(sheet) ?? 0) > 5_000) {
    lastSent.set(sheet, now);
    channel?.postMessage({ type: "hold", tab: me, sheet, at: now } satisfies Msg);
    if (!mine) notify();
  }
}

window.addEventListener("pagehide", () => {
  for (const [sheet, h] of holds) if (h.tab === me) channel?.postMessage({ type: "release", tab: me, sheet, at: Date.now() } satisfies Msg);
  lastSent = new Map();
});

/** Leaving a sheet gives it up right away, so another tab can write it without taking over. */
export function release(sheet: string) {
  if (holds.get(sheet)?.tab !== me) return;
  holds.delete(sheet);
  lastSent.delete(sheet);
  channel?.postMessage({ type: "release", tab: me, sheet, at: Date.now() } satisfies Msg);
}

/** Whether another tab is writing this sheet right now. */
export function useLease(sheet: string | null) {
  const [, tick] = useState(0);
  useEffect(() => {
    const f = () => tick((n) => n + 1);
    listeners.add(f);
    const timer = setInterval(f, 10_000); // let lapsed holds expire on screen
    return () => {
      listeners.delete(f);
      clearInterval(timer);
    };
  }, []);
  const h = sheet ? holds.get(sheet) : undefined;
  const locked = !!h && h.tab !== me && Date.now() - h.at < HOLD_MS;
  return { locked, takeOver: () => sheet && hold(sheet) };
}

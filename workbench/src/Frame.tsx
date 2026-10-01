import {
  Component, useEffect, useRef, useState,
  type CSSProperties, type PointerEvent as ReactPointerEvent, type ReactNode,
} from "react";
import { FrameContext, sample, sizeClassFor, type FrameInfo, type Locale, type Platform, type Theme } from "@ithaca/kit";
import { presetLabel, viewportById, viewports, type Viewport } from "./registry";

// ── Issue detection (J3) ─────────────────────────────────────────────────

export type IssueKind = "clip" | "spill" | "ellipsis" | "offscreen";
export type Issues = Record<IssueKind, number>;
const NO_ISSUES: Issues = { clip: 0, spill: 0, ellipsis: 0, offscreen: 0 };

const holdsText = (el: Element) => [...el.childNodes].some((n) => n.nodeType === Node.TEXT_NODE && n.textContent!.trim());

/**
 * Marks text the layout mangles:
 * - clip      — cut off by overflow:hidden (either axis)
 * - spill     — runs out of its own box (e.g. wraps to two lines inside a fixed-height field)
 * - ellipsis  — truncated with "…" (usually intentional; reported muted)
 * - offscreen — pushed outside the device
 * Only elements that directly hold text are checked, so big clipping containers (panes, lists) stay quiet.
 */
function scanIssues(root: HTMLElement): Issues {
  const found = { ...NO_ISSUES };
  const box = root.getBoundingClientRect();
  root.querySelectorAll<HTMLElement>("[data-wb-issue]").forEach((el) => delete el.dataset.wbIssue);
  root.querySelectorAll<HTMLElement>("*").forEach((el) => {
    if (!holdsText(el)) return;
    const cs = getComputedStyle(el);
    let kind: IssueKind | null = null;
    const overX = el.clientWidth > 0 && el.scrollWidth > el.clientWidth + 1;
    const overY = el.clientHeight > 0 && el.scrollHeight > el.clientHeight + 2;
    if (overX && cs.overflowX !== "visible") {
      kind = cs.textOverflow === "ellipsis" ? "ellipsis" : "clip";
    } else if (overY && cs.overflowY !== "visible") {
      kind = "clip";
    } else if (overX || overY) {
      kind = "spill";
    } else {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && (r.right > box.right + 1 || r.left < box.left - 1)) kind = "offscreen";
    }
    if (kind) {
      el.dataset.wbIssue = kind;
      found[kind]++;
    }
  });
  return found;
}

// ── Device: the bare box a prototype renders into ───────────────────────

interface DeviceProps {
  width: number;
  height: number;
  platform: Platform;
  theme: Theme;
  locale: Locale;
  className?: string;
  style?: CSSProperties;
  /** Receives issue counts after every render; omit to skip scanning (thumbnails). */
  onIssues?: (issues: Issues) => void;
  /** Links clicked inside the prototype; omit for non-interactive thumbnails. */
  onNavigate?: (to: string) => void;
  showIssues?: boolean;
  children: ReactNode;
}

/** Stands in for one device/window. The prototype derives its size class from `width` (logical px). */
export function Device({ width, height, platform, theme, locale, className, style, onIssues, onNavigate, showIssues, children }: DeviceProps) {
  const ref = useRef<HTMLDivElement>(null);
  const info: FrameInfo = { sizeClass: sizeClassFor(width), width, height, platform, theme, locale, sample, navigate: onNavigate };

  // Scan after each commit. A timeout (not rAF) so it also runs when the window is not painting.
  useEffect(() => {
    if (!onIssues || !ref.current) return;
    const id = setTimeout(() => ref.current && onIssues(scanIssues(ref.current)), 60);
    return () => clearTimeout(id);
  });

  return (
    <div
      ref={ref}
      data-theme={theme}
      lang={locale}
      className={`wb-device ${showIssues ? "wb-show-issues" : ""} ${className ?? ""}`}
      style={{ width, height, ...style }}
    >
      <FrameContext.Provider value={info}>
        <Boundary>{children}</Boundary>
      </FrameContext.Provider>
    </div>
  );
}

class Boundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) {
    return { error };
  }
  render() {
    return this.state.error ? <pre className="wb-error">{String(this.state.error.stack ?? this.state.error)}</pre> : this.props.children;
  }
}

// ── Sectors and size rules ───────────────────────────────────────────────

export interface FrameSpec {
  id: string;
  /** Preset id, or null once the user drags to a custom size. */
  preset: string | null;
  /** The sector the frame lives in. Never changes after the frame is created. */
  platform: Platform;
  /** The preset a custom size started from, so the caption can still say which device it was. */
  base?: string | null;
  w: number;
  h: number;
}

/**
 * On-screen caption size (screen px): a frame slot is at least this wide so the controls fit.
 * Device frames carry a picker and size inputs on two rows; fixed base frames need one short row.
 */
export const captionSize = (fixed: boolean) => (fixed ? { w: 190, h: 30 } : { w: 220, h: 60 });

/** Device sectors of the detail view. A frame lives in exactly one and is edited only within it. */
export const SECTORS: { os: Platform; name: string }[] = [
  { os: "ios", name: "iPhone" },
  { os: "android", name: "Android" },
  { os: "ipados", name: "iPad" },
  { os: "macos", name: "Mac" },
  { os: "windows", name: "Windows" },
];

/**
 * Sizes that make sense per platform, as short side / long side so rotating still works.
 * Phones stay phone-sized; desktop windows range from a narrow window to a 4K screen.
 */
const SIDES: Record<Platform, { short: [number, number]; long: [number, number] }> = {
  ios: { short: [320, 440], long: [568, 960] },
  android: { short: [320, 1000], long: [480, 1600] },
  ipados: { short: [320, 1032], long: [600, 1400] },
  macos: { short: [360, 2400], long: [480, 3840] },
  windows: { short: [360, 2400], long: [480, 3840] },
};
const clamp = (v: number, [lo, hi]: [number, number]) => Math.min(hi, Math.max(lo, Math.round(v)));

/** Clamp to the platform's sides. `portrait` decides which side is short; a drag keeps the frame's orientation. */
export function clampSize(os: Platform, w: number, h: number, portrait = w <= h): [number, number] {
  const { short, long } = SIDES[os];
  return portrait ? [clamp(w, short), clamp(h, long)] : [clamp(w, long), clamp(h, short)];
}

/**
 * A size change within the frame's platform: if the new size is exactly one of that platform's presets, the frame
 * becomes that preset again; otherwise it is a custom size that remembers which preset it came from.
 */
export function resized(frame: FrameSpec, w: number, h: number, rotate = false): FrameSpec {
  // Only the rotate button flips orientation; dragging or typing keeps it.
  const portrait = rotate ? w <= h : frame.w <= frame.h;
  [w, h] = clampSize(frame.platform, w, h, portrait);
  // A preset matches in either orientation — a rotated iPhone is still that iPhone.
  const match = viewports.find((v) => v.os === frame.platform && ((v.width === w && v.height === h) || (v.width === h && v.height === w)));
  if (match) return { ...frame, w, h, preset: match.id, base: null };
  return { ...frame, w, h, preset: null, base: frame.preset ?? frame.base ?? null };
}

export const presetsOf = (os: Platform) => viewports.filter((v) => v.os === os);

/** A platform's presets grouped by family, in file order, for <optgroup>s. */
export function presetGroups(os: Platform): [string, Viewport[]][] {
  const out: [string, Viewport[]][] = [];
  for (const v of presetsOf(os)) {
    const g = out.find(([name]) => name === v.group);
    if (g) g[1].push(v);
    else out.push([v.group, [v]]);
  }
  return out;
}

/** Suffix shown when a preset is displayed in the other orientation (e.g. a portrait iPad turned landscape). */
export const rotatedSuffix = (v: Viewport, w: number, h: number) => (w > h && v.width < v.height ? " · 가로" : w < h && v.width > v.height ? " · 세로" : "");

// ── ResizableFrame: a Device with its platform's presets, drag handles and tools ──

/** How a frame reports changes so each lands as one undo step. */
export interface FrameEdit {
  /** A discrete change. Same `key` within a second merges (typing a number). */
  commit: (frame: FrameSpec, label: string, key?: string) => void;
  /** A resize drag: previews while moving, one history step at the end. */
  dragStart: () => void;
  dragMove: (frame: FrameSpec) => void;
  dragEnd: (frame: FrameSpec) => void;
}

interface ResizableFrameProps {
  frame: FrameSpec;
  zoom: number;
  theme: Theme;
  locale: Locale;
  /** "app-shell#reference" — goes into the copied reference line. */
  nodeRef: string;
  showIssues: boolean;
  edit: FrameEdit;
  /** Links clicked inside the prototype. */
  onNavigate?: (to: string) => void;
  /** Show only this frame, large. Undefined when already focused. */
  onFocus?: () => void;
  /**
   * A fixed reference frame (one per layout size class): shows this title instead of the device picker and has no
   * resize, rotate or size inputs.
   */
  fixedTitle?: string;
  children: ReactNode;
}

export function ResizableFrame({ frame, zoom, theme, locale, nodeRef, showIssues, edit, onNavigate, onFocus, fixedTitle, children }: ResizableFrameProps) {
  const preset = frame.preset ? viewportById[frame.preset] : undefined;
  const base = frame.base ? viewportById[frame.base] : undefined;
  const [issues, setIssues] = useState<Issues>(NO_ISSUES);
  const [copied, setCopied] = useState(false);
  // Hard clips and offscreen text are defects; ellipsis is usually intentional and shown muted.
  const severe = issues.clip + issues.spill + issues.offscreen;

  const report = (next: Issues) =>
    setIssues((prev) => ((Object.keys(next) as IssueKind[]).every((k) => prev[k] === next[k]) ? prev : next));

  // Pointer deltas are screen px; divide by the stage zoom to get layout px.
  const startDrag = (axis: "x" | "y" | "xy") => (e: ReactPointerEvent) => {
    e.preventDefault();
    e.stopPropagation(); // not a stage pan
    const start = { x: e.clientX, y: e.clientY, w: frame.w, h: frame.h };
    let last = frame;
    edit.dragStart();
    const move = (ev: PointerEvent) => {
      const dx = (ev.clientX - start.x) / zoom;
      const dy = (ev.clientY - start.y) / zoom;
      last = resized(frame, axis === "y" ? start.w : start.w + dx, axis === "x" ? start.h : start.h + dy);
      edit.dragMove(last);
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      document.body.classList.remove("wb-resizing");
      edit.dragEnd(last);
    };
    document.body.classList.add("wb-resizing");
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  const setSize = (w: number, h: number, label: string, key?: string, rotate = false) => edit.commit(resized(frame, w, h, rotate), label, key);

  const copyRef = async () => {
    const where = fixedTitle ?? (preset ? presetLabel(preset) + rotatedSuffix(preset, frame.w, frame.h) : `custom${base ? ` from ${base.label}` : ""}`);
    const line = `${nodeRef} · ${frame.platform} ${where} ${frame.w}×${frame.h} (${sizeClassFor(frame.w)}) · ${theme} · ${locale}`;
    try {
      await navigator.clipboard.writeText(line);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      window.prompt("복사", line);
    }
  };

  return (
    <figure className="wb-frame" style={{ minWidth: captionSize(!!fixedTitle).w / zoom }} onDoubleClick={(e) => (e.target as HTMLElement).closest("figcaption") && onFocus?.()}>
      {/* Counter-zoomed so it stays at screen size; its screen width matches the slot (frame or CAPTION_W, whichever is wider). */}
      <figcaption style={{ zoom: 1 / zoom, width: Math.max(frame.w * zoom, captionSize(!!fixedTitle).w) }}>
        {fixedTitle ? (
          <div className="wb-cap-row">
            <b className="wb-cap-title">{fixedTitle}</b>
            <span className="wb-muted">{frame.w}×{frame.h}</span>
            <span
              className="wb-issues"
              title={`잘림 ${issues.clip} · 넘침 ${issues.spill} · 화면 밖 ${issues.offscreen} · 말줄임 ${issues.ellipsis} (말줄임은 의도된 경우가 많음)`}
            >
              {severe ? <b className="wb-issues-on">⚠ {severe}</b> : <span className="wb-ok">✓</span>}
            </span>
            <span className="wb-spacer" />
            {onFocus && <button title="이 프레임만 크게 (더블클릭도 됨)" onClick={onFocus}>⤢</button>}
            <button title="참조 복사 — agent 에게 붙여넣기" onClick={copyRef}>{copied ? "✓" : "⧉"}</button>
          </div>
        ) : (
        <>
        <div className="wb-cap-row">
          {fixedTitle ? (
            <b className="wb-cap-title">{fixedTitle}</b>
          ) : (
          <select
            value={frame.preset ?? ""}
            onChange={(e) => {
              const v = viewportById[e.target.value];
              if (!v) return;
              // Keep the frame's current orientation when switching device.
              const landscape = frame.w > frame.h;
              const [w, h] = landscape === v.width > v.height ? [v.width, v.height] : [v.height, v.width];
              edit.commit({ ...frame, preset: v.id, w, h, base: null }, `기기 · ${v.label}`);
            }}
          >
            {/* Only while the size is custom; names the device it started from. */}
            {!preset && <option value="">직접 조절{base ? ` · ${base.label} 기준` : ""}</option>}
            {presetGroups(frame.platform).map(([group, list]) => (
              <optgroup key={group} label={group}>
                {list.map((v) => (
                  <option key={v.id} value={v.id}>
                    {presetLabel(v)}
                    {v.id === frame.preset ? rotatedSuffix(v, frame.w, frame.h) : ""}
                  </option>
                ))}
              </optgroup>
            ))}
          </select>
          )}
          <span
            className="wb-issues"
            title={`잘림 ${issues.clip} · 넘침 ${issues.spill} · 화면 밖 ${issues.offscreen} · 말줄임 ${issues.ellipsis} (말줄임은 의도된 경우가 많음)`}
          >
            {severe ? <b className="wb-issues-on">⚠ {severe}</b> : <span className="wb-ok">✓</span>}
            {issues.ellipsis > 0 && <span className="wb-muted"> …{issues.ellipsis}</span>}
          </span>
        </div>
        <div className="wb-cap-row">
          {fixedTitle ? (
            <span className="wb-muted">{frame.w}×{frame.h}</span>
          ) : (
            <span className="wb-size">
              <input type="number" value={frame.w} onChange={(e) => setSize(Number(e.target.value), frame.h, "폭 입력", `w:${frame.id}`)} />×
              <input type="number" value={frame.h} onChange={(e) => setSize(frame.w, Number(e.target.value), "높이 입력", `h:${frame.id}`)} />
            </span>
          )}
          <span className="wb-spacer" />
          {onFocus && <button title="이 프레임만 크게 (더블클릭도 됨)" onClick={onFocus}>⤢</button>}
          {!fixedTitle && <button title="가로/세로 바꾸기" onClick={() => setSize(frame.h, frame.w, "가로/세로 바꾸기", undefined, true)}>⟲</button>}
          <button title="참조 복사 — agent 에게 붙여넣기" onClick={copyRef}>{copied ? "✓" : "⧉"}</button>
        </div>
        </>
        )}
      </figcaption>

      <div className="wb-resize-box">
        <Device width={frame.w} height={frame.h} platform={frame.platform} theme={theme} locale={locale} onIssues={report} onNavigate={onNavigate} showIssues={showIssues}>
          {children}
        </Device>
        {!fixedTitle && (
          <>
            <span className="wb-handle wb-handle-x" onPointerDown={startDrag("x")} />
            <span className="wb-handle wb-handle-y" onPointerDown={startDrag("y")} />
            <span className="wb-handle wb-handle-xy" onPointerDown={startDrag("xy")} />
          </>
        )}
      </div>
    </figure>
  );
}

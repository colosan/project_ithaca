import {
  Component, useEffect, useRef, useState,
  type CSSProperties, type PointerEvent as ReactPointerEvent, type ReactNode,
} from "react";
import { FrameContext, sample, sizeClassFor, type FrameInfo, type Locale, type Platform, type Theme } from "@ithaca/kit";
import { viewportById, viewports, type Viewport } from "./registry";

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
  showIssues?: boolean;
  children: ReactNode;
}

/** Stands in for one device/window. The prototype derives its size class from `width` (logical px). */
export function Device({ width, height, platform, theme, locale, className, style, onIssues, showIssues, children }: DeviceProps) {
  const ref = useRef<HTMLDivElement>(null);
  const info: FrameInfo = { sizeClass: sizeClassFor(width), width, height, platform, theme, locale, sample };

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

// ── ResizableFrame: a Device with presets, drag handles and tools ───────

export interface FrameSpec {
  id: string;
  /** Preset id, or null once the user drags to a custom size. */
  preset: string | null;
  /** Kept from the last preset when the size becomes custom. */
  platform: Platform;
  w: number;
  h: number;
}

/** Minimum on-screen width of a frame slot, so its caption controls always fit (screen px). */
export const CAPTION_W = 240;
/** Two caption rows (screen px). */
export const CAPTION_H = 60;

export const LIMIT = { minW: 280, maxW: 3840, minH: 360, maxH: 2400 };
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, Math.round(v)));

export const byPlatform = viewports.reduce<Record<string, Viewport[]>>((acc, v) => {
  (acc[v.platform] ??= []).push(v);
  return acc;
}, {});

interface ResizableFrameProps {
  frame: FrameSpec;
  zoom: number;
  theme: Theme;
  locale: Locale;
  /** "app-shell#reference" — goes into the copied reference line. */
  nodeRef: string;
  showIssues: boolean;
  onChange: (frame: FrameSpec) => void;
  onRemove: () => void;
  children: ReactNode;
}

export function ResizableFrame({ frame, zoom, theme, locale, nodeRef, showIssues, onChange, onRemove, children }: ResizableFrameProps) {
  const preset = frame.preset ? viewportById[frame.preset] : undefined;
  const sizeClass = sizeClassFor(frame.w);
  const [issues, setIssues] = useState<Issues>(NO_ISSUES);
  const [copied, setCopied] = useState(false);
  // Hard clips and offscreen text are defects; ellipsis is usually intentional and shown muted.
  const severe = issues.clip + issues.spill + issues.offscreen;

  const report = (next: Issues) =>
    setIssues((prev) => ((Object.keys(next) as IssueKind[]).every((k) => prev[k] === next[k]) ? prev : next));

  // Pointer deltas are screen px; divide by the matrix zoom to get layout px.
  const startDrag = (axis: "x" | "y" | "xy") => (e: ReactPointerEvent) => {
    e.preventDefault();
    const start = { x: e.clientX, y: e.clientY, w: frame.w, h: frame.h };
    const move = (ev: PointerEvent) => {
      const dx = (ev.clientX - start.x) / zoom;
      const dy = (ev.clientY - start.y) / zoom;
      onChange({
        ...frame,
        preset: null,
        w: axis === "y" ? start.w : clamp(start.w + dx, LIMIT.minW, LIMIT.maxW),
        h: axis === "x" ? start.h : clamp(start.h + dy, LIMIT.minH, LIMIT.maxH),
      });
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      document.body.classList.remove("wb-resizing");
    };
    document.body.classList.add("wb-resizing");
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  const setSize = (w: number, h: number) =>
    onChange({ ...frame, preset: null, w: clamp(w, LIMIT.minW, LIMIT.maxW), h: clamp(h, LIMIT.minH, LIMIT.maxH) });

  const copyRef = async () => {
    const where = preset ? `${preset.platform} ${preset.label}` : "custom";
    const line = `${nodeRef} · ${where} ${frame.w}×${frame.h} ${sizeClass} · ${frame.platform} · ${theme} · ${locale}`;
    try {
      await navigator.clipboard.writeText(line);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      window.prompt("복사", line);
    }
  };

  return (
    <figure className="wb-frame" style={{ minWidth: CAPTION_W / zoom }}>
      {/* Counter-zoomed so it stays at screen size; its screen width matches the slot (frame or CAPTION_W, whichever is wider). */}
      <figcaption style={{ zoom: 1 / zoom, width: Math.max(frame.w * zoom, CAPTION_W) }}>
        <div className="wb-cap-row">
          <select
            value={frame.preset ?? ""}
            onChange={(e) => {
              const v = viewportById[e.target.value];
              if (v) onChange({ ...frame, preset: v.id, platform: v.os, w: v.width, h: v.height });
            }}
          >
            <option value="">사용자 지정</option>
            {Object.entries(byPlatform).map(([platform, list]) => (
              <optgroup key={platform} label={platform}>
                {list.map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.label} ({v.width}×{v.height})
                  </option>
                ))}
              </optgroup>
            ))}
          </select>
          <span className={`wb-class wb-class-${sizeClass}`}>{sizeClass}</span>
          <span className="wb-issues" title={`잘림 ${issues.clip} · 넘침 ${issues.spill} · 화면 밖 ${issues.offscreen} · 말줄임 ${issues.ellipsis} (말줄임은 의도된 경우가 많음)`}>
            {severe ? <b className="wb-issues-on">⚠ {severe}</b> : <span className="wb-ok">✓</span>}
            {issues.ellipsis > 0 && <span className="wb-muted"> …{issues.ellipsis}</span>}
          </span>
        </div>
        <div className="wb-cap-row">
          <span className="wb-size">
            <input type="number" value={frame.w} onChange={(e) => setSize(Number(e.target.value), frame.h)} />×
            <input type="number" value={frame.h} onChange={(e) => setSize(frame.w, Number(e.target.value))} />
          </span>
          <span className="wb-muted wb-cap-os" title={preset?.scale && preset.physical ? `물리 ${preset.physical.join("×")} ÷ 배율 ${preset.scale * 100}%` : undefined}>
            {frame.platform}
            {preset?.scale && preset.physical ? ` · ${preset.scale * 100}%` : ""}
          </span>
          <span className="wb-spacer" />
          <button title="참조 복사 — agent 에게 붙여넣기" onClick={copyRef}>{copied ? "✓" : "⧉"}</button>
          <button title="가로/세로 바꾸기" onClick={() => setSize(frame.h, frame.w)}>⟲</button>
          <button title="프레임 빼기" onClick={onRemove}>✕</button>
        </div>
      </figcaption>

      <div className="wb-resize-box">
        <Device
          width={frame.w}
          height={frame.h}
          platform={frame.platform}
          theme={theme}
          locale={locale}
          onIssues={report}
          showIssues={showIssues}
        >
          {children}
        </Device>
        <span className="wb-handle wb-handle-x" onPointerDown={startDrag("x")} />
        <span className="wb-handle wb-handle-y" onPointerDown={startDrag("y")} />
        <span className="wb-handle wb-handle-xy" onPointerDown={startDrag("xy")} />
      </div>
    </figure>
  );
}

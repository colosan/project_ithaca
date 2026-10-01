import { Component, type CSSProperties, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { FrameContext, sample, sizeClassFor, type FrameInfo, type Locale, type Theme } from "@ithaca/kit";
import { viewportById, viewports, type Viewport } from "./registry";

// ── Device: the bare box a prototype renders into ───────────────────────

interface DeviceProps {
  width: number;
  height: number;
  theme: Theme;
  locale: Locale;
  className?: string;
  style?: CSSProperties;
  children: ReactNode;
}

/** Stands in for one device/window. The prototype derives its size class from `width` (logical px). */
export function Device({ width, height, theme, locale, className, style, children }: DeviceProps) {
  const info: FrameInfo = { sizeClass: sizeClassFor(width), width, height, theme, locale, sample };
  return (
    <div data-theme={theme} lang={locale} className={`wb-device ${className ?? ""}`} style={{ width, height, ...style }}>
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

// ── ResizableFrame: a Device with presets and drag handles ──────────────

export interface FrameSpec {
  id: string;
  /** Preset id, or null once the user drags to a custom size. */
  preset: string | null;
  w: number;
  h: number;
}

const LIMIT = { minW: 280, maxW: 3840, minH: 360, maxH: 2400 };
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, Math.round(v)));

const byPlatform = viewports.reduce<Record<string, Viewport[]>>((acc, v) => {
  (acc[v.platform] ??= []).push(v);
  return acc;
}, {});

interface ResizableFrameProps {
  frame: FrameSpec;
  zoom: number;
  theme: Theme;
  locale: Locale;
  onChange: (frame: FrameSpec) => void;
  onRemove: () => void;
  children: ReactNode;
}

export function ResizableFrame({ frame, zoom, theme, locale, onChange, onRemove, children }: ResizableFrameProps) {
  const preset = frame.preset ? viewportById[frame.preset] : undefined;
  const sizeClass = sizeClassFor(frame.w);

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

  return (
    <figure className="wb-frame">
      <figcaption>
        <select
          value={frame.preset ?? ""}
          onChange={(e) => {
            const v = viewportById[e.target.value];
            if (v) onChange({ ...frame, preset: v.id, w: v.width, h: v.height });
          }}
        >
          <option value="">사용자 지정</option>
          {Object.entries(byPlatform).map(([platform, list]) => (
            <optgroup key={platform} label={platform}>
              {list.map((v) => (
                <option key={v.id} value={v.id}>
                  {v.label}
                </option>
              ))}
            </optgroup>
          ))}
        </select>
        <span className="wb-size">
          <input type="number" value={frame.w} onChange={(e) => setSize(Number(e.target.value), frame.h)} />×
          <input type="number" value={frame.h} onChange={(e) => setSize(frame.w, Number(e.target.value))} />
        </span>
        <span className={`wb-class wb-class-${sizeClass}`}>{sizeClass}</span>
        {preset?.scale && preset.physical && (
          <span className="wb-muted">
            {preset.physical.join("×")} ÷ {preset.scale * 100}%
          </span>
        )}
        <button title="가로/세로 바꾸기" onClick={() => setSize(frame.h, frame.w)}>⟲</button>
        <button title="프레임 빼기" onClick={onRemove}>✕</button>
      </figcaption>

      <div className="wb-resize-box">
        <Device width={frame.w} height={frame.h} theme={theme} locale={locale}>
          {children}
        </Device>
        <span className="wb-handle wb-handle-x" onPointerDown={startDrag("x")} />
        <span className="wb-handle wb-handle-y" onPointerDown={startDrag("y")} />
        <span className="wb-handle wb-handle-xy" onPointerDown={startDrag("xy")} />
      </div>
    </figure>
  );
}

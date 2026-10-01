import { useEffect, type PointerEvent as ReactPointerEvent, type RefObject } from "react";

/** Screen transform of a pannable stage: content point p appears at (x + p.x·k, y + p.y·k). */
export type View = { x: number; y: number; k: number };

export const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** New view with zoom k2 that keeps the content point under screen point (cx, cy) fixed. */
export function zoomAround(v: View, k2: number, cx: number, cy: number): View {
  return { k: k2, x: cx - (cx - v.x) * (k2 / v.k), y: cy - (cy - v.y) * (k2 / v.k) };
}

/**
 * Figma-style wheel: plain wheel pans, Ctrl/⌘ + wheel (or trackpad pinch) zooms around the cursor.
 * Registered natively because React's wheel listener is passive and cannot preventDefault.
 */
export function useWheelPanZoom(
  ref: RefObject<HTMLElement | null>,
  getView: () => View,
  setView: (v: View) => void,
  limits: { min: number; max: number },
) {
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      if ((e.target as Element).closest?.("select")) return;
      e.preventDefault();
      const v = getView();
      if (e.ctrlKey || e.metaKey) {
        const rect = el.getBoundingClientRect();
        const speed = Math.abs(e.deltaY) < 50 ? 0.01 : 0.002;
        const k2 = clamp(v.k * Math.exp(-e.deltaY * speed), limits.min, limits.max);
        setView(zoomAround(v, k2, e.clientX - rect.left, e.clientY - rect.top));
      } else {
        const dx = e.shiftKey && !e.deltaX ? e.deltaY : e.deltaX;
        const dy = e.shiftKey && !e.deltaX ? 0 : e.deltaY;
        setView({ ...v, x: v.x - dx, y: v.y - dy });
      }
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  });
}

/** Pointer drag reporting screen-px deltas; `onEnd(moved)` tells a click (< 4px) from a drag. */
export function drag(e: ReactPointerEvent, onMove: (dx: number, dy: number) => void, onEnd: (moved: boolean) => void = () => {}) {
  const start = { x: e.clientX, y: e.clientY };
  let moved = false;
  const move = (ev: PointerEvent) => {
    const dx = ev.clientX - start.x;
    const dy = ev.clientY - start.y;
    if (!moved && Math.hypot(dx, dy) < 4) return;
    moved = true;
    onMove(dx, dy);
  };
  const up = () => {
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    onEnd(moved);
  };
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
}

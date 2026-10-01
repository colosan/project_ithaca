import { useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import type { Locale, Theme } from "@ithaca/kit";
import { Device } from "./Frame";
import { buildGraph, viewportById, viewports, type GraphEdge, type GraphNode, type Viewport } from "./registry";
import { usePref } from "./prefs";

type Pos = { x: number; y: number };
type Positions = Record<string, Pos>;
type View = { x: number; y: number; k: number };

const HEADER_H = 40;
const GAP_X = 240;
const GAP_Y = 160;
const ZOOM = { min: 0.08, max: 3 };
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Card footprint for a preview viewport: phones get narrow cards, tablets/desktops wide ones. */
function cardSize(vp: Viewport) {
  const w = vp.width <= 600 ? 300 : 560;
  const k = w / vp.width;
  return { w, h: Math.round(vp.height * k) + HEADER_H, k };
}

/**
 * Layered layout: BFS depth from one entry node becomes the column, order within a depth becomes the row.
 * Screens usually link back to the main shell, so "no incoming edges" finds nothing; the entry is the hub —
 * the node with the most outgoing links. Nodes it cannot reach start a column-0 stack of their own.
 */
function autoLayout(nodes: GraphNode[], edges: GraphEdge[], size: { w: number; h: number }): Positions {
  if (nodes.length === 0) return {};
  const outdegree = new Map(nodes.map((n) => [n.id, 0]));
  for (const e of edges) outdegree.set(e.from, (outdegree.get(e.from) ?? 0) + 1);
  const entry = [...nodes].sort((a, b) => outdegree.get(b.id)! - outdegree.get(a.id)!)[0].id;

  const depth = new Map([[entry, 0]]);
  const queue = [entry];
  while (queue.length) {
    const id = queue.shift()!;
    for (const e of edges)
      if (e.from === id && !depth.has(e.to)) {
        depth.set(e.to, depth.get(id)! + 1);
        queue.push(e.to);
      }
  }

  const rowsUsed = new Map<number, number>();
  const pos: Positions = {};
  for (const n of nodes) {
    const d = depth.get(n.id) ?? 0;
    const r = rowsUsed.get(d) ?? 0;
    rowsUsed.set(d, r + 1);
    pos[n.id] = { x: d * (size.w + GAP_X), y: r * (size.h + GAP_Y) };
  }
  // Center every column against the tallest one so the flow reads as a fan, not a staircase.
  const tallest = Math.max(...rowsUsed.values());
  for (const n of nodes) {
    const rows = rowsUsed.get(depth.get(n.id) ?? 0)!;
    pos[n.id].y += ((tallest - rows) * (size.h + GAP_Y)) / 2;
  }
  return pos;
}

/** Cubic edge between two cards. Forward and backward edges sit at different heights so a pair never overlaps. */
function edgeGeometry(a: Pos, b: Pos, size: { w: number; h: number }) {
  const sameColumn = Math.abs(b.x - a.x) < size.w;
  const forward = b.x >= a.x;
  const yOff = forward ? 0.38 : 0.62;
  const sy = a.y + size.h * yOff;
  const ty = b.y + size.h * yOff;
  let sx: number, tx: number, c1: number, c2: number;
  if (sameColumn) {
    sx = a.x + size.w;
    tx = b.x + size.w;
    const bulge = 120;
    c1 = sx + bulge;
    c2 = tx + bulge;
  } else {
    const dir = forward ? 1 : -1;
    sx = forward ? a.x + size.w : a.x;
    tx = forward ? b.x : b.x + size.w;
    const c = Math.max(80, Math.abs(tx - sx) / 2);
    c1 = sx + dir * c;
    c2 = tx - dir * c;
  }
  const d = `M ${sx} ${sy} C ${c1} ${sy}, ${c2} ${ty}, ${tx} ${ty}`;
  // Bezier midpoint (t = 0.5) for the label.
  const mid = { x: (sx + 3 * c1 + 3 * c2 + tx) / 8, y: (sy + 3 * sy + 3 * ty + ty) / 8 };
  return { d, mid };
}

export function Canvas({ theme, locale, onOpen }: {
  theme: Theme;
  locale: Locale;
  onOpen: (slug: string, state: string) => void;
}) {
  const { nodes, edges } = useMemo(buildGraph, []);
  const [previewId, setPreviewId] = usePref("canvas.preview", "iphone-15");
  const vp = viewportById[previewId] ?? viewports[0];
  const size = cardSize(vp);

  const [saved, setSaved] = useState<Positions>({});
  useEffect(() => {
    fetch("/__canvas")
      .then((r) => r.json())
      .then((j) => setSaved(j.positions ?? {}))
      .catch(() => {});
  }, []);
  const auto = useMemo(() => autoLayout(nodes, edges, size), [nodes, edges, size.w, size.h]);
  const pos = (id: string) => saved[id] ?? auto[id];

  const [view, setView] = useState<View>({ x: 80, y: 80, k: 0.8 });
  const viewRef = useRef(view);
  viewRef.current = view;
  const ref = useRef<HTMLDivElement>(null);

  // Figma-style wheel: plain wheel pans, Ctrl/⌘ + wheel (or trackpad pinch) zooms around the cursor.
  // Registered natively because React's wheel listener is passive and cannot preventDefault.
  useEffect(() => {
    const el = ref.current!;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      if (e.ctrlKey || e.metaKey) {
        const rect = el.getBoundingClientRect();
        const cx = e.clientX - rect.left;
        const cy = e.clientY - rect.top;
        const speed = Math.abs(e.deltaY) < 50 ? 0.01 : 0.002;
        setView((v) => {
          const k = clamp(v.k * Math.exp(-e.deltaY * speed), ZOOM.min, ZOOM.max);
          return { k, x: cx - (cx - v.x) * (k / v.k), y: cy - (cy - v.y) * (k / v.k) };
        });
      } else {
        const dx = e.shiftKey && !e.deltaX ? e.deltaY : e.deltaX;
        const dy = e.shiftKey && !e.deltaX ? 0 : e.deltaY;
        setView((v) => ({ ...v, x: v.x - dx, y: v.y - dy }));
      }
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, []);

  /** Shared pointer-drag helper: reports deltas in screen px; returns whether the pointer actually moved. */
  const drag = (e: ReactPointerEvent, onMove: (dx: number, dy: number) => void, onEnd: (moved: boolean) => void) => {
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
  };

  const onBackgroundDown = (e: ReactPointerEvent) => {
    if ((e.target as HTMLElement).closest(".wb-card, .wb-canvas-tools")) return;
    const start = viewRef.current;
    drag(e, (dx, dy) => setView({ ...start, x: start.x + dx, y: start.y + dy }), () => {});
  };

  const onCardDown = (node: GraphNode) => (e: ReactPointerEvent) => {
    e.stopPropagation();
    const origin = pos(node.id);
    const k = viewRef.current.k;
    let last = origin;
    drag(
      e,
      (dx, dy) => {
        last = { x: Math.round(origin.x + dx / k), y: Math.round(origin.y + dy / k) };
        setSaved((s) => ({ ...s, [node.id]: last }));
      },
      (moved) => {
        if (!moved) return onOpen(node.screen.slug, node.state);
        fetch("/__canvas", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: node.id, ...last }) });
      },
    );
  };

  const fit = () => {
    const el = ref.current;
    if (!el || nodes.length === 0) return;
    const ps = nodes.map((n) => pos(n.id));
    const minX = Math.min(...ps.map((p) => p.x));
    const minY = Math.min(...ps.map((p) => p.y));
    const maxX = Math.max(...ps.map((p) => p.x + size.w));
    const maxY = Math.max(...ps.map((p) => p.y + size.h));
    const pad = 80;
    const k = clamp(Math.min((el.clientWidth - pad * 2) / (maxX - minX), (el.clientHeight - pad * 2) / (maxY - minY)), ZOOM.min, 1.5);
    setView({ k, x: (el.clientWidth - (maxX - minX) * k) / 2 - minX * k, y: (el.clientHeight - (maxY - minY) * k) / 2 - minY * k });
  };

  const resetLayout = () => {
    setSaved({});
    fetch("/__canvas", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ reset: true }) });
  };

  return (
    <div ref={ref} className="wb-canvas" onPointerDown={onBackgroundDown}>
      <div className="wb-canvas-tools">
        <label>
          미리보기{" "}
          <select value={vp.id} onChange={(e) => setPreviewId(e.target.value)}>
            {viewports.map((v) => (
              <option key={v.id} value={v.id}>
                {v.platform} · {v.label} ({v.width}×{v.height})
              </option>
            ))}
          </select>
        </label>
        <span className="wb-muted">{Math.round(view.k * 100)}%</span>
        <button onClick={fit}>맞춤</button>
        <button onClick={resetLayout}>자동 정렬</button>
        <span className="wb-muted">휠 이동 · Ctrl+휠 확대 · 빈 곳 드래그 이동 · 카드 클릭 → 상세</span>
      </div>

      <div className="wb-canvas-layer" style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.k})` }}>
        <svg className="wb-edges" width="1" height="1">
          <defs>
            <marker id="wb-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
              <path d="M 0 0 L 10 5 L 0 10 z" />
            </marker>
          </defs>
          {edges.map((e) => {
            const { d } = edgeGeometry(pos(e.from), pos(e.to), size);
            return <path key={`${e.from}>${e.to}`} d={d} markerEnd="url(#wb-arrow)" />;
          })}
        </svg>

        {edges.map((e) => {
          const { mid } = edgeGeometry(pos(e.from), pos(e.to), size);
          return (
            <div key={`${e.from}>${e.to}:label`} className="wb-edge-label" style={{ left: mid.x, top: mid.y }}>
              {e.label[locale]}
            </div>
          );
        })}

        {nodes.map((n) => {
          const p = pos(n.id);
          return (
            <div key={n.id} className="wb-card" style={{ left: p.x, top: p.y, width: size.w }} onPointerDown={onCardDown(n)}>
              <header>
                <b>{n.screen.meta.title[locale]}</b>
                <span className="wb-chip">{n.state}</span>
              </header>
              <div className="wb-card-preview" style={{ height: size.h - HEADER_H }}>
                <div style={{ transform: `scale(${size.k})`, transformOrigin: "0 0" }}>
                  <Device width={vp.width} height={vp.height} platform={vp.os} theme={theme} locale={locale} className="wb-device-flat">
                    <n.screen.Prototype state={n.state} />
                  </Device>
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

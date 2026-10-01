import { useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import type { Locale, Theme } from "@ithaca/kit";
import { Device } from "./Frame";
import { usePref } from "./prefs";
import { buildGraph, specSummary, viewportById, viewports, type GraphEdge, type GraphNode, type Viewport } from "./registry";

/** Shortcuts stay off while typing in a field. The target can be window itself, which has no closest(). */
const isTyping = (e: KeyboardEvent) => e.target instanceof Element && !!e.target.closest("input, select, textarea");

type Pos = { x: number; y: number };
type Positions = Record<string, Pos>;
type View = { x: number; y: number; k: number };
type Size = { w: number; h: number; k: number };

const GAP_X = 120;
const GAP_Y = 160;
const ZOOM = { min: 0.05, max: 3 };
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Card footprint for a preview viewport: phones get narrow cards, tablets/desktops wide ones. */
function cardSize(vp: Viewport): Size {
  const w = vp.width <= 600 ? 260 : 520;
  const k = w / vp.width;
  return { w, h: Math.round(vp.height * k), k };
}

const PER_ROW = 4; // a lane wraps after this many cards
const COL_GAP = 320; // between lane columns — room for the left-gutter edges of the next column

/** Hub = the node with the most outgoing links (screens usually all link back to it). */
function hubOf(nodes: GraphNode[], edges: GraphEdge[]) {
  const out = new Map<string, number>();
  for (const e of edges) out.set(e.from, (out.get(e.from) ?? 0) + 1);
  return [...nodes].sort((a, b) => (out.get(b.id) ?? 0) - (out.get(a.id) ?? 0))[0];
}

/**
 * Lane layout: one lane per screen, its states left → right (wrapping after PER_ROW).
 * Lanes follow the navigation flow (BFS over screens from the hub); planned screens share the last lane.
 * Lanes are then packed into as many columns as best fit the viewport's aspect ratio.
 */
function laneLayout(nodes: GraphNode[], edges: GraphEdge[], size: Size, aspect: number): Positions {
  if (nodes.length === 0) return {};
  const slugOf = new Map(nodes.map((n) => [n.id, n.slug]));
  const order: string[] = [hubOf(nodes, edges).slug];
  for (let i = 0; i < order.length; i++) {
    for (const e of edges)
      if (slugOf.get(e.from) === order[i]) {
        const s = slugOf.get(e.to)!;
        if (!order.includes(s) && !nodes.find((n) => n.id === e.to)?.planned) order.push(s);
      }
  }
  for (const n of nodes) if (!n.planned && !order.includes(n.slug)) order.push(n.slug);

  const lanes = [
    ...order.map((slug) => nodes.filter((n) => n.slug === slug && !n.planned)),
    nodes.filter((n) => n.planned),
  ].filter((l) => l.length);
  const block = (l: GraphNode[]) => ({
    w: Math.min(l.length, PER_ROW) * (size.w + GAP_X) - GAP_X,
    h: Math.ceil(l.length / PER_ROW) * (size.h + GAP_Y),
  });

  // Try every column count; keep lane order, split columns at balanced heights; pick the best fit for `aspect`.
  let best: { cols: GraphNode[][][]; score: number } | null = null;
  const totalH = lanes.reduce((n, l) => n + block(l).h, 0);
  for (let c = 1; c <= lanes.length; c++) {
    const target = totalH / c;
    const cols: GraphNode[][][] = [[]];
    let h = 0;
    for (const l of lanes) {
      const bh = block(l).h;
      if (h > 0 && h + bh > target * 1.15 && cols.length < c) {
        cols.push([]);
        h = 0;
      }
      cols.at(-1)!.push(l);
      h += bh;
    }
    const W = cols.reduce((n, col) => n + Math.max(...col.map((l) => block(l).w)), 0) + COL_GAP * (cols.length - 1);
    const H = Math.max(...cols.map((col) => col.reduce((n, l) => n + block(l).h, 0)));
    const score = Math.min(aspect / W, 1 / H); // relative zoom that would fit a viewport of this aspect
    if (!best || score > best.score) best = { cols, score };
  }

  const pos: Positions = {};
  let x0 = 0;
  for (const col of best!.cols) {
    let y0 = 0;
    for (const lane of col) {
      lane.forEach((n, i) => {
        pos[n.id] = { x: x0 + (i % PER_ROW) * (size.w + GAP_X), y: y0 + Math.floor(i / PER_ROW) * (size.h + GAP_Y) };
      });
      y0 += block(lane).h;
    }
    x0 += Math.max(...col.map((l) => block(l).w)) + COL_GAP;
  }
  return pos;
}

/**
 * Edge routing tuned for lanes:
 * - same lane, neighbours → straight across the gap (forward high, backward low so a pair never overlaps)
 * - same lane, farther apart → arc over (forward) or under (backward) the cards in between
 * - different lanes → swing out through the left gutter; downward edges wider than upward ones
 */
function edgeGeometry(a: Pos, b: Pos, size: Size) {
  const { w, h } = size;
  const sameLane = Math.abs(a.y - b.y) < h / 2;
  let sx: number, sy: number, tx: number, ty: number, c1: Pos, c2: Pos;
  if (sameLane) {
    const forward = b.x > a.x;
    const adjacent = Math.abs(b.x - a.x) <= w + GAP_X + 1;
    if (adjacent) {
      const yOff = forward ? 0.42 : 0.58;
      sx = forward ? a.x + w : a.x;
      tx = forward ? b.x : b.x + w;
      sy = a.y + h * yOff;
      ty = b.y + h * yOff;
      const c = (tx - sx) / 2;
      c1 = { x: sx + c, y: sy };
      c2 = { x: tx - c, y: ty };
    } else {
      const arc = 140 + Math.abs(b.x - a.x) * 0.12;
      sx = a.x + w / 2;
      tx = b.x + w / 2;
      sy = forward ? a.y : a.y + h;
      ty = forward ? b.y : b.y + h;
      const dy = forward ? -arc : arc;
      c1 = { x: sx, y: sy + dy };
      c2 = { x: tx, y: ty + dy };
    }
  } else if (Math.abs(b.x - a.x) > w * 1.5) {
    // Different lane column: go straight across between the columns.
    const forward = b.x > a.x;
    sx = forward ? a.x + w : a.x;
    tx = forward ? b.x : b.x + w;
    sy = a.y + h * 0.5;
    ty = b.y + h * 0.3;
    const c = Math.max(80, Math.abs(tx - sx) / 2);
    c1 = { x: sx + (forward ? c : -c), y: sy };
    c2 = { x: tx - (forward ? c : -c), y: ty };
  } else {
    const down = b.y > a.y;
    const lanes = Math.max(1, Math.round(Math.abs(b.y - a.y) / (h + GAP_Y)));
    const g = (down ? 70 : 40) + lanes * (down ? 45 : 25);
    sx = a.x;
    tx = b.x;
    sy = a.y + h * (down ? 0.45 : 0.55);
    ty = b.y + h * (down ? 0.35 : 0.65);
    const gx = Math.min(sx, tx) - g;
    c1 = { x: gx, y: sy };
    c2 = { x: gx, y: ty };
  }
  const d = `M ${sx} ${sy} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${tx} ${ty}`;
  const mid = { x: (sx + 3 * c1.x + 3 * c2.x + tx) / 8, y: (sy + 3 * c1.y + 3 * c2.y + ty) / 8 };
  return { d, mid };
}

export function Canvas({ theme, locale, onOpen }: {
  theme: Theme;
  locale: Locale;
  onOpen: (slug: string, state: string | null) => void;
}) {
  const { nodes, edges } = useMemo(buildGraph, []);
  const [previewId, setPreviewId] = usePref("canvas.preview", "iphone-15");
  const vp = viewportById[previewId] ?? viewports[0];
  const size = cardSize(vp);

  const [saved, setSaved] = useState<Positions>({});
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    fetch("/__canvas")
      .then((r) => r.json())
      .then((j) => setSaved(j.positions ?? {}))
      .catch(() => {})
      .finally(() => setLoaded(true));
  }, []);
  // Viewport aspect, measured once on mount, decides how many lane columns the auto layout uses.
  const ref = useRef<HTMLDivElement>(null);
  const [aspect, setAspect] = useState(16 / 9);
  useLayoutEffect(() => {
    const el = ref.current;
    if (el && el.clientHeight > 0) setAspect(el.clientWidth / Math.max(1, el.clientHeight - 56));
  }, []);
  const auto = useMemo(() => laneLayout(nodes, edges, size, aspect), [nodes, edges, size.w, size.h, aspect]);
  const hub = useMemo(() => hubOf(nodes, edges), [nodes, edges]);
  // Edges that return to the hub from another screen (close, done) are noise until you hover their card.
  const isReturn = (e: GraphEdge) => e.to === hub?.id && e.from.split("#")[0] !== e.to.split("#")[0];
  const pos = (id: string) => saved[id] ?? auto[id];
  // Latest positions for callbacks that run after a state change (fit after reset).
  const posRef = useRef(pos);
  posRef.current = pos;

  const [storedView, setStoredView] = usePref<View | null>("canvas.view", null);
  const firstVisit = useRef(storedView === null);
  const [view, setView] = useState<View>(storedView ?? { x: 80, y: 80, k: 0.5 });
  useEffect(() => setStoredView(view), [view]);
  const viewRef = useRef(view);
  viewRef.current = view;

  const [hover, setHover] = useState<string | null>(null);
  const [labelsAlways, setLabelsAlways] = usePref("canvas.labels", false);

  const fit = () => {
    const el = ref.current;
    if (!el || nodes.length === 0) return;
    const ps = nodes.map((n) => posRef.current(n.id));
    const minX = Math.min(...ps.map((p) => p.x)) - 200; // room for the left gutter edges
    const minY = Math.min(...ps.map((p) => p.y)) - 40; // room for titles
    const maxX = Math.max(...ps.map((p) => p.x + size.w));
    const maxY = Math.max(...ps.map((p) => p.y + size.h));
    const pad = 40;
    const top = 56; // toolbar
    const k = clamp(Math.min((el.clientWidth - pad * 2) / (maxX - minX), (el.clientHeight - top - pad * 2) / (maxY - minY)), ZOOM.min, 1);
    setView({
      k,
      x: (el.clientWidth - (maxX - minX) * k) / 2 - minX * k,
      y: top + (el.clientHeight - top - (maxY - minY) * k) / 2 - minY * k,
    });
  };

  // First visit: fit once positions are known.
  useEffect(() => {
    if (loaded && firstVisit.current) {
      firstVisit.current = false;
      fit();
    }
  }, [loaded, auto]);

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

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e)) return;
      if (e.key === "f" || e.key === "F") fit();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  /** Shared pointer-drag helper: reports deltas in screen px; tells the end handler whether the pointer moved. */
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
        if (!moved) return onOpen(node.slug, node.state);
        fetch("/__canvas", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ id: node.id, ...last }) });
      },
    );
  };

  const resetLayout = () => {
    setSaved({});
    fetch("/__canvas", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ reset: true }) });
    setTimeout(fit, 50);
  };

  const toScreen = (p: Pos) => ({ left: p.x * view.k + view.x, top: p.y * view.k + view.y });

  // One header per screen lane (planned screens share one lane).
  const lanes = useMemo(() => {
    const out: { slug: string; title: { ko: string; en: string }; count: number; first: string }[] = [];
    for (const n of nodes) {
      const key = n.planned ? "@planned" : n.slug;
      const lane = out.find((l) => l.slug === key);
      if (lane) lane.count++;
      else out.push({ slug: key, title: n.planned ? { ko: "계획됨", en: "Planned" } : n.title, count: 1, first: n.id });
    }
    return out;
  }, [nodes]);
  const related = (e: GraphEdge) => hover !== null && (e.from === hover || e.to === hover);

  return (
    <div ref={ref} className="wb-canvas" onPointerDown={onBackgroundDown}>
      <div className="wb-canvas-tools">
        <label title="카드에 그릴 기기">
          미리보기{" "}
          <select value={vp.id} onChange={(e) => setPreviewId(e.target.value)}>
            {viewports.map((v) => (
              <option key={v.id} value={v.id}>
                {v.platform} · {v.label} ({v.width}×{v.height})
              </option>
            ))}
          </select>
        </label>
        <span className="wb-muted wb-zoom">{Math.round(view.k * 100)}%</span>
        <button onClick={fit} title="전체 맞춤 (F)">맞춤</button>
        <button onClick={resetLayout} title="끌어 둔 위치를 지우고 화면별 줄 배치로">자동 정렬</button>
        <label className="wb-check" title="끄면 카드에 마우스를 올렸을 때만 보임">
          <input type="checkbox" checked={labelsAlways} onChange={(e) => setLabelsAlways(e.target.checked)} /> 경로 이름
        </label>
        <span className="wb-hint" title="휠: 이동 · Ctrl/⌘+휠: 확대 · 빈 곳 드래그: 이동 · 카드 드래그: 위치 · 카드 클릭: 상세 · F: 맞춤">?</span>
      </div>

      <div className="wb-canvas-layer" style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.k})` }}>
        <svg className="wb-edges" width="1" height="1">
          <defs>
            <marker id="wb-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
              <path d="M 0 0 L 10 5 L 0 10 z" />
            </marker>
            <marker id="wb-arrow-on" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
              <path d="M 0 0 L 10 5 L 0 10 z" className="wb-arrow-on" />
            </marker>
          </defs>
          {edges.map((e) => {
            const on = related(e);
            if (isReturn(e) && !on) return null;
            const { d } = edgeGeometry(pos(e.from), pos(e.to), size);
            return (
              <path
                key={`${e.from}>${e.to}`}
                d={d}
                className={on ? "wb-edge-on" : hover ? "wb-edge-dim" : undefined}
                style={{ strokeWidth: (on ? 2.5 : 1.5) / view.k }}
                markerEnd={on ? "url(#wb-arrow-on)" : "url(#wb-arrow)"}
              />
            );
          })}
        </svg>

        {nodes.map((n) => {
          const p = pos(n.id);
          return (
            <div
              key={n.id}
              className={`wb-card ${n.planned ? "wb-card-planned" : ""} ${hover === n.id ? "wb-card-hover" : ""}`}
              style={{ left: p.x, top: p.y, width: size.w, height: size.h }}
              onPointerDown={onCardDown(n)}
              onPointerEnter={() => setHover(n.id)}
              onPointerLeave={() => setHover((h) => (h === n.id ? null : h))}
            >
              {n.screen ? (
                <div className="wb-card-preview" style={{ transform: `scale(${size.k})` }}>
                  <Device width={vp.width} height={vp.height} platform={vp.os} theme={theme} locale={locale} className="wb-device-flat">
                    <n.screen.Prototype state={n.state!} />
                  </Device>
                </div>
              ) : (
                <div className="wb-planned-body">
                  <b>계획됨</b>
                  <p>{specSummary(n.planned!.spec)}</p>
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Unscaled overlay: lane titles, state chips and route labels stay readable at any zoom. */}
      <div className="wb-canvas-overlay">
        {lanes.map(({ slug, title, count, first }) => {
          const s = toScreen(pos(first));
          return (
            <div key={slug} className={`wb-lane-title ${hover?.split("#")[0] === slug ? "wb-on" : ""}`} style={{ left: s.left, top: s.top - 26 }}>
              {title[locale]} <span className="wb-muted">{count > 1 ? `· ${count}` : ""}</span>
            </div>
          );
        })}
        {size.w * view.k >= 44 &&
          nodes.map((n) => {
            const s = toScreen(pos(n.id));
            return (
              <span key={n.id} className={n.planned ? "wb-chip wb-chip-planned wb-card-chip" : "wb-chip wb-card-chip"} style={{ left: s.left + 4, top: s.top + 4 }}>
                {n.planned ? n.title[locale] : n.state}
              </span>
            );
          })}
        {edges.map((e) => {
          if (!related(e) && (!labelsAlways || isReturn(e))) return null;
          const { mid } = edgeGeometry(pos(e.from), pos(e.to), size);
          const s = toScreen(mid);
          return (
            <div key={`${e.from}>${e.to}`} className={`wb-edge-label ${related(e) ? "wb-on" : ""}`} style={s}>
              {e.label[locale]}
            </div>
          );
        })}
      </div>
    </div>
  );
}

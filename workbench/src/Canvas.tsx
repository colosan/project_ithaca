import { useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import type { Locale, Theme } from "@ithaca/kit";
import { cardSize, collapseGraph, edgeGeometry, hubOf, laneLayout, type Pos } from "./canvasLayout";
import { Device } from "./Frame";
import { clamp, drag, useWheelPanZoom, type View } from "./panzoom";
import { usePref } from "./prefs";
import { buildGraph, specSummary, viewportById, viewports, type GraphEdge, type GraphNode } from "./registry";
import { commit, gesture, useStore } from "./store";
import { loadPositions, positionsStore, type Positions } from "./stores";

/** Shortcuts stay off while typing in a field. The target can be window itself, which has no closest(). */
const isTyping = (e: KeyboardEvent) => e.target instanceof Element && !!e.target.closest("input, select, textarea");

const ZOOM = { min: 0.05, max: 3 };

export function Canvas({ theme, locale, onOpen }: {
  theme: Theme;
  locale: Locale;
  onOpen: (slug: string, state: string | null) => void;
}) {
  const full = useMemo(buildGraph, []);
  const [collapsedList, setCollapsed] = usePref<string[]>("canvas.collapsed", ["app-shell"]);
  const collapsed = useMemo(() => new Set(collapsedList), [collapsedList]);
  const { nodes, edges } = useMemo(() => collapseGraph(full.nodes, full.edges, collapsed), [full, collapsed]);
  const stateCount = (slug: string) => full.nodes.filter((n) => n.slug === slug && n.screen).length;
  const foldableSlugs = useMemo(
    () => [...new Set(full.nodes.filter((n) => n.screen && n.state !== n.screen.states[0]).map((n) => n.slug))],
    [full],
  );

  const [previewId, setPreviewId] = usePref("canvas.preview", "iphone-15");
  const vp = viewportById[previewId] ?? viewports[0];
  const size = cardSize(vp);

  useEffect(loadPositions, []);
  const stored = useStore(positionsStore);
  const loaded = stored !== null;
  const saved: Positions = stored ?? {};

  // Viewport aspect, measured once on mount, decides how many lane columns the auto layout uses.
  const ref = useRef<HTMLDivElement>(null);
  const [aspect, setAspect] = useState(16 / 9);
  useLayoutEffect(() => {
    const el = ref.current;
    if (el && el.clientHeight > 0) setAspect(el.clientWidth / Math.max(1, el.clientHeight - 56));
  }, []);
  const auto = useMemo(() => laneLayout(nodes, edges, size, aspect), [nodes, edges, size.w, size.h, aspect]);
  const pos = (id: string): Pos => saved[id] ?? auto[id];
  const posRef = useRef(pos);
  posRef.current = pos;

  const hub = useMemo(() => hubOf(nodes, edges), [nodes, edges]);
  // Edges that return to the hub from another screen (close, done) are noise until you hover their card.
  const isReturn = (e: GraphEdge) => e.to === hub?.id && e.from.split("#")[0] !== e.to.split("#")[0];

  // The view lives in a pref; null means "fit on next render" (first visit, or after reset to initial state).
  const [storedView, setView] = usePref<View | null>("canvas.view", null);
  const view: View = storedView ?? { x: 80, y: 80, k: 0.5 };
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

  useEffect(() => {
    if (loaded && storedView === null) fit();
  }, [loaded, storedView === null, auto]);

  useWheelPanZoom(ref, () => viewRef.current, setView, ZOOM);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e)) return;
      if (e.key === "f" || e.key === "F") fit();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const onBackgroundDown = (e: ReactPointerEvent) => {
    if ((e.target as HTMLElement).closest(".wb-card, .wb-canvas-tools, .wb-foldable")) return;
    const start = viewRef.current;
    drag(e, (dx, dy) => setView({ ...start, x: start.x + dx, y: start.y + dy }));
  };

  // Card drag: previews while moving, one undo step on release. A click (no movement) opens the card.
  const onCardDown = (node: GraphNode) => (e: ReactPointerEvent) => {
    e.stopPropagation();
    const origin = pos(node.id);
    const k = viewRef.current.k;
    let g: ReturnType<typeof gesture<Positions | null>> | null = null;
    drag(
      e,
      (dx, dy) => {
        g ??= gesture(positionsStore);
        const next = { x: Math.round(origin.x + dx / k), y: Math.round(origin.y + dy / k) };
        g.move({ ...(positionsStore.get() ?? {}), [node.id]: next });
      },
      (moved) => {
        if (!moved) return onOpen(node.slug, node.state);
        g?.end(`카드 이동 · ${node.title.ko}${node.state ? ` ${node.state}` : ""}`);
      },
    );
  };

  const resetLayout = () => {
    commit(positionsStore, {}, "자동 정렬");
    setTimeout(fit, 50);
  };

  const toggleLane = (slug: string) =>
    setCollapsed((list) => (list.includes(slug) ? list.filter((s) => s !== slug) : [...list, slug]));

  const toScreen = (p: Pos) => ({ left: p.x * view.k + view.x, top: p.y * view.k + view.y });
  const related = (e: GraphEdge) => hover !== null && (e.from === hover || e.to === hover);

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
        <button onClick={resetLayout} title="끌어 둔 카드 위치를 지우고 화면별 줄 배치로 (Ctrl+Z 로 되돌림)">자동 정렬</button>
        <button
          onClick={() => setCollapsed(collapsed.size ? [] : foldableSlugs)}
          title="상태가 여러 개인 화면을 모두 접기 / 펴기"
        >
          {collapsed.size ? "모두 펴기" : "모두 접기"}
        </button>
        <label className="wb-check" title="끄면 카드에 마우스를 올렸을 때만 보임">
          <input type="checkbox" checked={labelsAlways} onChange={(e) => setLabelsAlways(e.target.checked)} /> 경로 이름
        </label>
        <span
          className="wb-hint"
          title="휠: 이동 · Ctrl/⌘+휠: 확대 · 빈 곳 드래그: 이동 · 카드 드래그: 위치 · 카드 클릭: 상세 · 줄 제목 ▸ 클릭: 펴기/접기 · F: 맞춤 · Ctrl+Z: 되돌리기"
        >
          ?
        </span>
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
          const total = slug === "@planned" ? count : stateCount(slug);
          const foldable = slug !== "@planned" && total > 1;
          const isCollapsed = collapsed.has(slug);
          return (
            <div
              key={slug}
              className={`wb-lane-title ${foldable ? "wb-foldable" : ""} ${hover?.split("#")[0] === slug ? "wb-on" : ""}`}
              style={{ left: s.left, top: s.top - 26 }}
              onClick={foldable ? () => toggleLane(slug) : undefined}
              title={foldable ? (isCollapsed ? "펴기 — 모든 상태 보기" : "접기 — 대표 상태만") : undefined}
            >
              {foldable && <span className="wb-fold">{isCollapsed ? "▸" : "▾"}</span>}
              {title[locale]} <span className="wb-muted">{total > 1 ? `· ${total}` : ""}</span>
            </div>
          );
        })}
        {size.w * view.k >= 44 &&
          nodes.map((n) => {
            const s = toScreen(pos(n.id));
            const hiddenStates = n.screen && collapsed.has(n.slug) ? stateCount(n.slug) - 1 : 0;
            return (
              <span
                key={n.id}
                className={n.planned ? "wb-chip wb-chip-planned wb-card-chip" : "wb-chip wb-card-chip"}
                style={{ left: s.left + 4, top: s.top + 4 }}
              >
                {n.planned ? n.title[locale] : n.state}
                {hiddenStates > 0 ? ` +${hiddenStates}` : ""}
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

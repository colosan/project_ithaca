import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import type { Locale, Platform, Theme } from "@ithaca/kit";
import { Canvas } from "./Canvas";
import { CAPTION_H, CAPTION_W, presetsOf, ResizableFrame, SECTORS, type FrameEdit, type FrameSpec } from "./Frame";
import { redo, undo, useHistory } from "./history";
import { InfoPanel } from "./InfoPanel";
import { clamp, drag, useWheelPanZoom, zoomAround, type View } from "./panzoom";
import { usePref } from "./prefs";
import { planned, plannedBySlug, screenBySlug, screens, viewportById, type PlannedScreen, type Screen } from "./registry";
import { ScreenList } from "./ScreenList";
import { commit, gesture, useStore } from "./store";
import { defaultFrames, framesStore, newFrame, resetAll } from "./stores";
import { Sweep } from "./Sweep";
import { TokensPage } from "./TokensPage";

/** Shortcuts stay off while typing in a field. The target can be window itself, which has no closest(). */
const isTyping = (e: KeyboardEvent) => e.target instanceof Element && !!e.target.closest("input, select, textarea");

// ── Routing (hash) ───────────────────────────────────────────────────────

type Route =
  | { view: "home" }
  | { view: "tokens" }
  | { view: "screen"; slug: string; state: string }
  | { view: "planned"; slug: string };

function parseHash(): Route {
  const [view, slug, state] = location.hash.replace(/^#\/?/, "").split("/");
  if (view === "tokens") return { view: "tokens" };
  if (view === "screen" && slug) {
    const screen = screenBySlug[slug];
    if (screen) return { view: "screen", slug, state: screen.states.includes(state) ? state : screen.states[0] };
    if (plannedBySlug[slug]) return { view: "planned", slug };
  }
  return { view: "home" };
}

const toHash = (r: Route) =>
  r.view === "screen" ? `#/screen/${r.slug}/${r.state}` : r.view === "planned" ? `#/screen/${r.slug}` : r.view === "tokens" ? "#/tokens" : "#/";

const go = (r: Route) => {
  location.hash = toHash(r);
};
const open = (slug: string, state: string | null) =>
  go(state ? { view: "screen", slug, state } : { view: "planned", slug });

/** Element size that follows window resizes too (ResizeObserver alone stalls while the window is not painting). */
function useSize<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setSize((s) => (s.w === el.clientWidth && s.h === el.clientHeight ? s : { w: el.clientWidth, h: el.clientHeight }));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    window.addEventListener("resize", measure);
    return () => {
      ro.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, []);
  return [ref, size] as const;
}

// ── App ──────────────────────────────────────────────────────────────────

export function App() {
  const [route, setRoute] = useState<Route>(parseHash);
  useEffect(() => {
    const onHash = () => setRoute(parseHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const [theme, setTheme] = usePref<Theme | "both">("theme", "light");
  const [locale, setLocale] = usePref<Locale>("locale", "ko");
  const [homeView, setHomeView] = usePref<"flow" | "list">("home.view", "flow");
  const singleTheme: Theme = theme === "dark" ? "dark" : "light";
  const history = useHistory();

  // Global keys: Esc → home, Ctrl/⌘+Z undo, Ctrl/⌘+Shift+Z or Ctrl+Y redo. Fields keep their own text undo.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e)) return;
      const mod = e.ctrlKey || e.metaKey;
      const k = e.key.toLowerCase();
      if (mod && k === "z") {
        e.preventDefault();
        if (e.shiftKey) redo();
        else undo();
      } else if (mod && k === "y") {
        e.preventDefault();
        redo();
      } else if (e.key === "Escape" && route.view !== "home") go({ view: "home" });
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [route.view]);

  const onScreen = route.view === "screen" || route.view === "planned";

  return (
    <div className="wb">
      <header className="wb-top">
        <button className="wb-logo" onClick={() => go({ view: "home" })} title="홈 (Esc)">
          <span className="wb-logo-mark">◐</span> Ithaca <span className="wb-muted">workbench</span>
        </button>

        <nav className="wb-tabs">
          <button className={route.view === "home" || onScreen ? "wb-active" : undefined} onClick={() => go({ view: "home" })}>화면</button>
          <button className={route.view === "tokens" ? "wb-active" : undefined} onClick={() => go({ view: "tokens" })}>토큰</button>
        </nav>

        {route.view === "home" && (
          <Seg value={homeView} options={[["flow", "흐름"], ["list", "목록"]]} onChange={setHomeView} />
        )}
        {onScreen && (
          <button className="wb-back" onClick={() => window.history.back()} title="이전 화면 (프로토타입 링크로 왔을 때 돌아가기)">←</button>
        )}
        {onScreen && <ScreenSwitcher current={route.slug} locale={locale} />}

        <div className="wb-history">
          <button disabled={!history.undoLabel} onClick={undo} title={history.undoLabel ? `되돌리기: ${history.undoLabel} (Ctrl+Z)` : "되돌릴 것 없음"}>↶</button>
          <button disabled={!history.redoLabel} onClick={redo} title={history.redoLabel ? `다시 실행: ${history.redoLabel} (Ctrl+Shift+Z)` : "다시 실행할 것 없음"}>↷</button>
          <button onClick={resetAll} title="프레임 · 카드 위치 · 보기 설정을 모두 처음 상태로 (Ctrl+Z 로 되돌릴 수 있음)">처음 상태로</button>
        </div>

        <div className="wb-spacer" />
        <Seg label="테마" value={theme} options={[["light", "라이트"], ["dark", "다크"], ["both", "둘 다"]]} onChange={setTheme} />
        <Seg label="UI 언어" value={locale} options={[["ko", "한국어"], ["en", "English"]]} onChange={setLocale} />
      </header>

      {route.view === "home" &&
        (homeView === "flow" ? (
          <Canvas theme={singleTheme} locale={locale} onOpen={open} />
        ) : (
          <ScreenList theme={singleTheme} locale={locale} onOpen={open} />
        ))}
      {route.view === "tokens" && (
        <main className="wb-scroll">
          <TokensPage />
        </main>
      )}
      {route.view === "screen" && (
        <ScreenDetail
          key={route.slug}
          screen={screenBySlug[route.slug]}
          state={route.state}
          themes={theme === "both" ? ["light", "dark"] : [theme]}
          locale={locale}
        />
      )}
      {route.view === "planned" && <PlannedDetail screen={plannedBySlug[route.slug]} locale={locale} />}

      <Toast flash={history.flash} />
    </div>
  );
}

/** Brief confirmation after undo/redo, so a change made in another view is not invisible. */
function Toast({ flash }: { flash: { text: string; at: number } | null }) {
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    if (!flash) return;
    setVisible(true);
    const id = setTimeout(() => setVisible(false), 1800);
    return () => clearTimeout(id);
  }, [flash?.at]);
  return flash && visible ? <div className="wb-toast">{flash.text}</div> : null;
}

/** Jump to any screen (built or planned) from the top bar. */
function ScreenSwitcher({ current, locale }: { current: string; locale: Locale }) {
  return (
    <select className="wb-switcher" value={current} onChange={(e) => open(e.target.value, screenBySlug[e.target.value]?.states[0] ?? null)}>
      <optgroup label="화면">
        {screens.map((s) => <option key={s.slug} value={s.slug}>{s.meta.title[locale]}</option>)}
      </optgroup>
      {planned.length > 0 && (
        <optgroup label="계획됨">
          {planned.map((p) => <option key={p.slug} value={p.slug}>{p.meta.title[locale]}</option>)}
        </optgroup>
      )}
    </select>
  );
}

// ── Screen detail: device sectors on a pannable stage ────────────────────

// All spacing is in screen px, so gaps stay generous whatever the zoom.
const FRAME_GAP = 48;
const SECTOR_GAP = 80;
const SECTOR_PAD = 20;
const SECTOR_HEAD = 40;
const EMPTY_SECTOR_H = 120;
const MARGIN = 48;
const ROW_LABEL = 28;
const ZOOM = { min: 0.05, max: 2 };

type SectorGroup = { os: Platform; name: string; frames: FrameSpec[] };

/** Size of one sector box in layout px at zoom z (frames in a single row, captions counter-zoomed). */
function sectorBox(g: SectorGroup, z: number) {
  const inner = g.frames.length
    ? g.frames.reduce((n, f) => n + Math.max(f.w, CAPTION_W / z), 0) + (FRAME_GAP / z) * (g.frames.length - 1)
    : CAPTION_W / z;
  const tallest = g.frames.length ? Math.max(...g.frames.map((f) => f.h + CAPTION_H / z)) : EMPTY_SECTOR_H / z;
  return { w: inner + (SECTOR_PAD * 2) / z, h: tallest + (SECTOR_PAD * 2 + SECTOR_HEAD) / z };
}

/** Sector boxes wrapped into rows within wrapW (layout px). Returns the content size in layout px. */
function layoutSectors(groups: SectorGroup[], wrapW: number, z: number) {
  const gap = SECTOR_GAP / z;
  let height = 0;
  let line = 0;
  let maxLine = 0;
  let rowH = 0;
  for (const g of groups) {
    const b = sectorBox(g, z);
    if (line > 0 && line + gap + b.w > wrapW) {
      height += rowH + gap;
      maxLine = Math.max(maxLine, line);
      line = 0;
      rowH = 0;
    }
    line += (line > 0 ? gap : 0) + b.w;
    rowH = Math.max(rowH, b.h);
  }
  return { w: Math.max(maxLine, line), h: height + rowH };
}

function ScreenDetail({ screen, state, themes, locale }: { screen: Screen; state: string; themes: Theme[]; locale: Locale }) {
  const frames = useStore(framesStore);
  const [visible, setVisible] = usePref<Platform[]>("detail.sectors", SECTORS.map((s) => s.os));
  const [showIssues, setShowIssues] = usePref("detail.issues", true);
  const [sweep, setSweep] = usePref("detail.sweep", false);
  const [info, setInfo] = usePref("detail.info", true);
  // null = fit (recomputed whenever the stage or frames change); a View once you pan or zoom yourself.
  const [manual, setManual] = usePref<View | null>("detail.view", null);
  const [stageRef, stage] = useSize<HTMLDivElement>();

  // Focus: one frame alone, large, still interactive. Esc or the exit button returns.
  // A pref (not local state) so focus survives clicking through to another screen.
  const [focusId, setFocusId] = usePref<string | null>("detail.focus", null);
  const focused = frames.find((f) => f.id === focusId) ?? null;
  const focus = (id: string | null) => {
    setFocusId(id);
    setManual(null); // re-fit for the new set of frames
  };

  const groups: SectorGroup[] = focused
    ? SECTORS.filter((s) => s.os === focused.platform).map((s) => ({ ...s, frames: [focused] }))
    : SECTORS.filter((s) => visible.includes(s.os)).map((s) => ({ ...s, frames: frames.filter((f) => f.platform === s.os) }));

  /**
   * Fit: show everything if that is still readable (zoom ≥ FIT_READABLE). Otherwise fit the widest sector to the
   * width and let the rest continue below — wheel scrolls down. Captions, headers and gaps keep their screen size,
   * so in a small window "everything at once" would only be reachable at an unreadable zoom.
   */
  const fit = (() => {
    const FIT_READABLE = 0.22;
    const availW = Math.max(1, stage.w - MARGIN * 2);
    const availH = Math.max(1, stage.h - MARGIN * 2);
    const rowLabels = themes.length > 1 ? themes.length * ROW_LABEL : 0;
    const totalH = (box: { h: number }, z: number) => (box.h * themes.length + (SECTOR_GAP / z) * (themes.length - 1)) * z + rowLabels;
    let z = 1;
    let box = layoutSectors(groups, availW / z, z);
    if (focused) {
      // Focus is for looking closely: width decides, up to actual size; a tall frame continues below (wheel).
      while (z > ZOOM.min && sectorBox(groups[0], z).w * z > availW) z *= 0.96;
      box = layoutSectors(groups, availW / z, z);
      return { wrapW: availW / z, view: { k: z, x: (stage.w - box.w * z) / 2, y: Math.max(MARGIN, (stage.h - totalH(box, z)) / 2) } as View };
    }
    while (z > FIT_READABLE && totalH(box, z) > availH) {
      z *= 0.96;
      box = layoutSectors(groups, availW / z, z);
    }
    if (totalH(box, z) > availH) {
      // Width-only: the largest zoom at which no single sector is wider than the stage.
      z = 1;
      while (z > ZOOM.min && Math.max(...groups.map((g) => sectorBox(g, z).w)) * z > availW) z *= 0.96;
      box = layoutSectors(groups, availW / z, z);
    }
    return {
      wrapW: availW / z,
      view: { k: z, x: (stage.w - box.w * z) / 2, y: Math.max(MARGIN, (stage.h - totalH(box, z)) / 2) } as View,
    };
  })();
  const view = manual ?? fit.view;
  const k = view.k;
  const viewRef = useRef(view);
  viewRef.current = view;
  const setView = (v: View) => setManual(v);

  useWheelPanZoom(stageRef, () => viewRef.current, setView, ZOOM);

  // Sectors scrolled out of the stage, so you know there is more above or below (and can jump there).
  const [offstage, setOffstage] = useState<{ above: string[]; below: string[] }>({ above: [], below: [] });
  useEffect(() => {
    const id = setTimeout(() => {
      const el = stageRef.current;
      if (!el) return;
      const box = el.getBoundingClientRect();
      const above: string[] = [];
      const below: string[] = [];
      el.querySelectorAll<HTMLElement>(".wb-sector").forEach((s) => {
        const r = s.getBoundingClientRect();
        const name = s.dataset.name!;
        if (r.bottom < box.top + 40 && !above.includes(name)) above.push(name);
        else if (r.top > box.bottom - 40 && !below.includes(name)) below.push(name);
      });
      setOffstage((prev) => (prev.above.join() === above.join() && prev.below.join() === below.join() ? prev : { above, below }));
    }, 80);
    return () => clearTimeout(id);
  });
  /** Pan so the named sector's top sits at the margin. */
  const reveal = (name: string) => {
    const el = stageRef.current?.querySelector<HTMLElement>(`.wb-sector[data-name="${name}"]`);
    if (!el || !stageRef.current) return;
    const dy = el.getBoundingClientRect().top - stageRef.current.getBoundingClientRect().top - MARGIN;
    setView({ ...viewRef.current, y: viewRef.current.y - dy });
  };

  // Space held → panning anywhere (like Figma). Tracked so prototypes keep their clicks otherwise.
  const [spaceDown, setSpaceDown] = useState(false);
  useEffect(() => {
    const down = (e: KeyboardEvent) => {
      if (e.code === "Space" && !isTyping(e)) {
        e.preventDefault();
        setSpaceDown(true);
      }
    };
    const up = (e: KeyboardEvent) => e.code === "Space" && setSpaceDown(false);
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    return () => {
      window.removeEventListener("keydown", down);
      window.removeEventListener("keyup", up);
    };
  }, []);

  /**
   * Pan by dragging the empty stage or sector boxes, with Space held, or with the middle button.
   * Prototypes keep their own clicks; captions and resize handles keep theirs.
   */
  const onStageDown = (e: ReactPointerEvent) => {
    const t = e.target as HTMLElement;
    const forced = spaceDown || e.button === 1;
    if (!forced && t.closest(".wb-device, figcaption, .wb-sector-head, .wb-handle, button, select, input")) return;
    if (e.button === 1) e.preventDefault(); // no autoscroll
    const start = viewRef.current;
    drag(e, (dx, dy) => setView({ ...start, x: start.x + dx, y: start.y + dy }));
  };

  /** Links inside a prototype open their target here, so a flow can be walked by clicking. */
  const navigate = (to: string) => {
    const [slug, st] = to.split("#");
    open(slug, st ?? screenBySlug[slug]?.states[0] ?? null);
  };

  const zoomTo = (z: number) => setView(zoomAround(view, clamp(z, ZOOM.min, ZOOM.max), stage.w / 2, stage.h / 2));

  // ── Frame edits (all undoable) ──
  const replace = (list: FrameSpec[], f: FrameSpec) => list.map((x) => (x.id === f.id ? f : x));
  const dragRef = useRef<ReturnType<typeof gesture<FrameSpec[]>> | null>(null);
  const edit: FrameEdit = {
    commit: (f, label, key) => commit(framesStore, replace(framesStore.get(), f), label, key),
    dragStart: () => {
      dragRef.current = gesture(framesStore);
    },
    dragMove: (f) => dragRef.current?.move(replace(framesStore.get(), f)),
    dragEnd: (f) => {
      dragRef.current?.end(`프레임 크기 ${f.w}×${f.h}`);
      dragRef.current = null;
    },
  };
  const sectorName = (os: Platform) => SECTORS.find((s) => s.os === os)!.name;
  /** Swap with the previous/next frame of the same sector. */
  const move = (f: FrameSpec, dir: -1 | 1) => {
    const list = framesStore.get();
    const same = list.map((x, i) => [x, i] as const).filter(([x]) => x.platform === f.platform);
    const at = same.findIndex(([x]) => x.id === f.id);
    const other = same[at + dir];
    if (!other) return;
    const next = [...list];
    [next[same[at][1]], next[other[1]]] = [next[other[1]], next[same[at][1]]];
    commit(framesStore, next, `${sectorName(f.platform)} 프레임 순서`);
  };
  const add = (presetId: string) => {
    const f = newFrame(presetId);
    commit(framesStore, [...framesStore.get(), f], `${sectorName(f.platform)} 프레임 추가`);
  };

  useEffect(() => {
    const onEsc = (e: KeyboardEvent) => {
      if (e.key === "Escape" && focusId && !isTyping(e)) {
        e.stopPropagation();
        focus(null);
      }
    };
    window.addEventListener("keydown", onEsc, true);
    return () => window.removeEventListener("keydown", onEsc, true);
  });

  // Keys: ←/→ state, [/] screen, F fit, I info panel.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e) || e.ctrlKey || e.metaKey) return;
      const i = screen.states.indexOf(state);
      if (e.key === "ArrowRight") open(screen.slug, screen.states[(i + 1) % screen.states.length]);
      else if (e.key === "ArrowLeft") open(screen.slug, screen.states[(i - 1 + screen.states.length) % screen.states.length]);
      else if (e.key === "]" || e.key === "[") {
        const j = screens.findIndex((s) => s.slug === screen.slug);
        const next = screens[(j + (e.key === "]" ? 1 : -1) + screens.length) % screens.length];
        open(next.slug, next.states[0]);
      } else if (e.key === "f" || e.key === "F") setManual(null);
      else if (e.key === "i" || e.key === "I") setInfo((v) => !v);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const zoomOptions: [string, string][] = [["fit", "맞춤"], ["0.25", "25%"], ["0.5", "50%"], ["1", "100%"]];

  return (
    <div className="wb-detail" style={{ gridTemplateColumns: info ? "1fr auto" : "1fr" }}>
      <main className="wb-detail-main">
        <div className="wb-toolbar">
          <Seg label="상태" value={state} options={screen.states.map((s) => [s, s] as const)} onChange={(s) => open(screen.slug, s)} />
          {focused && (
            <button className="wb-focus-exit" onClick={() => focus(null)} title="모든 프레임 보기 (Esc)">
              ◱ 전체 보기 <span className="wb-muted">— {viewportById[focused.base ?? focused.preset ?? ""]?.label ?? "직접 조절"} 만 보는 중</span>
            </button>
          )}
          <div className="wb-seg" title="보고 싶은 기기 구역만 켠다" style={focused ? { display: "none" } : undefined}>
            <span>기기</span>
            {SECTORS.map((s) => (
              <button
                key={s.os}
                className={visible.includes(s.os) ? "wb-active" : undefined}
                onClick={() => setVisible((v) => (v.includes(s.os) ? v.filter((x) => x !== s.os) : SECTORS.map((x) => x.os).filter((x) => x === s.os || v.includes(x))))}
              >
                {s.name}
              </button>
            ))}
          </div>
          <div className="wb-seg">
            <span>배율</span>
            {zoomOptions.map(([v, text]) => (
              <button
                key={v}
                className={(v === "fit" ? manual === null : manual !== null && Math.abs(manual.k - Number(v)) < 0.001) ? "wb-active" : undefined}
                onClick={() => (v === "fit" ? setManual(null) : zoomTo(Number(v)))}
              >
                {text}
              </button>
            ))}
            <span className="wb-muted wb-zoom">{Math.round(k * 100)}%</span>
          </div>
          <button onClick={() => commit(framesStore, defaultFrames(), "프레임 초기화")} title="모든 구역을 기본 프레임으로 (Ctrl+Z 로 되돌림)">프레임 초기화</button>
          <label className="wb-check" title="잘림 · 넘침 · 화면 밖 텍스트를 빨간 테두리로, 말줄임을 점선으로">
            <input type="checkbox" checked={showIssues} onChange={(e) => setShowIssues(e.target.checked)} /> 문제 표시
          </label>
          <label className="wb-check" title="한 프레임의 폭을 연속으로 바꿔 레이아웃이 바뀌는 지점을 본다">
            <input type="checkbox" checked={sweep} onChange={(e) => setSweep(e.target.checked)} /> 폭 스윕
          </label>
          <span className="wb-spacer" />
          <button onClick={() => setInfo((v) => !v)} title="정보 패널 (I)">{info ? "정보 ⟩" : "⟨ 정보"}</button>
          <span
            className="wb-hint"
            title="빈 곳·프레임 드래그 / 휠: 이동 · Ctrl+휠: 확대 · ← →: 상태 · [ ]: 화면 · F: 맞춤 · I: 정보 · Esc: 홈 · Ctrl+Z / Ctrl+Shift+Z: 되돌리기 / 다시 · 프레임 모서리 끌기: 크기 · ‹ ›: 순서 · ⧉: 참조 복사"
          >
            ?
          </span>
        </div>

        {sweep && <Sweep screen={screen} state={state} theme={themes[0]} locale={locale} availWidth={stage.w} onNavigate={navigate} />}

        <div ref={stageRef} className={spaceDown ? "wb-stage wb-stage-pan" : "wb-stage"} onPointerDown={onStageDown}>
          <div className="wb-stage-layer" style={{ transform: `translate(${view.x}px, ${view.y}px)` }}>
            <div className="wb-matrix" style={{ zoom: k, ["--wb-z" as string]: k }}>
              {themes.map((theme) => (
                <section key={theme} className="wb-row" style={{ marginBottom: SECTOR_GAP / k }}>
                  {themes.length > 1 && <h4 style={{ zoom: 1 / k }}>{theme === "light" ? "라이트" : "다크"}</h4>}
                  <div className="wb-sectors" style={{ width: fit.wrapW, gap: SECTOR_GAP / k }}>
                    {groups.map((g) => (
                      <section
                        key={g.os}
                        className="wb-sector"
                        data-name={g.name}
                        style={{ padding: SECTOR_PAD / k, paddingTop: 0, borderRadius: 14 / k, borderWidth: 1 / k }}
                      >
                        <header className="wb-sector-head" style={{ zoom: 1 / k, height: SECTOR_HEAD }}>
                          <b>{g.name}</b>
                          <span className="wb-muted">{g.frames.length}</span>
                          {!focused && <select value="" onChange={(e) => e.target.value && add(e.target.value)} title={`${g.name} 기기 추가`}>
                            <option value="">＋ 추가</option>
                            {presetsOf(g.os).map((v) => (
                              <option key={v.id} value={v.id}>
                                {v.label} ({v.width}×{v.height})
                              </option>
                            ))}
                          </select>}
                        </header>
                        <div className="wb-sector-frames" style={{ gap: FRAME_GAP / k }}>
                          {g.frames.length === 0 && (
                            <div className="wb-sector-empty" style={{ zoom: 1 / k, width: CAPTION_W, height: EMPTY_SECTOR_H }}>
                              비어 있음 — ＋ 추가
                            </div>
                          )}
                          {g.frames.map((f, i) => (
                            <ResizableFrame
                              key={f.id}
                              frame={f}
                              zoom={k}
                              theme={theme}
                              locale={locale}
                              nodeRef={`${screen.slug}#${state}`}
                              showIssues={showIssues}
                              edit={edit}
                              onNavigate={navigate}
                              onFocus={focused ? undefined : () => focus(f.id)}
                              onMoveLeft={i > 0 ? () => move(f, -1) : undefined}
                              onMoveRight={i < g.frames.length - 1 ? () => move(f, 1) : undefined}
                              onRemove={() => commit(framesStore, framesStore.get().filter((x) => x.id !== f.id), `${g.name} 프레임 빼기`)}
                            >
                              <screen.Prototype key={state} state={state} />
                            </ResizableFrame>
                          ))}
                        </div>
                      </section>
                    ))}
                  </div>
                </section>
              ))}
            </div>
          </div>
          {offstage.above.length > 0 && (
            <button className="wb-offstage wb-offstage-up" onClick={() => reveal(offstage.above[offstage.above.length - 1])}>
              ↑ {offstage.above.join(" · ")}
            </button>
          )}
          {offstage.below.length > 0 && (
            <button className="wb-offstage wb-offstage-down" onClick={() => reveal(offstage.below[0])}>
              ↓ {offstage.below.join(" · ")}
            </button>
          )}
        </div>
      </main>
      {info && (
        <InfoPanel
          slug={screen.slug}
          state={state}
          title={screen.meta.title}
          version={screen.meta.version}
          description={screen.meta.description}
          spec={screen.spec}
          locale={locale}
          onOpen={open}
        />
      )}
    </div>
  );
}

/** A screen that only has a spec so far. */
function PlannedDetail({ screen, locale }: { screen: PlannedScreen; locale: Locale }) {
  return (
    <div className="wb-detail" style={{ gridTemplateColumns: "1fr auto" }}>
      <main className="wb-scroll wb-planned-page">
        <div className="wb-planned-banner">
          <button onClick={() => window.history.back()}>← 돌아가기</button> 계획만 있는 화면. 프로토타입을 만들려면 <code>design/screens/{screen.slug}/prototype.tsx</code> 를 추가하고 meta 의 <code>planned</code> 를 지운다.
        </div>
        <pre className="wb-spec wb-spec-large">{screen.spec}</pre>
      </main>
      <InfoPanel
        slug={screen.slug}
        state={null}
        title={screen.meta.title}
        version={screen.meta.version}
        description={screen.meta.description}
        spec=""
        locale={locale}
        onOpen={open}
      />
    </div>
  );
}

function Seg<T extends string>({ label, value, options, onChange }: {
  label?: string;
  value: T;
  options: readonly (readonly [T, string])[];
  onChange: (v: T) => void;
}) {
  return (
    <div className="wb-seg">
      {label && <span>{label}</span>}
      {options.map(([v, text]) => (
        <button key={v} className={v === value ? "wb-active" : undefined} onClick={() => onChange(v)}>
          {text}
        </button>
      ))}
    </div>
  );
}

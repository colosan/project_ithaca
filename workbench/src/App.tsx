import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import type { Locale, Theme } from "@ithaca/kit";
import { Canvas } from "./Canvas";
import { CAPTION_H, CAPTION_W, ResizableFrame, type FrameEdit, type FrameSpec } from "./Frame";
import { redo, undo, useHistory } from "./history";
import { InfoPanel } from "./InfoPanel";
import { clamp, drag, useWheelPanZoom, zoomAround, type View } from "./panzoom";
import { usePref } from "./prefs";
import { planned, plannedBySlug, screenBySlug, screens, viewports, type PlannedScreen, type Screen } from "./registry";
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

// ── Screen detail: frames on a pannable stage ────────────────────────────

const GAP = 56; // between frames (layout px)
const MARGIN = 48; // around the content at fit (screen px)
const ROW_LABEL = 28; // theme row label (screen px)
const ZOOM = { min: 0.05, max: 2 };

/**
 * Wrap frames into rows within `wrapW` (layout px) at zoom z. A slot is max(frame, caption) wide; rows grow by the
 * counter-zoomed caption. Returns the content size in layout px.
 */
function layoutFrames(frames: FrameSpec[], wrapW: number, z: number) {
  let height = 0;
  let line = 0;
  let maxLine = 0;
  let rowH = 0;
  for (const f of frames) {
    const slot = Math.max(f.w, CAPTION_W / z);
    if (line > 0 && line + GAP + slot > wrapW) {
      height += rowH + GAP;
      maxLine = Math.max(maxLine, line);
      line = 0;
      rowH = 0;
    }
    line += (line > 0 ? GAP : 0) + slot;
    rowH = Math.max(rowH, f.h + CAPTION_H / z);
  }
  return { w: Math.max(maxLine, line), h: height + rowH };
}

function ScreenDetail({ screen, state, themes, locale }: { screen: Screen; state: string; themes: Theme[]; locale: Locale }) {
  const frames = useStore(framesStore);
  const [showIssues, setShowIssues] = usePref("detail.issues", true);
  const [sweep, setSweep] = usePref("detail.sweep", false);
  const [info, setInfo] = usePref("detail.info", true);
  // null = fit (recomputed whenever the stage or frames change); a View once you pan or zoom yourself.
  const [manual, setManual] = usePref<View | null>("detail.view", null);
  const [stageRef, stage] = useSize<HTMLDivElement>();

  // Fit: the largest zoom at which every theme row of wrapped frames fits the stage with MARGIN around it.
  const fit = (() => {
    const availW = Math.max(1, stage.w - MARGIN * 2);
    const availH = Math.max(1, stage.h - MARGIN * 2);
    const rowLabels = themes.length > 1 ? themes.length * ROW_LABEL : 0;
    let z = 1;
    let box = { w: 0, h: 0 };
    while (z > ZOOM.min) {
      box = layoutFrames(frames, availW / z, z);
      const totalH = box.h * themes.length + GAP * (themes.length - 1);
      if (totalH * z + rowLabels <= availH) break;
      z *= 0.96;
    }
    const contentH = (box.h * themes.length + GAP * (themes.length - 1)) * z + rowLabels;
    return {
      wrapW: availW / z, // fixed while zooming manually, so frames do not re-wrap under the cursor
      view: { k: z, x: (stage.w - box.w * z) / 2, y: Math.max(MARGIN, (stage.h - contentH) / 2) } as View,
    };
  })();
  const view = manual ?? fit.view;
  const viewRef = useRef(view);
  viewRef.current = view;
  const setView = (v: View) => setManual(v);

  useWheelPanZoom(stageRef, () => viewRef.current, setView, ZOOM);

  /** Drag anywhere on the stage (frames included) to pan — except on captions and resize handles. */
  const onStageDown = (e: ReactPointerEvent) => {
    if ((e.target as HTMLElement).closest("figcaption, .wb-handle, button, select, input")) return;
    const start = viewRef.current;
    drag(e, (dx, dy) => setView({ ...start, x: start.x + dx, y: start.y + dy }));
  };

  const zoomTo = (k: number) => setView(zoomAround(view, clamp(k, ZOOM.min, ZOOM.max), stage.w / 2, stage.h / 2));

  // Frame edits go through the undoable store; a resize drag is one step.
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
            <span className="wb-muted wb-zoom">{Math.round(view.k * 100)}%</span>
          </div>
          <select
            value=""
            onChange={(e) => {
              const v = e.target.value;
              if (v) commit(framesStore, [...framesStore.get(), newFrame(v)], `프레임 추가 · ${viewports.find((x) => x.id === v)?.label}`);
            }}
          >
            <option value="">＋ 프레임</option>
            {viewports.map((v) => (
              <option key={v.id} value={v.id}>
                {v.platform} · {v.label} ({v.width}×{v.height})
              </option>
            ))}
          </select>
          <button onClick={() => commit(framesStore, defaultFrames(), "프레임 초기화")} title="기본 프레임 5개로 (Ctrl+Z 로 되돌림)">프레임 초기화</button>
          <label className="wb-check" title="잘림 · 넘침 · 화면 밖 텍스트를 빨간 테두리로, 말줄임을 점선으로">
            <input type="checkbox" checked={showIssues} onChange={(e) => setShowIssues(e.target.checked)} /> 문제 표시
          </label>
          <label className="wb-check" title="한 프레임의 폭을 연속으로 바꿔 size class 전환을 본다">
            <input type="checkbox" checked={sweep} onChange={(e) => setSweep(e.target.checked)} /> 폭 스윕
          </label>
          <span className="wb-spacer" />
          <button onClick={() => setInfo((v) => !v)} title="정보 패널 (I)">{info ? "정보 ⟩" : "⟨ 정보"}</button>
          <span
            className="wb-hint"
            title="빈 곳·프레임 드래그 / 휠: 이동 · Ctrl+휠: 확대 · ← →: 상태 · [ ]: 화면 · F: 맞춤 · I: 정보 · Esc: 홈 · Ctrl+Z / Ctrl+Shift+Z: 되돌리기 / 다시 · 프레임 모서리 끌기: 크기 · ⧉: 참조 복사"
          >
            ?
          </span>
        </div>

        {sweep && <Sweep screen={screen} state={state} theme={themes[0]} locale={locale} availWidth={stage.w} />}

        <div ref={stageRef} className="wb-stage" onPointerDown={onStageDown}>
          <div className="wb-stage-layer" style={{ transform: `translate(${view.x}px, ${view.y}px)` }}>
            <div className="wb-matrix" style={{ zoom: view.k, ["--wb-z" as string]: view.k }}>
              {themes.map((theme) => (
                <section key={theme} className="wb-row">
                  {themes.length > 1 && <h4 style={{ zoom: 1 / view.k }}>{theme === "light" ? "라이트" : "다크"}</h4>}
                  <div className="wb-frames" style={{ width: fit.wrapW }}>
                    {frames.map((f) => (
                      <ResizableFrame
                        key={f.id}
                        frame={f}
                        zoom={view.k}
                        theme={theme}
                        locale={locale}
                        nodeRef={`${screen.slug}#${state}`}
                        showIssues={showIssues}
                        edit={edit}
                        onRemove={() => commit(framesStore, framesStore.get().filter((x) => x.id !== f.id), "프레임 빼기")}
                      >
                        <screen.Prototype state={state} />
                      </ResizableFrame>
                    ))}
                  </div>
                </section>
              ))}
            </div>
          </div>
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
          계획만 있는 화면. 프로토타입을 만들려면 <code>design/screens/{screen.slug}/prototype.tsx</code> 를 추가하고 meta 의 <code>planned</code> 를 지운다.
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

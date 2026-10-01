import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { sizeClasses, type Locale, type Platform, type SizeClass, type Theme } from "@ithaca/kit";
import { Canvas } from "./Canvas";
import { captionSize, ResizableFrame, type FrameEdit, type FrameSpec } from "./Frame";
import { redo, undo, useHistory } from "./history";
import { InfoPanel } from "./InfoPanel";
import { clamp, drag, useWheelPanZoom, zoomAround, type View } from "./panzoom";
import { usePref } from "./prefs";
import { planned, plannedBySlug, presetLabel, screenBySlug, screens, viewportById, type PlannedScreen, type Screen } from "./registry";
import { ScreenList } from "./ScreenList";
import { commit, gesture, useStore } from "./store";
import { framesStore, normalizeDevices, resetAll } from "./stores";
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

// ── Screen detail: four base screens on top, one device per family below ─

// All spacing is in screen px, so gaps stay generous whatever the zoom.
const FRAME_GAP = 48;
const SECTION_GAP = 80;
const SECTION_PAD = 20;
const SECTION_HEAD = 40;
const MARGIN = 48;
const ROW_LABEL = 28;
const ZOOM = { min: 0.05, max: 2 };

/** The four base screens: one per layout size class, at its reference size (design/tokens/layout.json). */
const BASE_LABEL: Record<SizeClass, string> = { compact: "폰", medium: "태블릿 세로", expanded: "태블릿 가로", large: "데스크톱" };
const BASE_OS: Record<SizeClass, Platform> = { compact: "ios", medium: "ipados", expanded: "ipados", large: "macos" };
/** Representative device per base screen — only its safe area is borrowed (the size stays the class reference). */
const BASE_DEVICE: Record<SizeClass, string | null> = { compact: "iphone-14", medium: "ipad-air-11", expanded: "ipad-air-11", large: null };
const baseFrames: FrameSpec[] = sizeClasses.map((c) => ({
  id: `base-${c.name}`,
  preset: null,
  base: BASE_DEVICE[c.name],
  platform: BASE_OS[c.name],
  w: c.referenceViewport[0],
  h: c.referenceViewport[1],
}));
const baseTitle = (f: FrameSpec) => BASE_LABEL[f.id.replace("base-", "") as SizeClass];

/** Frames in rows of `perRow` inside a section box, in layout px at zoom z (captions are counter-zoomed). */
function gridBox(frames: FrameSpec[], perRow: number, z: number) {
  const cap = (f: FrameSpec) => captionSize(f.id.startsWith("base-"));
  let w = 0;
  let h = 0;
  for (let i = 0; i < frames.length; i += perRow) {
    const row = frames.slice(i, i + perRow);
    const rowW = row.reduce((n, f) => n + Math.max(f.w, cap(f).w / z), 0) + (FRAME_GAP / z) * (row.length - 1);
    w = Math.max(w, rowW);
    h += Math.max(...row.map((f) => f.h + cap(f).h / z + 6 / z)) + (i > 0 ? FRAME_GAP / z : 0);
  }
  // Padding plus the 1px border on each side (box-sizing: border-box), so wrapping matches this math.
  return { w: w + (SECTION_PAD * 2 + 2) / z, h: h + (SECTION_PAD * 2 + SECTION_HEAD + 2) / z };
}

function ScreenDetail({ screen, state, themes, locale }: { screen: Screen; state: string; themes: Theme[]; locale: Locale }) {
  const devices = useStore(framesStore);
  const [showIssues, setShowIssues] = usePref("detail.issues", true);
  const [sweep, setSweep] = usePref("detail.sweep", false);
  const [info, setInfo] = usePref("detail.info", true);
  // OS text size to simulate: users with larger text are where layouts break first.
  const [textScale, setTextScale] = usePref("detail.textScale", 1);
  const [showSafe, setShowSafe] = usePref("detail.safe", true);
  // null = fit (recomputed whenever the stage changes); a View once you pan or zoom yourself.
  const [manual, setManual] = usePref<View | null>("detail.view", null);
  const [stageRef, stage] = useSize<HTMLDivElement>();

  // Focus: one frame alone, large, still interactive. A pref so it survives clicking through to another screen.
  const [focusId, setFocusId] = usePref<string | null>("detail.focus", null);
  const focused = [...baseFrames, ...devices].find((f) => f.id === focusId) ?? null;
  const focus = (id: string | null) => {
    setFocusId(id);
    setManual(null);
  };

  /**
   * Fit: the four base screens in one row, filling the stage. The device row continues below (wheel / chip).
   * In focus, width decides up to actual size and a tall frame continues below.
   */
  const fit = (() => {
    const availW = Math.max(1, stage.w - MARGIN * 2);
    const availH = Math.max(1, stage.h - MARGIN * 2);
    const rowLabel = themes.length > 1 ? ROW_LABEL : 0;
    const top = focused ? [focused] : baseFrames;
    const fits = (perRow: number, z: number) => {
      const b = gridBox(top, perRow, z);
      return b.w * z <= availW && (focused || b.h * z + rowLabel <= availH);
    };
    // Base screens: one row of four, or 2×2 — whichever shows them larger.
    let best = { perRow: top.length, z: ZOOM.min };
    for (const perRow of focused ? [1] : [top.length, 2]) {
      let z = 1;
      while (z > ZOOM.min && !fits(perRow, z)) z *= 0.96;
      if (z > best.z) best = { perRow, z };
    }
    const z = best.z;
    const box = gridBox(top, best.perRow, z);
    return {
      z,
      sectionW: box.w,
      view: { k: z, x: (stage.w - box.w * z) / 2, y: focused ? MARGIN : Math.max(MARGIN, (stage.h - box.h * z - rowLabel) / 2) } as View,
    };
  })();
  const view = manual ?? fit.view;
  const k = view.k;
  const viewRef = useRef(view);
  viewRef.current = view;
  const setView = (v: View) => setManual(v);

  useWheelPanZoom(stageRef, () => viewRef.current, setView, ZOOM);

  // Sections scrolled out of the stage, so you know there is more above or below (and can jump there).
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
  /** Pan so the named section's top sits at the margin. */
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

  /** Pan by dragging the empty stage or section boxes, with Space held, or with the middle button. */
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

  // Device frame edits (swap, rotate, resize) are undoable; a resize drag is one step.
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
  const noEdit: FrameEdit = { commit: () => {}, dragStart: () => {}, dragMove: () => {}, dragEnd: () => {} };

  // Esc leaves focus before the app-level Esc goes home (capture phase runs first).
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

  const frameFor = (f: FrameSpec, theme: Theme, base: boolean) => (
    <ResizableFrame
      key={f.id}
      frame={f}
      zoom={k}
      theme={theme}
      locale={locale}
      nodeRef={`${screen.slug}#${state}`}
      showIssues={showIssues}
      edit={base ? noEdit : edit}
      fixedTitle={base ? baseTitle(f) : undefined}
      onNavigate={navigate}
      onFocus={focused ? undefined : () => focus(f.id)}
      textScale={textScale}
      showSafe={showSafe}
    >
      <screen.Prototype key={state} state={state} />
    </ResizableFrame>
  );

  const section = (name: string, frames: FrameSpec[], theme: Theme, base: boolean, hint?: string) => (
    <section
      key={name}
      className="wb-sector"
      data-name={name}
      style={{ width: fit.sectionW + 2 / k, padding: SECTION_PAD / k, paddingTop: 0, borderRadius: 14 / k, borderWidth: 1 / k, marginBottom: SECTION_GAP / k }}
    >
      <header className="wb-sector-head" style={{ zoom: 1 / k, height: SECTION_HEAD }}>
        <b>{name}</b>
        {hint && <span className="wb-muted">{hint}</span>}
      </header>
      <div className="wb-sector-frames" style={{ gap: FRAME_GAP / k, flexWrap: "wrap" }}>
        {frames.map((f) => frameFor(f, theme, base))}
      </div>
    </section>
  );

  return (
    <div className="wb-detail" style={{ gridTemplateColumns: info ? "1fr auto" : "1fr" }}>
      <main className="wb-detail-main">
        <div className="wb-toolbar">
          <Seg label="상태" value={state} options={screen.states.map((s) => [s, s] as const)} onChange={(s) => open(screen.slug, s)} />
          {focused && (
            <button className="wb-focus-exit" onClick={() => focus(null)} title="모든 프레임 보기 (Esc)">
              ◱ 전체 보기 <span className="wb-muted">— {focused.id.startsWith("base-") ? baseTitle(focused) : (viewportById[focused.preset ?? focused.base ?? ""] ? presetLabel(viewportById[focused.preset ?? focused.base ?? ""]) : "직접 조절")} 만 보는 중</span>
            </button>
          )}
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
          <Seg
            label="글자"
            value={String(textScale)}
            options={[["1", "기본"], ["1.3", "130%"], ["2", "200%"]]}
            onChange={(v) => setTextScale(Number(v))}
          />
          <button onClick={() => commit(framesStore, normalizeDevices([]), "기기 초기화")} title="기기별 프레임을 대표 모델로 (Ctrl+Z 로 되돌림)">기기 초기화</button>
          <label className="wb-check" title="상태바 · 홈 표시줄 · 카메라 자리(안전 영역)를 겹쳐 보여준다. 그 안의 글자는 ⚠ 가림">
            <input type="checkbox" checked={showSafe} onChange={(e) => setShowSafe(e.target.checked)} /> 안전 영역
          </label>
          <label className="wb-check" title="잘림 · 넘침 · 화면 밖 · 가림 텍스트를 빨간 테두리로, 말줄임을 점선으로">
            <input type="checkbox" checked={showIssues} onChange={(e) => setShowIssues(e.target.checked)} /> 문제 표시
          </label>
          <label className="wb-check" title="한 프레임의 폭을 연속으로 바꿔 레이아웃이 바뀌는 지점을 본다">
            <input type="checkbox" checked={sweep} onChange={(e) => setSweep(e.target.checked)} /> 폭 스윕
          </label>
          <span className="wb-spacer" />
          <button onClick={() => setInfo((v) => !v)} title="정보 패널 (I)">{info ? "정보 ⟩" : "⟨ 정보"}</button>
          <span
            className="wb-hint"
            title="빈 곳 드래그 · 휠: 이동 · Space+드래그: 어디서나 이동 · Ctrl+휠: 확대 · ← →: 상태 · [ ]: 화면 · F: 맞춤 · I: 정보 · Esc: 홈 · Ctrl+Z: 되돌리기 · ⤢: 크게 · ⟲: 회전 · ⧉: 참조 복사"
          >
            ?
          </span>
        </div>

        {sweep && <Sweep screen={screen} state={state} theme={themes[0]} locale={locale} availWidth={stage.w} onNavigate={navigate} textScale={textScale} />}

        <div ref={stageRef} className={spaceDown ? "wb-stage wb-stage-pan" : "wb-stage"} onPointerDown={onStageDown}>
          <div className="wb-stage-layer" style={{ transform: `translate(${view.x}px, ${view.y}px)` }}>
            <div className="wb-matrix" style={{ zoom: k, ["--wb-z" as string]: k }}>
              {themes.map((theme) => (
                <section key={theme} className="wb-row">
                  {themes.length > 1 && <h4 style={{ zoom: 1 / k }}>{theme === "light" ? "라이트" : "다크"}</h4>}
                  {focused
                    ? section(focused.id.startsWith("base-") ? "기본 화면" : "기기별", [focused], theme, focused.id.startsWith("base-"))
                    : [
                        section("기본 4화면", baseFrames, theme, true, "레이아웃이 바뀌는 4구간의 대표 크기"),
                        section("기기별", devices, theme, false, "제품군마다 대표 1개 · 이름을 눌러 다른 모델로"),
                      ]}
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

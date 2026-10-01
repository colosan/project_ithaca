import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Locale, Theme } from "@ithaca/kit";
import { Canvas } from "./Canvas";
import { CAPTION_H, CAPTION_W, ResizableFrame, type FrameSpec } from "./Frame";
import { InfoPanel } from "./InfoPanel";
import { usePref } from "./prefs";
import {
  detailDefaults, planned, plannedBySlug, screenBySlug, screens, viewportById, viewports,
  type PlannedScreen, type Screen,
} from "./registry";
import { ScreenList } from "./ScreenList";
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

// ── Frames ───────────────────────────────────────────────────────────────

let frameSeq = 0;
const newFrame = (presetId: string): FrameSpec => {
  const v = viewportById[presetId];
  return { id: `f${Date.now()}-${frameSeq++}`, preset: v.id, platform: v.os, w: v.width, h: v.height };
};
const defaultFrames = () => detailDefaults.filter((id) => viewportById[id]).map(newFrame);

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

  // Global keys: Esc → home.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e)) return;
      if (e.key === "Escape" && route.view !== "home") go({ view: "home" });
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
    </div>
  );
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

// ── Screen detail ────────────────────────────────────────────────────────

const GAP = 56; // .wb-frames gap
const PAD = 24; // .wb-matrix padding

function ScreenDetail({ screen, state, themes, locale }: { screen: Screen; state: string; themes: Theme[]; locale: Locale }) {
  const [zoomPref, setZoom] = usePref<"fit" | number>("detail.zoom", "fit");
  const [stored, setFrames] = usePref<FrameSpec[]>("detail.frames", defaultFrames());
  const [showIssues, setShowIssues] = usePref("detail.issues", true);
  const [sweep, setSweep] = usePref("detail.sweep", false);
  const [info, setInfo] = usePref("detail.info", true);
  const [mainRef, area] = useSize<HTMLElement>();
  const [toolbarRef, toolbar] = useSize<HTMLDivElement>();

  // Frames saved before `platform` existed get it back from their preset.
  const frames = stored.map((f) => (f.platform ? f : { ...f, platform: viewportById[f.preset ?? ""]?.os ?? "ios" }));
  const update = (f: FrameSpec) => setFrames((list) => list.map((x) => (x.id === f.id ? f : x)));

  // "Fit": the largest zoom at which all frames — wrapped into rows across the available width — fit on screen.
  // A slot is max(frame width, caption width) and rows grow by the (counter-zoomed) caption height.
  const fitZoom = (() => {
    if (!area.w || frames.length === 0) return 0.4;
    const usableH = area.h - toolbar.h - 8 - (themes.length > 1 ? themes.length * 24 : 0);
    const fits = (z: number) => {
      const lineMax = area.w / z - PAD * 2;
      let height = 0;
      let line = 0;
      let rowH = 0;
      for (const f of frames) {
        const slot = Math.max(f.w, CAPTION_W / z);
        if (line > 0 && line + GAP + slot > lineMax) {
          height += rowH + GAP;
          line = 0;
          rowH = 0;
        }
        line += (line > 0 ? GAP : 0) + slot;
        rowH = Math.max(rowH, f.h + CAPTION_H / z);
      }
      height += rowH;
      return (height * themes.length + PAD * 2 + GAP * (themes.length - 1)) * z <= usableH;
    };
    let z = 1;
    while (z > 0.05 && !fits(z)) z *= 0.96;
    return Math.max(0.05, z);
  })();
  const zoom = zoomPref === "fit" ? fitZoom : zoomPref;

  // Keys: ←/→ state, [/] screen, F fit, I info panel.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e)) return;
      const i = screen.states.indexOf(state);
      if (e.key === "ArrowRight") open(screen.slug, screen.states[(i + 1) % screen.states.length]);
      else if (e.key === "ArrowLeft") open(screen.slug, screen.states[(i - 1 + screen.states.length) % screen.states.length]);
      else if (e.key === "]" || e.key === "[") {
        const j = screens.findIndex((s) => s.slug === screen.slug);
        const next = screens[(j + (e.key === "]" ? 1 : -1) + screens.length) % screens.length];
        open(next.slug, next.states[0]);
      } else if (e.key === "f" || e.key === "F") setZoom("fit");
      else if (e.key === "i" || e.key === "I") setInfo((v) => !v);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  return (
    <div className="wb-detail" style={{ gridTemplateColumns: info ? "1fr auto" : "1fr" }}>
      <main ref={mainRef} className="wb-scroll">
        <div ref={toolbarRef} className="wb-toolbar">
          <Seg label="상태" value={state} options={screen.states.map((s) => [s, s] as const)} onChange={(s) => open(screen.slug, s)} />
          <Seg
            label="배율"
            value={String(zoomPref)}
            options={[["fit", `맞춤${zoomPref === "fit" ? ` ${Math.round(fitZoom * 100)}%` : ""}`], ["0.25", "25%"], ["0.5", "50%"], ["0.75", "75%"], ["1", "100%"]]}
            onChange={(z) => setZoom(z === "fit" ? "fit" : Number(z))}
          />
          <select value="" onChange={(e) => e.target.value && setFrames((list) => [...list, newFrame(e.target.value)])}>
            <option value="">＋ 프레임</option>
            {viewports.map((v) => (
              <option key={v.id} value={v.id}>
                {v.platform} · {v.label} ({v.width}×{v.height})
              </option>
            ))}
          </select>
          <button onClick={() => setFrames(defaultFrames())} title="기본 프레임 5개로">초기화</button>
          <label className="wb-check" title="잘림 · 화면 밖 텍스트를 빨간 테두리로, 말줄임을 점선으로">
            <input type="checkbox" checked={showIssues} onChange={(e) => setShowIssues(e.target.checked)} /> 문제 표시
          </label>
          <label className="wb-check" title="한 프레임의 폭을 연속으로 바꿔 size class 전환을 본다">
            <input type="checkbox" checked={sweep} onChange={(e) => setSweep(e.target.checked)} /> 폭 스윕
          </label>
          <span className="wb-spacer" />
          <button onClick={() => setInfo((v) => !v)} title="정보 패널 (I)">{info ? "정보 ⟩" : "⟨ 정보"}</button>
          <span className="wb-hint" title="← →: 상태 · [ ]: 화면 · F: 맞춤 · I: 정보 패널 · Esc: 홈 · 프레임 오른쪽/아래/모서리 끌기: 크기 · ⧉: 참조 복사">?</span>
        </div>

        {sweep && <Sweep screen={screen} state={state} theme={themes[0]} locale={locale} availWidth={area.w} />}

        <div className="wb-matrix" style={{ zoom, ["--wb-z" as string]: zoom }}>
          {themes.map((theme) => (
            <section key={theme} className="wb-row">
              {themes.length > 1 && <h4 style={{ zoom: 1 / zoom }}>{theme === "light" ? "라이트" : "다크"}</h4>}
              <div className="wb-frames" style={{ width: Math.max(0, area.w / zoom - PAD * 2) }}>
                {frames.map((f) => (
                  <ResizableFrame
                    key={f.id}
                    frame={f}
                    zoom={zoom}
                    theme={theme}
                    locale={locale}
                    nodeRef={`${screen.slug}#${state}`}
                    showIssues={showIssues}
                    onChange={update}
                    onRemove={() => setFrames((list) => list.filter((x) => x.id !== f.id))}
                  >
                    <screen.Prototype state={state} />
                  </ResizableFrame>
                ))}
              </div>
            </section>
          ))}
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

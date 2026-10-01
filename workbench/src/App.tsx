import { useEffect, useState } from "react";
import type { Locale, Theme } from "@ithaca/kit";
import { Canvas } from "./Canvas";
import { ResizableFrame, type FrameSpec } from "./Frame";
import { InfoPanel } from "./InfoPanel";
import { usePref } from "./prefs";
import { detailDefaults, screenBySlug, viewportById, viewports, type Screen } from "./registry";
import { TokensPage } from "./TokensPage";

type Route = { view: "canvas" } | { view: "tokens" } | { view: "screen"; slug: string; state: string };

function parseHash(): Route {
  const [view, slug, state] = location.hash.replace(/^#\/?/, "").split("/");
  if (view === "tokens") return { view: "tokens" };
  const screen = slug ? screenBySlug[slug] : undefined;
  if (view === "screen" && screen) {
    return { view: "screen", slug, state: screen.states.includes(state) ? state : screen.states[0] };
  }
  return { view: "canvas" };
}

const toHash = (r: Route) =>
  r.view === "screen" ? `#/screen/${r.slug}/${r.state}` : r.view === "tokens" ? "#/tokens" : "#/";

let frameSeq = 0;
const newFrame = (presetId: string): FrameSpec => {
  const v = viewportById[presetId];
  return { id: `f${Date.now()}-${frameSeq++}`, preset: v.id, w: v.width, h: v.height };
};
const defaultFrames = () => detailDefaults.filter((id) => viewportById[id]).map(newFrame);

export function App() {
  const [route, setRoute] = useState<Route>(parseHash);
  useEffect(() => {
    const onHash = () => setRoute(parseHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  const go = (r: Route) => {
    location.hash = toHash(r);
  };
  const openScreen = (slug: string, state: string) => go({ view: "screen", slug, state });

  const [theme, setTheme] = usePref<Theme | "both">("theme", "light");
  const [locale, setLocale] = usePref<Locale>("locale", "ko");

  return (
    <div className="wb">
      <header className="wb-top">
        <h1>
          Ithaca <span className="wb-muted">workbench</span>
        </h1>
        <nav className="wb-tabs">
          <button className={route.view !== "tokens" ? "wb-active" : undefined} onClick={() => go({ view: "canvas" })}>
            캔버스
          </button>
          <button className={route.view === "tokens" ? "wb-active" : undefined} onClick={() => go({ view: "tokens" })}>
            토큰
          </button>
        </nav>
        {route.view === "screen" && (
          <span className="wb-crumb">
            › {screenBySlug[route.slug].meta.title.ko} <span className="wb-chip">{route.state}</span>
          </span>
        )}
        <div className="wb-spacer" />
        <Seg label="테마" value={theme} options={[["light", "라이트"], ["dark", "다크"], ["both", "둘 다"]]} onChange={setTheme} />
        <Seg label="UI 언어" value={locale} options={[["ko", "한국어"], ["en", "English"]]} onChange={setLocale} />
      </header>

      {route.view === "canvas" && <Canvas theme={theme === "dark" ? "dark" : "light"} locale={locale} onOpen={openScreen} />}
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
          onState={(state) => go({ view: "screen", slug: route.slug, state })}
          onOpen={openScreen}
        />
      )}
    </div>
  );
}

function ScreenDetail({ screen, state, themes, locale, onState, onOpen }: {
  screen: Screen;
  state: string;
  themes: Theme[];
  locale: Locale;
  onState: (state: string) => void;
  onOpen: (slug: string, state: string) => void;
}) {
  const [zoom, setZoom] = usePref("detail.zoom", 0.5);
  const [frames, setFrames] = usePref<FrameSpec[]>("detail.frames", defaultFrames());
  const update = (f: FrameSpec) => setFrames((list) => list.map((x) => (x.id === f.id ? f : x)));

  return (
    <div className="wb-detail">
      <main className="wb-scroll">
        <div className="wb-toolbar">
          <Seg label="상태" value={state} options={screen.states.map((s) => [s, s] as const)} onChange={onState} />
          <Seg label="배율" value={String(zoom)} options={[["0.25", "25%"], ["0.35", "35%"], ["0.5", "50%"], ["0.75", "75%"], ["1", "100%"]]} onChange={(z) => setZoom(Number(z))} />
          <select value="" onChange={(e) => e.target.value && setFrames((list) => [...list, newFrame(e.target.value)])}>
            <option value="">+ 프레임 추가</option>
            {viewports.map((v) => (
              <option key={v.id} value={v.id}>
                {v.platform} · {v.label} ({v.width}×{v.height})
              </option>
            ))}
          </select>
          <button onClick={() => setFrames(defaultFrames())}>기본 프레임</button>
          <span className="wb-muted">프레임 오른쪽·아래·모서리를 끌어 크기 조절</span>
        </div>

        <div className="wb-matrix" style={{ zoom }}>
          {themes.map((theme) => (
            <section key={theme} className="wb-row">
              {themes.length > 1 && <h4>{theme}</h4>}
              <div className="wb-frames">
                {frames.map((f) => (
                  <ResizableFrame
                    key={f.id}
                    frame={f}
                    zoom={zoom}
                    theme={theme}
                    locale={locale}
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
      <InfoPanel screen={screen} state={state} locale={locale} onOpen={onOpen} />
    </div>
  );
}

function Seg<T extends string>({ label, value, options, onChange }: {
  label: string;
  value: T;
  options: readonly (readonly [T, string])[];
  onChange: (v: T) => void;
}) {
  return (
    <div className="wb-seg">
      <span>{label}</span>
      {options.map(([v, text]) => (
        <button key={v} className={v === value ? "wb-active" : undefined} onClick={() => onChange(v)}>
          {text}
        </button>
      ))}
    </div>
  );
}

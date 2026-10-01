import { useEffect, useState } from "react";
import { sizeClasses, type Locale, type Platform, type Theme } from "@ithaca/kit";
import { Device } from "./Frame";
import { usePref } from "./prefs";
import type { Screen } from "./registry";

const RANGE = { min: 320, max: 2560 };
const PLATFORMS: Platform[] = ["ios", "ipados", "android", "macos", "windows"];

/** J2: scrub one frame's width continuously to watch every size-class transition, instead of guessing presets. */
export function Sweep({ screen, state, theme, locale, availWidth, onNavigate, textScale }: {
  screen: Screen;
  state: string;
  theme: Theme;
  locale: Locale;
  availWidth: number;
  onNavigate?: (to: string) => void;
  textScale?: number;
}) {
  const [w, setW] = usePref("sweep.w", 390);
  const [h, setH] = usePref("sweep.h", 760);
  const [platform, setPlatform] = usePref<Platform>("sweep.platform", "macos");
  const [playing, setPlaying] = useState(false);

  // setInterval (not rAF) so playback also advances while the window is in the background.
  useEffect(() => {
    if (!playing) return;
    const id = setInterval(() => {
      setW((x) => {
        if (x >= 1600) {
          setPlaying(false);
          return 1600;
        }
        return x + 10;
      });
    }, 30);
    return () => clearInterval(id);
  }, [playing]);

  const zoom = Math.min(1, Math.max(0.1, (availWidth - 48) / w));
  const pct = (v: number) => `${((v - RANGE.min) / (RANGE.max - RANGE.min)) * 100}%`;

  return (
    <section className="wb-sweep">
      <div className="wb-sweep-bar">
        <button
          onClick={() => {
            if (!playing && w >= 1600) setW(RANGE.min);
            setPlaying((p) => !p);
          }}
          title="320 → 1600 자동 재생"
        >
          {playing ? "⏸" : "▶"}
        </button>
        <div className="wb-ruler">
          <input type="range" min={RANGE.min} max={RANGE.max} value={w} onChange={(e) => { setPlaying(false); setW(Number(e.target.value)); }} />
          <div className="wb-ticks">
            {sizeClasses.filter((c) => c.min > 0).map((c) => (
              <span key={c.name} style={{ left: pct(c.min) }} title={`레이아웃이 바뀌는 폭 (${c.name})`}>
                <i />
                {c.min}
              </span>
            ))}
          </div>
        </div>
        <span className="wb-size">
          <input type="number" value={w} onChange={(e) => setW(Math.max(RANGE.min, Number(e.target.value)))} />×
          <input type="number" value={h} onChange={(e) => setH(Math.max(360, Number(e.target.value)))} />
        </span>
        <select value={platform} onChange={(e) => setPlatform(e.target.value as Platform)} title="플랫폼에 따라 달라지는 기능(MCP 등) 확인용">
          {PLATFORMS.map((p) => <option key={p}>{p}</option>)}
        </select>
        <span className="wb-muted">{Math.round(zoom * 100)}%</span>
      </div>
      <div className="wb-sweep-stage" style={{ zoom }}>
        <Device width={w} height={h} platform={platform} theme={theme} locale={locale} onNavigate={onNavigate} textScale={textScale}>
          <screen.Prototype key={state} state={state} />
        </Device>
      </div>
    </section>
  );
}

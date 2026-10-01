import type { Locale, Theme } from "@ithaca/kit";
import { Device } from "./Frame";
import { usePref } from "./prefs";
import { buildGraph, planned, screens, specSummary, viewportById, viewports } from "./registry";

const CARD_W = { phone: 200, wide: 420 };

/** J1 inventory: every screen as a section, its states as cards — readable without zooming. */
export function ScreenList({ theme, locale, onOpen }: {
  theme: Theme;
  locale: Locale;
  onOpen: (slug: string, state: string | null) => void;
}) {
  const [previewId, setPreviewId] = usePref("list.preview", "iphone-15");
  const vp = viewportById[previewId] ?? viewports[0];
  const w = vp.width <= 600 ? CARD_W.phone : CARD_W.wide;
  const k = w / vp.width;
  const h = Math.round(vp.height * k);
  const { edges } = buildGraph();
  const stateCount = screens.reduce((n, s) => n + s.states.length, 0);

  return (
    <main className="wb-scroll wb-list">
      <div className="wb-list-head">
        <div className="wb-stats">
          <span><b>{screens.length}</b> 화면</span>
          <span><b>{stateCount}</b> 상태</span>
          <span><b>{edges.length}</b> 이동 경로</span>
          <span className="wb-muted"><b>{planned.length}</b> 계획됨</span>
        </div>
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
      </div>

      {screens.map((s) => {
        const out = edges.filter((e) => e.from.startsWith(`${s.slug}#`) && !e.to.startsWith(`${s.slug}#`)).length;
        const inn = edges.filter((e) => e.to.startsWith(`${s.slug}#`) && !e.from.startsWith(`${s.slug}#`)).length;
        return (
          <section key={s.slug} className="wb-list-screen">
            <header>
              <h2>{s.meta.title[locale]}</h2>
              <code>{s.slug}</code>
              <span className="wb-muted">v{s.meta.version} · 상태 {s.states.length} · 나가는 경로 {out} · 들어오는 경로 {inn}</span>
            </header>
            {s.meta.description && <p className="wb-muted">{s.meta.description}</p>}
            <div className="wb-list-cards">
              {s.states.map((state) => (
                <button key={state} className="wb-list-card" onClick={() => onOpen(s.slug, state)} style={{ width: w }}>
                  <div className="wb-list-thumb" style={{ width: w, height: h }}>
                    <div style={{ transform: `scale(${k})`, transformOrigin: "0 0" }}>
                      <Device width={vp.width} height={vp.height} platform={vp.os} theme={theme} locale={locale} className="wb-device-flat">
                        <s.Prototype state={state} />
                      </Device>
                    </div>
                  </div>
                  <span className="wb-chip">{state}</span>
                </button>
              ))}
            </div>
          </section>
        );
      })}

      {planned.length > 0 && (
        <section className="wb-list-screen">
          <header>
            <h2>계획된 화면</h2>
            <span className="wb-muted">spec 만 있고 프로토타입은 아직 — 클릭하면 spec</span>
          </header>
          <div className="wb-list-cards">
            {planned.map((p) => (
              <button key={p.slug} className="wb-list-card wb-list-planned" onClick={() => onOpen(p.slug, null)} style={{ width: CARD_W.phone }}>
                <b>{p.meta.title[locale]}</b>
                <code>{p.slug}</code>
                <p>{specSummary(p.spec)}</p>
              </button>
            ))}
          </div>
        </section>
      )}
    </main>
  );
}

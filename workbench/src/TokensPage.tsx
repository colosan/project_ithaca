import color from "../../design/tokens/color.json";
import effects from "../../design/tokens/effects.json";
import layout from "../../design/tokens/layout.json";
import sizing from "../../design/tokens/sizing.json";
import spacing from "../../design/tokens/spacing.json";
import typography from "../../design/tokens/typography.json";
import { camel, kebab } from "./names";

type ColorTokens = Record<string, { light: string; dark: string; description?: string }>;
type TypeStyles = Record<string, { family: string; size: number; lineHeight: number; tracking: number; weight: number; description?: string }>;

const SAMPLE = { ko: "윤재의 지도에는 섬이 하나 더 있었다.", en: "Yunjae's map had one island too many." };

/** Lays out all six token axes from design/tokens. Values are read from the source JSON. */
export function TokensPage() {
  return (
    <div className="wb-tokens">
      <section>
        <h2>color</h2>
        <p className="wb-muted">{color.description}</p>
        <table>
          <thead>
            <tr><th>이름</th><th>light</th><th>dark</th><th>쓰임</th></tr>
          </thead>
          <tbody>
            {Object.entries(color.tokens as ColorTokens).map(([k, v]) => (
              <tr key={k}>
                <td><code>color.{camel(k)}</code></td>
                <td><Swatch theme="light" name={k} hex={v.light} /></td>
                <td><Swatch theme="dark" name={k} hex={v.dark} /></td>
                <td className="wb-muted">{v.description}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <section>
        <h2>typography</h2>
        <p className="wb-muted">{typography.description}</p>
        {Object.entries(typography.styles as TypeStyles).map(([k, s]) => (
          <div key={k} className="wb-type-row">
            <div className="wb-type-meta">
              <code>type.{camel(k)}</code>
              <span className="wb-muted">{s.family} · {s.size}/{s.lineHeight} · {s.weight} · {s.tracking}em</span>
            </div>
            <div data-theme="light" className="wb-type-sample" style={{
              fontFamily: `var(--type-${kebab(k)}-family)`, fontSize: `var(--type-${kebab(k)}-size)`,
              lineHeight: `var(--type-${kebab(k)}-line-height)`, letterSpacing: `var(--type-${kebab(k)}-tracking)`,
              fontWeight: `var(--type-${kebab(k)}-weight)`,
            }}>
              <div>{SAMPLE.ko}</div>
              <div>{SAMPLE.en}</div>
            </div>
          </div>
        ))}
      </section>

      <section>
        <h2>spacing</h2>
        <p className="wb-muted">{spacing.description}</p>
        {Object.entries(spacing.scale).map(([k, v]) => (
          <div key={k} className="wb-bar-row">
            <code>space[{k}]</code>
            <span className="wb-bar" style={{ width: `var(--space-${k})` }} />
            <span className="wb-muted">{v}</span>
          </div>
        ))}
      </section>

      <section>
        <h2>sizing · radius · opacity</h2>
        <div className="wb-chips">
          {Object.entries(sizing.sizes).map(([k, v]) => <span key={k}><code>size.{camel(k)}</code> {v}</span>)}
        </div>
        <div className="wb-radius-row">
          {Object.entries(effects.radius).map(([k, v]) => (
            <div key={k} className="wb-radius" style={{ borderRadius: `var(--radius-${kebab(k)})` }}>
              <code>radius.{camel(k)}</code><span className="wb-muted">{v}</span>
            </div>
          ))}
        </div>
        <div className="wb-chips">
          {Object.entries(effects.opacity).map(([k, v]) => <span key={k}><code>opacity.{camel(k)}</code> {v}</span>)}
        </div>
      </section>

      <section>
        <h2>layout</h2>
        <p className="wb-muted">{layout.description}</p>
        <table>
          <thead>
            <tr><th>size class</th><th>폭</th><th>대표 뷰포트</th><th>pane 수</th><th>에디터 좌우 여백</th></tr>
          </thead>
          <tbody>
            {Object.entries(layout.sizeClasses).map(([k, v]) => (
              <tr key={k}>
                <td><span className={`wb-class wb-class-${k}`}>{k}</span></td>
                <td>{v.min} – {v.max ?? "∞"}</td>
                <td>{v.referenceViewport.join(" × ")}</td>
                <td>{v.panes}</td>
                <td>{layout.editor.paddingX[k as keyof typeof layout.editor.paddingX]}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="wb-muted">
          pane: {Object.entries(layout.panes).map(([k, v]) => `${k} ${v.default} (${v.min}–${v.max})`).join(" · ")} · editor.measure {layout.editor.measure}
        </p>
      </section>
    </div>
  );
}

function Swatch({ theme, name, hex }: { theme: "light" | "dark"; name: string; hex: string }) {
  return (
    <span className="wb-swatch" data-theme={theme}>
      <span className="wb-swatch-chip" style={{ background: `var(--color-${kebab(name)})` }} />
      <code>{hex}</code>
    </span>
  );
}

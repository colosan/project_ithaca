import color from "../../design/tokens/color.json";
import { camel } from "./names";

type Tokens = Record<string, { light: string; dark: string }>;
const tokens = color.tokens as Tokens;

/** Text-like colors checked against every surface. `ink.markup` is dimmed on purpose (Markdown syntax). */
const FOREGROUNDS = ["ink.primary", "ink.secondary", "ink.tertiary", "ink.markup", "accent.primary", "state.warning", "state.danger", "state.success", "state.info"];
const BACKGROUNDS = ["surface.canvas", "surface.sidebar", "surface.list", "surface.raised", "surface.selected", "accent.soft"];
const INTENTIONALLY_LOW = new Set(["ink.markup"]);

function luminance(hex: string) {
  const [r, g, b] = [1, 3, 5].map((i) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrast(a: string, b: string) {
  const [l1, l2] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (l1 + 0.05) / (l2 + 0.05);
}

/** WCAG 2.x: 4.5 body text (AA), 3 large text / UI parts. */
const grade = (r: number) => (r >= 7 ? "aaa" : r >= 4.5 ? "aa" : r >= 3 ? "large" : "fail");

export function ContrastTable() {
  const modes = ["light", "dark"] as const;
  const failures = modes.flatMap((m) =>
    FOREGROUNDS.filter((f) => !INTENTIONALLY_LOW.has(f)).flatMap((f) =>
      BACKGROUNDS.filter((b) => contrast(tokens[f][m], tokens[b][m]) < 4.5).map((b) => `${m} ${f} / ${b}`),
    ),
  );
  return (
    <section>
      <h2>대비 (WCAG)</h2>
      <p className="wb-muted">
        글자색 × 면색. 4.5 이상 = 본문 OK(AA) · 3 이상 = 큰 글자 · UI 만 · 3 미만 = 실패. <code>ink.markup</code> 은 Markdown 기호를 일부러 흐리게 둔 것이라 판정 제외.
        {failures.length > 0 && <> 본문 기준(4.5) 미달 <b>{failures.length}</b>쌍.</>}
      </p>
      {modes.map((m) => (
        <table key={m} className="wb-contrast">
          <thead>
            <tr>
              <th>{m}</th>
              {BACKGROUNDS.map((b) => <th key={b}><code>{camel(b)}</code></th>)}
            </tr>
          </thead>
          <tbody>
            {FOREGROUNDS.map((f) => (
              <tr key={f}>
                <td><code>{camel(f)}</code></td>
                {BACKGROUNDS.map((b) => {
                  const r = contrast(tokens[f][m], tokens[b][m]);
                  const g = INTENTIONALLY_LOW.has(f) ? "exempt" : grade(r);
                  return (
                    <td key={b} className={`wb-cr wb-cr-${g}`} style={{ background: tokens[b][m], color: tokens[f][m] }} title={`${r.toFixed(2)} : 1`}>
                      가Aa <small>{r.toFixed(1)}</small>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      ))}
    </section>
  );
}

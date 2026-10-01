import type { Locale } from "@ithaca/kit";
import { buildGraph, nodeId, type Screen } from "./registry";

/** Right-hand panel in the screen detail view: where this state leads, what leads here, and the spec. */
export function InfoPanel({ screen, state, locale, onOpen }: {
  screen: Screen;
  state: string;
  locale: Locale;
  onOpen: (slug: string, state: string) => void;
}) {
  const { edges } = buildGraph();
  const here = nodeId(screen.slug, state);
  const outgoing = edges.filter((e) => e.from === here);
  const incoming = edges.filter((e) => e.to === here);

  const go = (id: string) => {
    const [slug, s] = id.split("#");
    onOpen(slug, s);
  };

  return (
    <aside className="wb-info">
      <header>
        <h2>{screen.meta.title[locale]}</h2>
        <p className="wb-muted">
          <code>{screen.slug}</code> · v{screen.meta.version}
        </p>
        {screen.meta.description && <p>{screen.meta.description}</p>}
      </header>

      <section>
        <h3>여기서 가는 곳 {outgoing.length}</h3>
        {outgoing.length === 0 && <p className="wb-muted">없음</p>}
        {outgoing.map((e) => (
          <button key={e.to + e.label.ko} className="wb-link" onClick={() => go(e.to)}>
            → <code>{e.to}</code> <span className="wb-muted">{e.label[locale]}</span>
          </button>
        ))}
      </section>

      <section>
        <h3>여기로 오는 곳 {incoming.length}</h3>
        {incoming.length === 0 && <p className="wb-muted">없음</p>}
        {incoming.map((e) => (
          <button key={e.from + e.label.ko} className="wb-link" onClick={() => go(e.from)}>
            ← <code>{e.from}</code> <span className="wb-muted">{e.label[locale]}</span>
          </button>
        ))}
      </section>

      <section>
        <h3>spec.md</h3>
        <pre className="wb-spec">{screen.spec}</pre>
      </section>
    </aside>
  );
}

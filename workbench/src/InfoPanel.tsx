import type { Locale } from "@ithaca/kit";
import { buildGraph, nodeId, type GraphEdge, type GraphNode, type Bilingual } from "./registry";

/** Right-hand panel: where this card leads, what leads here, and the spec. */
export function InfoPanel({ slug, state, title, version, description, spec, locale, onOpen }: {
  slug: string;
  state: string | null;
  title: Bilingual;
  version: string;
  description?: string;
  spec: string;
  locale: Locale;
  onOpen: (slug: string, state: string | null) => void;
}) {
  const { nodes, edges } = buildGraph();
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const here = nodeId(slug, state);
  const outgoing = edges.filter((e) => e.from === here);
  const incoming = edges.filter((e) => e.to === here);

  const Link = ({ e, target, arrow }: { e: GraphEdge; target: GraphNode | undefined; arrow: string }) =>
    target ? (
      <button className="wb-link" onClick={() => onOpen(target.slug, target.state)}>
        <span className="wb-link-arrow">{arrow}</span>
        <span className="wb-link-main">
          <b>{target.title[locale]}</b> <span className={target.planned ? "wb-chip wb-chip-planned" : "wb-chip"}>{target.state ?? "계획"}</span>
          <span className="wb-muted wb-link-label">{e.label[locale]}</span>
        </span>
      </button>
    ) : null;

  return (
    <aside className="wb-info">
      <header>
        <h2>{title[locale]}</h2>
        <p className="wb-muted">
          <code>{here}</code> · v{version}
        </p>
        {description && <p>{description}</p>}
      </header>

      <section>
        <h3>여기서 가는 곳 {outgoing.length}</h3>
        {outgoing.length === 0 && <p className="wb-muted">없음</p>}
        {outgoing.map((e) => <Link key={e.to + e.label.ko} e={e} target={byId.get(e.to)} arrow="→" />)}
      </section>

      <section>
        <h3>여기로 오는 곳 {incoming.length}</h3>
        {incoming.length === 0 && <p className="wb-muted">없음</p>}
        {incoming.map((e) => <Link key={e.from + e.label.ko} e={e} target={byId.get(e.from)} arrow="←" />)}
      </section>

      <section>
        <h3>spec.md</h3>
        <pre className="wb-spec">{spec}</pre>
      </section>
    </aside>
  );
}

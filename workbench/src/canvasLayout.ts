// Pure layout for the flow canvas: card sizes, lane packing, edge routing, collapsing.
import type { GraphEdge, GraphNode, Viewport } from "./registry";
import type { Positions } from "./stores";

export type Pos = { x: number; y: number };
export type Size = { w: number; h: number; k: number };

const GAP_X = 120;
const GAP_Y = 160;
const PER_ROW = 4; // a lane wraps after this many cards
const COL_GAP = 320; // between lane columns — room for the left-gutter edges of the next column

/** Card footprint for a preview viewport: phones get narrow cards, tablets/desktops wide ones. */
export function cardSize(vp: Viewport): Size {
  const w = vp.width <= 600 ? 260 : 520;
  const k = w / vp.width;
  return { w, h: Math.round(vp.height * k), k };
}

/** Hub = the node with the most outgoing links (screens usually all link back to it). */
export function hubOf(nodes: GraphNode[], edges: GraphEdge[]) {
  const out = new Map<string, number>();
  for (const e of edges) out.set(e.from, (out.get(e.from) ?? 0) + 1);
  return [...nodes].sort((a, b) => (out.get(b.id) ?? 0) - (out.get(a.id) ?? 0))[0];
}

/**
 * Collapsed screens show only their first state; links to or from hidden states are redrawn from that card,
 * and links inside the collapsed screen disappear.
 */
export function collapseGraph(nodes: GraphNode[], edges: GraphEdge[], collapsed: Set<string>) {
  const hidden = (n: GraphNode) => !!n.screen && collapsed.has(n.slug) && n.state !== n.screen.states[0];
  const rep = new Map(nodes.map((n) => [n.id, hidden(n) ? `${n.slug}#${n.screen!.states[0]}` : n.id]));
  const seen = new Set<string>();
  const out: GraphEdge[] = [];
  for (const e of edges) {
    const from = rep.get(e.from)!;
    const to = rep.get(e.to)!;
    if (from === to || seen.has(`${from}>${to}`)) continue;
    seen.add(`${from}>${to}`);
    out.push({ ...e, from, to });
  }
  return { nodes: nodes.filter((n) => !hidden(n)), edges: out };
}

/**
 * Lane layout: one lane per screen, its states left → right (wrapping after PER_ROW).
 * Lanes follow the navigation flow (BFS over screens from the hub); planned screens share the last lane.
 * Lanes are then packed into as many columns as best fit the viewport's aspect ratio.
 */
export function laneLayout(nodes: GraphNode[], edges: GraphEdge[], size: Size, aspect: number): Positions {
  if (nodes.length === 0) return {};
  const slugOf = new Map(nodes.map((n) => [n.id, n.slug]));
  const order: string[] = [hubOf(nodes, edges).slug];
  for (let i = 0; i < order.length; i++) {
    for (const e of edges)
      if (slugOf.get(e.from) === order[i]) {
        const s = slugOf.get(e.to)!;
        if (!order.includes(s) && !nodes.find((n) => n.id === e.to)?.planned) order.push(s);
      }
  }
  for (const n of nodes) if (!n.planned && !order.includes(n.slug)) order.push(n.slug);

  const lanes = [
    ...order.map((slug) => nodes.filter((n) => n.slug === slug && !n.planned)),
    nodes.filter((n) => n.planned),
  ].filter((l) => l.length);
  const block = (l: GraphNode[]) => ({
    w: Math.min(l.length, PER_ROW) * (size.w + GAP_X) - GAP_X,
    h: Math.ceil(l.length / PER_ROW) * (size.h + GAP_Y),
  });

  // Try every column count; keep lane order, split columns at balanced heights; pick the best fit for `aspect`.
  let best: { cols: GraphNode[][][]; score: number } | null = null;
  const totalH = lanes.reduce((n, l) => n + block(l).h, 0);
  for (let c = 1; c <= lanes.length; c++) {
    const target = totalH / c;
    const cols: GraphNode[][][] = [[]];
    let h = 0;
    for (const l of lanes) {
      const bh = block(l).h;
      if (h > 0 && h + bh > target * 1.15 && cols.length < c) {
        cols.push([]);
        h = 0;
      }
      cols.at(-1)!.push(l);
      h += bh;
    }
    const W = cols.reduce((n, col) => n + Math.max(...col.map((l) => block(l).w)), 0) + COL_GAP * (cols.length - 1);
    const H = Math.max(...cols.map((col) => col.reduce((n, l) => n + block(l).h, 0)));
    const score = Math.min(aspect / W, 1 / H); // relative zoom that would fit a viewport of this aspect
    if (!best || score > best.score) best = { cols, score };
  }

  const pos: Positions = {};
  let x0 = 0;
  for (const col of best!.cols) {
    let y0 = 0;
    for (const lane of col) {
      lane.forEach((n, i) => {
        pos[n.id] = { x: x0 + (i % PER_ROW) * (size.w + GAP_X), y: y0 + Math.floor(i / PER_ROW) * (size.h + GAP_Y) };
      });
      y0 += block(lane).h;
    }
    x0 += Math.max(...col.map((l) => block(l).w)) + COL_GAP;
  }
  return pos;
}

/**
 * Edge routing tuned for lanes:
 * - same lane, neighbours → straight across the gap (forward high, backward low so a pair never overlaps)
 * - same lane, farther apart → arc over (forward) or under (backward) the cards in between
 * - different lane column → straight across between the columns
 * - same column, different lane → swing out through the left gutter; downward edges wider than upward ones
 */
export function edgeGeometry(a: Pos, b: Pos, size: Size) {
  const { w, h } = size;
  const sameLane = Math.abs(a.y - b.y) < h / 2;
  let sx: number, sy: number, tx: number, ty: number, c1: Pos, c2: Pos;
  if (sameLane) {
    const forward = b.x > a.x;
    const adjacent = Math.abs(b.x - a.x) <= w + GAP_X + 1;
    if (adjacent) {
      const yOff = forward ? 0.42 : 0.58;
      sx = forward ? a.x + w : a.x;
      tx = forward ? b.x : b.x + w;
      sy = a.y + h * yOff;
      ty = b.y + h * yOff;
      const c = (tx - sx) / 2;
      c1 = { x: sx + c, y: sy };
      c2 = { x: tx - c, y: ty };
    } else {
      const arc = 140 + Math.abs(b.x - a.x) * 0.12;
      sx = a.x + w / 2;
      tx = b.x + w / 2;
      sy = forward ? a.y : a.y + h;
      ty = forward ? b.y : b.y + h;
      const dy = forward ? -arc : arc;
      c1 = { x: sx, y: sy + dy };
      c2 = { x: tx, y: ty + dy };
    }
  } else if (Math.abs(b.x - a.x) > w * 1.5) {
    const forward = b.x > a.x;
    sx = forward ? a.x + w : a.x;
    tx = forward ? b.x : b.x + w;
    sy = a.y + h * 0.5;
    ty = b.y + h * 0.3;
    const c = Math.max(80, Math.abs(tx - sx) / 2);
    c1 = { x: sx + (forward ? c : -c), y: sy };
    c2 = { x: tx - (forward ? c : -c), y: ty };
  } else {
    const down = b.y > a.y;
    const lanes = Math.max(1, Math.round(Math.abs(b.y - a.y) / (h + GAP_Y)));
    const g = (down ? 70 : 40) + lanes * (down ? 45 : 25);
    sx = a.x;
    tx = b.x;
    sy = a.y + h * (down ? 0.45 : 0.55);
    ty = b.y + h * (down ? 0.35 : 0.65);
    const gx = Math.min(sx, tx) - g;
    c1 = { x: gx, y: sy };
    c2 = { x: gx, y: ty };
  }
  const d = `M ${sx} ${sy} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${tx} ${ty}`;
  const mid = { x: (sx + 3 * c1.x + 3 * c2.x + tx) / 8, y: (sy + 3 * c1.y + 3 * c2.y + ty) / 8 };
  return { d, mid };
}

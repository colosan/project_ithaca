import type { SizeClass } from "@ithaca/kit";

/**
 * Human labels for size classes. The code (and native) names stay compact/medium/expanded/large;
 * the workbench shows what they mean: how many panes fit, and which device width it usually is.
 */
export const SIZE_CLASS: Record<SizeClass, { panes: string; device: string; range: string; desc: string }> = {
  compact: { panes: "1단", device: "폰 폭", range: "600 미만", desc: "한 번에 한 화면만 — 라이브러리 · 시트 목록 · 에디터를 오가며 본다" },
  medium: { panes: "2단", device: "태블릿 세로", range: "600–839", desc: "시트 목록 + 에디터. 라이브러리는 필요할 때 위에 띄운다" },
  expanded: { panes: "3단", device: "태블릿 가로", range: "840–1199", desc: "라이브러리 + 시트 목록 + 에디터" },
  large: { panes: "3단+", device: "데스크톱", range: "1200 이상", desc: "3단에 참조 패널까지 옆에 붙는다" },
};

export const sizeClassBadge = (c: SizeClass) => `${SIZE_CLASS[c].panes} · ${SIZE_CLASS[c].device}`;

export const sizeClassTitle = (c: SizeClass) =>
  `${c} — 폭 ${SIZE_CLASS[c].range}px: ${SIZE_CLASS[c].desc}.\n기기 종류가 아니라 창 폭으로 정해진다 (Mac 창을 좁히면 Mac 도 '폰 폭'이 된다).`;

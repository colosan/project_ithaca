import { createContext, useContext } from "react";
import { format, type Locale, type StringKey } from "../generated/strings";
import type { SizeClass } from "../generated/tokens";
import type { Platform, Sample } from "./samples";

export type Theme = "light" | "dark";

/** Everything a prototype knows about its world. The frame supplies it in place of a real device. */
export interface FrameInfo {
  sizeClass: SizeClass;
  width: number;
  height: number;
  /** Which OS this frame pretends to be — decides desktop-only features (MCP) and platform conventions. */
  platform: Platform;
  theme: Theme;
  locale: Locale;
  sample: Sample;
  /** Follow a link to another screen ("slug" or "slug#state"). A no-op in thumbnails. */
  navigate?: (to: string) => void;
  /** OS text size setting the frame simulates (1 = default). Type tokens already apply it. */
  textScale: number;
}

export const FrameContext = createContext<FrameInfo | null>(null);

export function useFrame(): FrameInfo {
  const frame = useContext(FrameContext);
  if (!frame) throw new Error("useFrame() must be called inside a workbench frame");
  return frame;
}

/**
 * Navigation for links inside a prototype — the same targets as meta.json `links`.
 * In the detail view it opens that screen, so a flow can be walked by clicking.
 */
export function useNavigate() {
  const { navigate } = useFrame();
  return (to: string) => navigate?.(to);
}

/** Looks up copy in the frame's locale. Use this instead of hard-coded copy (ADR-0005). */
export function useT() {
  const { locale } = useFrame();
  return (key: StringKey, params?: Record<string, string | number>) => format(locale, key, params);
}

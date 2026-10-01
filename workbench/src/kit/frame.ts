import { createContext, useContext } from "react";
import { format, type Locale, type StringKey } from "../generated/strings";
import type { SizeClass } from "../generated/tokens";
import type { Sample } from "./samples";

export type Theme = "light" | "dark";

/** Everything a prototype knows about its world. The frame supplies it in place of a real device. */
export interface FrameInfo {
  sizeClass: SizeClass;
  width: number;
  height: number;
  theme: Theme;
  locale: Locale;
  sample: Sample;
}

export const FrameContext = createContext<FrameInfo | null>(null);

export function useFrame(): FrameInfo {
  const frame = useContext(FrameContext);
  if (!frame) throw new Error("useFrame() must be called inside a workbench frame");
  return frame;
}

/** Looks up copy in the frame's locale. Use this instead of hard-coded copy (ADR-0005). */
export function useT() {
  const { locale } = useFrame();
  return (key: StringKey, params?: Record<string, string | number>) => format(locale, key, params);
}

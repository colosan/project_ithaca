import { createContext, useContext, type Dispatch } from "react";
import { format, type Locale, type SizeClass, type StringKey } from "@ithaca/kit";
import type { Action, SaveStatus, State } from "./store";

export type Overlay = null | "settings" | "palette" | "newProject" | "projectSettings" | "export";
export interface Toast { message: string; undo?: { label: string; run: () => void }; /** Stays until closed. */ sticky?: boolean }

export interface App {
  state: State;
  dispatch: Dispatch<Action>;
  locale: Locale;
  sizeClass: SizeClass;
  /** Which panes dock at the current width (App.panesFor). */
  panes: { compact: boolean; list: boolean; library: boolean; inspector: boolean };
  mac: boolean;
  /** No hover (phones, tablets): row actions are always visible instead of on hover. */
  touch: boolean;
  saveStatus: SaveStatus;
  overlay: Overlay;
  setOverlay: (o: Overlay) => void;
  /** Panels the user toggles: inspector, focus mode, library overlay, trash view, compact page. */
  view: { inspector: boolean; focus: boolean; libraryOpen: boolean; trash: boolean; compact: "library" | "list" | "editor" };
  setView: (patch: Partial<App["view"]>) => void;
  /** Ask before a destructive action when the preference says so. */
  confirm: (message: string) => boolean;
  toast: (t: Toast) => void;
}

export const AppContext = createContext<App | null>(null);

export function useApp() {
  const app = useContext(AppContext);
  if (!app) throw new Error("useApp() outside the app");
  return app;
}

export function useT() {
  const { locale } = useApp();
  return (key: StringKey, params?: Record<string, string | number>) => format(locale, key, params);
}

import { useEffect, useRef } from "react";
import type { Locale, Platform, Theme } from "@ithaca/kit";
import { Device, insetsFor, NO_INSETS, type Issues } from "./Frame";
import { screenBySlug, viewportById } from "./registry";

/** What tools/snap reads after each render: the hash it belongs to, defect counts and the marked texts. */
export interface CaptureResult {
  key: string;
  issues: Issues;
  marks: { kind: string; text: string }[];
}

declare global {
  interface Window {
    __capture?: CaptureResult;
  }
}

/**
 * #/capture/<slug>/<state>?w=&h=&p=&t=&l=&x=&v=
 * One frame at 1:1, nothing else on the page — for headless screenshots (pnpm design:snap).
 * w/h size · p platform · t theme · l locale · x text scale · v preset id whose safe area to use (optional).
 */
export function Capture({ slug, state, query }: { slug: string; state: string; query: URLSearchParams }) {
  const screen = screenBySlug[slug];
  const w = Number(query.get("w") ?? 390);
  const h = Number(query.get("h") ?? 844);
  const preset = query.get("v");
  const { insets } = preset && viewportById[preset] ? insetsFor({ id: "capture", preset, platform: viewportById[preset].os, w, h }) : { insets: NO_INSETS };
  const key = location.hash;
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    window.__capture = undefined;
  }, [key]);

  if (!screen) return <pre className="wb-error">unknown screen: {slug}</pre>;
  return (
    <div ref={ref} className="wb-capture">
      <Device
        width={w}
        height={h}
        platform={(query.get("p") ?? "ios") as Platform}
        theme={(query.get("t") ?? "light") as Theme}
        locale={(query.get("l") ?? "ko") as Locale}
        textScale={Number(query.get("x") ?? 1)}
        safeArea={insets}
        className="wb-device-flat"
        showIssues={false}
        onIssues={(issues) => {
          const marks = [...(ref.current?.querySelectorAll<HTMLElement>("[data-wb-issue]") ?? [])].map((el) => ({
            kind: el.dataset.wbIssue!,
            text: (el.textContent ?? "").trim().slice(0, 60),
          }));
          window.__capture = { key, issues, marks };
        }}
      >
        <screen.Prototype key={key} state={state} />
      </Device>
    </div>
  );
}

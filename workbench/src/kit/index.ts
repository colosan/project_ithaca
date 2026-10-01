// The only entry point prototypes import: `import { … } from "@ithaca/kit"`.
// Exports only tokens, copy and frame info. Anything without a native counterpart does not belong here.
export * from "../generated/tokens";
export { format, locales, type Locale, type StringKey } from "../generated/strings";
export { FrameContext, safePadding, useFrame, useNavigate, useT, type FrameInfo, type Insets, type Theme } from "./frame";
export {
  isDesktop, openContext, sample,
  type Folder, type ManuscriptLanguage, type Platform, type Project, type Sample, type SheetSummary,
} from "./samples";

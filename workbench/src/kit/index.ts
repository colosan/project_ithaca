// The only entry point prototypes import: `import { … } from "@ithaca/kit"`.
// Exports only tokens, copy and frame info. Anything without a native counterpart does not belong here.
export * from "../generated/tokens";
export { format, locales, type Locale, type StringKey } from "../generated/strings";
export { FrameContext, useFrame, useT, type FrameInfo, type Theme } from "./frame";
export { sample, type ManuscriptLanguage, type Sample } from "./samples";

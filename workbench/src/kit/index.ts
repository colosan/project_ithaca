// The only entry point prototypes import: `import { … } from "@ithaca/kit"`.
// Exports tokens, copy, frame info and the shared controls. Anything without a native counterpart does not belong here.
export * from "../generated/tokens";
export { format, locales, type Locale, type StringKey } from "../generated/strings";
export { FrameContext, safePadding, useFrame, useNavigate, useT, type FrameInfo, type Insets, type Theme } from "./frame";
export {
  isDesktop, openContext, sample,
  type Folder, type HistoryRecord, type ManuscriptLanguage, type Platform, type Project, type Sample, type SheetSummary,
} from "./samples";
export { type IconName } from "../generated/icons";
export { Button, Checkbox, Chip, Icon, IconButton, Radio, Segmented, Switch, TextField, type ButtonVariant, type IconSize } from "./components";

// New project and project settings (design/screens/new-project, project-settings).
import { useState } from "react";
import { color, radius, space, type, Button, Checkbox, Segmented, TextField, format } from "@ithaca/kit";
import { Dialog, DialogBody, Group, Row, usePressable } from "./Dialog";
import { useApp, useT } from "./ctx";
import { liveProjects, type GoalBasis, type ManuscriptLanguage } from "./store";

export function NewProject() {
  const t = useT();
  const { dispatch, setOverlay, locale, sizeClass } = useApp();
  const [title, setTitle] = useState("");
  const [language, setLanguage] = useState<ManuscriptLanguage>(locale);
  // Default folder names follow the manuscript language, so an English novel starts with Episodes · Lore · Notes.
  const defaults = (l: ManuscriptLanguage) => [format("ko", "folder.defaultSerial"), format("ko", "folder.defaultLore"), format("ko", "folder.defaultMaterial")];
  const [folders, setFolders] = useState(() => defaults(language).map((name) => ({ name, on: true })));
  const stacked = sizeClass === "compact";
  const create = () => {
    if (!title.trim()) return;
    dispatch({ type: "newProject", title: title.trim(), language, folders: folders.filter((f) => f.on && f.name.trim()).map((f) => f.name.trim()) });
    setOverlay(null);
  };
  return (
    <Dialog title={t("newProject.title")} footer={<><Button variant="ghost" onClick={() => setOverlay(null)}>{t("action.cancel")}</Button><Button variant="primary" disabled={!title.trim()} onClick={create}>{t("newProject.create")}</Button></>}>
      <DialogBody onKeyDown={(e) => e.key === "Enter" && !e.nativeEvent.isComposing && create()}>
        <TextField value={title} onChange={setTitle} placeholder={t("newProject.titlePlaceholder")} autoFocus />
        <Group>
          <Row label={t("projectSettings.language")} hint={t("projectSettings.languageHint")} column={stacked}>
            <Segmented
              items={[["ko", t("language.ko")], ["en", t("language.en")]]}
              value={language}
              onChange={(l) => { setLanguage(l); setFolders(defaults(l).map((name) => ({ name, on: true }))); }}
              full={stacked}
            />
          </Row>
        </Group>
        <div>
          <div style={{ ...type.label, color: color.inkTertiary, marginBottom: space[100] }}>{t("newProject.folders")}</div>
          <Group>
            {folders.map((f, i) => (
              <div key={i} style={{ display: "flex", alignItems: "center", gap: space[150], padding: `${space[100]} ${space[200]}` }}>
                <FolderToggle on={f.on} label={f.name} onToggle={() => setFolders((xs) => xs.map((x, j) => (j === i ? { ...x, on: !x.on } : x)))} />
                <TextField value={f.name} onChange={(name) => setFolders((xs) => xs.map((x, j) => (j === i ? { ...x, name } : x)))} />
              </div>
            ))}
          </Group>
          <div style={{ ...type.caption, color: color.inkTertiary, marginTop: space[100] }}>{t("newProject.foldersHint")}</div>
        </div>
      </DialogBody>
    </Dialog>
  );
}

export function ProjectSettings() {
  const t = useT();
  const app = useApp();
  const { state, dispatch, setOverlay, sizeClass } = app;
  const project = state.projects.find((p) => p.id === state.ui.projectId)!;
  const [goal, setGoal] = useState(project.goal ? String(project.goal.count) : "");
  const [title, setTitle] = useState(project.title);
  const stacked = sizeClass === "compact" || sizeClass === "medium";
  const update = (patch: Parameters<typeof dispatch>[0] extends infer A ? (A extends { type: "updateProject"; patch: infer P } ? P : never) : never) =>
    dispatch({ type: "updateProject", id: project.id, patch });
  const basis: GoalBasis = project.goal?.basis ?? (project.language === "ko" ? "withSpaces" : "words");
  const saveGoal = (text: string, b: GoalBasis = basis) => {
    setGoal(text);
    const n = parseInt(text.replace(/[^\d]/g, ""), 10);
    update({ goal: n > 0 ? { count: n, basis: b } : null });
  };
  return (
    <Dialog title={t("projectSettings.title")} footer={<Button variant="primary" onClick={() => setOverlay(null)}>{t("action.done")}</Button>}>
      <DialogBody>
        <Group>
          <Row label={t("projectSettings.name")} column>
            {/* A project always has a name: an emptied field keeps the last one. */}
            <TextField value={title} onChange={(v) => { setTitle(v); if (v.trim()) update({ title: v.trim() }); }} placeholder={project.title} />
          </Row>
          <Row label={t("projectSettings.language")} hint={t("projectSettings.languageHint")} column={stacked} divided>
            <Segmented items={[["ko", t("language.ko")], ["en", t("language.en")]]} value={project.language} onChange={(language) => update({ language })} full={stacked} />
          </Row>
        </Group>
        <Group>
          <Row label={t("projectSettings.goal")} hint={t("projectSettings.goalHint")} column>
            <div style={{ display: "flex", gap: space[100], flexWrap: "wrap" }}>
              <TextField value={goal} onChange={(v) => saveGoal(v)} placeholder={t("projectSettings.goalNone")} />
              <Segmented
                items={[["withSpaces", t("goal.basis.withSpaces")], ["withoutSpaces", t("goal.basis.withoutSpaces")], ["words", t("goal.basis.words")]]}
                value={basis}
                onChange={(b) => saveGoal(goal, b)}
              />
            </div>
          </Row>
        </Group>
        {liveProjects(state).length > 1 && (
          <div>
            <Button
              variant="danger"
              icon="delete"
              onClick={() => {
                if (!window.confirm(t("projectSettings.deleteConfirm", { name: project.title }))) return;
                dispatch({ type: "deleteProject", id: project.id });
                setOverlay(null);
                // Kept 30 days; the toast stays until dismissed so the undo can't be missed.
                app.toast({ message: t("projectSettings.deleted", { name: project.title }), sticky: true, undo: { label: t("action.undo"), run: () => dispatch({ type: "undeleteProject", id: project.id }) } });
              }}
            >
              {t("projectSettings.delete")}
            </Button>
          </div>
        )}
      </DialogBody>
    </Dialog>
  );
}

/** A keyboard-operable checkbox for a default folder. */
function FolderToggle({ on, label, onToggle }: { on: boolean; label: string; onToggle: () => void }) {
  const { ringStyle, ...press } = usePressable(onToggle);
  return (
    <span {...press} role="checkbox" aria-checked={on} aria-label={label} style={{ cursor: "pointer", display: "inline-flex", borderRadius: radius.piece, ...ringStyle }}>
      <Checkbox on={on} />
    </span>
  );
}

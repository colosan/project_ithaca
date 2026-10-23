// Library pane: projects → folders, trash, new project, settings.
import { useState, type ReactNode } from "react";
import { color, pane, radius, size, space, type, Button, Icon, IconButton, TextField } from "@ithaca/kit";
import { useApp, useT } from "./ctx";
import { usePressable } from "./Dialog";
import { openSettings } from "./Settings";
import { foldersOf, liveProjects, sheetsIn, trashOf } from "./store";

const hairline = (c: string) => `${size.strokeHairline} solid ${c}`;

export function Library({ full }: { full?: boolean }) {
  const t = useT();
  const app = useApp();
  const { state, dispatch, setView, setOverlay } = app;
  const [editing, setEditing] = useState<string | null>(null); // folder id being renamed, or "new"
  const [draft, setDraft] = useState("");
  const trashCount = trashOf(state, state.ui.projectId).length;

  const commit = () => {
    const name = draft.trim();
    if (name && editing === "new") dispatch({ type: "newFolder", projectId: state.ui.projectId, name });
    else if (name && editing) dispatch({ type: "renameFolder", id: editing, name });
    setEditing(null);
  };
  const field = (
    <div
      style={{ padding: `${space[25]} ${space[100]} ${space[25]} ${space[300]}` }}
      onKeyDown={(e) => {
        if (e.nativeEvent.isComposing) return;
        if (e.key === "Enter") commit();
        if (e.key === "Escape") { e.stopPropagation(); setEditing(null); }
      }}
      onBlur={commit}
    >
      <TextField value={draft} onChange={setDraft} autoFocus placeholder={t("folder.namePlaceholder")} />
    </div>
  );

  return (
    <aside style={{ width: full ? "100%" : pane.library, flex: "none", display: "flex", flexDirection: "column", background: color.surfaceSidebar, borderRight: full ? undefined : hairline(color.lineSubtle) }}>
      <div style={{ ...type.label, color: color.inkTertiary, padding: `${space[200]} ${space[200]} ${space[100]}` }}>{t("library.title")}</div>
      <div style={{ flex: 1, overflow: "auto", padding: `0 ${space[100]}` }}>
        {liveProjects(state).map((p) => {
          const open = p.id === state.ui.projectId;
          return (
            <div key={p.id} style={{ marginBottom: space[150] }}>
              <Row muted={!open} onClick={() => !open && dispatch({ type: "selectProject", id: p.id })}>
                <Icon name={open ? "expanded" : "collapsed"} size="sm" color={color.inkTertiary} />
                <span style={{ ...type.label, fontWeight: type.heading.fontWeight, flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{p.title}</span>
                {open && <IconButton icon="more" label={t("projectSettings.title")} onClick={() => setOverlay("projectSettings")} />}
              </Row>
              {open &&
                foldersOf(state, p.id).map((f) =>
                  editing === f.id ? (
                    <div key={f.id}>{field}</div>
                  ) : (
                    <Row
                      key={f.id}
                      indent
                      active={f.id === state.ui.folderId && !app.view.trash}
                      onClick={() => {
                        dispatch({ type: "selectFolder", id: f.id });
                        // When the sheet list lives inside the overlay too, keep it open so a sheet can be picked.
                        setView({ trash: false, libraryOpen: app.view.libraryOpen && !app.panes.list, compact: "list" });
                      }}
                      onDoubleClick={() => { setEditing(f.id); setDraft(f.name); }}
                      trailing={<FolderMenu id={f.id} name={f.name} onRename={() => { setEditing(f.id); setDraft(f.name); }} />}
                    >
                      <Icon name="folder" size="sm" color={f.id === state.ui.folderId && !app.view.trash ? color.accentPrimary : color.inkTertiary} />
                      <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{f.name}</span>
                      <span style={{ ...type.caption, color: color.inkTertiary }}>{sheetsIn(state, f.id).length}</span>
                    </Row>
                  ),
                )}
              {open &&
                (editing === "new" ? (
                  field
                ) : (
                  <Row indent muted onClick={() => { setEditing("new"); setDraft(""); }}>
                    <Icon name="add" size="sm" />
                    <span style={type.caption}>{t("folder.new")}</span>
                  </Row>
                ))}
            </div>
          );
        })}
        <Row muted active={app.view.trash} onClick={() => setView({ trash: true, libraryOpen: false, compact: "list" })}>
          <Icon name="trash" size="sm" />
          <span style={{ flex: 1 }}>{t("trash.title")}</span>
          {trashCount > 0 && <span style={{ ...type.caption, color: color.inkTertiary }}>{trashCount}</span>}
        </Row>
      </div>
      <BackupReminder />
      <div style={{ display: "flex", alignItems: "center", gap: space[100], padding: space[100], borderTop: hairline(color.lineSubtle) }}>
        <Button variant="ghost" icon="add" onClick={() => setOverlay("newProject")}>{t("library.newProject")}</Button>
        <span style={{ flex: 1 }} />
        <IconButton icon="settings" label={t("prefs.title")} onClick={() => setOverlay("settings")} />
      </div>
    </aside>
  );
}

/** Rename · delete for a folder. Shown on hover like a native context menu's shortcut. */
function FolderMenu({ id, name, onRename }: { id: string; name: string; onRename: () => void }) {
  const t = useT();
  const { dispatch, confirm, state, toast } = useApp();
  const count = sheetsIn(state, id).length;
  return (
    <span style={{ display: "inline-flex" }} onClick={(e) => e.stopPropagation()}>
      <IconButton icon="rename" label={t("folder.rename")} onClick={onRename} />
      <IconButton
        icon="delete"
        label={t("folder.delete")}
        onClick={() => {
          if (!confirm(count ? t("folder.deleteConfirm", { name, count }) : t("folder.deleteConfirmEmpty", { name }))) return;
          dispatch({ type: "deleteFolder", id });
          toast({ message: t("folder.deleted", { name }), undo: { label: t("action.undo"), run: () => dispatch({ type: "undeleteFolder", id }) } });
        }}
      />
    </span>
  );
}

function Row({
  children, active, muted, indent, onClick, onDoubleClick, trailing,
}: { children: ReactNode; active?: boolean; muted?: boolean; indent?: boolean; onClick?: () => void; onDoubleClick?: () => void; trailing?: ReactNode }) {
  const { touch } = useApp();
  const [hover, setHover] = useState(false);
  const { ringStyle, ...press } = usePressable(onClick ?? (() => {}));
  return (
    <div
      {...(onClick ? press : {})}
      onDoubleClick={onDoubleClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: "flex", alignItems: "center", gap: space[100],
        minHeight: size.controlMd, padding: `0 ${space[100]}`, paddingLeft: indent ? space[300] : space[100],
        borderRadius: radius.control,
        background: active ? color.surfaceSelected : hover && onClick ? color.surfaceList : "transparent",
        color: muted ? color.inkTertiary : active ? color.inkPrimary : color.inkSecondary,
        cursor: onClick ? "pointer" : undefined,
        ...(onClick ? ringStyle : {}),
      }}
    >
      {children}
      {trailing && (hover || touch || active) && trailing}
    </div>
  );
}

/** Web data lives in one browser: nudge for a backup file when the last one is a week old (or never). */
function BackupReminder() {
  const t = useT();
  const app = useApp();
  const { state } = app;
  const last = state.prefs.lastBackup;
  const { ringStyle, ...press } = usePressable(() => openSettings(app, "backup"));
  const days = last ? Math.floor((Date.now() - last) / 86_400_000) : null;
  const words = state.sheets.reduce((n, s) => n + s.body.length, 0);
  if ((days !== null && days < 7) || words < 2000) return null;
  return (
    <div
      {...press}
      role="button"
      style={{ display: "flex", gap: space[100], alignItems: "flex-start", margin: `0 ${space[100]} ${space[100]}`, padding: space[150], borderRadius: radius.panel, background: color.accentSoft, color: color.stateWarning, ...type.caption, cursor: "pointer", ...ringStyle }}
    >
      <Icon name="backup" size="sm" />
      <span style={{ flex: 1, minWidth: 0 }}>{days === null ? t("backup.reminderNever") : t("backup.reminder", { count: days })}</span>
    </div>
  );
}

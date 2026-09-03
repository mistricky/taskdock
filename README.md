# TaskDock

Bar taskbar plugin for Noctalia Shell, ported from the core `Modules/Bar/Widgets/Taskbar.qml` widget.

## Features

- Running windows with focus / close / desktop actions
- Pinned apps (uses shell `Settings.data.dock.pinnedApps`)
- Drag-and-drop reorder
- Scroll to cycle focused window
- Same filter options as core Taskbar (monitor, workspace, titles, smart width)

## Entry points

- `BarWidget.qml` — bar widget
- `Settings.qml` — plugin settings
- `Main.qml` — plugin host (no runtime logic)

## Install

Ensure this directory is linked or copied as:

```text
~/.config/noctalia/plugins/taskdock
```

Enable the plugin in Noctalia settings, then add **plugin:taskdock** to a bar section.

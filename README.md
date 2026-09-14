# TaskDock

Bar taskbar plugin for Noctalia Shell, ported from the core `Modules/Bar/Widgets/Taskbar.qml` widget.

## Features

- Running windows with focus / close / desktop actions
- macOS-style dock: after closing a window, keep the app icon while the process is still alive; click re-launches / restores; drop when the process dies
- Pinned apps (uses shell `Settings.data.dock.pinnedApps`)
- Drag-and-drop reorder
- Scroll to cycle focused window
- Same filter options as core Taskbar (monitor, workspace, titles, smart width)

Does **not** use the system tray. IME / Wi‑Fi / Bluetooth indicators never appear on the dock.

## Entry points

- `BarWidget.qml` — bar widget
- `Settings.qml` — plugin settings
- `Main.qml` — shared window snapshots and event-driven process lifecycle host
- `scripts/process_watch.py` — one Linux pidfd listener for all bar instances

## Install

Ensure this directory is linked or copied as:

```text
~/.config/noctalia/plugins/taskdock
```

Enable the plugin in Noctalia settings, then add **plugin:taskdock** to a bar section.

## State synchronization

Window changes come from Noctalia's compositor events. Window IDs are deduplicated;
the count is **windows**, not OS processes. Open window pickers refresh with the model.

On Hyprland, the host obtains window PIDs from Quickshell's toplevel IPC data.
A single Python helper opens `pidfd`s and blocks on kernel events (no periodic
process scans, shell scripts, `pgrep`, root access or third-party Python packages).
Closing a window keeps its icon only while an observed process is confirmed alive;
an exit event removes the background icon. Pinned icons follow the pinned-app setting.

Main-process detection only climbs same-user, same-executable ancestors, excluding
generic runtimes such as Python, Node, Electron and Java. Different helper binaries,
sandbox boundaries and application-specific process handoffs are not guessed:
the original window process is the conservative fallback. This is not a universal
application-process-tree monitor. Multiple independent observed processes can keep
one application's background icon alive.

Requires Linux `pidfd_open` support and Python 3.9+. Backend PID absence or listener
failure degrades to window-only state, never name-based liveness. Toggle background
tracking off/on or reload the plugin to restart a stopped listener. Reload reconstructs
associations from current windows; apps already windowless are not rediscovered.

## Verification

```sh
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
node tests/model.test.cjs
/usr/lib/qt6/bin/qmlformat Main.qml >/dev/null
/usr/lib/qt6/bin/qmlformat BarWidget.qml >/dev/null
/usr/lib/qt6/bin/qmlformat Panel.qml >/dev/null
```

The Quickshell integration test runs a separate headless config, uses an owned test
process, and does not close or focus desktop applications. It is skipped without `qs`.

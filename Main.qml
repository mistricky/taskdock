import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Services.Compositor

Item {
  id: root

  property var pluginApi: null

  // Mirrored settings — written explicitly on save so BarWidget always sees updates
  property string hideMode: "hidden"
  property bool onlySameOutput: false
  property bool onlyActiveWorkspaces: false
  property bool colorizeIcons: false
  property bool showTitle: false
  property bool smartWidth: false
  property int maxTaskbarWidth: 100
  property int titleWidth: 120
  property bool showPinnedApps: false
  property bool keepBackgroundApps: true
  property real iconScale: 0.8

  property int settingsVersion: 0

  // One authoritative, proxy-free snapshot and one pidfd listener per plugin,
  // not per bar/output. Non-Hyprland backends keep normal window-only behavior
  // until they expose a trustworthy window PID.
  property var trackedWindows: []
  property var aliveWindowIds: ({})
  property int processGeneration: 0
  property bool processReady: false
  property int nextWindowToken: 0
  property string lastProcessSnapshot: ""

  function windowId(id) {
    const value = String(id ?? "");
    return CompositorService.isHyprland ? value.replace(/^0x/i, "").toLowerCase() : value;
  }

  function captureWindows() {
    const pids = ({});
    if (CompositorService.isHyprland) {
      const tops = Hyprland.toplevels.values;
      for (var t = 0; t < tops.length; t++) {
        const top = tops[t];
        if (top)
          pids[windowId(top.address)] = Number(top.lastIpcObject?.pid || 0);
      }
    }
    const next = [];
    const seen = new Set();
    for (var i = 0; i < CompositorService.windows.count; i++) {
      const w = CompositorService.windows.get(i);
      const id = windowId(w.id);
      if (!id || seen.has(id))
        continue;
      seen.add(id);
      const pid = pids[id] || 0;
      const previous = trackedWindows.find(w => w.id === id && w.pid === pid);
      const token = previous ? previous.trackId : String(++nextWindowToken);
      next.push({"id": id, "trackId": token, "pid": pid,
                  "appId": String(w.appId || ""), "title": String(w.title || ""),
                  "workspaceId": w.workspaceId, "workspaceName": String(w.workspaceName || ""),
                  "output": String(w.output || ""), "isFocused": w.isFocused === true});
    }
    trackedWindows = next;
    sendProcessSnapshot();
  }

  function sendProcessSnapshot() {
    if (!processReady || !processWatcher.running)
      return;
    const windows = trackedWindows.map(w => ({"id": w.trackId, "pid": w.pid}));
    const snapshot = JSON.stringify(windows);
    // Focus/title/workspace events update the UI, not process registration.
    if (snapshot === lastProcessSnapshot)
      return;
    lastProcessSnapshot = snapshot;
    processGeneration++;
    processWatcher.write(JSON.stringify({"generation": processGeneration,
                                          "windows": windows}) + "\n");
  }

  Connections {
    target: CompositorService
    function onWindowListChanged() { Qt.callLater(root.captureWindows); }
    function onActiveWindowChanged() { Qt.callLater(root.captureWindows); }
    function onWorkspaceChanged() { Qt.callLater(root.captureWindows); }
  }

  Process {
    id: processWatcher
    command: ["python3", "-u", root.pluginApi?.pluginDir + "/scripts/process_watch.py"]
    stdinEnabled: true
    running: !!root.pluginApi && root.keepBackgroundApps && CompositorService.isHyprland
    stdout: SplitParser {
      onRead: function(line) {
        try {
          const event = JSON.parse(line);
          if (event.ready === true) {
            root.lastProcessSnapshot = "";
            root.processReady = true;
            root.sendProcessSnapshot();
          } else if (event.generation === root.processGeneration && Array.isArray(event.alive)) {
            const alive = ({});
            event.alive.forEach(id => { alive[id] = true; });
            root.aliveWindowIds = alive;
          }
        } catch (e) {
          Logger.w("TaskDock", "Invalid process watcher event");
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) { Logger.w("TaskDock", "Process watcher: " + line); }
    }
    onExited: function(exitCode, exitStatus) {
      root.processReady = false;
      root.aliveWindowIds = ({});
      if (root.keepBackgroundApps)
        Logger.w("TaskDock", "Process watcher stopped; using window-only state (" + exitCode + ")");
    }
  }

  // Stack picker payload for Panel.qml (SmartPanel host)
  property var stackWindows: []
  property string stackAppId: ""
  property string stackTitle: ""
  property int stackVersion: 0

  // Optional icon resolver injected from BarWidget (has ThemeIcons / desktop lookups)
  property var resolveIconSource: null
  property var stackWindowLabel: null

  function defaults() {
    return pluginApi?.manifest?.metadata?.defaultSettings || ({});
  }

  function applyFromSettings() {
    const d = defaults();
    const s = pluginApi?.pluginSettings || ({});

    hideMode = s.hideMode ?? d.hideMode ?? "hidden";
    onlySameOutput = s.onlySameOutput ?? d.onlySameOutput ?? false;
    onlyActiveWorkspaces = s.onlyActiveWorkspaces ?? d.onlyActiveWorkspaces ?? false;
    colorizeIcons = s.colorizeIcons ?? d.colorizeIcons ?? false;
    showTitle = s.showTitle ?? d.showTitle ?? false;
    smartWidth = s.smartWidth ?? d.smartWidth ?? false;
    maxTaskbarWidth = s.maxTaskbarWidth ?? d.maxTaskbarWidth ?? 100;
    titleWidth = s.titleWidth ?? d.titleWidth ?? 120;
    showPinnedApps = s.showPinnedApps ?? d.showPinnedApps ?? false;
    keepBackgroundApps = s.keepBackgroundApps ?? d.keepBackgroundApps ?? true;
    iconScale = s.iconScale ?? d.iconScale ?? 0.8;
    settingsVersion++;

    Logger.d("TaskDock", "Settings applied to mainInstance v" + settingsVersion);
  }

  function setStackPicker(payload) {
    stackWindows = (payload && payload.windows) ? payload.windows : [];
    stackAppId = (payload && payload.appId) ? payload.appId : "";
    stackTitle = (payload && payload.title) ? payload.title : "";
    stackVersion++;
  }

  function clearStackPicker() {
    stackWindows = [];
    stackAppId = "";
    stackTitle = "";
    stackVersion++;
  }

  Component.onCompleted: {
    applyFromSettings();
    Qt.callLater(captureWindows);
  }

  onPluginApiChanged: {
    if (pluginApi)
      applyFromSettings();
  }
}

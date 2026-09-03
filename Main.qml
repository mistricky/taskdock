import QtQuick
import qs.Commons

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
  property real iconScale: 0.8

  property int settingsVersion: 0

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

  Component.onCompleted: applyFromSettings()

  onPluginApiChanged: {
    if (pluginApi)
      applyFromSettings();
  }
}

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  property var pluginApi: null

  readonly property var main: pluginApi?.mainInstance
  readonly property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

  readonly property bool isVerticalBar: {
    const pos = Settings.data.bar.position;
    return pos === "left" || pos === "right";
  }

  // Edit buffer — seeded from mainInstance (already merged defaults + disk)
  property string valueHideMode: main?.hideMode ?? defaults.hideMode ?? "hidden"
  property bool valueOnlyActiveWorkspaces: main?.onlyActiveWorkspaces ?? defaults.onlyActiveWorkspaces ?? false
  property bool valueOnlySameOutput: main?.onlySameOutput ?? defaults.onlySameOutput ?? false
  property bool valueColorizeIcons: main?.colorizeIcons ?? defaults.colorizeIcons ?? false
  property bool valueShowTitle: isVerticalBar ? false : (main?.showTitle ?? defaults.showTitle ?? false)
  property bool valueSmartWidth: main?.smartWidth ?? defaults.smartWidth ?? true
  property int valueMaxTaskbarWidth: main?.maxTaskbarWidth ?? defaults.maxTaskbarWidth ?? 40
  property int valueTitleWidth: main?.titleWidth ?? defaults.titleWidth ?? 120
  property bool valueShowPinnedApps: main?.showPinnedApps ?? defaults.showPinnedApps ?? false
  property bool valueKeepBackgroundApps: main?.keepBackgroundApps ?? defaults.keepBackgroundApps ?? true
  property real valueIconScale: main?.iconScale ?? defaults.iconScale ?? 0.8

  spacing: Style.marginM

  Component.onCompleted: {
    // Re-seed from live mainInstance once loader finishes injecting pluginApi
    if (main) {
      valueHideMode = main.hideMode;
      valueOnlyActiveWorkspaces = main.onlyActiveWorkspaces;
      valueOnlySameOutput = main.onlySameOutput;
      valueColorizeIcons = main.colorizeIcons;
      valueShowTitle = isVerticalBar ? false : main.showTitle;
      valueSmartWidth = main.smartWidth;
      valueMaxTaskbarWidth = main.maxTaskbarWidth;
      valueTitleWidth = main.titleWidth;
      valueShowPinnedApps = main.showPinnedApps;
      valueKeepBackgroundApps = main.keepBackgroundApps;
      valueIconScale = main.iconScale;
    }
  }

  function saveSettings() {
    if (!pluginApi || !pluginApi.pluginSettings) {
      Logger.e("TaskDock", "Cannot save settings: pluginApi is null");
      return;
    }

    pluginApi.pluginSettings.hideMode = valueHideMode;
    pluginApi.pluginSettings.onlySameOutput = valueOnlySameOutput;
    pluginApi.pluginSettings.onlyActiveWorkspaces = valueOnlyActiveWorkspaces;
    pluginApi.pluginSettings.colorizeIcons = valueColorizeIcons;
    pluginApi.pluginSettings.showTitle = valueShowTitle;
    pluginApi.pluginSettings.smartWidth = valueSmartWidth;
    pluginApi.pluginSettings.maxTaskbarWidth = valueMaxTaskbarWidth;
    pluginApi.pluginSettings.titleWidth = parseInt(titleWidthInput.text) || (defaults.titleWidth ?? 120);
    pluginApi.pluginSettings.showPinnedApps = valueShowPinnedApps;
    pluginApi.pluginSettings.keepBackgroundApps = valueKeepBackgroundApps;
    pluginApi.pluginSettings.iconScale = valueIconScale;

    // Drop legacy keys from the previous TaskDock stub
    delete pluginApi.pluginSettings.message;
    delete pluginApi.pluginSettings.iconColor;

    pluginApi.saveSettings();

    // Push into mainInstance so BarWidget bindings update immediately
    if (pluginApi.mainInstance && pluginApi.mainInstance.applyFromSettings) {
      pluginApi.mainInstance.applyFromSettings();
    }

    Logger.d("TaskDock", "Settings saved successfully");
  }

  NComboBox {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.hideMode.label") || "Hide mode"
    description: pluginApi?.tr("settings.hideMode.desc") || ""
    model: [
      {
        "key": "visible",
        "name": pluginApi?.tr("hideModes.visible") || "Always visible"
      },
      {
        "key": "hidden",
        "name": pluginApi?.tr("hideModes.hidden") || "Hide when empty"
      },
      {
        "key": "transparent",
        "name": pluginApi?.tr("hideModes.transparent") || "Transparent when empty"
      }
    ]
    currentKey: root.valueHideMode
    onSelected: key => {
                  root.valueHideMode = key;
                  saveSettings();
                }
    defaultValue: defaults.hideMode ?? "hidden"
  }

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.onlySameOutput.label") || "Only same monitor"
    description: pluginApi?.tr("settings.onlySameOutput.desc") || ""
    checked: root.valueOnlySameOutput
    onToggled: checked => {
                 root.valueOnlySameOutput = checked;
                 saveSettings();
               }
    defaultValue: defaults.onlySameOutput ?? false
  }

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.onlyActiveWorkspaces.label") || "Only active workspaces"
    description: pluginApi?.tr("settings.onlyActiveWorkspaces.desc") || ""
    checked: root.valueOnlyActiveWorkspaces
    onToggled: checked => {
                 root.valueOnlyActiveWorkspaces = checked;
                 saveSettings();
               }
    defaultValue: defaults.onlyActiveWorkspaces ?? false
  }

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.colorizeIcons.label") || "Colorize icons"
    description: pluginApi?.tr("settings.colorizeIcons.desc") || ""
    checked: root.valueColorizeIcons
    onToggled: checked => {
                 root.valueColorizeIcons = checked;
                 saveSettings();
               }
    defaultValue: defaults.colorizeIcons ?? false
  }

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.showPinnedApps.label") || "Show pinned apps"
    description: pluginApi?.tr("settings.showPinnedApps.desc") || ""
    checked: root.valueShowPinnedApps
    onToggled: checked => {
                 root.valueShowPinnedApps = checked;
                 saveSettings();
               }
    defaultValue: defaults.showPinnedApps ?? false
  }

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.keepBackgroundApps.label") || "Keep background apps"
    description: pluginApi?.tr("settings.keepBackgroundApps.desc") || ""
    checked: root.valueKeepBackgroundApps
    onToggled: checked => {
                 root.valueKeepBackgroundApps = checked;
                 saveSettings();
               }
    defaultValue: defaults.keepBackgroundApps ?? true
  }

  NValueSlider {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.iconScale.label") || "Icon scale"
    description: pluginApi?.tr("settings.iconScale.desc") || ""
    from: 0.5
    to: 1
    stepSize: 0.01
    showReset: true
    value: root.valueIconScale
    defaultValue: defaults.iconScale ?? 0.8
    onMoved: value => {
               root.valueIconScale = value;
               saveSettings();
             }
    text: Math.round(root.valueIconScale * 100) + "%"
  }

  NToggle {
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.showTitle.label") || "Show title"
    description: isVerticalBar ? (pluginApi?.tr("settings.showTitle.descDisabled") || "") : (pluginApi?.tr("settings.showTitle.desc") || "")
    checked: root.valueShowTitle
    onToggled: checked => {
                 root.valueShowTitle = checked;
                 saveSettings();
               }
    enabled: !isVerticalBar
    defaultValue: defaults.showTitle ?? false
  }

  NTextInput {
    id: titleWidthInput
    visible: root.valueShowTitle && !isVerticalBar
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.titleWidth.label") || "Title width"
    description: pluginApi?.tr("settings.titleWidth.desc") || ""
    text: String(root.valueTitleWidth)
    placeholderText: pluginApi?.tr("placeholders.titleWidth") || "Width in pixels"
    onEditingFinished: {
      root.valueTitleWidth = parseInt(text) || (defaults.titleWidth ?? 120);
      saveSettings();
    }
    defaultValue: String(defaults.titleWidth ?? 120)
  }

  NToggle {
    Layout.fillWidth: true
    visible: !isVerticalBar && root.valueShowTitle
    label: pluginApi?.tr("settings.smartWidth.label") || "Smart width"
    description: pluginApi?.tr("settings.smartWidth.desc") || ""
    checked: root.valueSmartWidth
    onToggled: checked => {
                 root.valueSmartWidth = checked;
                 saveSettings();
               }
    defaultValue: defaults.smartWidth ?? true
  }

  NValueSlider {
    visible: root.valueSmartWidth && !isVerticalBar
    Layout.fillWidth: true
    label: pluginApi?.tr("settings.maxTaskbarWidth.label") || "Max taskbar width"
    description: pluginApi?.tr("settings.maxTaskbarWidth.desc") || ""
    from: 10
    to: 100
    stepSize: 5
    showReset: true
    value: root.valueMaxTaskbarWidth
    defaultValue: defaults.maxTaskbarWidth ?? 40
    onMoved: value => {
               root.valueMaxTaskbarWidth = Math.round(value);
               saveSettings();
             }
    text: Math.round(root.valueMaxTaskbarWidth) + "%"
  }
}

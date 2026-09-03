import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Services.Compositor
import qs.Services.System
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  property var pluginApi: null
  property ShellScreen screen

  // Widget properties passed from Bar.qml for per-instance settings
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  // Explicit screenName property ensures reactive binding when screen changes
  readonly property string screenName: screen ? screen.name : ""
  readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
  readonly property bool isVerticalBar: barPosition === "left" || barPosition === "right"
  readonly property real barHeight: Style.getBarHeightForScreen(screenName)
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
  readonly property real barFontSize: Style.getBarFontSizeForScreen(screenName)

  // Live settings from Main.qml (updated explicitly on save — reliable QML reactivity)
  readonly property var main: pluginApi?.mainInstance
  readonly property int settingsVersion: main?.settingsVersion ?? 0

  property bool hasWindow: false
  // Defaults: show every open window icon (all monitors + all workspaces)
  readonly property string hideMode: main?.hideMode ?? "hidden"
  readonly property bool onlySameOutput: main?.onlySameOutput ?? false
  readonly property bool onlyActiveWorkspaces: main?.onlyActiveWorkspaces ?? false
  readonly property bool showTitle: isVerticalBar ? false : (main?.showTitle ?? false)
  readonly property bool smartWidth: main?.smartWidth ?? false
  readonly property int maxTaskbarWidthPercent: main?.maxTaskbarWidth ?? 100
  readonly property real iconScale: main?.iconScale ?? 0.8
  readonly property bool colorizeIcons: main?.colorizeIcons ?? false
  readonly property bool showPinnedApps: main?.showPinnedApps ?? false
  readonly property int itemSize: Style.toOdd(capsuleHeight * Math.max(0.1, iconScale))

  // Maximum width for the taskbar widget to prevent overlapping with other widgets
  readonly property real maxTaskbarWidth: {
    if (!screen || isVerticalBar || !smartWidth || maxTaskbarWidthPercent <= 0)
      return 0;
    var barFloating = Settings.data.bar.barType === "floating";
    var barMarginH = barFloating ? Math.ceil(Settings.data.bar.marginHorizontal) : 0;
    var availableWidth = screen.width - (barMarginH * 2);
    return Math.round(availableWidth * (maxTaskbarWidthPercent / 100));
  }

  readonly property int titleWidth: {
    // Depend on settingsVersion so title width recalculates after settings apply
    const _v = settingsVersion;
    var calculatedWidth = main?.titleWidth ?? 120;

    // Shrink title width if it exceeds maxTaskbarWidth when smartWidth is enabled
    if (smartWidth && combinedModel.length > 0) {
      if (maxTaskbarWidth > 0) {
        var entriesCount = combinedModel.length;
        var maxWidthPerEntry = (maxTaskbarWidth / entriesCount) - itemSize - Style.marginS - Style.margin2M;
        calculatedWidth = Math.min(calculatedWidth, maxWidthPerEntry);
      }

      calculatedWidth = Math.max(Math.round(calculatedWidth), 20);
    }

    return calculatedWidth;
  }

  // Context menu state - store ID instead of object reference to avoid stale references
  property string selectedWindowId: ""
  property string selectedAppId: ""

  // Helper to get the current window object from ID (supports stacked groups)
  function getSelectedWindow() {
    if (!selectedWindowId)
      return null;

    for (var i = 0; i < combinedModel.length; i++) {
      const entry = combinedModel[i];

      if (!entry)
        continue;

      // Using loose equality on purpose (==)
      if (entry.id == selectedWindowId && entry.window)
        return entry.window;

      const windows = entry.windows || [];

      for (var j = 0; j < windows.length; j++) {
        if (windows[j] && windows[j].id == selectedWindowId)
          return windows[j];
      }
    }

    return null;
  }
  property int modelUpdateTrigger: 0  // Dummy property to force model re-evaluation

  // Hover state
  property var hoveredWindowId: ""
  // Combined model of running windows and pinned apps
  property var combinedModel: []

  // Wheel scroll handling
  property int wheelAccumulatedDelta: 0
  property bool wheelCooldown: false

  // Drag and Drop state for visual feedback
  property int dragSourceIndex: -1
  property int dragTargetIndex: -1

  // Track the session order of apps (transient reordering)
  property var sessionAppOrder: []

  function getAppKey(appData) {
    if (!appData)
      return null;

    // Group / reorder by app identity (same app stacks into one icon)
    if (appData.appId)
      return normalizeAppId(resolveToDesktopEntryId(appData.appId));

    return appData.id;
  }

  // Pick the "front" window for a stack: focused first, else first entry
  function primaryWindow(windows) {
    if (!windows || windows.length === 0)
      return null;

    for (var i = 0; i < windows.length; i++) {
      if (windows[i] && windows[i].isFocused)
        return windows[i];
    }

    return windows[0];
  }

  // Left-click: single window → focus; stacked → open SmartPanel picker (clashia-style)
  function activateAppGroup(group, anchorItem) {
    if (!group)
      return;

    const windows = group.windows || [];

    if (windows.length === 0) {
      if (group.type === "pinned")
        root.launchPinnedApp(group.appId);

      return;
    }

    if (windows.length === 1) {
      try {
        CompositorService.focusWindow(windows[0]);
      } catch (error) {
        Logger.e("TaskDock", "Failed to focus window: " + error);
      }

      return;
    }

    openStackPicker(group, anchorItem || null);
  }

  function openStackPicker(group, anchorItem) {
    if (!group || !pluginApi)
      return;

    TooltipService.hide();

    try {
      contextMenu.close();
    } catch (e) {}

    const main = pluginApi.mainInstance;
    const wins = group.windows || [];
    const entries = [];

    for (var i = 0; i < wins.length; i++) {
      const w = wins[i];
      const title = (w && w.title) ? String(w.title).trim() : "";
      const label = title || getAppNameFromDesktopEntry(group.appId) || ("Window " + (i + 1));
      entries.push({
                     "window": w,
                     "title": label,
                     "iconSource": resolveIconSource(group.appId, label)
                   });
    }

    if (main) {
      // Share resolvers with Panel.qml
      main.resolveIconSource = resolveIconSource;
      main.stackWindowLabel = function (window, index) {
        if (!window)
          return "Window " + (index + 1);

        const t = (window.title || "").trim();

        if (t)
          return t;

        return getAppNameFromDesktopEntry(group.appId) || ("Window " + (index + 1));
      };
      main.setStackPicker({
                            "windows": entries,
                            "appId": group.appId || "",
                            "title": group.title || getAppNameFromDesktopEntry(group.appId) || ""
                          });
    }

    // Official plugin panel host (SmartPanel) — same background as bar/clashia
    pluginApi.openPanel(root.screen, anchorItem || root);
  }

  function closeStackPicker() {
    if (pluginApi && pluginApi.mainInstance && pluginApi.mainInstance.clearStackPicker)
      pluginApi.mainInstance.clearStackPicker();

    if (pluginApi && root.screen)
      pluginApi.closePanel(root.screen);
  }

  function sortApps(apps) {
    if (!sessionAppOrder || sessionAppOrder.length === 0) {
      return apps;
    }

    const sorted = [];
    const remaining = [...apps];

    // 1. Pick apps that are in the session order
    for (let i = 0; i < sessionAppOrder.length; i++) {
      const key = sessionAppOrder[i];
      const idx = remaining.findIndex(app => getAppKey(app) === key);
      if (idx !== -1) {
        sorted.push(remaining[idx]);
        remaining.splice(idx, 1);
      }
    }

    // 2. Append any new/remaining apps
    remaining.forEach(app => sorted.push(app));

    return sorted;
  }

  function reorderApps(fromIndex, toIndex) {
    Logger.d("TaskDock", "Reordering apps from " + fromIndex + " to " + toIndex);
    if (fromIndex === toIndex || fromIndex < 0 || toIndex < 0 || fromIndex >= combinedModel.length || toIndex >= combinedModel.length)
      return;

    const list = [...combinedModel];
    const item = list.splice(fromIndex, 1)[0];
    list.splice(toIndex, 0, item);

    combinedModel = list;
    sessionAppOrder = combinedModel.map(getAppKey);
    savePinnedOrder();
  }

  function savePinnedOrder() {
    const currentPinned = Settings.data.dock.pinnedApps || [];
    const newPinned = [];
    const seen = new Set();

    // Extract pinned apps in their current visual order
    combinedModel.forEach(app => {
                            if (app.appId && !seen.has(app.appId)) {
                              const isPinned = currentPinned.some(p => normalizeAppId(p) === normalizeAppId(app.appId));

                              if (isPinned) {
                                newPinned.push(app.appId);
                                seen.add(app.appId);
                              }
                            }
                          });

    // Check if any pinned apps were missed (e.g. filtered out by workspace)
    currentPinned.forEach(p => {
                            if (!seen.has(p)) {
                              newPinned.push(p);
                              seen.add(p);
                            }
                          });

    if (JSON.stringify(currentPinned) !== JSON.stringify(newPinned)) {
      Settings.data.dock.pinnedApps = newPinned;
    }
  }

  // Helper function to normalize app IDs for case-insensitive matching
  function normalizeAppId(appId) {
    if (!appId || typeof appId !== 'string')
      return "";
    return appId.toLowerCase().trim();
  }

  // Compositor sometimes reports empty appId/class (e.g. Feishu/Lark).
  // Map common window titles → desktop entry ids so icons/grouping still work.
  readonly property var titleAppFallbacks: ({
                                              "飞书": "feishu",
                                              "feishu": "feishu",
                                              "lark": "feishu",
                                              "weixin": "wechat",
                                              "微信": "wechat"
                                            })

  // Desktop Icon= name overrides when ThemeIcons can't resolve the icon theme name
  readonly property var iconNameOverrides: ({
                                              "feishu": "bytedance-feishu",
                                              "bytedance-feishu": "bytedance-feishu"
                                            })

  property var _iconSourceCache: ({})
  property var _titleEntryCache: ({})

  function iconPathFromName(iconName) {
    if (!iconName)
      return "";

    // Absolute path or file URL — use directly
    if (iconName.startsWith("/") || iconName.startsWith("file:") || iconName.startsWith("image:"))
      return iconName;

    try {
      if (typeof Quickshell !== "undefined" && Quickshell.iconPath) {
        const p = Quickshell.iconPath(iconName, true);

        if (p && p !== "" && !String(p).includes("image-missing"))
          return p;
      }
    } catch (e) {}

    try {
      if (typeof ThemeIcons !== "undefined" && ThemeIcons.iconFromName)
        return ThemeIcons.iconFromName(iconName, "application-x-executable");
    } catch (e2) {}

    return "";
  }

  // Match a window title against desktop entry Name / localized names
  function findDesktopEntryByTitle(title) {
    if (!title)
      return null;

    if (_titleEntryCache.hasOwnProperty(title))
      return _titleEntryCache[title];

    let found = null;

    try {
      if (typeof DesktopEntries !== "undefined" && DesktopEntries.applications) {
        const values = Array.from(DesktopEntries.applications.values);
        const needle = String(title).trim().toLowerCase();

        for (var i = 0; i < values.length; i++) {
          const entry = values[i];

          if (!entry)
            continue;

          const names = [entry.name, entry.id, entry.genericName].filter(Boolean);

          for (var n = 0; n < names.length; n++) {
            if (String(names[n]).trim().toLowerCase() === needle) {
              found = entry;
              break;
            }
          }

          if (found)
            break;

          // Partial: title starts with app name or vice versa (e.g. "Feishu - chat")
          for (var p = 0; p < names.length; p++) {
            const nm = String(names[p]).trim().toLowerCase();

            if (nm.length >= 2 && (needle.indexOf(nm) === 0 || nm.indexOf(needle) === 0)) {
              found = entry;
              break;
            }
          }

          if (found)
            break;
        }
      }
    } catch (e) {}

    _titleEntryCache[title] = found;
    return found;
  }

  // Best-effort app identity for grouping + icons when compositor appId is empty
  function resolveAppIdentity(windowOrAppId, titleHint) {
    let rawAppId = "";
    let title = titleHint || "";

    if (windowOrAppId && typeof windowOrAppId === "object") {
      rawAppId = windowOrAppId.appId || "";
      title = title || windowOrAppId.title || "";
    } else if (typeof windowOrAppId === "string") {
      rawAppId = windowOrAppId;
    }

    if (rawAppId) {
      const resolved = resolveToDesktopEntryId(rawAppId);
      return {
        "appId": resolved || rawAppId,
        "rawAppId": rawAppId,
        "title": title
      };
    }

    // Title fallback map (飞书 → feishu)
    const titleKey = String(title).trim().toLowerCase();
    const mapped = titleAppFallbacks[title] || titleAppFallbacks[titleKey];

    if (mapped) {
      return {
        "appId": mapped,
        "rawAppId": "",
        "title": title
      };
    }

    const entry = findDesktopEntryByTitle(title);

    if (entry && entry.id) {
      return {
        "appId": entry.id,
        "rawAppId": "",
        "title": title
      };
    }

    return {
      "appId": title ? ("title:" + title) : "",
      "rawAppId": "",
      "title": title
    };
  }

  /**
   * Resolve icon source for an app group / window.
   * Order: cache → ThemeIcons(appId) → icon overrides → desktop entry.icon → title lookup → generic.
   */
  function resolveIconSource(appId, titleHint) {
    const cacheKey = (appId || "") + "\n" + (titleHint || "");

    if (_iconSourceCache.hasOwnProperty(cacheKey))
      return _iconSourceCache[cacheKey];

    let source = "";

    // 1) ThemeIcons by appId
    if (appId && !String(appId).startsWith("title:")) {
      try {
        source = ThemeIcons.iconForAppId(appId, "");
      } catch (e) {}
    }

    // 2) Known icon theme name overrides (feishu → bytedance-feishu)
    if ((!source || source === "") && appId) {
      const override = iconNameOverrides[normalizeAppId(appId)] || iconNameOverrides[appId];

      if (override)
        source = iconPathFromName(override);
    }

    // 3) Desktop entry icon field via heuristic / byId
    if ((!source || source === "") && appId && !String(appId).startsWith("title:")) {
      try {
        let entry = null;

        if (typeof DesktopEntries !== "undefined") {
          if (DesktopEntries.heuristicLookup)
            entry = DesktopEntries.heuristicLookup(appId);

          if (!entry && DesktopEntries.byId)
            entry = DesktopEntries.byId(appId);
        }

        if (entry && entry.icon)
          source = iconPathFromName(entry.icon);
      } catch (e2) {}
    }

    // 4) Title → desktop entry
    if ((!source || source === "") && titleHint) {
      const mapped = titleAppFallbacks[titleHint] || titleAppFallbacks[String(titleHint).trim().toLowerCase()];

      if (mapped) {
        const override = iconNameOverrides[normalizeAppId(mapped)];

        if (override)
          source = iconPathFromName(override);

        if (!source) {
          try {
            source = ThemeIcons.iconForAppId(mapped, "");
          } catch (e3) {}
        }
      }

      if (!source) {
        const entry = findDesktopEntryByTitle(titleHint);

        if (entry && entry.icon)
          source = iconPathFromName(entry.icon);
        else if (entry && entry.id) {
          try {
            source = ThemeIcons.iconForAppId(entry.id, "");
          } catch (e4) {}
        }
      }
    }

    // 5) Generic fallback
    if (!source || source === "")
      source = iconPathFromName("application-x-executable");

    _iconSourceCache[cacheKey] = source;
    return source;
  }

  // Helper function to check if an app ID matches a pinned app (case-insensitive)
  function isAppIdPinned(appId, pinnedApps) {
    if (!appId || !pinnedApps || pinnedApps.length === 0)
      return false;
    const normalizedId = normalizeAppId(appId);
    // Direct match
    if (pinnedApps.some(pinnedId => normalizeAppId(pinnedId) === normalizedId))
      return true;
    // Resolve via desktop entry lookup (handles StartupWMClass != .desktop filename)
    const resolved = resolveToDesktopEntryId(appId);
    if (resolved !== appId) {
      const normalizedResolved = normalizeAppId(resolved);
      return pinnedApps.some(pinnedId => normalizeAppId(pinnedId) === normalizedResolved);
    }
    return false;
  }

  // Desktop entry ID resolution cache (cleared when DesktopEntries change)
  property var _desktopEntryIdCache: ({})

  // Resolve a toplevel appId to its canonical .desktop entry ID via heuristic lookup.
  function resolveToDesktopEntryId(appId) {
    if (!appId)
      return appId;
    if (_desktopEntryIdCache.hasOwnProperty(appId))
      return _desktopEntryIdCache[appId];
    try {
      if (typeof DesktopEntries !== 'undefined' && DesktopEntries.heuristicLookup) {
        const entry = DesktopEntries.heuristicLookup(appId);
        if (entry && entry.id) {
          _desktopEntryIdCache[appId] = entry.id;
          return entry.id;
        }
      }
    } catch (e) {}
    _desktopEntryIdCache[appId] = appId;
    return appId;
  }

  // Helper function to get app name from desktop entry
  function getAppNameFromDesktopEntry(appId) {
    if (!appId)
      return appId;

    try {
      if (typeof DesktopEntries !== 'undefined' && DesktopEntries.heuristicLookup) {
        const entry = DesktopEntries.heuristicLookup(appId);
        if (entry && entry.name) {
          return entry.name;
        }
      }

      if (typeof DesktopEntries !== 'undefined' && DesktopEntries.byId) {
        const entry = DesktopEntries.byId(appId);
        if (entry && entry.name) {
          return entry.name;
        }
      }
    } catch (e)
      // Fall through to return original appId
    {}

    // Return original appId if we can't find a desktop entry
    return appId;
  }

  // Helper function to get desktop entry ID from an app ID
  function getDesktopEntryId(appId) {
    if (!appId)
      return appId;

    // Try to find the desktop entry using heuristic lookup
    if (typeof DesktopEntries !== 'undefined' && DesktopEntries.heuristicLookup) {
      try {
        const entry = DesktopEntries.heuristicLookup(appId);
        if (entry && entry.id) {
          return entry.id;
        }
      } catch (e)
        // Fall through to return original appId
      {}
    }

    // Try direct lookup
    if (typeof DesktopEntries !== 'undefined' && DesktopEntries.byId) {
      try {
        const entry = DesktopEntries.byId(appId);
        if (entry && entry.id) {
          return entry.id;
        }
      } catch (e)
        // Fall through to return original appId
      {}
    }

    // Return original appId if we can't find a desktop entry
    return appId;
  }

  // Helper function to check if an app is pinned
  function isAppPinned(appId) {
    if (!appId)
      return false;
    const pinnedApps = Settings.data.dock.pinnedApps || [];
    const normalizedId = normalizeAppId(appId);
    if (pinnedApps.some(pinnedId => normalizeAppId(pinnedId) === normalizedId))
      return true;
    const resolved = resolveToDesktopEntryId(appId);
    if (resolved !== appId) {
      const normalizedResolved = normalizeAppId(resolved);
      return pinnedApps.some(pinnedId => normalizeAppId(pinnedId) === normalizedResolved);
    }
    return false;
  }

  // Helper function to toggle app pin/unpin
  function toggleAppPin(appId) {
    if (!appId)
      return;

    // Get the desktop entry ID for consistent pinning
    const desktopEntryId = getDesktopEntryId(appId);
    const normalizedId = normalizeAppId(desktopEntryId);

    let pinnedApps = (Settings.data.dock.pinnedApps || []).slice(); // Create a copy

    // Find existing pinned app with case-insensitive matching
    const existingIndex = pinnedApps.findIndex(pinnedId => normalizeAppId(pinnedId) === normalizedId);
    const isPinned = existingIndex >= 0;

    if (isPinned) {
      // Unpin: remove from array
      pinnedApps.splice(existingIndex, 1);
    } else {
      // Pin: add desktop entry ID to array
      pinnedApps.push(desktopEntryId);
    }

    // Update the settings
    Settings.data.dock.pinnedApps = pinnedApps;
  }

  // Function to update the combined model — stack windows of the same app into one icon
  function updateCombinedModel() {
    const groups = [];
    const groupByKey = ({});
    const pinnedApps = Settings.data.dock.pinnedApps || [];
    const processedAppIds = new Set();

    // First pass: collect running windows, grouped by resolved app id
    try {
      const total = CompositorService.windows.count || 0;
      const activeIds = CompositorService.getActiveWorkspaces().map(function (ws) {
        return ws.id;
      });

      for (var i = 0; i < total; i++) {
        var w = CompositorService.windows.get(i);

        if (!w)
          continue;

        var passOutput = (!onlySameOutput) || (w.output == screen?.name);
        var passWorkspace = (!onlyActiveWorkspaces) || (activeIds.includes(w.workspaceId));

        if (!(passOutput && passWorkspace))
          continue;

        const identity = resolveAppIdentity(w, w.title || "");
        const resolvedId = identity.appId;
        const groupKey = normalizeAppId(resolvedId) || normalizeAppId(w.appId) || ("win:" + String(w.id));
        const isPinned = isAppIdPinned(resolvedId, pinnedApps) || isAppIdPinned(w.appId, pinnedApps);

        if (!groupByKey[groupKey]) {
          const group = {
            "id": groupKey,
            "type": isPinned ? "pinned-running" : "running",
            "window": null,
            "windows": [],
            "count": 0,
            "appId": resolvedId || w.appId || groupKey,
            "title": identity.title || ""
          };
          groupByKey[groupKey] = group;
          groups.push(group);
        }

        const group = groupByKey[groupKey];
        group.windows.push(w);
        group.count = group.windows.length;

        if (isPinned)
          group.type = "pinned-running";

        if (w.appId)
          processedAppIds.add(normalizeAppId(w.appId));

        if (resolvedId)
          processedAppIds.add(normalizeAppId(resolvedId));
      }

      // Finalize primary window + title + icon key per group
      for (var g = 0; g < groups.length; g++) {
        const group = groups[g];
        const primary = primaryWindow(group.windows);
        group.window = primary;

        const displayName = getAppNameFromDesktopEntry(group.appId);
        const looksLikeId = !displayName || displayName === group.appId || String(group.appId).startsWith("title:");
        const fallbackTitle = (primary && primary.title) ? primary.title : (group.title || group.appId);
        group.title = looksLikeId ? fallbackTitle : displayName;

        if (group.count > 1)
          group.title = group.title + " ×" + group.count;
      }
    } catch (e)
      // Ignore errors
    {}

    // Second pass: Add non-running pinned apps (only if showPinnedApps is enabled)
    if (showPinnedApps) {
      pinnedApps.forEach(pinnedAppId => {
                           const normalizedPinnedId = normalizeAppId(pinnedAppId);
                           const resolvedPinned = normalizeAppId(resolveToDesktopEntryId(pinnedAppId));

                           if (processedAppIds.has(normalizedPinnedId) || processedAppIds.has(resolvedPinned))
                             return;

                           if (groupByKey[normalizedPinnedId] || groupByKey[resolvedPinned])
                             return;

                           const appName = getAppNameFromDesktopEntry(pinnedAppId);
                           groups.push({
                                         "id": pinnedAppId,
                                         "type": "pinned",
                                         "window": null,
                                         "windows": [],
                                         "count": 0,
                                         "appId": pinnedAppId,
                                         "title": appName
                                       });
                         });
    }

    combinedModel = sortApps(groups);

    // Sync session order if needed (e.g. first run or new apps added)
    if (!sessionAppOrder || sessionAppOrder.length === 0 || sessionAppOrder.length !== combinedModel.length) {
      sessionAppOrder = combinedModel.map(getAppKey);
    }

    updateHasWindow();
  }

  // Function to launch a pinned app
  function launchPinnedApp(appId) {
    if (!appId)
      return;

    try {
      const app = DesktopEntries.byId(appId);

      if (Settings.data.appLauncher.customLaunchPrefixEnabled && Settings.data.appLauncher.customLaunchPrefix.trim() !== "") {
        // Use custom launch prefix
        const prefix = Settings.data.appLauncher.customLaunchPrefix.trim().split(" ");

        if (app.runInTerminal && Settings.data.appLauncher.terminalCommand.trim() !== "") {
          const terminal = Settings.data.appLauncher.terminalCommand.trim().split(" ");
          const command = prefix.concat(terminal.concat(app.command));
          Quickshell.execDetached(command);
        } else {
          const command = prefix.concat(app.command);
          Quickshell.execDetached(command);
        }
      } else {
        if (app.runInTerminal && Settings.data.appLauncher.terminalCommand.trim() !== "") {
          Logger.d("TaskDock", "Executing terminal app manually: " + app.name);
          const terminal = Settings.data.appLauncher.terminalCommand.trim().split(" ");
          const command = terminal.concat(app.command);
          CompositorService.spawn(command);
        } else if (app.command && app.command.length > 0) {
          CompositorService.spawn(app.command);
        } else if (app.execute) {
          app.execute();
        } else {
          Logger.w("TaskDock", `Could not launch: ${app.name}. No valid launch method.`);
        }
      }
    } catch (e) {
      Logger.e("TaskDock", "Failed to launch app: " + e);
    }
  }



  NPopupContextMenu {
    id: contextMenu
    model: {
      // Reference modelUpdateTrigger to make binding reactive
      const _ = root.modelUpdateTrigger;

      var items = [];
      if (root.selectedWindowId) {
        // Focus item (for running apps)
        items.push({
                     "label": I18n.tr("common.focus"),
                     "action": "focus",
                     "icon": "eye"
                   });

        // Pin/Unpin item (always available when right-clicking an app)
        const isPinned = root.isAppPinned(root.selectedAppId);
        items.push({
                     "label": !isPinned ? I18n.tr("common.pin") : I18n.tr("common.unpin"),
                     "action": "pin",
                     "icon": !isPinned ? "pin" : "unpin"
                   });

        // Close item (for running apps)
        items.push({
                     "label": I18n.tr("common.close"),
                     "action": "close",
                     "icon": "x"
                   });

        // Add desktop entry actions (like "New Window", "Private Window", etc.)
        if (typeof DesktopEntries !== 'undefined' && DesktopEntries.byId && root.selectedAppId) {
          const entry = (DesktopEntries.heuristicLookup) ? DesktopEntries.heuristicLookup(root.selectedAppId) : DesktopEntries.byId(root.selectedAppId);
          if (entry != null && entry.actions) {
            entry.actions.forEach(function (action) {
              items.push({
                           "label": action.name,
                           "action": "desktop-action-" + action.name,
                           "icon": "chevron-right",
                           "desktopAction": action
                         });
            });
          }
        }
      }
      items.push({
                   "label": I18n.tr("actions.widget-settings"),
                   "action": "widget-settings",
                   "icon": "settings"
                 });
      return items;
    }
    onTriggered: (action, item) => {
                   contextMenu.close();
                   PanelService.closeContextMenu(root.screen);

                   // Look up the window fresh each time to avoid stale references
                   const selectedWindow = root.getSelectedWindow();

                   if (action === "focus" && selectedWindow) {
                     CompositorService.focusWindow(selectedWindow);
                   } else if (action === "pin" && root.selectedAppId) {
                     root.toggleAppPin(root.selectedAppId);
                   } else if (action === "close" && selectedWindow) {
                     CompositorService.closeWindow(selectedWindow);
                   } else if (action === "widget-settings") {
                     if (root.pluginApi && root.pluginApi.manifest) {
                       BarService.openPluginSettings(root.screen, root.pluginApi.manifest);
                     }
                   } else if (action.startsWith("desktop-action-") && item && item.desktopAction) {
                     if (item.desktopAction.command && item.desktopAction.command.length > 0) {
                       Quickshell.execDetached(item.desktopAction.command);
                     } else if (item.desktopAction.execute) {
                       item.desktopAction.execute();
                     }
                   }
                   root.selectedWindowId = "";
                   root.selectedAppId = "";
                 }
  }

  function updateHasWindow() {
    // Check if we have any items in the combined model (windows or pinned apps)
    hasWindow = combinedModel.length > 0;
  }

  Connections {
    target: CompositorService
    function onActiveWindowChanged() {
      updateCombinedModel();
    }
    function onWindowListChanged() {
      updateCombinedModel();
    }
    function onWorkspaceChanged() {
      updateCombinedModel();
    }
  }

  Connections {
    target: Settings.data.dock
    function onPinnedAppsChanged() {
      updateCombinedModel();
    }
  }

  Component.onCompleted: {
    updateCombinedModel();
  }
  onScreenChanged: updateCombinedModel()
  onOnlySameOutputChanged: updateCombinedModel()
  onOnlyActiveWorkspacesChanged: updateCombinedModel()
  onShowPinnedAppsChanged: updateCombinedModel()

  // Debounce timer for wheel interactions
  Timer {
    id: wheelDebounce
    interval: 150
    repeat: false
    onTriggered: {
      root.wheelCooldown = false;
      root.wheelAccumulatedDelta = 0;
    }
  }

  // Scroll to switch between windows
  WheelHandler {
    id: wheelHandler
    target: root
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function (event) {
      if (root.wheelCooldown || root.combinedModel.length === 0)
        return;
      var dy = event.angleDelta.y;
      var dx = event.angleDelta.x;
      var useDy = Math.abs(dy) >= Math.abs(dx);
      var delta = useDy ? dy : dx;
      root.wheelAccumulatedDelta += delta;
      var step = 120;
      if (Math.abs(root.wheelAccumulatedDelta) >= step) {
        var direction = root.wheelAccumulatedDelta > 0 ? -1 : 1;
        // Prefer cycling windows inside the focused app stack; else cycle app groups
        var focusedGroupIndex = -1;
        var focusedWindowIndex = -1;

        for (var i = 0; i < root.combinedModel.length; i++) {
          const wins = root.combinedModel[i].windows || [];

          for (var wi = 0; wi < wins.length; wi++) {
            if (wins[wi] && wins[wi].isFocused) {
              focusedGroupIndex = i;
              focusedWindowIndex = wi;
              break;
            }
          }

          if (focusedGroupIndex >= 0)
            break;
        }

        if (focusedGroupIndex >= 0) {
          const group = root.combinedModel[focusedGroupIndex];
          const wins = group.windows || [];

          if (wins.length > 1) {
            const nextWin = wins[(focusedWindowIndex + direction + wins.length) % wins.length];

            try {
              CompositorService.focusWindow(nextWin);
            } catch (error) {
              Logger.e("TaskDock", "Failed to focus window: " + error);
            }
          } else {
            var nextGroupIndex = (focusedGroupIndex + direction + root.combinedModel.length) % root.combinedModel.length;
            var guard = 0;

            while (guard < root.combinedModel.length) {
              const candidate = root.combinedModel[nextGroupIndex];
              const cWins = candidate.windows || [];

              if (cWins.length > 0) {
                try {
                  CompositorService.focusWindow(primaryWindow(cWins));
                } catch (error) {
                  Logger.e("TaskDock", "Failed to focus window: " + error);
                }

                break;
              }

              nextGroupIndex = (nextGroupIndex + direction + root.combinedModel.length) % root.combinedModel.length;
              guard++;
            }
          }
        } else {
          for (var j = 0; j < root.combinedModel.length; j++) {
            const wins = root.combinedModel[j].windows || [];

            if (wins.length > 0) {
              try {
                CompositorService.focusWindow(primaryWindow(wins));
              } catch (error) {
                Logger.e("TaskDock", "Failed to focus window: " + error);
              }

              break;
            }
          }
        }
        root.wheelCooldown = true;
        wheelDebounce.restart();
        root.wheelAccumulatedDelta = 0;
        event.accepted = true;
      }
    }
  }

  // "visible": Always Visible, "hidden": Hide When Empty, "transparent": Transparent When Empty
  visible: hideMode !== "hidden" || hasWindow
  opacity: ((hideMode !== "hidden" && hideMode !== "transparent") || hasWindow) ? 1.0 : 0.0
  Behavior on opacity {
    NumberAnimation {
      duration: Style.animationNormal
      easing.type: Easing.OutCubic
    }
  }

  // Content dimensions for implicit sizing.
  // IMPORTANT: never cap total width/height to maxTaskbarWidth — that only
  // shrinks title text. Capping the capsule + parent clip hid extra icons.
  readonly property real contentWidth: {
    if (!visible)
      return 0;

    if (isVerticalBar)
      return barHeight;

    return Math.round(showTitle ? taskbarLayout.implicitWidth : taskbarLayout.implicitWidth + Style.margin2M);
  }
  readonly property real contentHeight: visible ? (isVerticalBar ? Math.round(taskbarLayout.implicitHeight + Style.margin2S) : capsuleHeight) : 0

  implicitWidth: contentWidth
  implicitHeight: contentHeight

  // Visual capsule centered in parent
  Rectangle {
    id: visualCapsule
    width: root.contentWidth
    height: root.contentHeight
    anchors.centerIn: parent
    radius: Style.radiusM
    color: Style.capsuleColor
    border.color: Style.capsuleBorderColor
    border.width: Style.capsuleBorderWidth
    clip: false

    GridLayout {
      id: taskbarLayout

      // Pixel-perfect centering
      x: isVerticalBar ? Style.pixelAlignCenter(parent.width, width) : ((root.showTitle) ? Style.pixelAlignCenter(parent.width, width) : Style.marginM)
      y: Style.pixelAlignCenter(parent.height, height)

      // Configure GridLayout to behave like RowLayout or ColumnLayout
      rows: isVerticalBar ? -1 : 1 // -1 means unlimited
      columns: isVerticalBar ? 1 : -1 // -1 means unlimited

      rowSpacing: isVerticalBar ? Style.marginS : 0
      columnSpacing: isVerticalBar ? 0 : Style.marginS

      Repeater {
        model: root.combinedModel
        delegate: Item {
          id: taskbarItem
          required property var modelData
          required property int index
          property ShellScreen screen: root.screen

          readonly property var groupWindows: modelData.windows || []
          readonly property int windowCount: modelData.count || groupWindows.length || (modelData.window ? 1 : 0)
          readonly property bool isRunning: windowCount > 0
          readonly property bool isPinned: modelData.type === "pinned" || modelData.type === "pinned-running"
          readonly property bool isFocused: {
            for (var fi = 0; fi < groupWindows.length; fi++) {
              if (groupWindows[fi] && groupWindows[fi].isFocused)
                return true;
            }

            return false;
          }
          readonly property bool isPinnedRunning: isPinned && isRunning && !isFocused
          readonly property bool isHovered: root.hoveredWindowId === modelData.id
          readonly property bool isStacked: windowCount > 1
          // Non-active apps dim; hover restores full opacity for affordance
          readonly property real itemOpacity: (isFocused || isHovered) ? 1.0 : 0.45

          readonly property bool shouldShowTitle: root.showTitle && modelData.type !== "pinned"
          readonly property real itemSpacing: Style.marginS
          readonly property real contentWidth: shouldShowTitle ? root.itemSize + itemSpacing + root.titleWidth : root.itemSize

          readonly property string title: modelData.title || modelData.appId || "Unknown application"
          readonly property color titleBgColor: (isHovered || isFocused) ? Color.mHover : Style.capsuleColor
          readonly property color titleFgColor: (isHovered || isFocused) ? Color.mOnHover : Color.mOnSurface

          Layout.preferredWidth: root.isVerticalBar ? root.barHeight : (root.showTitle ? Math.round(contentWidth + Style.margin2M) : Math.round(contentWidth)) // Add margins for both pinned and running apps
          Layout.preferredHeight: root.isVerticalBar ? root.itemSize : root.barHeight
          Layout.alignment: Qt.AlignCenter

          opacity: itemOpacity
          Behavior on opacity {
            NumberAnimation {
              duration: Style.animationFast
              easing.type: Easing.OutCubic
            }
          }

          // Ensure dragged item is on top
          z: (root.dragSourceIndex === index) ? 1000 : 1

          property int modelIndex: index
          objectName: "taskbarAppItem"

          DropArea {
            anchors.fill: parent
            keys: ["taskbar-app"]
            onEntered: function (drag) {
              if (drag.source && drag.source.objectName === "taskbarAppItem") {
                root.dragTargetIndex = taskbarItem.modelIndex;
              }
            }
            onExited: function () {
              if (root.dragTargetIndex === taskbarItem.modelIndex) {
                root.dragTargetIndex = -1;
              }
            }
            onDropped: function (drop) {
              root.dragSourceIndex = -1;
              root.dragTargetIndex = -1;
              Logger.d("TaskDock", "Dropped! Source: " + (drop.source ? drop.source.objectName : "null") + " Index: " + (drop.source ? drop.source.modelIndex : "?") + " -> Target Index: " + taskbarItem.modelIndex);
              if (drop.source && drop.source.objectName === "taskbarAppItem" && drop.source !== taskbarItem) {
                root.reorderApps(drop.source.modelIndex, taskbarItem.modelIndex);
              } else {
                Logger.d("TaskDock", "Drop ignored. Source objectName: " + (drop.source ? drop.source.objectName : "null"));
              }
            }
          }

          Item {
            id: draggableContent
            width: parent.width
            height: parent.height
            anchors.centerIn: dragging ? undefined : parent

            // Visual shifting logic
            readonly property bool isDragged: root.dragSourceIndex === index
            property real shiftOffset: 0

            // Calculate shift based on drag state
            // If I am NOT the dragged item, but I am in the path of the drag
            Binding on shiftOffset {
              value: {
                if (root.dragSourceIndex !== -1 && root.dragTargetIndex !== -1 && !draggableContent.isDragged) {
                  if (root.dragSourceIndex < root.dragTargetIndex) {
                    // Dragging Right: Items between source and target shift Left
                    if (index > root.dragSourceIndex && index <= root.dragTargetIndex) {
                      return -1 * (root.isVerticalBar ? root.itemSize : draggableContent.width); // Simple approximation, could be refined
                    }
                  } else if (root.dragSourceIndex > root.dragTargetIndex) {
                    // Dragging Left: Items between target and source shift Right
                    if (index >= root.dragTargetIndex && index < root.dragSourceIndex) {
                      return (root.isVerticalBar ? root.itemSize : draggableContent.width);
                    }
                  }
                }
                return 0;
              }
            }

            transform: Translate {
              x: !root.isVerticalBar ? draggableContent.shiftOffset : 0
              y: root.isVerticalBar ? draggableContent.shiftOffset : 0

              Behavior on x {
                NumberAnimation {
                  duration: Style.animationFast
                  easing.type: Easing.OutQuad
                }
              }
              Behavior on y {
                NumberAnimation {
                  duration: Style.animationFast
                  easing.type: Easing.OutQuad
                }
              }
            }

            property bool dragging: taskbarMouseArea.drag.active
            onDraggingChanged: {
              if (dragging) {
                root.dragSourceIndex = index;
              } else {
                // Don't reset immediately on release to allow drop to handle it,
                // or use a timer if needed, but drop handler usually fires.
                // However, if dropped outside, we need to reset.
                // Let's reset if not handled by drop area quickly?
                // Actually, drag.active becomes false on release.
                // We might want to clear it if no drop happened.
                if (root.dragSourceIndex === index) {
                  // Slight delay/check? For now, let DropArea handle reset on success.
                  // If cancelled (dropped nowhere), we should reset.
                  Qt.callLater(() => {
                                 if (!taskbarMouseArea.drag.active && root.dragSourceIndex === index) {
                                   root.dragSourceIndex = -1;
                                   root.dragTargetIndex = -1;
                                 }
                               });
                }
              }
            }

            Drag.active: dragging
            Drag.source: taskbarItem
            Drag.hotSpot.x: width / 2
            Drag.hotSpot.y: height / 2
            Drag.keys: ["taskbar-app"]

            z: dragging ? 1000 : 0
            scale: dragging ? 1.05 : 1.0
            Behavior on scale {
              NumberAnimation {
                duration: Style.animationFast
              }
            }

            Rectangle {
              id: titleBackground
              visible: shouldShowTitle
              anchors.centerIn: parent
              width: parent.width
              height: root.capsuleHeight
              color: titleBgColor
              radius: Style.radiusM

              Behavior on color {
                ColorAnimation {
                  duration: Style.animationFast
                  easing.type: Easing.InOutQuad
                }
              }
            }

            Rectangle {
              anchors.centerIn: parent
              width: taskbarItem.contentWidth
              height: parent.height
              color: "transparent"

              RowLayout {
                id: itemLayout
                anchors.fill: parent
                spacing: taskbarItem.itemSpacing

                Item {
                  Layout.preferredWidth: root.itemSize
                  Layout.preferredHeight: root.itemSize
                  Layout.alignment: Qt.AlignVCenter | Qt.AlignLeft

                  // Stacked "cards" behind the front icon when multiple windows share an app
                  Repeater {
                    model: taskbarItem.isStacked ? Math.min(taskbarItem.windowCount - 1, 2) : 0

                    Rectangle {
                      required property int index
                      // Deeper cards sit further back/right so the stack reads as layered
                      readonly property int depth: index + 1
                      width: root.itemSize * 0.88
                      height: root.itemSize * 0.88
                      x: Style.toOdd(depth * 2)
                      y: Style.toOdd(depth * 2)
                      radius: Style.radiusS
                      color: Color.mSurfaceVariant
                      opacity: 0.5 - index * 0.1
                      border.color: Style.capsuleBorderColor
                      border.width: Style.capsuleBorderWidth
                      z: index
                    }
                  }

                  IconImage {
                    id: appIcon
                    anchors.fill: parent
                    z: 10

                    // Resolve via appId, icon overrides, desktop entry, then window title
                    // (Feishu reports empty class/appId — title "飞书" → bytedance-feishu)
                    source: root.resolveIconSource(taskbarItem.modelData.appId, taskbarItem.modelData.title || (taskbarItem.modelData.window ? taskbarItem.modelData.window.title : ""))
                    smooth: true
                    asynchronous: true

                    // Apply dock shader to all taskbar icons
                    layer.enabled: root.colorizeIcons
                    layer.effect: ShaderEffect {
                      property color targetColor: Settings.data.colorSchemes.darkMode ? Color.mOnSurface : Color.mSurfaceVariant
                      property real colorizeMode: 0.0 // Dock mode (grayscale)

                      fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/appicon_colorize.frag.qsb")
                    }
                  }

                  // Window count badge (2+)
                  Rectangle {
                    id: countBadge
                    visible: taskbarItem.isStacked
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.rightMargin: -2
                    anchors.topMargin: -2
                    z: 20
                    width: Math.max(Style.toOdd(root.itemSize * 0.42), 12)
                    height: width
                    radius: width / 2
                    color: Qt.rgba(1, 1, 1, 0.55)

                    NText {
                      anchors.centerIn: parent
                      text: taskbarItem.windowCount > 9 ? "9+" : String(taskbarItem.windowCount)
                      pointSize: Style.toOdd(root.itemSize * 0.28)
                      // Fully opaque digit — do not use translucent theme colors
                      color: "#FF000000"
                      opacity: 1.0
                      font.weight: Font.Bold
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                    }
                  }

                }

                NText {
                  id: titleText
                  visible: shouldShowTitle
                  Layout.preferredWidth: root.titleWidth
                  Layout.preferredHeight: root.itemSize
                  Layout.alignment: Qt.AlignVCenter | Qt.AlignLeft
                  Layout.fillWidth: false

                  text: taskbarItem.title
                  elide: Text.ElideRight
                  verticalAlignment: Text.AlignVCenter
                  horizontalAlignment: Text.AlignLeft

                  pointSize: barFontSize
                  color: titleFgColor
                  opacity: Style.opacityFull
                }
              }
            }
          }

          MouseArea {
            id: taskbarMouseArea
            objectName: "taskbarMouseArea"
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton

            drag.target: draggableContent
            drag.axis: root.isVerticalBar ? Drag.YAxis : Drag.XAxis
            preventStealing: true

            onPressed: {
              // Constrain drag to roughly the taskbar area but allow some freedom
              // Or just let it be free since we only care about drops
            }

            onReleased: {
              if (draggableContent.Drag.active) {
                draggableContent.Drag.drop();
              }
            }

            onClicked: mouse => {
                         if (!modelData)
                           return;

                         if (mouse.button === Qt.LeftButton) {
                           root.activateAppGroup(modelData, taskbarItem);
                         } else if (mouse.button === Qt.RightButton) {
                           TooltipService.hide();
                           root.closeStackPicker();

                           if (isRunning) {
                             const primary = modelData.window || root.primaryWindow(modelData.windows);
                             root.selectedWindowId = primary ? primary.id : modelData.id;
                             root.selectedAppId = modelData.appId;
                             root.openTaskbarContextMenu(taskbarItem);
                           }
                         }
                       }
            onEntered: {
              root.hoveredWindowId = taskbarItem.modelData.id;
              TooltipService.show(taskbarItem, taskbarItem.title, BarService.getTooltipDirection(root.screen?.name));
            }
            onExited: {
              root.hoveredWindowId = "";
              TooltipService.hide();
            }
          }
        }
      }
    }
  }

  function openTaskbarContextMenu(item) {
    // Build menu model directly
    var items = [];
    if (root.selectedWindowId) {
      // Focus item (for running apps)
      items.push({
                   "label": I18n.tr("common.focus"),
                   "action": "focus",
                   "icon": "eye"
                 });

      // Pin/Unpin item
      const isPinned = root.isAppPinned(root.selectedAppId);
      items.push({
                   "label": !isPinned ? I18n.tr("common.pin") : I18n.tr("common.unpin"),
                   "action": "pin",
                   "icon": !isPinned ? "pin" : "unpin"
                 });

      // Close item
      items.push({
                   "label": I18n.tr("common.close"),
                   "action": "close",
                   "icon": "x"
                 });

      // Add desktop entry actions (like "New Window", "Private Window", etc.)
      if (typeof DesktopEntries !== 'undefined' && DesktopEntries.byId && root.selectedAppId) {
        const entry = (DesktopEntries.heuristicLookup) ? DesktopEntries.heuristicLookup(root.selectedAppId) : DesktopEntries.byId(root.selectedAppId);
        if (entry != null && entry.actions) {
          entry.actions.forEach(function (action) {
            items.push({
                         "label": action.name,
                         "action": "desktop-action-" + action.name,
                         "icon": "chevron-right",
                         "desktopAction": action
                       });
          });
        }
      }
    }
    items.push({
                 "label": I18n.tr("actions.widget-settings"),
                 "action": "widget-settings",
                 "icon": "settings"
               });

    // Set the model directly
    contextMenu.model = items;

    // Anchor to root (stable) but center horizontally on the clicked item
    PanelService.showContextMenu(contextMenu, root, screen, item);
  }
}

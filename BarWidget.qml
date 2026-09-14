import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Services.SystemTray
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
  // macOS-style: keep dock icon after killactive while process is still alive
  readonly property bool keepBackgroundApps: main?.keepBackgroundApps ?? true
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

  // Apps seen with a real window this session → keep dock icon after killactive
  // (Cmd+W style: process often still alive, window gone). Keyed by group key.
  property var sessionSeenApps: ({})

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

  /**
   * Snapshot a CompositorService ListModel row into a plain JS object.
   * ListModel proxies go stale after syncWindows() clears the model — never store them.
   * Returns null when the row has no usable window id (cannot focus/close).
   */
  function snapshotWindow(w) {
    if (!w)
      return null;

    const rawId = w.id;

    if (rawId === undefined || rawId === null || String(rawId) === "")
      return null;

    const wsId = w.workspaceId;
    // HyprlandService uses -1 as "unknown" sentinel — treat as null, not a real workspace
    const hasNumericWs = typeof wsId === "number" && !isNaN(wsId) && wsId !== -1;

    // Strip embedded NULs from X11 WM_CLASS / titles before anything else sees them
    const rawTitle = w.title ? String(w.title).replace(/\0/g, " ").trim() : "";
    const rawAppId = w.appId ? String(w.appId).replace(/\0/g, "").trim() : "";

    return {
      "id": String(rawId),
      "trackId": w.trackId || String(rawId),
      "title": rawTitle,
      "appId": rawAppId,
      "workspaceId": hasNumericWs ? wsId : null,
      "workspaceName": w.workspaceName ? String(w.workspaceName) : "",
      "isFocused": w.isFocused === true,
      "output": w.output ? String(w.output) : ""
    };
  }

  /** Drop null / id-less entries so counts and click paths stay consistent. */
  function validWindows(windows) {
    if (!windows || windows.length === 0)
      return [];

    const out = [];
    const seen = new Set();

    for (var i = 0; i < windows.length; i++) {
      const w = windows[i];

      if (w && w.id !== undefined && w.id !== null && String(w.id) !== "" && !seen.has(String(w.id))) {
        seen.add(String(w.id));
        out.push(w);
      }
    }

    return out;
  }

  /**
   * Windows that must never appear on the dock (IME candidates, OSK, etc.).
   * Example: Fcitx5 XWayland popup reports class "fcitx\0fcit" + title "Fcitx5 Input Window"
   * → broken appId, generic/unknown icon, and a useless dock entry.
   */
  function isDockNoiseWindow(w) {
    if (!w)
      return true;

    // NULs already stripped in snapshotWindow; keep defensive replace anyway
    const appId = String(w.appId || "").replace(/\0/g, "").trim().toLowerCase();
    const title = String(w.title || "").replace(/\0/g, " ").trim().toLowerCase();

    if (!appId && !title)
      return true;

    // Class / appId prefixes (X11 often truncates: "fcitx\0fcit" → "fcitxfcit" after NUL strip)
    const classNoise = [
      "fcitx",
      "ibus",
      "gcin",
      "hime",
      "sogou",
      "sunpinyin",
      "nimf",
      "mozc",
      "anthy",
      "onboard",
      "maliit",
      "org.fcitx",
      "org.freedesktop.ibus"
    ];

    for (var i = 0; i < classNoise.length; i++) {
      const n = classNoise[i];

      if (appId === n || appId.indexOf(n) === 0 || appId.indexOf(n) >= 0)
        return true;
    }

    // Titles that clearly identify IME chrome (avoid bare "candidate" / short tokens)
    const titleNoise = [
      "fcitx",
      "ibus",
      "input window",
      "input method",
      "candidate window",
      "candidate panel",
      "on-screen keyboard",
      "virtual keyboard"
    ];

    for (var t = 0; t < titleNoise.length; t++) {
      if (title.indexOf(titleNoise[t]) >= 0)
        return true;
    }

    return false;
  }

  /**
   * Hyprland special workspaces use negative ids (e.g. special:magic → -98).
   * Also accept workspace names that start with "special" when present on the window.
   *
   * HyprlandService uses workspaceId === -1 as "unknown / missing" sentinel — never special.
   */
  function isSpecialWorkspaceId(wsId, wsName) {
    if (wsName && String(wsName).indexOf("special") === 0)
      return true;

    // Real special ids are < -1 (e.g. -98). -1 is the unknown-workspace sentinel.
    if (typeof wsId === "number" && !isNaN(wsId) && wsId < -1)
      return true;

    return false;
  }

  function countSpecialWindows(windows) {
    if (!windows || windows.length === 0)
      return 0;

    var n = 0;

    for (var i = 0; i < windows.length; i++) {
      const w = windows[i];

      if (!w)
        continue;

      if (isSpecialWorkspaceId(w.workspaceId, w.workspaceName))
        n++;
    }

    return n;
  }

  /** Ratio of group windows on a special workspace (0..1). */
  function specialWorkspaceRatio(windows) {
    if (!windows || windows.length === 0)
      return 0;

    return countSpecialWindows(windows) / windows.length;
  }

  /**
   * Focus a tracked window. For Hyprland special/scratchpad windows, also dispatch
   * focuswindow by address so the special workspace is revealed when hidden.
   * Returns false when the window cannot be focused (caller should fall back).
   */
  function focusTrackedWindow(window) {
    if (!window || window.id === undefined || window.id === null || String(window.id) === "")
      return false;

    try {
      if (isSpecialWorkspaceId(window.workspaceId, window.workspaceName))
        root.revealSpecialWorkspace(window);

      CompositorService.focusWindow(window);

      // Belt-and-suspenders on Hyprland: address focus surfaces special clients reliably
      if (CompositorService.isHyprland) {
        const addr = String(window.id).replace(/^0x/i, "");

        Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "address:0x" + addr]);
      }

      return true;
    } catch (error) {
      Logger.e("TaskDock", "Failed to focus window: " + error);
      return false;
    }
  }

  /**
   * Show a Hyprland special workspace before focusing one of its windows.
   * Uses workspace name when available (special:magic → magic).
   * Prefer `workspace special:NAME` over togglespecialworkspace so we don't hide an already-open scratchpad.
   */
  function revealSpecialWorkspace(window) {
    if (!CompositorService.isHyprland || !window)
      return;

    try {
      var name = "";

      if (window.workspaceName && String(window.workspaceName).indexOf("special") === 0) {
        name = String(window.workspaceName).replace(/^special:/, "");
      }

      if (name)
        Quickshell.execDetached(["hyprctl", "dispatch", "workspace", "special:" + name]);
    } catch (e) {
      Logger.w("TaskDock", "revealSpecialWorkspace failed: " + e);
    }
  }

  // Left-click: single window → focus; stacked → SmartPanel picker;
  // no usable windows → background restore (SNI / hyprctl / launch) — including stale "running" groups
  function activateAppGroup(group, anchorItem) {
    if (!group)
      return;

    const windows = validWindows(group.windows || []);

    if (windows.length === 0) {
      // Empty or stale window list (ListModel proxy died, app closed to tray, etc.)
      root.activateBackgroundApp(group);
      return;
    }

    if (windows.length === 1) {
      if (!root.focusTrackedWindow(windows[0]))
        root.activateBackgroundApp(group);

      return;
    }

    // Keep picker payload aligned with focusable windows only
    const pickerGroup = Object.assign(({}), group, {
                                        "windows": windows,
                                        "count": windows.length,
                                        "window": primaryWindow(windows)
                                      });

    openStackPicker(pickerGroup, anchorItem || null);
  }

  /**
   * macOS-style: click a dock icon with no tracked window.
   * 1) Search all compositor windows and focus match
   * 2) Hyprland focuswindow by class/title
   * 3) StatusNotifier Activate — same path as Tray widget click (WeChat/ChatGPT need this)
   * 4) Re-launch desktop entry (single-instance / apps with no SNI e.g. Feishu)
   *
   * Note: SystemTray is ONLY used here for restore, never for building the dock model.
   */
  function activateBackgroundApp(group) {
    if (!group)
      return;

    const appId = group.appId || group.id || "";

    // 1) Any live window for this app anywhere?
    const match = findWindowForApp(appId, group.id);

    if (match && root.focusTrackedWindow(match))
      return;

    // 2) StatusNotifier Activate (what Tray left-click does) — proven for WeChat
    if (trySniActivate(appId, group.title))
      return;

    // 3) Hyprland class focus (window may exist but not in our model)
    tryHyprlandFocusApp(appId, group.title);

    // 4) Single-instance re-launch (Feishu often has no SNI after killactive)
    root.launchPinnedApp(appId);
  }

  /**
   * Find a matching StatusNotifierItem and call Activate — identical to Tray.qml left-click.
   * Matching is by SNI id / title / tooltip against our app patterns; system applets skipped.
   */
  function trySniActivate(appId, titleHint) {
    try {
      if (!SystemTray.items || !SystemTray.items.values)
        return false;

      const patterns = buildProcessPatterns(appId).map(function (p) {
        return String(p).toLowerCase();
      });

      if (titleHint)
        patterns.push(String(titleHint).toLowerCase());

      const want = normalizeAppId(appId);

      if (want)
        patterns.push(want);

      const items = SystemTray.items.values;

      for (var i = 0; i < items.length; i++) {
        const item = items[i];

        if (!item)
          continue;

        // Skip system indicators (IME, nm-applet, blueman…)
        const cat = item.category;

        if (cat === Category.Hardware || cat === Category.SystemServices || cat === 0 || cat === 1)
          continue;

        const id = String(item.id || "").toLowerCase();
        const title = String(item.title || "").toLowerCase();
        const tip = String(item.tooltipTitle || "").toLowerCase();
        const hay = id + " " + title + " " + tip;

        // Ignore empty / chrome generic ids unless tooltip matches
        if (!hay.trim())
          continue;

        let matched = false;

        for (var p = 0; p < patterns.length; p++) {
          const pat = patterns[p];

          if (!pat || pat.length < 2)
            continue;

          if (id === pat || title === pat || tip === pat || hay.indexOf(pat) >= 0) {
            matched = true;
            break;
          }
        }

        if (!matched)
          continue;

        // Same as Tray.qml: onlyMenu → skip activate; else activate()
        if (item.onlyMenu)
          continue;

        Logger.d("TaskDock", "SNI activate for " + appId + " via " + (item.id || item.tooltipTitle || item.title));
        item.activate();
        return true;
      }
    } catch (e) {
      Logger.w("TaskDock", "SNI activate failed: " + e);
    }

    return false;
  }

  function findWindowForApp(appId, groupKey) {
    try {
      const total = CompositorService.windows.count || 0;
      const want = normalizeAppId(appId);
      const wantKey = normalizeAppId(groupKey);
      const patterns = buildProcessPatterns(appId).map(function (p) {
        return String(p).toLowerCase();
      });

      for (var i = 0; i < total; i++) {
        const snap = snapshotWindow(CompositorService.windows.get(i));

        if (!snap || isDockNoiseWindow(snap))
          continue;

        const identity = resolveAppIdentity(snap, snap.title || "");
        const wid = normalizeAppId(identity.appId || snap.appId || "");
        const wtitle = String(snap.title || "").toLowerCase();
        const wclass = String(snap.appId || "").toLowerCase();

        if (want && (wid === want || wclass === want))
          return snap;

        if (wantKey && wid === wantKey)
          return snap;

        for (var p = 0; p < patterns.length; p++) {
          const pat = patterns[p];

          if (pat.length >= 3 && (wid.indexOf(pat) >= 0 || wclass.indexOf(pat) >= 0 || wtitle.indexOf(pat) >= 0))
            return snap;
        }
      }
    } catch (e) {}

    return null;
  }

  function tryHyprlandFocusApp(appId, titleHint) {
    if (!CompositorService.isHyprland)
      return false;

    const patterns = buildProcessPatterns(appId);
    const extras = [];

    if (titleHint)
      extras.push(String(titleHint));

    // WeChat reports class "wechat" while desktop id is WeChatLinux_x86_64
    const all = patterns.concat(extras);
    const classes = [];
    const seen = ({});

    for (var i = 0; i < all.length; i++) {
      const raw = String(all[i] || "").trim();

      if (raw.length < 2)
        continue;

      // Only use simple tokens as class regex (no spaces / path junk)
      if (/[\s\/]/.test(raw))
        continue;

      const key = raw.toLowerCase();

      if (seen[key])
        continue;

      seen[key] = true;
      classes.push(raw);
    }

    if (classes.length === 0)
      return false;

    // Try each class; hyprctl returns ok even if no match sometimes — still best-effort
    try {
      for (var c = 0; c < classes.length; c++) {
        const cls = classes[c].replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        // focuswindow class:^(wechat)$
        Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "class:^(" + cls + ")$"]);
      }

      // Also try title match for apps with empty/odd class
      if (titleHint && String(titleHint).trim().length >= 2) {
        const t = String(titleHint).trim().replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "title:^(" + t + ")"]);
      }

      return true;
    } catch (e) {
      Logger.w("TaskDock", "hyprland focus failed: " + e);
      return false;
    }
  }

  // Mutates `into` map in-place during updateCombinedModel (assign once at end)
  function rememberSessionAppInto(into, groupKey, appId, title, windows) {
    if (!into || !groupKey)
      return;

    // Skip ephemeral per-window keys
    if (String(groupKey).startsWith("win:") || String(groupKey).startsWith("title:"))
      return;

    const prev = into[groupKey] || sessionSeenApps[groupKey] || ({});
    const currentIds = windows.map(w => w.trackId);
    // Metadata resolution may improve after a window first appears. Move its
    // association rather than leaving a second sticky app behind.
    Object.keys(into).forEach(key => {
      if (key !== groupKey) {
        const remaining = (into[key].windowIds || []).filter(id => !currentIds.includes(id));
        into[key] = Object.assign({}, into[key], {"windowIds": remaining});
      }
    });
    into[groupKey] = {
      "key": groupKey,
      "appId": appId || prev.appId || groupKey,
      "title": title || prev.title || "",
      "windowIds": Array.from(new Set((prev.windowIds || []).concat(currentIds)))
    };
  }

  /**
   * Build aliases for activation/class lookup only, NEVER process liveness.
   * Prefer distinctive names; skip generic path segments (org, desktop, linux…).
   */
  function buildProcessPatterns(appId) {
    const patterns = [];
    const seen = ({});
    const generic = ({
                       "org": true,
                       "com": true,
                       "net": true,
                       "io": true,
                       "app": true,
                       "apps": true,
                       "desktop": true,
                       "linux": true,
                       "x86": true,
                       "x86_64": true,
                       "amd64": true,
                       "bin": true,
                       "usr": true,
                       "lib": true,
                       "share": true,
                       "application": true,
                       "applications": true
                     });

    function add(p) {
      if (!p)
        return;

      const s = String(p).trim();

      if (s.length < 3)
        return;

      // Drop synthetic prefixes
      if (s.indexOf("title:") === 0 || s.indexOf("win:") === 0)
        return;

      const key = s.toLowerCase();

      if (generic[key])
        return;

      if (seen[key])
        return;

      seen[key] = true;
      patterns.push(s);
    }

    if (!appId)
      return patterns;

    const raw = String(appId);
    const norm = normalizeAppId(raw);
    const bare = norm.replace(/^title:/, "");

    add(raw);
    add(bare);

    // Meaningful segments of dotted/desktop ids (org.telegram.desktop → telegram)
    const parts = bare.split(/[./\\:_-]+/).filter(function (p) {
      return p && p.length >= 3 && !generic[p.toLowerCase()];
    });

    for (var i = 0; i < parts.length; i++)
      add(parts[i]);

    // Known aliases from closeToBackgroundApps keys that match this app
    const known = Object.keys(closeToBackgroundApps);

    for (var k = 0; k < known.length; k++) {
      const kn = normalizeAppId(known[k]);

      if (kn.length >= 3 && (bare.indexOf(kn) >= 0 || kn.indexOf(bare) >= 0 || bare === kn))
        add(known[k]);
    }

    // Extra well-known process name variants
    if (bare.indexOf("feishu") >= 0 || bare.indexOf("lark") >= 0) {
      add("feishu");
      add("bytedance-feishu");
      add("lark");
    }

    if (bare.indexOf("wechat") >= 0 || bare.indexOf("weixin") >= 0) {
      add("wechat");
      add("WeChat");
      add("xwechat");
      add("weixin");
    }

    if (bare.indexOf("chatgpt") >= 0) {
      add("ChatGPT");
      add("chatgpt");
    }

    if (bare.indexOf("telegram") >= 0) {
      add("telegram");
      add("Telegram");
    }

    return patterns;
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
                                              "bytedance-feishu": "feishu",
                                              "weixin": "WeChatLinux_x86_64",
                                              "wechat": "WeChatLinux_x86_64",
                                              "微信": "WeChatLinux_x86_64",
                                              "xwechat": "WeChatLinux_x86_64",
                                              "chatgpt": "chatgpt",
                                              "telegramdesktop": "org.telegram.desktop",
                                              "telegram desktop": "org.telegram.desktop"
                                            })

  // Desktop Icon= name overrides when ThemeIcons can't resolve the icon theme name
  readonly property var iconNameOverrides: ({
                                              "feishu": "bytedance-feishu",
                                              "bytedance-feishu": "bytedance-feishu",
                                              "WeChatLinux_x86_64": "wechat",
                                              "wechat": "wechat"
                                            })

  // Activation aliases only; process identity comes from compositor PIDs.
  readonly property var closeToBackgroundApps: ({
                                                  "feishu": true,
                                                  "bytedance-feishu": true,
                                                  "lark": true,
                                                  "wechat": true,
                                                  "weixin": true,
                                                  "WeChatLinux_x86_64": true,
                                                  "chatgpt": true,
                                                  "telegram": true,
                                                  "org.telegram.desktop": true,
                                                  "TelegramDesktop": true,
                                                  "discord": true,
                                                  "slack": true,
                                                  "steam": true,
                                                  "qq": true,
                                                  "linuxqq": true
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

    // Title / appId fallback map first (wechat → WeChatLinux_x86_64, 飞书 → feishu)
    const tryMap = function (value) {
      if (!value)
        return "";

      const v = String(value).trim();
      return titleAppFallbacks[v] || titleAppFallbacks[v.toLowerCase()] || "";
    };

    const mappedFromId = tryMap(rawAppId);
    const mappedFromTitle = tryMap(title);

    // A known class outranks an unrelated page/document title.
    if (mappedFromId || (!rawAppId && mappedFromTitle)) {
      return {
        "appId": resolveToDesktopEntryId(mappedFromId || mappedFromTitle),
        "rawAppId": rawAppId,
        "title": title
      };
    }

    if (rawAppId) {
      const resolved = resolveToDesktopEntryId(rawAppId);
      return {
        "appId": resolved || rawAppId,
        "rawAppId": rawAppId,
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

  // Function to update the combined model — stack windows of the same app into one icon.
  // After killactive (Cmd+W style): keep dock icons via session sticky until process dies.
  function updateCombinedModel() {
    const groups = [];
    const groupByKey = ({});
    const pinnedApps = Settings.data.dock.pinnedApps || [];
    const processedAppIds = new Set();
    // Accumulate session memory this pass, then commit once
    const seenNext = Object.assign(({}), sessionSeenApps);

    // First pass: collect running windows, grouped by resolved app id
    try {
      const liveWindows = main?.trackedWindows || [];
      const total = liveWindows.length;
      const activeIds = CompositorService.getActiveWorkspaces().map(function (ws) {
        return ws.id;
      });

      for (var i = 0; i < total; i++) {
        var w = liveWindows[i];

        if (!w)
          continue;

        // Plain snapshot — never store ListModel row proxies (invalid after syncWindows clear)
        const snap = snapshotWindow(w);

        if (!snap)
          continue;

        // IME / OSK / broken-class popups (Fcitx5 Input Window, etc.)
        if (isDockNoiseWindow(snap))
          continue;

        var passOutput = (!onlySameOutput) || (snap.output == screen?.name);
        var passWorkspace = (!onlyActiveWorkspaces) || (activeIds.includes(snap.workspaceId));

        if (!(passOutput && passWorkspace))
          continue;

        const identity = resolveAppIdentity(snap, snap.title || "");
        const resolvedId = identity.appId;
        const groupKey = normalizeAppId(resolvedId) || normalizeAppId(snap.appId) || ("win:" + String(snap.id));
        const isPinned = isAppIdPinned(resolvedId, pinnedApps) || isAppIdPinned(snap.appId, pinnedApps);

        if (!groupByKey[groupKey]) {
          const group = {
            "id": groupKey,
            "type": isPinned ? "pinned-running" : "running",
            "window": null,
            "windows": [],
            "count": 0,
            "appId": resolvedId || snap.appId || groupKey,
            "title": identity.title || ""
          };
          groupByKey[groupKey] = group;
          groups.push(group);
        }

        const group = groupByKey[groupKey];
        group.windows.push(snap);
        group.count = group.windows.length;

        if (isPinned)
          group.type = "pinned-running";

        if (snap.appId)
          processedAppIds.add(normalizeAppId(snap.appId));

        if (resolvedId)
          processedAppIds.add(normalizeAppId(resolvedId));
      }

      // Finalize primary window + title per group; remember for sticky dock
      for (var g = 0; g < groups.length; g++) {
        const group = groups[g];
        // Re-filter in case any entry lost its id
        group.windows = validWindows(group.windows);
        group.count = group.windows.length;

        if (group.count === 0)
          continue;

        const primary = primaryWindow(group.windows);
        group.window = primary;

        const displayName = getAppNameFromDesktopEntry(group.appId);
        const looksLikeId = !displayName || displayName === group.appId || String(group.appId).startsWith("title:");
        const fallbackTitle = (primary && primary.title) ? primary.title : (group.title || group.appId);
        group.title = looksLikeId ? fallbackTitle : displayName;

        if (group.count > 1)
          group.title = group.title + " ×" + group.count;

        // Session memory: after killactive, restore dock icon without window
        rememberSessionAppInto(seenNext, group.id, group.appId, group.title, group.windows);
      }

      // Drop groups that ended with zero valid windows so session sticky can re-add as background
      for (var dg = groups.length - 1; dg >= 0; dg--) {
        const doomed = groups[dg];

        if (!doomed || !doomed.windows || doomed.windows.length === 0) {
          if (doomed && doomed.id && groupByKey[doomed.id])
            delete groupByKey[doomed.id];

          groups.splice(dg, 1);
        }
      }
    } catch (e)
      // Ignore errors
    {}

    // Session sticky: apps that had a window this session, now window-less.
    // Keep dock icon like macOS until the kernel reports process exit.
    if (keepBackgroundApps) {
      const seenKeys = Object.keys(seenNext);

      for (var sk = 0; sk < seenKeys.length; sk++) {
        const key = seenKeys[sk];
        const seen = seenNext[key];

        if (!seen)
          continue;

        if (groupByKey[key])
          continue;

        // Retain only identities confirmed by the shared kernel-event watcher.
        // Windows filtered onto another monitor/workspace are not background.
        const allWindows = main?.trackedWindows || [];
        const ids = seen.windowIds || [];
        if (allWindows.some(w => ids.includes(w.trackId)))
          continue;
        const alive = main?.aliveWindowIds || ({});
        if (!ids.some(id => alive[id] === true)) {
          // Keep association while registration is in flight, but never render
          // an unconfirmed background icon. A later event can restore it.
          continue;
        }

        const seenAppId = seen.appId || key;

        if (processedAppIds.has(normalizeAppId(seenAppId)) || processedAppIds.has(key))
          continue;

        // Skip synthetic keys that can't be relaunched
        if (String(key).startsWith("win:") || String(key).startsWith("title:"))
          continue;

        if (String(seenAppId).startsWith("title:") || String(seenAppId).startsWith("win:"))
          continue;

        const isPinnedBg = isAppIdPinned(seenAppId, pinnedApps);
        const displayName = getAppNameFromDesktopEntry(seenAppId) || seen.title || seenAppId;
        const bgGroup = {
          "id": key,
          "type": "background",
          "window": null,
          "windows": [],
          "count": 0,
          "appId": seenAppId,
          "title": displayName,
          "isPinned": isPinnedBg
        };

        groupByKey[key] = bgGroup;
        groups.push(bgGroup);
        processedAppIds.add(key);
        processedAppIds.add(normalizeAppId(seenAppId));
      }
    }

    // Commit session memory once
    sessionSeenApps = seenNext;

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
                           processedAppIds.add(normalizedPinnedId);
                           processedAppIds.add(resolvedPinned);
                         });
    }

    combinedModel = sortApps(groups);

    // Sync session order if needed (e.g. first run or new apps added)
    if (!sessionAppOrder || sessionAppOrder.length === 0 || sessionAppOrder.length !== combinedModel.length) {
      sessionAppOrder = combinedModel.map(getAppKey);
    }

    updateHasWindow();
    // The open picker is a projection, never an independent stale snapshot.
    if (main?.stackAppId && pluginApi?.panelOpenScreen === screen) {
      const selected = combinedModel.find(g => g.appId === main.stackAppId);
      const windows = selected?.windows || [];
      main.setStackPicker({"appId": main.stackAppId,
                            "title": selected?.title || "",
                            "windows": windows.map(w => ({"window": w, "title": w.title,
                                                           "iconSource": resolveIconSource(selected.appId, w.title)}))});
    }
  }

  // Resolve desktop entry for launch (handles wechat → WeChatLinux_x86_64, etc.)
  function resolveDesktopEntry(appId) {
    if (!appId || typeof DesktopEntries === "undefined")
      return null;

    const identity = resolveAppIdentity(appId, "");
    const candidates = [identity.appId, appId, resolveToDesktopEntryId(appId), getDesktopEntryId(appId)].filter(Boolean);
    // Unique
    const tried = ({});

    for (var i = 0; i < candidates.length; i++) {
      const id = candidates[i];
      const k = normalizeAppId(id);

      if (!k || tried[k])
        continue;

      tried[k] = true;

      try {
        let entry = null;

        if (DesktopEntries.heuristicLookup)
          entry = DesktopEntries.heuristicLookup(id);

        if (!entry && DesktopEntries.byId)
          entry = DesktopEntries.byId(id);

        if (entry)
          return entry;
      } catch (e) {}
    }

    return null;
  }

  // Function to launch / restore a pinned or background app
  function launchPinnedApp(appId) {
    if (!appId)
      return;

    try {
      const app = resolveDesktopEntry(appId);

      if (!app) {
        // Last resort: gtk-launch with desktop id basename
        const deskId = String(appId).replace(/\.desktop$/i, "");
        Logger.w("TaskDock", "No desktop entry for " + appId + ", trying gtk-launch");
        Quickshell.execDetached(["gtk-launch", deskId]);
        return;
      }

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
        } else if (app.id) {
          // gtk-launch uses desktop file id (single-instance friendly for many apps)
          Quickshell.execDetached(["gtk-launch", String(app.id).replace(/\.desktop$/i, "")]);
        } else {
          Logger.w("TaskDock", `Could not launch: ${app.name || appId}. No valid launch method.`);
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
                     if (!root.focusTrackedWindow(selectedWindow) && item && item.group)
                       root.activateBackgroundApp(item.group);
                   } else if (action === "background-activate" && item && item.group) {
                     root.activateBackgroundApp(item.group);
                   } else if (action === "background-launch" && item && item.appId) {
                     root.launchPinnedApp(item.appId);
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
    target: root.main
    function onTrackedWindowsChanged() {
      updateCombinedModel();
    }
    function onAliveWindowIdsChanged() {
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
  onMainChanged: updateCombinedModel()
  onScreenChanged: updateCombinedModel()
  onOnlySameOutputChanged: updateCombinedModel()
  onOnlyActiveWorkspacesChanged: updateCombinedModel()
  onShowPinnedAppsChanged: updateCombinedModel()
  onKeepBackgroundAppsChanged: updateCombinedModel()

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
            root.focusTrackedWindow(nextWin);
          } else {
            var nextGroupIndex = (focusedGroupIndex + direction + root.combinedModel.length) % root.combinedModel.length;
            var guard = 0;

            while (guard < root.combinedModel.length) {
              const candidate = root.combinedModel[nextGroupIndex];
              const cWins = candidate.windows || [];

              if (cWins.length > 0) {
                root.focusTrackedWindow(primaryWindow(cWins));
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
              root.focusTrackedWindow(primaryWindow(wins));
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
          readonly property bool isBackground: modelData.type === "background"
          // Still "alive" after killactive (session sticky until process dies)
          readonly property bool isRunning: windowCount > 0 || isBackground
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
          // How many of this app's windows sit on a special workspace (Hyprland scratchpad etc.)
          readonly property int specialWindowCount: root.countSpecialWindows(groupWindows)
          // 0 = none on special; 1 = all on special; partial = mixed
          readonly property real specialRatio: windowCount > 0 ? (specialWindowCount / windowCount) : 0
          // Non-active apps dim; hover restores full opacity for affordance
          // Background stays slightly brighter so it reads as "still running"
          readonly property real itemOpacity: (isFocused || isHovered) ? 1.0 : (isBackground ? 0.7 : 0.45)

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
                  id: iconSlot
                  // Dots for multi-window only (2+), max 5, on the right of the icon
                  readonly property int windowDotCount: taskbarItem.windowCount >= 2 ? Math.min(taskbarItem.windowCount, 5) : 0
                  readonly property real windowDotSize: Math.max(3, Style.toOdd(root.itemSize * 0.12))
                  readonly property real windowDotGap: Math.max(2, Math.round(root.itemSize * 0.06))
                  readonly property real windowDotsPad: Math.max(2, Math.round(root.itemSize * 0.06))
                  readonly property real windowDotsWidth: windowDotCount > 0 ? (windowDotSize + windowDotsPad) : 0

                  Layout.preferredWidth: root.itemSize + windowDotsWidth
                  Layout.preferredHeight: root.itemSize
                  Layout.alignment: Qt.AlignVCenter | Qt.AlignLeft

                  // Rounded-rect icon + matching progress border (special workspace ratio).
                  // Border is drawn ON the edge — icon keeps full itemSize (not inset).
                  readonly property real iconRadius: Math.min(Style.radiusM, root.itemSize * 0.22)
                  readonly property real specialStroke: Math.max(2, root.itemSize * 0.085)

                  Item {
                    id: iconFace
                    width: root.itemSize
                    height: root.itemSize
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter

                    // Rounded app icon (full size) — mask host like MediaCard
                    Item {
                      id: roundedIconHost
                      anchors.fill: parent
                      z: 10
                      layer.enabled: true
                      layer.smooth: true
                      layer.effect: MultiEffect {
                        maskEnabled: true
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                        maskSource: ShaderEffectSource {
                          sourceItem: Rectangle {
                            width: root.itemSize
                            height: root.itemSize
                            radius: iconSlot.iconRadius
                            color: "white"
                          }
                        }
                      }

                      IconImage {
                        id: appIcon
                        anchors.fill: parent

                        source: root.resolveIconSource(taskbarItem.modelData.appId, taskbarItem.modelData.title || (taskbarItem.modelData.window ? taskbarItem.modelData.window.title : ""))
                        smooth: true
                        asynchronous: true

                        // Optional theme colorize (under the rounded mask)
                        layer.enabled: root.colorizeIcons
                        layer.effect: ShaderEffect {
                          property color targetColor: Settings.data.colorSchemes.darkMode ? Color.mOnSurface : Color.mSurfaceVariant
                          property real colorizeMode: 0.0

                          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/appicon_colorize.frag.qsb")
                        }
                      }
                    }

                    // Yellow rounded-rect border progress along the perimeter
                    // 1/1 special → full border; 2/4 → 50% of path from top-center clockwise
                    Canvas {
                      id: specialProgressBorder
                      anchors.fill: parent
                      z: 15
                      visible: taskbarItem.specialRatio > 0.001
                      antialiasing: true

                      readonly property real progress: taskbarItem.specialRatio
                      readonly property color borderColor: "#F5C518"
                      readonly property real stroke: iconSlot.specialStroke
                      readonly property real cornerR: iconSlot.iconRadius

                      onProgressChanged: requestPaint()
                      onWidthChanged: requestPaint()
                      onHeightChanged: requestPaint()
                      onVisibleChanged: if (visible)
                                          requestPaint()
                      onStrokeChanged: requestPaint()
                      onCornerRChanged: requestPaint()

                      onPaint: {
                        const ctx = getContext("2d");
                        ctx.reset();

                        if (progress <= 0 || width <= 0 || height <= 0)
                          return;

                        const p = Math.max(0, Math.min(1, progress));
                        const sw = stroke;
                        // Inset by half stroke so the stroke sits on the icon edge without layout growth
                        const x = sw / 2;
                        const y = sw / 2;
                        const w = width - sw;
                        const h = height - sw;
                        let r = Math.min(cornerR, w / 2, h / 2);

                        if (r < 0)
                          r = 0;

                        // Perimeter segments clockwise from top-center
                        const topLen = Math.max(0, w - 2 * r);
                        const sideLen = Math.max(0, h - 2 * r);
                        const cornerLen = (Math.PI / 2) * r;
                        const halfTop = topLen / 2;

                        const segs = [
                          halfTop, cornerLen, sideLen, cornerLen, topLen, cornerLen, sideLen, cornerLen, halfTop
                        ];
                        let total = 0;

                        for (var si = 0; si < segs.length; si++)
                          total += segs[si];

                        if (total <= 0)
                          return;

                        const target = p * total;

                        function pointOnSeg(idx, t) {
                          const left = x;
                          const right = x + w;
                          const top = y;
                          const bottom = y + h;
                          const tr = {
                            "cx": right - r,
                            "cy": top + r
                          };
                          const br = {
                            "cx": right - r,
                            "cy": bottom - r
                          };
                          const bl = {
                            "cx": left + r,
                            "cy": bottom - r
                          };
                          const tl = {
                            "cx": left + r,
                            "cy": top + r
                          };

                          if (idx === 0) {
                            return {
                              "x": x + r + halfTop + t * halfTop,
                              "y": top
                            };
                          }

                          if (idx === 1) {
                            const a = -Math.PI / 2 + t * (Math.PI / 2);
                            return {
                              "x": tr.cx + r * Math.cos(a),
                              "y": tr.cy + r * Math.sin(a)
                            };
                          }

                          if (idx === 2) {
                            return {
                              "x": right,
                              "y": top + r + t * sideLen
                            };
                          }

                          if (idx === 3) {
                            const a = 0 + t * (Math.PI / 2);
                            return {
                              "x": br.cx + r * Math.cos(a),
                              "y": br.cy + r * Math.sin(a)
                            };
                          }

                          if (idx === 4) {
                            return {
                              "x": right - r - t * topLen,
                              "y": bottom
                            };
                          }

                          if (idx === 5) {
                            const a = Math.PI / 2 + t * (Math.PI / 2);
                            return {
                              "x": bl.cx + r * Math.cos(a),
                              "y": bl.cy + r * Math.sin(a)
                            };
                          }

                          if (idx === 6) {
                            return {
                              "x": left,
                              "y": bottom - r - t * sideLen
                            };
                          }

                          if (idx === 7) {
                            const a = Math.PI + t * (Math.PI / 2);
                            return {
                              "x": tl.cx + r * Math.cos(a),
                              "y": tl.cy + r * Math.sin(a)
                            };
                          }

                          return {
                            "x": left + r + t * halfTop,
                            "y": top
                          };
                        }

                        const steps = Math.max(24, Math.ceil(target / 1.5));
                        ctx.beginPath();

                        let walked = 0;
                        let started = false;
                        let segIdx = 0;

                        for (var step = 0; step <= steps; step++) {
                          const dist = (step / steps) * target;

                          while (segIdx < segs.length && walked + segs[segIdx] < dist - 1e-6) {
                            walked += segs[segIdx];
                            segIdx++;
                          }

                          if (segIdx >= segs.length)
                            segIdx = segs.length - 1;

                          const segLen = segs[segIdx] || 1;
                          const local = Math.max(0, Math.min(1, (dist - walked) / segLen));
                          const pt = pointOnSeg(segIdx, local);

                          if (!started) {
                            ctx.moveTo(pt.x, pt.y);
                            started = true;
                          } else {
                            ctx.lineTo(pt.x, pt.y);
                          }
                        }

                        ctx.strokeStyle = borderColor;
                        ctx.lineWidth = sw;
                        ctx.lineCap = p >= 0.999 ? "butt" : "round";
                        ctx.lineJoin = "round";
                        ctx.stroke();
                      }
                    }
                  }

                  // Window indicators on the right: one dot per window (2+ only), max 5
                  Column {
                    id: windowDotsCol
                    visible: iconSlot.windowDotCount > 0
                    anchors.left: iconFace.right
                    anchors.leftMargin: iconSlot.windowDotsPad
                    anchors.verticalCenter: iconFace.verticalCenter
                    spacing: iconSlot.windowDotGap
                    z: 20

                    Repeater {
                      model: iconSlot.windowDotCount

                      Rectangle {
                        required property int index
                        width: iconSlot.windowDotSize
                        height: iconSlot.windowDotSize
                        radius: width / 2
                        // Focused app: stronger dots; otherwise muted
                        color: taskbarItem.isFocused ? Color.mPrimary : Color.mOnSurface
                        opacity: taskbarItem.isFocused ? 0.95 : 0.45
                      }
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

                            if (isBackground) {
                              // No open window: Open (re-launch) / Pin / settings
                              root.selectedWindowId = "";
                              root.selectedAppId = modelData.appId;
                              root.openBackgroundContextMenu(taskbarItem, modelData);
                            } else if (isRunning) {
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

  function openBackgroundContextMenu(anchorItem, group) {
    var items = [];

    if (group && group.type === "background") {
      // Focus existing window or single-instance launch (macOS dock click)
      items.push({
                   "label": I18n.tr("common.focus") || "Open",
                   "action": "background-activate",
                   "icon": "eye",
                   "group": group
                 });
    }

    if (root.selectedAppId && !String(root.selectedAppId).startsWith("title:")) {
      const isPinned = root.isAppPinned(root.selectedAppId);
      items.push({
                   "label": !isPinned ? I18n.tr("common.pin") : I18n.tr("common.unpin"),
                   "action": "pin",
                   "icon": !isPinned ? "pin" : "unpin"
                 });
    }

    items.push({
                 "label": I18n.tr("actions.widget-settings"),
                 "action": "widget-settings",
                 "icon": "settings"
               });

    contextMenu.model = items;
    // Same anchoring as openTaskbarContextMenu (root stable, center on item)
    PanelService.showContextMenu(contextMenu, root, screen, anchorItem);
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

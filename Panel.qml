import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.Commons
import qs.Services.Compositor
import qs.Services.UI
import qs.Widgets

// Stacked-app window picker — vertical list, SmartPanel host (clashia-style)
Item {
  id: root

  property var pluginApi: null

  readonly property var main: pluginApi?.mainInstance
  readonly property var windows: main?.stackWindows || []
  readonly property string appId: main?.stackAppId || ""
  readonly property string appTitle: main?.stackTitle || ""

  // SmartPanel contract (see clashia Panel.qml / PluginPanelSlot)
  readonly property var geometryPlaceholder: panelContainer
  property real contentPreferredWidth: Math.round(320 * Style.uiScaleRatio)
  property real contentPreferredHeight: {
    const header = Style.marginM * 2 + Style.fontSizeS + Style.marginXS;
    const rows = Math.min(windows.length, 8);
    const listH = rows * (rowHeight + rowSpacing) + Style.marginS;
    return Math.round(header + listH);
  }
  readonly property bool allowAttach: true

  // Match bar / panel surface (SmartPanel also paints Color.mSurface behind us)
  readonly property color panelBackgroundColor: Color.mSurface

  readonly property real rowHeight: Math.round(36 * Style.uiScaleRatio)
  readonly property real rowIconSize: Math.round(24 * Style.uiScaleRatio)
  readonly property real rowSpacing: Math.round(2 * Style.uiScaleRatio)

  anchors.fill: parent

  function focusWindow(window) {
    if (!window)
      return;

    try {
      CompositorService.focusWindow(window);
    } catch (error) {
      Logger.e("TaskDock", "Failed to focus stacked window: " + error);
    }

    if (pluginApi) {
      const scr = pluginApi.panelOpenScreen;

      if (scr)
        pluginApi.closePanel(scr);
      else if (pluginApi.withCurrentScreen) {
        pluginApi.withCurrentScreen(function (s) {
          pluginApi.closePanel(s);
        });
      }
    }

    if (main && main.clearStackPicker)
      main.clearStackPicker();
  }

  function windowLabel(entry, index) {
    if (entry && entry.title && String(entry.title).trim() !== "")
      return entry.title;

    if (main && main.stackWindowLabel)
      return main.stackWindowLabel(entry ? entry.window : null, index);

    return "Window " + (index + 1);
  }

  Item {
    id: panelContainer
    anchors.fill: parent

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginXS

      NText {
        visible: root.appTitle !== ""
        Layout.fillWidth: true
        text: root.appTitle
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        elide: Text.ElideRight
      }

      // Vertical list + top/bottom edge shadow fades (NScrollView-style)
      Item {
        id: scrollHost
        Layout.fillWidth: true
        Layout.fillHeight: true

        readonly property real gradientHeight: Math.round(24 * Style.uiScaleRatio)
        readonly property color gradientColor: root.panelBackgroundColor
        readonly property bool verticalScrollable: stackFlick.contentHeight > stackFlick.height + 1
        readonly property bool canScrollUp: verticalScrollable && stackFlick.contentY > 1
        readonly property bool canScrollDown: verticalScrollable && (stackFlick.contentY + stackFlick.height < stackFlick.contentHeight - 1)

        Flickable {
          id: stackFlick
          anchors.fill: parent
          contentWidth: width
          contentHeight: stackColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick

          Column {
            id: stackColumn
            width: stackFlick.width
            spacing: root.rowSpacing

            Repeater {
              model: root.windows

              delegate: Item {
                id: stackRow
                required property var modelData
                required property int index

                readonly property var win: modelData.window || modelData
                readonly property bool isFocused: !!(win && win.isFocused)
                readonly property string winTitle: root.windowLabel(modelData, index)
                readonly property string iconSrc: modelData.iconSource || (main && main.resolveIconSource ? main.resolveIconSource(root.appId, winTitle) : "")

                width: stackColumn.width
                height: root.rowHeight
                // Default full; hover only dims — focused stays full
                opacity: rowMouse.containsMouse && !stackRow.isFocused ? 0.55 : 1.0

                Behavior on opacity {
                  NumberAnimation {
                    duration: Style.animationFast
                    easing.type: Easing.OutCubic
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.marginXS
                  anchors.rightMargin: Style.marginXS
                  spacing: Style.marginS

                  Item {
                    Layout.preferredWidth: root.rowIconSize
                    Layout.preferredHeight: root.rowIconSize
                    Layout.alignment: Qt.AlignVCenter

                    IconImage {
                      anchors.fill: parent
                      source: stackRow.iconSrc
                      smooth: true
                      asynchronous: true
                    }
                  }

                  NText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: stackRow.winTitle
                    pointSize: Style.fontSizeS
                    color: stackRow.isFocused ? Color.mPrimary : Color.mOnSurface
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                    maximumLineCount: 1
                    font.weight: stackRow.isFocused ? Font.DemiBold : Font.Normal
                  }
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.focusWindow(stackRow.win)
                }
              }
            }
          }
        }

        // Top edge fade
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: scrollHost.gradientHeight
          z: 2
          visible: scrollHost.verticalScrollable
          opacity: scrollHost.canScrollUp ? 1 : 0
          enabled: false

          Behavior on opacity {
            NumberAnimation {
              duration: Style.animationFast
              easing.type: Easing.InOutQuad
            }
          }

          gradient: Gradient {
            GradientStop {
              position: 0.0
              color: scrollHost.gradientColor
            }
            GradientStop {
              position: 1.0
              color: "transparent"
            }
          }
        }

        // Bottom edge fade
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: scrollHost.gradientHeight
          z: 2
          visible: scrollHost.verticalScrollable
          opacity: scrollHost.canScrollDown ? 1 : 0
          enabled: false

          Behavior on opacity {
            NumberAnimation {
              duration: Style.animationFast
              easing.type: Easing.InOutQuad
            }
          }

          gradient: Gradient {
            GradientStop {
              position: 0.0
              color: "transparent"
            }
            GradientStop {
              position: 1.0
              color: scrollHost.gradientColor
            }
          }
        }
      }
    }
  }
}

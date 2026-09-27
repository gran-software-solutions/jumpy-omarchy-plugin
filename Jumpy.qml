// Jumpy: the window list for the Alt+Tab switcher.
//
// Display only. jumpy.lua, loaded from the Hyprland config, owns the keys, the
// frozen window list, the filter and the cursor, and drives this panel:
//
//   omarchy-shell jumpy show '{"windows":[...],"index":1,"filter":"",...}'
//   omarchy-shell jumpy hide
//
// The list arrives most recent first, one row per window: the app's icon and
// name on the left, the title, and the workspace number on the right.
//
// The panel never takes keyboard focus: while a switch is up, Hyprland's "jumpy"
// submap swallows stray keys, so a grab here would only add a way to get stuck.
// A quick Alt+Tab is committed before showDelay runs out, so the list is never
// drawn for it and the flip feels instant.
//
// Colours and type come from the active Omarchy theme and font.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root

  // Injected by Omarchy's panel loader.
  property var shell: null
  property var manifest: null

  property bool active: false   // a switch is in progress
  property bool opened: false   // ...and has been held long enough to draw
  property var windows: []
  property int selectedIndex: 0
  property string filterText: ""
  property int total: 0

  readonly property int showDelay: 90

  // ---- colour, from the theme ----
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.accent
  readonly property bool lightTheme: background.hslLightness > 0.5
  readonly property color hairline: Util.alpha(foreground, lightTheme ? 0.07 : 0.10)
  readonly property color frame: Util.alpha(foreground, lightTheme ? 0.10 : 0.14)
  readonly property color faint: Util.alpha(foreground, 0.42)
  readonly property color muted: Util.alpha(foreground, 0.62)
  // The cursor is a raised pill: a touch lighter than the card, a hairline
  // edge and a small shadow, like a key sitting on the surface. The title on
  // it keeps its own colour.
  readonly property color cursorFill: lightTheme ? background : Util.alpha(foreground, 0.07)
  readonly property color cursorEdge: Util.alpha(foreground, lightTheme ? 0.10 : 0.12)
  readonly property color scrim: Util.alpha("#000000", lightTheme ? 0.10 : 0.28)

  // ---- type ----
  // The Omarchy system font, as set with `omarchy font set`, so Jumpy matches
  // the bar and the menus.
  readonly property string sans: Style.font.menuFamily
  readonly property string label: Style.font.menuFamily
  readonly property int rowFont: Style.font.body                          // 12 at the default size
  readonly property int labelFont: Math.max(9, Math.round(Style.font.caption * 0.95))

  // ---- measure ----
  readonly property int rowHeight: Style.space(32)
  readonly property int appColumn: Style.space(150)
  readonly property int wsColumn: Style.space(28)
  readonly property int rowPadding: Style.space(10)
  readonly property int iconSize: Style.space(20)
  readonly property int maxRows: 14
  readonly property int cardRadius: Style.space(12)
  readonly property int cardWidth: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)

  readonly property int listHeight: Math.max(1, Math.min(root.windows.length, root.maxRows)) * root.rowHeight

  // ---- pointer ----
  // The pointer may already rest over the list when it opens, so hovering only
  // takes the cursor once the pointer has actually moved.
  property point pointerOrigin: Qt.point(-1, -1)
  property bool pointerLive: false

  function pointerMoved(x, y) {
    if (root.pointerOrigin.x < 0) { root.pointerOrigin = Qt.point(x, y); return false }
    if (!root.pointerLive && Math.abs(x - root.pointerOrigin.x) + Math.abs(y - root.pointerOrigin.y) > 6)
      root.pointerLive = true
    return root.pointerLive
  }

  function pointAt(index) {
    if (index === root.selectedIndex) return
    root.selectedIndex = index
    watchdog.restart()
    Quickshell.execDetached(["hyprctl", "eval", "__jumpy_point(" + index + ")"])
  }

  function pickAt(index) {
    Quickshell.execDetached(["hyprctl", "eval", "__jumpy_pick(" + index + ")"])
  }

  function friendlyAppName(appClass) {
    const raw = String(appClass || "").trim()
    if (!raw) return "Unknown"
    const entry = DesktopEntries.heuristicLookup(raw)
    if (entry && entry.name) return String(entry.name)
    let name = raw.replace(/^steam_app_/i, "")
    if (name.indexOf(".") !== -1) name = name.split(".").pop()
    name = name.replace(/[_-]+/g, " ").trim()
    return name.replace(/(^|\s)\S/g, function(letter) { return letter.toUpperCase() })
  }

  function appIcon(appClass) {
    const raw = String(appClass || "").trim()
    const entry = raw ? DesktopEntries.heuristicLookup(raw) : null
    const icon = entry ? String(entry.icon || "") : ""
    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon || "application-x-executable", true)
  }

  function show(payloadJson) {
    // Armed before anything that can throw, so a bad payload can never strand
    // the panel on screen.
    watchdog.restart()

    let payload
    try {
      payload = JSON.parse(payloadJson)
    } catch (error) {
      console.warn("jumpy: unreadable payload:", error)
      root.hide()
      return
    }

    root.windows = payload.windows || []
    root.selectedIndex = payload.index || 0
    root.filterText = payload.filter || ""
    root.total = payload.total || root.windows.length

    if (!root.active) {
      root.active = true
      root.pointerOrigin = Qt.point(-1, -1)
      root.pointerLive = false
      revealTimer.restart()
    }
  }

  function hide() {
    watchdog.stop()
    revealTimer.stop()
    root.active = false
    root.opened = false
  }

  Timer {
    id: revealTimer
    interval: root.showDelay
    onTriggered: if (root.active) root.opened = true
  }

  // If jumpy.lua ever misses the end of a switch, give up and tell it to reset,
  // so the two halves cannot disagree about whether a switch is running.
  Timer {
    id: watchdog
    interval: 20000
    onTriggered: {
      root.hide()
      Quickshell.execDetached(["hyprctl", "eval", "__jumpy_cancel()"])
    }
  }

  IpcHandler {
    target: "jumpy"

    function show(payloadJson: string): string {
      root.show(payloadJson)
      return "ok"
    }

    function hide(): string {
      root.hide()
      return "ok"
    }

    function state(): string {
      return root.opened ? "open" : (root.active ? "pending" : "closed")
    }
  }

  component RowText: Text {
    // Every text in a row fills the row's height and centres in it, so the
    // app name, title and workspace share one baseline.
    Layout.fillHeight: true
    textFormat: Text.PlainText
    elide: Text.ElideRight
    font.family: root.sans
    font.pixelSize: root.rowFont
    font.features: { "tnum": 1 }
    verticalAlignment: Text.AlignVCenter
  }

  PanelWindow {
    id: panel

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "de.gransoftware.jumpy"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    // A click outside the card cancels the switch.
    MouseArea {
      anchors.fill: parent
      onClicked: Quickshell.execDetached(["hyprctl", "eval", "__jumpy_cancel()"])
    }

    Item {
      id: stage
      width: root.cardWidth
      height: column.implicitHeight + Style.space(12)
      anchors.centerIn: parent

      // Opens with a short settle rather than a pop.
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.97
      Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

      // Two shadows: a wide, soft one for lift and a tight one for the edge.
      RectangularShadow {
        anchors.fill: card
        radius: root.cardRadius
        offset: Qt.vector2d(0, Style.space(18))
        blur: Style.space(56)
        spread: -Style.space(8)
        color: Util.alpha("#000000", root.lightTheme ? 0.22 : 0.50)
      }
      RectangularShadow {
        anchors.fill: card
        radius: root.cardRadius
        offset: Qt.vector2d(0, 1)
        blur: Style.space(4)
        color: Util.alpha("#000000", root.lightTheme ? 0.08 : 0.30)
      }

      Rectangle {
        id: card
        anchors.fill: parent
        radius: root.cardRadius
        // A shade below the theme's surface, so the cursor pill (at the
        // surface colour) sits visibly on top of it.
        color: root.lightTheme ? Qt.darker(root.background, 1.03) : root.background

        // Clicks on the card itself (header, padding) must not reach the
        // cancel area behind it.
        MouseArea { anchors.fill: parent }
        border.width: 1
        border.color: root.frame

        // A one-pixel light edge along the top, like a lit bevel.
        Rectangle {
          anchors.top: parent.top
          anchors.topMargin: 1
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width - root.cardRadius * 2
          height: 1
          color: Util.alpha("#ffffff", root.lightTheme ? 0.7 : 0.06)
        }

        Column {
          id: column
          anchors.fill: parent
          anchors.margins: Style.space(6)
          spacing: 0

          // ---- header: what you typed (or how many windows) and the column label ----
          Item {
            width: parent.width
            height: Style.space(36)

            Row {
              anchors.left: parent.left
              anchors.leftMargin: root.rowPadding
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              // Search glyph, the typed filter and a caret, while you type.
              Row {
                visible: root.filterText.length > 0
                spacing: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  rightPadding: Style.space(6)
                  text: "\u{F0349}"   // nf-md-magnify, from the theme's Nerd Font
                  color: root.faint
                  font.family: Style.font.family
                  font.pixelSize: Math.round(root.rowFont * 1.25)
                }

                RowText {
                  text: root.filterText
                  color: root.foreground
                  font.pixelSize: Math.round(root.rowFont * 1.1)
                  font.weight: Font.Medium
                  elide: Text.ElideNone
                }
                Rectangle {
                  width: 2
                  height: Math.round(root.rowFont * 1.2)
                  radius: 1
                  color: root.accent
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              RowText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.filterText.length > 0
                      ? root.windows.length + " of " + root.total
                      : root.total + (root.total === 1 ? " window" : " windows")
                color: root.faint
                font.pixelSize: Math.round(root.rowFont * 0.93)
                elide: Text.ElideNone
              }
            }

            Text {
              anchors.right: parent.right
              anchors.rightMargin: root.rowPadding
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "WORKSPACE"
              color: root.faint
              font.family: root.label
              font.weight: Font.DemiBold
              font.pixelSize: root.labelFont
              font.letterSpacing: 1.4
            }

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: root.rowPadding
              anchors.rightMargin: root.rowPadding
              height: 1
              color: root.hairline
            }
          }

          // Air between the header rule and the first row.
          Item { width: parent.width; height: Style.space(4) }

          ListView {
            id: list
            width: parent.width
            height: root.listHeight
            clip: true
            interactive: false
            model: root.windows
            currentIndex: root.selectedIndex
            highlightMoveDuration: 0
            preferredHighlightBegin: 0
            preferredHighlightEnd: height
            highlightRangeMode: ListView.ApplyRange

            RowText {
              anchors.centerIn: parent
              visible: root.windows.length === 0
              text: "Nothing matches “" + root.filterText + "”"
              color: root.faint
            }

            delegate: Item {
              id: row
              required property int index
              required property var modelData
              readonly property bool selected: index === root.selectedIndex

              width: list.width
              height: root.rowHeight

              RectangularShadow {
                visible: row.selected
                anchors.fill: pill
                radius: pill.radius
                offset: Qt.vector2d(0, 1)
                blur: Style.space(6)
                color: Util.alpha("#000000", root.lightTheme ? 0.10 : 0.35)
              }

              Rectangle {
                id: pill
                anchors.fill: parent
                radius: Style.space(8)
                color: row.selected ? root.cursorFill : "transparent"
                border.width: row.selected ? 1 : 0
                border.color: root.cursorEdge

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: root.rowPadding
                  anchors.rightMargin: root.rowPadding
                  spacing: Style.space(10)

                  // App column: icon and name, on every row.
                  RowLayout {
                    Layout.preferredWidth: root.appColumn
                    Layout.minimumWidth: root.appColumn
                    Layout.maximumWidth: root.appColumn
                    Layout.fillHeight: true
                    spacing: Style.space(10)

                    Image {
                      Layout.preferredWidth: root.iconSize
                      Layout.preferredHeight: root.iconSize
                      Layout.alignment: Qt.AlignVCenter
                      fillMode: Image.PreserveAspectFit
                      sourceSize.width: width * Screen.devicePixelRatio
                      sourceSize.height: height * Screen.devicePixelRatio
                      source: root.appIcon(row.modelData.appClass)
                      asynchronous: true
                      smooth: true
                      mipmap: true
                    }

                    RowText {
                      Layout.fillWidth: true
                      text: root.friendlyAppName(row.modelData.appClass)
                      color: row.selected ? root.foreground : root.muted
                      font.weight: Font.Medium
                    }
                  }

                  RowText {
                    Layout.fillWidth: true
                    text: row.modelData.title || root.friendlyAppName(row.modelData.appClass)
                    color: row.modelData.current && !row.selected ? root.muted : root.foreground
                    font.weight: row.selected ? Font.Medium : Font.Normal
                  }

                  RowText {
                    Layout.preferredWidth: root.wsColumn
                    horizontalAlignment: Text.AlignRight
                    text: row.modelData.workspace
                    color: row.selected ? root.accent : root.faint
                    font.weight: row.selected ? Font.DemiBold : Font.Normal
                  }
                }
              }

              // Hover takes the cursor, a click switches to the window.
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) {
                  const p = mapToItem(null, mouse.x, mouse.y)
                  if (root.pointerMoved(p.x, p.y)) root.pointAt(row.index)
                }
                onClicked: root.pickAt(row.index)
              }
            }
          }
        }
      }
    }
  }
}

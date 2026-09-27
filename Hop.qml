// Hop: the window list for the Alt+Tab switcher.
//
// Display only. hop.lua, loaded from the Hyprland config, owns the keys, the
// frozen window list, the filter and the cursor, and drives this panel:
//
//   omarchy-shell hop show '{"windows":[...],"index":1,"filter":"",...}'
//   omarchy-shell hop hide
//
// The list arrives grouped by app. Each window says whether it opens its app's
// block ("first") and how many windows the block has ("count"); the app's
// icon, name and count, "Brave (2)", are drawn once, on the first row, and a hairline
// separates one app from the next.
//
// The panel never takes keyboard focus: while a switch is up, Hyprland's "hop"
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
  // The cursor is a quiet wash of the accent rather than the theme's solid
  // selection block, so the title on it keeps its own colour.
  readonly property color cursorFill: Util.alpha(accent, lightTheme ? 0.10 : 0.16)
  readonly property color scrim: Util.alpha("#000000", lightTheme ? 0.10 : 0.28)

  // ---- type ----
  // The Omarchy system font, as set with `omarchy font set`, so Hop matches
  // the bar and the menus.
  readonly property string sans: Style.font.menuFamily
  readonly property string label: Style.font.menuFamily
  readonly property int rowFont: Math.round(Style.font.body * 1.17)       // 14 at the default size
  readonly property int labelFont: Math.max(9, Math.round(Style.font.caption * 0.95))

  // ---- measure ----
  readonly property int rowHeight: Style.space(38)
  readonly property int groupGap: Style.space(6)
  readonly property int appColumn: Style.space(128)
  readonly property int wsColumn: Style.space(28)
  readonly property int rowPadding: Style.space(14)
  readonly property int iconSize: Style.space(20)
  readonly property int maxRows: 14
  readonly property int cardRadius: Style.space(16)
  readonly property int cardWidth: Math.min(Style.space(500), panel.width - Style.gapsOut * 2)

  // Rows plus the gap each app block after the first adds above itself.
  readonly property int listHeight: {
    let h = 0
    const n = Math.min(root.windows.length, root.maxRows)
    for (let i = 0; i < n; i++) h += root.rowHeight + (root.startsBlock(i) ? root.groupGap * 2 + 1 : 0)
    return Math.max(root.rowHeight, h)
  }

  function startsBlock(index) {
    return index > 0 && !!root.windows[index] && root.windows[index].first
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
      console.warn("hop: unreadable payload:", error)
      root.hide()
      return
    }

    root.windows = payload.windows || []
    root.selectedIndex = payload.index || 0
    root.filterText = payload.filter || ""
    root.total = payload.total || root.windows.length

    if (!root.active) {
      root.active = true
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

  // If hop.lua ever misses the end of a switch, give up and tell it to reset,
  // so the two halves cannot disagree about whether a switch is running.
  Timer {
    id: watchdog
    interval: 20000
    onTriggered: {
      root.hide()
      Quickshell.execDetached(["hyprctl", "eval", "__hop_cancel()"])
    }
  }

  IpcHandler {
    target: "hop"

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
    WlrLayershell.namespace: "de.gransoftware.hop"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    Item {
      id: stage
      width: root.cardWidth
      height: column.implicitHeight + Style.space(24)
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
        color: root.background
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
          anchors.margins: Style.space(12)
          spacing: 0

          // ---- header: what you typed (or how many windows) and the column label ----
          Item {
            width: parent.width
            height: Style.space(48)

            Row {
              anchors.left: parent.left
              anchors.leftMargin: root.rowPadding
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              // Typed filter with a caret, while you type.
              Row {
                visible: root.filterText.length > 0
                spacing: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter

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
          Item { width: parent.width; height: Style.space(8) }

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
              readonly property bool block: root.startsBlock(index)

              width: list.width
              height: root.rowHeight + (block ? root.groupGap * 2 + 1 : 0)

              // Hairline that closes the app above.
              Rectangle {
                visible: row.block
                y: root.groupGap
                x: root.rowPadding
                width: parent.width - root.rowPadding * 2
                height: 1
                color: root.hairline
              }

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: root.rowHeight
                radius: Style.space(10)
                color: row.selected ? root.cursorFill : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: root.rowPadding
                  anchors.rightMargin: root.rowPadding
                  spacing: Style.space(12)

                  // App column: icon, name and window count, first row only.
                  RowLayout {
                    Layout.preferredWidth: root.appColumn
                    Layout.maximumWidth: root.appColumn
                    Layout.fillHeight: true
                    spacing: Style.space(10)
                    visible: row.modelData.first

                    Image {
                      Layout.preferredWidth: root.iconSize
                      Layout.preferredHeight: root.iconSize
                      fillMode: Image.PreserveAspectFit
                      sourceSize.width: width * Screen.devicePixelRatio
                      sourceSize.height: height * Screen.devicePixelRatio
                      source: row.modelData.first ? root.appIcon(row.modelData.appClass) : ""
                      asynchronous: true
                      smooth: true
                      mipmap: true
                    }

                    // "Brave (2)": the count follows the name, in a lighter tone.
                    RowText {
                      Layout.maximumWidth: root.appColumn - root.iconSize - Style.space(40)
                      text: root.friendlyAppName(row.modelData.appClass)
                      color: row.selected ? root.foreground : root.muted
                      font.weight: Font.Medium
                    }

                    RowText {
                      visible: (row.modelData.count || 1) > 1
                      Layout.leftMargin: -Style.space(5)
                      text: "(" + row.modelData.count + ")"
                      color: root.faint
                      elide: Text.ElideNone
                    }

                    Item { Layout.fillWidth: true }
                  }
                  Item {
                    visible: !row.modelData.first
                    Layout.preferredWidth: root.appColumn
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
            }
          }
        }
      }
    }
  }
}

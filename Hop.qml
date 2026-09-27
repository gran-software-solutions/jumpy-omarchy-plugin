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
// icon, name and count are drawn once, on the first row, and a hairline
// separates one app from the next.
//
// The panel never takes keyboard focus: while a switch is up, Hyprland's "hop"
// submap swallows stray keys, so a grab here would only add a way to get stuck.
// A quick Alt+Tab is committed before showDelay runs out, so the list is never
// drawn for it and the flip feels instant.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
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

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  // Same hairline card frame as Yank and Sesame.
  readonly property var borderSpec: Border.flat(Util.alpha(Color.menu.border, 0.4), 1)
  readonly property color hairline: Util.alpha(foreground, 0.09)
  readonly property color faint: Util.alpha(foreground, 0.45)
  readonly property color muted: Util.alpha(foreground, 0.68)

  readonly property string fontFamily: Style.font.menuFamily
  readonly property int labelFont: Math.max(9, Math.round(Style.font.caption * 0.82))
  readonly property int rowHeight: Style.space(32)
  readonly property int groupGap: Style.space(4)
  readonly property int appColumn: Style.space(118)
  readonly property int wsColumn: Style.space(28)
  readonly property int rowPadding: Style.space(10)
  readonly property int maxRows: 14
  readonly property int cardWidth: Math.min(Style.space(460), panel.width - Style.gapsOut * 2)

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
      color: Color.menu.scrim
    }

    BorderSurface {
      id: card

      width: root.cardWidth
      height: column.implicitHeight + contentTopInset + contentBottomInset
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.space(6)

      Column {
        id: column
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: 0

        // ---- filter line: only while you are typing ----
        Item {
          width: parent.width
          height: visible ? Style.space(34) : 0
          visible: root.filterText.length > 0

          Text {
            anchors.left: parent.left
            anchors.leftMargin: root.rowPadding
            anchors.right: countLabel.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.filterText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideLeft
          }

          Text {
            id: countLabel
            anchors.right: parent.right
            anchors.rightMargin: root.rowPadding
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.windows.length + " of " + root.total
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: root.labelFont
          }

          Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: root.hairline
          }
        }

        // ---- column label, once ----
        Item {
          width: parent.width
          height: Style.space(20)

          Text {
            anchors.right: parent.right
            anchors.rightMargin: root.rowPadding
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(2)
            textFormat: Text.PlainText
            text: "WORKSPACE"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: root.labelFont
            font.letterSpacing: 0.8
          }
        }

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

          Text {
            anchors.centerIn: parent
            visible: root.windows.length === 0
            textFormat: Text.PlainText
            text: "No window matches “" + root.filterText + "”"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
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
              radius: Style.space(7)
              color: row.selected ? root.selectedBackground : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: root.rowPadding
                anchors.rightMargin: root.rowPadding
                spacing: Style.space(10)

                // App column: icon, name and window count, on the first row only.
                RowLayout {
                  Layout.preferredWidth: root.appColumn
                  Layout.maximumWidth: root.appColumn
                  spacing: Style.space(8)
                  opacity: row.modelData.first ? 1 : 0

                  Image {
                    Layout.preferredWidth: Style.space(18)
                    Layout.preferredHeight: Style.space(18)
                    fillMode: Image.PreserveAspectFit
                    sourceSize.width: width * Screen.devicePixelRatio
                    sourceSize.height: height * Screen.devicePixelRatio
                    source: row.modelData.first ? root.appIcon(row.modelData.appClass) : ""
                    asynchronous: true
                  }

                  Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.friendlyAppName(row.modelData.appClass)
                    color: row.selected ? root.selectedText : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.weight: Font.Medium
                  }

                  Text {
                    visible: (row.modelData.count || 1) > 1
                    textFormat: Text.PlainText
                    text: String(row.modelData.count)
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: root.labelFont + 1
                  }
                }

                Text {
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: row.modelData.title || root.friendlyAppName(row.modelData.appClass)
                  color: row.selected ? root.selectedText
                       : (row.modelData.current ? root.muted : root.foreground)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.weight: row.selected ? Font.Medium : Font.Normal
                }

                Text {
                  Layout.preferredWidth: root.wsColumn
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: row.modelData.workspace
                  color: row.selected ? Color.accent : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }
              }
            }
          }
        }
      }
    }
  }
}

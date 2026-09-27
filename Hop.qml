// Hop: the window list for the Alt+Tab switcher.
//
// Display only. hop.lua, loaded from the Hyprland config, owns the keys, the
// frozen window list, the filter and the cursor, and drives this panel:
//
//   omarchy-shell hop show '{"windows":[...],"index":1,"filter":"",...}'
//   omarchy-shell hop hide
//
// The panel never takes keyboard focus: while a switch is up, Hyprland's "hop"
// submap swallows stray keys, so a grab here would only add a way to get stuck.
//
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
  property string mode: "all"
  property int total: 0

  readonly property int showDelay: 90

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  // Same hairline card frame as Yank and Sesame.
  readonly property var borderSpec: Border.flat(Util.alpha(Color.menu.border, 0.4), 1)
  readonly property bool lightTheme: background.hslLightness > 0.5
  readonly property color keycapFill: lightTheme ? Util.alpha("#ffffff", 0.55) : Util.alpha(foreground, 0.07)
  readonly property color keycapBorder: Util.alpha(foreground, 0.20)
  readonly property color keycapText: Util.alpha(foreground, 0.9)
  readonly property color keycapAccentFill: Util.alpha(selectedText, 0.15)
  readonly property color keycapAccentBorder: Util.alpha(selectedText, 0.45)
  readonly property color hintLabel: Util.alpha(foreground, 0.68)

  readonly property string fontFamily: Style.font.menuFamily
  readonly property int metaFont: Math.max(9, Math.round(Style.font.caption * 0.82))
  readonly property int capHeight: metaFont + Style.space(7)
  readonly property int contentMargin: Style.space(7)
  readonly property int headerHeight: Style.space(34)
  readonly property int footerHeight: Style.space(34)
  readonly property int rowHeight: Style.space(44)
  readonly property int maxRows: 9
  readonly property int cardWidth: Math.min(Style.space(680), panel.width - Style.gapsOut * 2)

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
    root.mode = payload.mode || "all"
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

  component KeyCap: Rectangle {
    id: keyCap
    property string label
    property bool primary: false
    width: keyCapLabel.implicitWidth + Style.space(9)
    height: root.capHeight
    radius: 5
    color: keyCap.primary ? root.keycapAccentFill : root.keycapFill
    border.color: keyCap.primary ? root.keycapAccentBorder : root.keycapBorder
    border.width: 1

    Text {
      id: keyCapLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: keyCap.label
      color: root.keycapText
      font.family: root.fontFamily
      font.pixelSize: root.metaFont
      font.weight: keyCap.primary ? Font.DemiBold : Font.Normal
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
      padding: root.contentMargin

      Column {
        id: column
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: 0

        // ---- header: the filter you are typing, with Alt held ----
        Item {
          width: parent.width
          height: root.headerHeight + Style.space(10)

          Rectangle {
            anchors.left: parent.left
            anchors.right: modeLabel.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            height: root.headerHeight
            radius: Style.space(8)
            color: Util.alpha(root.foreground, 0.05)
            border.width: 1
            border.color: root.filterText.length > 0
                          ? Util.alpha(Color.accent, 0.55)
                          : Util.alpha(root.foreground, 0.10)

            Text {
              id: searchIcon
              anchors.left: parent.left
              anchors.leftMargin: Style.space(11)
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              color: root.filterText.length > 0 ? Color.accent : root.foreground
              opacity: root.filterText.length > 0 ? 1 : 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              anchors.left: searchIcon.right
              anchors.leftMargin: Style.space(9)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.filterText || "Keep Alt held and type to filter"
              color: root.foreground
              opacity: root.filterText.length > 0 ? 1 : 0.38
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              elide: Text.ElideLeft
            }
          }

          Text {
            id: modeLabel
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.mode === "app" && root.windows.length > 0
                  ? root.friendlyAppName(root.windows[0].appClass) + " windows"
                  : "All windows"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- the list ----
        ListView {
          id: list
          width: parent.width
          height: Math.max(1, Math.min(root.windows.length, root.maxRows)) * root.rowHeight
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
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          delegate: Rectangle {
            id: row
            required property int index
            required property var modelData
            readonly property bool selected: index === root.selectedIndex

            width: list.width
            height: root.rowHeight
            radius: Style.space(8)
            color: selected ? root.selectedBackground : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              // Alt+1..9 jumps straight to this row.
              Item {
                Layout.preferredWidth: Style.space(20)
                Layout.preferredHeight: root.capHeight
                KeyCap {
                  anchors.centerIn: parent
                  visible: row.index < 9
                  label: String(row.index + 1)
                  primary: row.selected
                }
              }

              Image {
                Layout.preferredWidth: Style.space(26)
                Layout.preferredHeight: Style.space(26)
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: root.appIcon(row.modelData.appClass)
                asynchronous: true
              }

              Column {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: row.modelData.title || root.friendlyAppName(row.modelData.appClass)
                  color: row.selected ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.friendlyAppName(row.modelData.appClass)
                        + (row.modelData.current ? "  ·  current" : "")
                  color: row.selected ? root.selectedText : root.foreground
                  opacity: 0.55
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont + 1
                }
              }

              // Workspace chip, so a jump across workspaces is expected.
              Rectangle {
                Layout.preferredHeight: root.capHeight + Style.space(2)
                Layout.preferredWidth: Math.max(height, wsLabel.implicitWidth + Style.space(12))
                radius: height / 2
                color: Util.alpha(row.selected ? root.selectedText : root.foreground, 0.08)

                Text {
                  id: wsLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: row.modelData.workspace
                  color: row.selected ? root.selectedText : root.foreground
                  opacity: 0.75
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                }
              }
            }
          }
        }

        // ---- footer: count + key hints ----
        Item {
          width: parent.width
          height: root.footerHeight

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.windows.length === root.total
                  ? root.total + (root.total === 1 ? " window" : " windows")
                  : root.windows.length + " of " + root.total
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: root.metaFont
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(14)

            Repeater {
              model: [
                { keys: "Release Alt", label: "Switch", primary: true },
                { keys: "Alt+1–9", label: "Jump" },
                { keys: "Alt+Del", label: "Close" },
                { keys: "Esc", label: "Cancel" }
              ]

              delegate: Row {
                required property var modelData
                spacing: Style.space(6)
                KeyCap { label: modelData.keys; primary: !!modelData.primary; anchors.verticalCenter: parent.verticalCenter }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.hintLabel
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }
        }
      }
    }
  }
}

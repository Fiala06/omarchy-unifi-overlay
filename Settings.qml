import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Console address, API key, and stream quality.
//
// Summoned by the shell rather than over IPC: the bar widget already owns the
// "unifi-overlay" target, and a target routes to one handler.
//   omarchy-shell shell summon unifi-overlay '{}'
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string hostDraft: ""
  // The stored key never comes back to screen; blank means "keep what's there".
  property string keyDraft: ""

  readonly property string family: Style.font.menuFamily
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: Color.urgent
  readonly property var borderSpec: Border.surfaceSpec(
    "menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  readonly property bool ready: service !== null
  readonly property bool hasKey: ready && service.hasKey

  function open(payloadJson) {
    root.opened = true
    root.resetDrafts()
    if (ready) service.refreshStatus()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide((root.manifest && root.manifest.id) || "unifi-overlay")
    }
  }

  function resetDrafts() {
    // Assigned, not bound: typing into a QQC TextField replaces any binding on
    // `text`, so a declarative one would go stale after the first keystroke and
    // never repopulate on the next open.
    root.hostDraft = ready ? service.host : ""
    root.keyDraft = ""
    hostField.text = root.hostDraft
    keyField.text = ""
  }

  function applyConnection() {
    if (!ready) return
    var host = root.hostDraft.trim()
    if (!host) return
    if (host !== service.host) service.setHost(host)
    if (root.keyDraft.trim().length > 0) {
      // setHost and storeKey both need the host settled first; the service
      // writes config synchronously into its own property, so this is safe.
      service.storeKey(root.keyDraft.trim())
      root.keyDraft = ""
    } else if (host === service.host) {
      service.checkConnection()
    }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "unifi-overlay-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(620), window.width - Style.gapsOut * 2)
      // Fixed, and in raw pixels: the column's implicitHeight is unreliable
      // here (wrapping Text reports its unwrapped height), and Style.space()
      // scales with the font. This fits the whole form; the Flickable still
      // scrolls if a larger font or a short screen needs it to.
      height: Math.min(1080, window.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      // Swallow clicks so they don't reach the dismiss handler behind the card.
      MouseArea { anchors.fill: parent }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        onCloseRequested: root.dismiss()

        Flickable {
          anchors.fill: parent
          contentWidth: width
          contentHeight: body.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          ColumnLayout {
            id: body
            width: parent.width
            spacing: Style.space(14)

            // ------------------------------------------------------- header
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                text: "󰄀"
                color: root.foreground
                font.family: root.family
                font.pixelSize: Style.font.display
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "UniFi Overlay"
                  color: root.foreground
                  font.family: root.family
                  font.pixelSize: Style.font.heading
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.ready && root.service.reachable && root.service.consoleVersion
                    ? "Connected · Protect " + root.service.consoleVersion
                    : "Connect to your UniFi Protect console"
                  color: root.dim
                  font.family: root.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }

              PanelActionButton {
                iconText: "󰅖"
                tooltipText: "Close"
                foreground: root.foreground
                fontFamily: root.family
                onClicked: root.dismiss()
              }
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

            // --------------------------------------------------------- host
            FieldLabel { text: "CONSOLE ADDRESS" }

            TextField {
              id: hostField
              Layout.fillWidth: true
              foreground: root.foreground
              placeholderText: "192.168.1.1"
              onTextChanged: root.hostDraft = text
              onAccepted: root.applyConnection()
            }

            Hint {
              text: "The IP or hostname of the UniFi console running Protect — a UDM, "
                  + "Cloud Key, or UNVR. No https:// and no port."
            }

            // ---------------------------------------------------------- key
            FieldLabel { text: root.hasKey ? "API KEY (STORED)" : "API KEY" }

            TextField {
              id: keyField
              Layout.fillWidth: true
              foreground: root.foreground
              password: true
              placeholderText: root.hasKey ? "Stored — type to replace" : "Paste your API key"
              onTextChanged: root.keyDraft = text
              onAccepted: root.applyConnection()
            }

            Hint {
              text: "Create one in UniFi OS → Settings → Control Plane → Integrations → "
                  + "Create API Key. It is kept in your login keyring, never on disk."
            }

            // ------------------------------------------------------ actions
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Button {
                text: "Save & test"
                iconText: "󰄬"
                foreground: root.foreground
                fontFamily: root.family
                bordered: true
                enabled: root.ready && !root.service.busy && root.hostDraft.trim().length > 0
                onClicked: root.applyConnection()
              }

              Button {
                text: "Refresh cameras"
                iconText: "󰑐"
                foreground: root.foreground
                fontFamily: root.family
                bordered: true
                enabled: root.ready && root.service.configured
                onClicked: root.service.refreshCameras()
              }

              Item { Layout.fillWidth: true }

              Button {
                text: "Remove key"
                iconText: "󰩹"
                foreground: root.urgent
                fontFamily: root.family
                bordered: true
                enabled: root.hasKey && root.ready && !root.service.busy
                onClicked: root.service.clearKey()
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: text.length > 0
              text: {
                if (!root.ready) return "Service unavailable."
                if (root.service.actionStatus) return root.service.actionStatus
                return root.service.errorText
              }
              color: (root.ready && root.service.errorText && !root.service.actionStatus)
                ? root.urgent : root.dim
              font.family: root.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

            // ------------------------------------------------------ quality
            FieldLabel { text: "STREAM QUALITY" }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Repeater {
                model: ["high", "medium", "low"]
                Button {
                  required property var modelData
                  text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                  foreground: root.foreground
                  fontFamily: root.family
                  bordered: true
                  selected: root.ready && root.service.quality === modelData
                  enabled: root.ready && !root.service.busy
                  Layout.fillWidth: true
                  onClicked: root.service.setQuality(modelData)
                }
              }
            }

            Hint {
              text: "Protect publishes a separate RTSPS stream per quality. If the one "
                  + "you pick is switched off, the plugin turns it on for you."
            }

            // --------------------------------------------------- pinned size
            FieldLabel { text: "PINNED SIZE" }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Repeater {
                model: ["small", "medium", "large"]
                Button {
                  required property var modelData
                  text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                  foreground: root.foreground
                  fontFamily: root.family
                  bordered: true
                  selected: root.ready && root.service.pipSize === modelData
                  enabled: root.ready && !root.service.busy
                  Layout.fillWidth: true
                  onClicked: root.service.setSize(modelData)
                }
              }
            }

            Hint {
              text: "The pinned view floats in the upper-right corner, stays above other "
                  + "windows, follows you between workspaces, and never takes focus."
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

            // ------------------------------------------------------- display
            FieldLabel { text: "DISPLAY" }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                text: "Active screen"
                foreground: root.foreground
                fontFamily: root.family
                bordered: true
                selected: root.ready && root.service.monitor === ""
                enabled: root.ready && !root.service.busy
                Layout.fillWidth: true
                onClicked: root.service.setMonitor("")
              }

              Repeater {
                model: root.ready ? root.service.monitors : []
                Button {
                  required property var modelData
                  text: modelData
                  foreground: root.foreground
                  fontFamily: root.family
                  bordered: true
                  selected: root.ready && root.service.monitor === modelData
                  enabled: root.ready && !root.service.busy
                  Layout.fillWidth: true
                  onClicked: root.service.setMonitor(modelData)
                }
              }
            }

            Hint {
              text: "Lock the view to one screen, or let it follow whichever screen you "
                  + "are working on."
            }

            // ------------------------------------------------------ opacity
            FieldLabel {
              text: "OPACITY — " + (root.ready ? Math.round(root.service.opacity * 100) : 100) + "%"
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Repeater {
                model: [100, 90, 80, 70, 60]
                Button {
                  required property var modelData
                  text: modelData + "%"
                  foreground: root.foreground
                  fontFamily: root.family
                  bordered: true
                  selected: root.ready
                    && Math.round(root.service.opacity * 100) === modelData
                  enabled: root.ready && !root.service.busy
                  Layout.fillWidth: true
                  onClicked: root.service.setOpacity(modelData / 100)
                }
              }
            }

            Hint {
              text: "Applies to the live window immediately. Hyprland 0.56 has no "
                  + "click-through rule, so the view still catches clicks — but it never "
                  + "takes keyboard focus."
            }

            // ----------------------------------------------------- auto-hide
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Hide over fullscreen windows"
                  color: root.foreground
                  font.family: root.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Blanks the view while a game or video is fullscreen, without "
                      + "dropping the stream, so it returns instantly."
                  color: root.dim
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              ToggleSwitch {
                checked: root.ready && root.service.autoHideFullscreen
                foreground: root.foreground
                enabled: root.ready && !root.service.busy
                onToggled: root.service.setAutoHide(!root.service.autoHideFullscreen)
              }
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

            // -------------------------------------------------------- alerts
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Doorbell & motion auto-pin"
                  color: root.foreground
                  font.family: root.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.ready && root.service.alertsRunning
                    ? "Listening. Point a Protect alarm at the URL below."
                    : "Pops the camera up on its own when Protect fires an alarm."
                  color: root.dim
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              ToggleSwitch {
                checked: root.ready && root.service.alertsRunning
                foreground: root.foreground
                enabled: root.ready && !root.service.busy && root.service.configured
                onToggled: root.service.toggleAlerts()
              }
            }

            // The webhook URL is the one piece the user must copy into Protect,
            // so it is selectable text rather than a label.
            TextField {
              Layout.fillWidth: true
              visible: root.ready && root.service.alertsRunning
              foreground: root.foreground
              readOnly: true
              text: root.ready ? root.service.webhookUrl : ""
            }

            Hint {
              visible: root.ready && root.service.alertsRunning
              text: "In Protect: Settings → Alarm Manager → Create Alarm. Trigger on "
                  + "Doorbell Ring or Smart Detection, add a Webhook action, and paste "
                  + "that URL with ?camera=<id> on the end to force a specific camera. "
                  + "The view unpins itself after " + (root.ready ? root.service.alertSeconds : 30)
                  + " seconds."
            }

            Item { Layout.fillWidth: true; Layout.preferredHeight: Style.space(4) }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components

  component FieldLabel: Text {
    textFormat: Text.PlainText
    Layout.fillWidth: true
    color: root.foreground
    opacity: 0.6
    font.family: root.family
    font.pixelSize: Style.font.caption
  }

  component Hint: Text {
    textFormat: Text.PlainText
    Layout.fillWidth: true
    color: root.dim
    font.family: root.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon plus the camera picker popup.
//
// Left click toggles the pinned corner view -- the one-click path the whole
// plugin exists for. Right click opens this popup to choose a camera, the wheel
// steps through favourites, and the service owns all of the state.
Panel {
  id: root
  // The host registry keys bar entries by plugin id, so this has to be the
  // namespaced id. The IPC target deliberately stays short: it is what people
  // type in keybinds and scripts, and it is independent of the id.
  moduleName: "io.github.fiala06.unifi-overlay"
  ipcTarget: "unifi-overlay"
  manageIpc: false

  readonly property var svc: bar && bar.shell
    ? bar.shell.serviceFor("io.github.fiala06.unifi-overlay") : null
  readonly property bool ready: svc !== null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var cameras: ready ? svc.cameras : []
  readonly property bool pinned: ready && svc.pipRunning
  readonly property bool configured: ready && svc.configured
  readonly property bool gridMode: ready && svc.mode === "grid"

  // focus sections: "hero" | "cameras" | "setup"
  property string focusSection: "cameras"
  property int cameraIndex: 0
  property bool cursorActive: false
  property real wheelAccumulator: 0

  readonly property int snapshotInterval: Math.max(2, Number(setting("snapshotIntervalSec", 10))) * 1000
  readonly property bool hoverPreview: setting("hoverPreview", false) === true

  readonly property color barIconColor: {
    if (!ready || !configured) return Qt.darker(barForeground, 1.8)
    if (pinned) return bar ? bar.urgent : Color.urgent
    if (!svc.reachable && svc.lastError) return Qt.darker(barForeground, 1.8)
    return barForeground
  }

  readonly property string barTooltip: {
    if (!ready) return "UniFi Overlay"
    if (!configured) return "UniFi Overlay — not connected"
    var name = gridMode ? "Grid" : (svc.activeCameraName || "No camera")
    var verb = pinned ? "pinned" : "click to pin"
    return name + " — " + verb + (svc.alertsRunning ? " · alerts on" : "")
  }

  // ------------------------------------------------------------- behaviour

  function primaryAction() {
    if (!ready) return
    if (!configured) { openSettings(); return }
    if (!gridMode && !svc.activeCameraId) { root.open(); return }
    svc.togglePip()
  }

  function openSettings() {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    // Close first: the overlay takes exclusive keyboard focus.
    root.close()
    // summon() resolves against the plugin id, not the IPC target.
    bar.shell.summon(root.moduleName, JSON.stringify({}))
  }

  function ensureCursor() {
    if (!configured) { focusSection = "setup"; return }
    if (cameras.length === 0) { focusSection = "hero"; cameraIndex = 0; return }
    if (focusSection !== "cameras" && focusSection !== "hero") focusSection = "cameras"
    if (cameraIndex >= cameras.length) cameraIndex = Math.max(0, cameras.length - 1)
    if (cameraIndex < 0) cameraIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0 || focusSection === "setup") return
    if (focusSection === "hero") {
      if (dy > 0 && cameras.length > 0) { focusSection = "cameras"; cameraIndex = 0 }
      return
    }
    if (dy < 0 && cameraIndex === 0) { focusSection = "hero"; return }
    cameraIndex = Math.max(0, Math.min(cameras.length - 1, cameraIndex + dy))
    scrollCursorIntoView()
  }

  function selectedCamera() {
    if (cameras.length === 0) return null
    return cameras[Math.max(0, Math.min(cameraIndex, cameras.length - 1))]
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "setup") { openSettings(); return }
    if (focusSection === "hero") { primaryAction(); return }
    var camera = selectedCamera()
    if (!camera || !ready) return
    // In grid mode a row click edits the grid membership; in single mode it
    // picks the camera. Same gesture, whichever list you are actually editing.
    if (gridMode) svc.toggleGridMember(camera.id)
    else svc.selectCamera(camera.id, camera.name)
  }

  function setCameraCursor(index) {
    cursorActive = true
    focusSection = "cameras"
    cameraIndex = index
  }

  function jumpToCamera(number) {
    if (!ready) return
    var index = number - 1
    if (index < 0 || index >= cameras.length) return
    setCameraCursor(index)
    scrollCursorIntoView()
    var camera = cameras[index]
    if (gridMode) svc.toggleGridMember(camera.id)
    else svc.selectCamera(camera.id, camera.name)
  }

  function scrollCursorIntoView() {
    if (!panelFlick || focusSection !== "cameras") return
    if (cameraIndex < 0 || cameraIndex >= cameraColumn.children.length) return
    var item = cameraColumn.children[cameraIndex]
    if (!item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) {
        panelFlick.contentY = Math.max(0, top - margin)
      } else if (bottom > panelFlick.contentY + panelFlick.height - margin) {
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
      }
    })
  }

  // Held while this popup is on screen, so the service knows to poll quickly.
  // Tracked as a flag rather than a bare increment so the release is exact
  // even if the widget is torn down while open.
  property bool watching: false

  function setWatching(on) {
    if (!ready || watching === on) return
    svc.panelWatchers += on ? 1 : -1
    watching = on
  }

  onOpenedChanged: {
    setWatching(opened)
    if (!opened) return
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    if (ready) {
      svc.refreshStatus()
      if (configured) {
        svc.refreshCameras()
        svc.grabSnapshot(false)
      }
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onDestruction: setWatching(false)

  Connections {
    target: root.svc
    enabled: root.ready
    function onCamerasRefreshed() { root.ensureCursor() }
  }

  // Previews only tick while the popup is on screen; there is no reason to
  // pull stills from the console into a panel nobody is looking at.
  Timer {
    interval: root.snapshotInterval
    running: root.opened && root.configured && root.ready
    repeat: true
    onTriggered: root.svc.grabSnapshot(false)
  }

  // Opt-in hover-to-open, with enough delay that crossing the bar on the way
  // somewhere else doesn't fling the panel open.
  Timer {
    id: hoverOpen
    interval: 600
    repeat: false
    onTriggered: if (root.hoverPreview && button.tooltipHovered && !root.opened) root.open()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function pin(): string { if (root.ready) root.svc.startPip(); return "ok" }
    function unpin(): string { if (root.ready) root.svc.stopPip(); return "ok" }
    function togglePin(): string { if (root.ready) root.svc.togglePip(); return "ok" }
    function view(): string { if (root.ready) root.svc.openWindow(); return "ok" }
    function cycleSize(): string { if (root.ready) root.svc.cycleSize(); return "ok" }
    function next(): string { if (root.ready) root.svc.cycleCamera("next"); return "ok" }
    function prev(): string { if (root.ready) root.svc.cycleCamera("prev"); return "ok" }
    function grid(): string { if (root.ready) root.svc.toggleMode(); return "ok" }
    // Arming the listener without a console configured used to leave an
    // unauthenticated port open on the LAN, so this needs the same guard the
    // settings toggle has.
    function alerts(): string {
      if (!root.ready) return "unavailable"
      if (!root.configured) return "not configured"
      root.svc.toggleAlerts()
      return "ok"
    }
    function refresh(): string { if (root.ready) { root.svc.refreshStatus(); root.svc.refreshCameras() } return "ok" }
    function settings(): void { root.openSettings() }
    function camera(id: string): string {
      if (!root.ready) return "unavailable"
      var match = Model.findCamera(root.svc.cameras, id)
      root.svc.selectCamera(id, match ? match.name : "")
      return "ok"
    }
    function status(): string {
      if (!root.ready) return "unavailable"
      return JSON.stringify({
        configured: root.configured,
        pinned: root.pinned,
        camera: root.svc.activeCameraName,
        size: root.svc.pipSize,
        mode: root.svc.mode,
        alerts: root.svc.alertsRunning
      })
    }
  }

  // ------------------------------------------------------------- bar button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: Model.barGlyph(root.ready ? root.svc.glanceState : ({}))
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }

        // A small dot when the doorbell/motion listener is armed, so "will this
        // pop up on its own?" is answerable without opening anything.
        Rectangle {
          visible: root.ready && root.svc.alertsRunning
          width: Style.space(4); height: width; radius: width / 2
          color: root.urgent
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(1)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggle()
      else if (buttonCode === Qt.MiddleButton) { if (root.ready) root.svc.openWindow() }
      else root.primaryAction()
    }
    // Wheel steps through favourites, falling back to every camera when none
    // are marked. The bridge re-pins if a view is already up.
    onWheelMoved: function(delta) {
      if (!root.ready || !root.configured || root.gridMode) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.svc.cycleCamera(wheel.steps < 0 ? "next" : "prev")
    }
    onTooltipHoveredChanged: {
      if (button.tooltipHovered) {
        if (root.ready && root.configured) root.svc.grabSnapshot(false)
        if (root.hoverPreview) hoverOpen.restart()
      } else {
        hoverOpen.stop()
      }
    }
  }

  // ------------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t || "").toLowerCase()
        if (!root.ready) return
        if (key >= "1" && key <= "9") { root.jumpToCamera(parseInt(key, 10)); return }
        if (key === "p") root.svc.togglePip()
        else if (key === "o") root.svc.openWindow()
        else if (key === "s") root.openSettings()
        else if (key === "r") { root.svc.refreshStatus(); root.svc.refreshCameras(); root.svc.grabSnapshot(false) }
        else if (key === "z") root.svc.cycleSize()
        else if (key === "g") root.svc.toggleMode()
        else if (key === "a") { if (root.configured) root.svc.toggleAlerts() }
        else if (key === "f") {
          var camera = root.selectedCamera()
          if (camera) root.svc.toggleFavorite(camera.id)
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------------ hero
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "hero"
            function focusHero() { root.cursorActive = true; root.focusSection = "hero" }

            PanelHero {
              id: hero
              width: parent.width
              title: root.gridMode ? "Camera grid"
                                   : Model.heroTitle(root.ready ? root.svc.glanceState : ({}))
              meta: Model.heroMeta(root.ready ? root.svc.glanceState : ({}))
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.pinned ? 1.0 : 0.55
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: Model.barGlyph(root.ready ? root.svc.glanceState : ({}))
                  color: root.pinned ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              // The switch is the pin. It mirrors what left-clicking the bar
              // icon does, so the popup teaches the shortcut.
              trailingControl: Component {
                StateSwitch {
                  id: pinSwitch
                  enabled: root.configured && root.ready
                    && (root.gridMode ? root.svc.gridReady : root.svc.activeCameraId !== "")
                  checked: root.pinned
                  busy: root.ready && root.svc.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onColor: root.urgent
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: root.primaryAction()

                  PanelToolTip {
                    visible: pinSwitch.containsMouse
                    text: root.pinned ? "Unpin the corner view" : "Pin to the upper right"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // -------------------------------------------------------- preview
          Rectangle {
            id: preview
            visible: root.configured && root.ready && !root.gridMode
              && root.svc.activeCameraId !== ""
            width: parent.width
            height: Math.round(width * 9 / 16)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            radius: Style.cornerRadius
            clip: true

            Image {
              id: still
              anchors.fill: parent
              // cache:false plus a changing query is what forces a re-read of a
              // path whose bytes changed underneath us.
              cache: false
              asynchronous: true
              fillMode: Image.PreserveAspectCrop
              source: (root.ready && root.svc.snapshotStamp > 0)
                ? "file://" + root.svc.snapshotPath + "?" + root.svc.snapshotStamp
                : ""
            }

            Text {
              anchors.centerIn: parent
              visible: still.status !== Image.Ready
              textFormat: Text.PlainText
              text: root.ready && root.svc.snapshotBusy ? "Loading preview…" : "No preview yet"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // A live badge while the corner view is up, so the popup and the
            // pinned window never disagree about what is on screen.
            Rectangle {
              visible: root.pinned
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(6)
              radius: Style.cornerRadius
              color: Qt.rgba(0, 0, 0, 0.55)
              implicitWidth: liveLabel.implicitWidth + Style.space(12)
              implicitHeight: liveLabel.implicitHeight + Style.space(6)
              Text {
                id: liveLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "● PINNED"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.ready) root.svc.openWindow()
            }
          }

          // Grid mode has no single still to show, so summarise the line-up.
          Text {
            visible: root.configured && root.gridMode
            width: parent.width
            textFormat: Text.PlainText
            text: root.ready && root.svc.gridCameras.length > 0
              ? "Grid: " + Model.gridNames(root.cameras, root.svc.gridCameras)
              : "Pick up to four cameras below for the grid."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // --------------------------------------------------------- status
          Text {
            textFormat: Text.PlainText
            visible: text.length > 0
            width: parent.width
            text: {
              if (!root.ready) return "Service unavailable."
              if (root.svc.actionStatus) return root.svc.actionStatus
              return root.svc.errorText
            }
            color: (root.ready && root.svc.errorText && !root.svc.actionStatus) ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------------------------------------------------------- setup
          CursorSurface {
            id: setupRow
            visible: root.ready && !root.configured
            width: parent.width
            hasCursor: root.cursorActive && root.focusSection === "setup"
            foreground: root.foreground
            implicitHeight: setupContent.implicitHeight + Style.spacing.rowPaddingX

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: { root.cursorActive = true; root.focusSection = "setup" }
              onClicked: root.openSettings()
            }

            ColumnLayout {
              id: setupContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Connect to UniFi Protect"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Add your console address and API key"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          // --------------------------------------------------------- actions
          RowLayout {
            visible: root.configured
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: root.pinned ? "Unpin" : "Pin"
              iconText: root.pinned ? "󰤰" : "󰤱"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: root.ready
                && (root.gridMode ? root.svc.gridReady : root.svc.activeCameraId !== "")
              Layout.fillWidth: true
              onClicked: root.primaryAction()
            }

            PanelActionButton {
              iconText: root.gridMode ? "󰕰" : "󰞮"
              tooltipText: root.gridMode ? "Grid mode — switch to one camera"
                                         : "Single camera — switch to grid"
              foreground: root.gridMode ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.ready) root.svc.toggleMode()
            }

            PanelActionButton {
              iconText: "󰐊"
              tooltipText: "Open a full window"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: root.ready && root.svc.activeCameraId !== ""
              onClicked: if (root.ready) root.svc.openWindow()
            }

            PanelActionButton {
              iconText: Model.sizeLabel(root.ready ? root.svc.pipSize : "medium")
              tooltipText: "Cycle pinned size"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.ready) root.svc.cycleSize()
            }

            PanelActionButton {
              iconText: "󰂚"
              tooltipText: root.ready && root.svc.alertsRunning
                ? "Doorbell alerts on — click to disable"
                : "Doorbell alerts off — click to enable"
              foreground: root.ready && root.svc.alertsRunning ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: root.configured
              onClicked: if (root.ready && root.configured) root.svc.toggleAlerts()
            }

            PanelActionButton {
              iconText: "󰒓"
              tooltipText: "Settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openSettings()
            }
          }

          PanelSeparator {
            visible: root.configured
            foreground: root.foreground
          }

          // --------------------------------------------------------- cameras
          Column {
            visible: root.configured
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: root.gridMode ? "GRID CAMERAS — PICK UP TO FOUR" : "CAMERAS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: root.cameras.length === 0
              width: parent.width
              text: root.ready && root.svc.loadingCameras ? "Loading…" : "No cameras found."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: cameraColumn
              visible: root.cameras.length > 0
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.cameras
                CameraRow {
                  required property var modelData
                  required property int index
                  width: cameraColumn.width
                  camera: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components

  component CameraRow: CursorSurface {
    id: cameraRow
    property var camera: null
    property int rowIndex: 0
    readonly property bool isActive: camera && root.ready && !root.gridMode
      && camera.id === root.svc.activeCameraId
    readonly property bool inGrid: camera && root.ready
      && root.svc.gridCameras.indexOf(camera.id) !== -1
    readonly property bool isFavorite: camera && root.ready
      && root.svc.favorites.indexOf(camera.id) !== -1

    hasCursor: root.cursorActive && root.focusSection === "cameras" && root.cameraIndex === rowIndex
    current: root.gridMode ? inGrid : isActive
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCameraCursor(cameraRow.rowIndex)
      onClicked: if (root.ready && cameraRow.camera) {
        if (root.gridMode) root.svc.toggleGridMember(cameraRow.camera.id)
        else root.svc.selectCamera(cameraRow.camera.id, cameraRow.camera.name)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      // The first nine rows advertise their number-key shortcut; past that the
      // state dot is all there is room for.
      Text {
        textFormat: Text.PlainText
        text: cameraRow.rowIndex < 9 ? String(cameraRow.rowIndex + 1)
                                     : Model.stateDot(cameraRow.camera)
        color: cameraRow.camera && cameraRow.camera.connected ? root.dim
                                                              : Qt.darker(root.dim, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(10)
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        textFormat: Text.PlainText
        text: Model.stateDot(cameraRow.camera)
        visible: cameraRow.rowIndex < 9
        color: cameraRow.camera && cameraRow.camera.connected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: cameraRow.camera ? cameraRow.camera.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.cameraMeta(cameraRow.camera)
            + (cameraRow.inGrid ? " · in grid" : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Favourites are the wheel's cycle list, so marking one from here is the
      // fastest way to build the set you actually flip between.
      PanelActionButton {
        iconText: cameraRow.isFavorite ? "★" : "☆"
        tooltipText: cameraRow.isFavorite ? "Remove from wheel cycle"
                                          : "Add to wheel cycle"
        foreground: cameraRow.isFavorite ? root.urgent : root.dim
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: if (root.ready && cameraRow.camera) root.svc.toggleFavorite(cameraRow.camera.id)
      }

      PanelActionButton {
        visible: cameraRow.isActive
        iconText: root.pinned ? "󰤰" : "󰤱"
        tooltipText: root.pinned ? "Unpin" : "Pin to corner"
        foreground: root.pinned ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.primaryAction()
      }
    }
  }
}

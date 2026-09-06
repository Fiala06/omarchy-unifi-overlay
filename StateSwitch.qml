import QtQuick
import qs.Commons

// A toggle that goes green when it is on.
//
// The kit's ToggleSwitch resolves its "on" colour through Style's `selected`
// state token, and themes routinely pin that to a hex (this one uses
// "#ddf7ff"), so the colour cannot be overridden per instance. For a control
// whose whole job is to answer "is the camera on screen right now?", a pale
// knob that barely differs from the off state is the wrong trade.
//
// Geometry is copied from Style so this still sits correctly beside the kit's
// own controls; only the colour behaviour differs.
Item {
  id: root

  property bool checked: false
  property bool busy: false
  property bool interactive: true
  property bool hasCursor: false
  property color foreground: Color.foreground
  // The colour used when on. Defaults to the bar's active colour so a toggle
  // agrees with the bar icon that reflects the same state.
  property color onColor: Color.bar.active

  signal toggled()
  signal hovered(bool isHovered)

  readonly property alias containsMouse: mouse.containsMouse
  readonly property bool hot: hasCursor || mouse.containsMouse

  readonly property int trackHeight: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
  readonly property int trackWidth: Math.round(trackHeight * 1.9)
  readonly property int knobSize: Math.max(6, Math.round(trackHeight * 0.72))
  readonly property int knobInset: Math.max(1, Math.round((trackHeight - knobSize) / 2))
  readonly property bool rounded: Style.cornerRadius > 0

  implicitWidth: trackWidth
  implicitHeight: trackHeight

  Rectangle {
    id: track
    anchors.centerIn: parent
    width: root.trackWidth
    height: root.trackHeight
    radius: root.rounded ? height / 2 : 0
    color: root.checked
      ? Qt.rgba(root.onColor.r, root.onColor.g, root.onColor.b, root.hot ? 0.34 : 0.24)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, root.hot ? 0.10 : 0.05)
    border.width: root.checked ? 0 : 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                          root.hot ? 0.30 : 0.40)

    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      width: root.knobSize
      height: root.knobSize
      radius: root.rounded ? height / 2 : 0
      x: root.checked ? track.width - width - root.knobInset : root.knobInset
      anchors.verticalCenter: parent.verticalCenter
      color: root.checked ? root.onColor : Qt.darker(root.foreground, 1.25)
      opacity: root.busy ? 0.55 : 1.0

      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 120 } }
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    anchors.margins: -Style.space(6)
    hoverEnabled: true
    enabled: root.interactive
    cursorShape: Qt.PointingHandCursor
    onEntered: root.hovered(true)
    onExited: root.hovered(false)
    onClicked: root.toggled()
  }
}

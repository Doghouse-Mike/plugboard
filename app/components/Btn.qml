import QtQuick
import ".."

// Omarchy-style control: faint fill, hairline border, fg-alpha hover.
Rectangle {
  id: b
  property string text: ""
  property string icon: ""
  property bool active: false
  property bool quiet: false
  property color textColor: active ? Theme.accent : Theme.fg
  property string tip: ""
  signal clicked()
  implicitHeight: Theme.px(26)
  implicitWidth: row.implicitWidth + Theme.px(16)
  color: ma.pressed ? Theme.selectedFill : active ? Theme.selectedFill : ma.containsMouse ? Theme.hoverFill : quiet ? "transparent" : Theme.normalFill
  border.width: quiet ? 0 : 1
  border.color: active ? Theme.accent : Theme.a(Theme.fg, 0.18)
  Row {
    id: row
    anchors.centerIn: parent
    spacing: Theme.px(6)
    Txt { visible: b.icon !== ""; text: b.icon; color: b.textColor; font.pixelSize: Theme.fsLarge }
    Txt { visible: b.text !== ""; text: b.text; color: b.textColor }
  }
  MouseArea {
    id: ma
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: b.clicked()
  }
  Tip { text: b.tip; show: ma.containsMouse && b.tip !== "" }
}

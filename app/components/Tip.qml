import QtQuick
import ".."

Rectangle {
  property string text: ""
  property bool show: false
  visible: show && opacity > 0
  opacity: show ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 120 } }
  z: 1000
  anchors.top: parent.bottom
  anchors.topMargin: 4
  anchors.horizontalCenter: parent.horizontalCenter
  width: t.implicitWidth + 12
  height: t.implicitHeight + 6
  color: Theme.bg
  border.color: Theme.border
  Txt { id: t; anchors.centerIn: parent; text: parent.text; font.pixelSize: Theme.fsSmall }
}

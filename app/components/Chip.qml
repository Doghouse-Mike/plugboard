import QtQuick
import ".."

Rectangle {
  property string text: ""
  property color tone: Theme.muted
  implicitWidth: t.implicitWidth + Theme.px(10)
  implicitHeight: t.implicitHeight + Theme.px(4)
  color: Theme.a(tone, 0.14)
  border.width: 1
  border.color: Theme.a(tone, 0.35)
  Txt { id: t; anchors.centerIn: parent; text: parent.text; font.pixelSize: Theme.fsSmall; color: Theme.a(Theme.fg, 0.85) }
}

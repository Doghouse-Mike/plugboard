import QtQuick
import ".."

// Every label in the app comes through here, and most show text from the
// vault, which may be shared or synced. Plain text, so a note titled
// <img src="http://..."> is shown as written instead of fetched.
Text {
  textFormat: Text.PlainText
  color: Theme.fg
  font.family: Theme.font
  font.pixelSize: Theme.fs
  elide: Text.ElideRight
  verticalAlignment: Text.AlignVCenter
}

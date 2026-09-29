import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Optional bar button: opens the same app window as the launcher entry.
BarWidget {
  id: root
  moduleName: "sumiran.theme-gallery"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    fontFamily: "JetBrainsMono Nerd Font"
    tooltipText: "Themes Gallery — browse & apply variants"
    horizontalMargin: 8.5
    onPressed: function(code) {
      if (code === Qt.LeftButton) {
        if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function")
          root.bar.shell.toggle(root.moduleName, "{}")
      } else if (code === Qt.RightButton) {
        if (root.bar && root.bar.run) root.bar.run("aether")
        else Quickshell.execDetached(["aether"])
      }
    }
  }
}

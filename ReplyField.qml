import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

TextArea {
  id: root
  readonly property var themeFont: Style.font
  readonly property var themeSpacing: Style.spacing

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property real horizontalPadding: themeSpacing.controlPaddingX
  property real verticalPadding: themeSpacing.inputPaddingY

  readonly property bool _focused: activeFocus
  readonly property bool _hot: hovered
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

    wrapMode: TextEdit.Wrap
    selectByMouse: true
  font.family: themeFont.family
  font.pixelSize: themeFont.body
  color: foreground
  selectionColor: selectionTint
  selectedTextColor: foreground
  placeholderTextColor: Qt.darker(foreground, 1.6)
  leftPadding: horizontalPadding + Border.left(_borderSpec)
  rightPadding: horizontalPadding + Border.right(_borderSpec)
  topPadding: verticalPadding + Border.top(_borderSpec)
  bottomPadding: verticalPadding + Border.bottom(_borderSpec)

  background: BorderSurface {
    color: Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }
}

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

BorderSurface {
  id: root

  property var message: ({})
  property bool selected: false
  property bool unread: false
  property color unreadColor: Color.urgent
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property string timeLabel: ""
  property bool pointerHovered: hoverHandler.hovered

  signal activated()
  signal linkActivated(string url)

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string kind: String(root.message.kind || "customer").toLowerCase()
  readonly property bool note: kind === "note"
  readonly property bool teammate: kind === "teammate"
  readonly property bool bot: kind === "bot"
  property string badge: note ? "NOTE" : ""

  function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }

  implicitHeight: inner.implicitHeight + Style.space(16)
  color: selected || pointerHovered ? Style.hoverFillFor(foreground, accent)
    : note ? alpha(foreground, 0.04)
    : teammate ? alpha(accent, 0.10)
    : "transparent"
  borderSpec: selected
    ? Border.controlSpec("normal", foreground, accent)
    : Border.flat(alpha(note ? foreground : (teammate ? accent : foreground), note || teammate ? 0.22 : 0.13), 1)
  radius: Style.cornerRadius

  Rectangle {
    objectName: "unreadDot"
    visible: root.unread
    x: Style.space(3)
    y: Style.space(3)
    width: Style.space(7)
    height: width
    radius: width / 2
    color: root.unreadColor
    z: 1
  }

  HoverHandler {
    id: hoverHandler
  }

  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: root.activated()
  }

  ColumnLayout {
    id: inner
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(10)
    anchors.topMargin: Style.space(8)
    spacing: Style.space(4)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
          Layout.fillWidth: true
          text: String(root.message.from || (root.note ? "Note" : root.bot ? "Bot" : "Customer"))
          color: root.teammate ? root.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.italic: root.note
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: {
            var email = String(root.message.email || "").trim()
            var from = String(root.message.from || "").trim()
            return email !== "" && email.toLowerCase() !== from.toLowerCase()
          }
          text: String(root.message.email || "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAnywhere
        }
      }

      Text {
        visible: root.badge !== ""
        Layout.alignment: Qt.AlignTop
        text: root.badge
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        visible: root.timeLabel !== ""
        Layout.alignment: Qt.AlignTop
        text: root.timeLabel
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0
      visible: paragraphRepeater.count > 0

      Repeater {
        id: paragraphRepeater
        model: Model.messageParagraphs(root.message.body)

        Text {
          required property var modelData
          required property int index
          Layout.fillWidth: true
          topPadding: index > 0 ? Style.space(12) : 0
          text: String(modelData || "")
          color: root.note || root.bot ? root.dim : root.foreground
          linkColor: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: root.note
          wrapMode: Text.WordWrap
          textFormat: Text.StyledText
          onLinkActivated: function(link) { root.linkActivated(link) }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
          }
        }
      }
    }
  }
}

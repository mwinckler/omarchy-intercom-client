import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

BorderSurface {
  id: root
  readonly property var themeFont: Style.font

  property var conversation: ({})
  property bool selected: false
  property bool unread: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: root.themeFont.family
  property string waitingLabel: ""
  property string updatedLabel: ""
  property bool hasDraft: false
  property bool hasScheduled: false
  property bool pointerHovered: hoverHandler.hovered

  signal activated()

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property bool waiting: waitingLabel !== ""
  readonly property string metaLabel: waiting ? waitingLabel : updatedLabel

  function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }

  implicitHeight: inner.implicitHeight + Style.space(16)
  color: selected || pointerHovered ? Style.hoverFillFor(foreground, accent) : "transparent"
  borderSpec: selected
    ? Border.controlSpec("normal", foreground, accent)
    : Border.flat(alpha(foreground, 0.13), 1)
  radius: Style.cornerRadius

  Rectangle {
    visible: root.unread
    x: Style.space(3)
    y: Style.space(3)
    width: Style.space(7)
    height: width
    radius: width / 2
    color: root.urgent
    z: 1
  }

  HoverHandler {
    id: hoverHandler
  }

  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: root.activated()
  }

  RowLayout {
    id: inner
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(10)
    anchors.topMargin: Style.space(8)
    spacing: Style.space(10)

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignTop
      spacing: Style.space(2)

      Text {
        Layout.fillWidth: true
        text: String(root.conversation.title || "Conversation")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.themeFont.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        visible: String(root.conversation.from || "") !== ""
        text: String(root.conversation.from || "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.themeFont.caption
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Text {
        Layout.fillWidth: true
        visible: {
          var email = String(root.conversation.email || "").trim()
          var from = String(root.conversation.from || "").trim()
          return email !== "" && email.toLowerCase() !== from.toLowerCase()
        }
        text: String(root.conversation.email || "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.themeFont.caption
        wrapMode: Text.WrapAnywhere
      }

      Text {
        Layout.fillWidth: true
        visible: String(root.conversation.snippet || "") !== ""
        text: String(root.conversation.snippet || "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.themeFont.bodySmall
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
    }

    ColumnLayout {
      visible: root.metaLabel !== "" || root.hasDraft || root.hasScheduled
      Layout.alignment: Qt.AlignTop
      Layout.topMargin: Style.space(2)
      spacing: Style.space(4)

      BorderSurface {
        visible: root.metaLabel !== ""
        implicitWidth: waitText.implicitWidth + Style.space(12)
        implicitHeight: waitText.implicitHeight + Style.space(6)
        color: root.alpha(root.waiting ? root.urgent : root.foreground, root.waiting ? 0.10 : 0.06)
        borderSpec: Border.flat(root.alpha(root.waiting ? root.urgent : root.foreground, root.waiting ? 0.35 : 0.18), 1)
        radius: Style.cornerRadius

        Text {
          id: waitText
          anchors.centerIn: parent
          text: root.metaLabel
          color: root.waiting ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: root.themeFont.caption
          font.bold: root.waiting
        }
      }

      BorderSurface {
        visible: root.hasDraft
        implicitWidth: draftText.implicitWidth + Style.space(12)
        implicitHeight: draftText.implicitHeight + Style.space(6)
        color: root.alpha(root.accent, 0.10)
        borderSpec: Border.flat(root.alpha(root.accent, 0.35), 1)
        radius: Style.cornerRadius

        Text {
          id: draftText
          anchors.centerIn: parent
          text: "DRAFT"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.themeFont.caption
          font.bold: true
        }
      }

      BorderSurface {
        visible: root.hasScheduled
        implicitWidth: laterText.implicitWidth + Style.space(12)
        implicitHeight: laterText.implicitHeight + Style.space(6)
        color: root.alpha(root.accent, 0.10)
        borderSpec: Border.flat(root.alpha(root.accent, 0.35), 1)
        radius: Style.cornerRadius

        Text {
          id: laterText
          anchors.centerIn: parent
          text: "LATER"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.themeFont.caption
          font.bold: true
        }
      }
    }
  }
}

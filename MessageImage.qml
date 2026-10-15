pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

ColumnLayout {
  id: root
  readonly property var themeFont: Style.font

  property var image: ({})
  property bool imagesEnabled: false
  property Flickable viewport: null
  property Item messageRow: null
  property real messageTop: 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: root.themeFont.family
  property bool consent: false
  property bool requested: false
  readonly property string url: Model.safeImageUrl(image.url)
  readonly property string label: String(image.name || image.alt || "Image")
  readonly property int imageStatus: preview.status
  readonly property bool automatic: Model.autoLoadImage(image)
  readonly property bool nearViewport: {
    if (!viewport || !messageRow) return true
    var top = messageTop + root.mapToItem(messageRow, 0, 0).y
    var scroll = Math.min(viewport.contentY, Math.max(0, viewport.contentHeight - viewport.height))
    return top + root.height >= scroll - viewport.height / 2
      && top <= scroll + viewport.height * 1.5
  }
  readonly property bool shouldLoad: imagesEnabled && nearViewport && url !== "" && (automatic || consent)
  readonly property real previewHeight: {
    var w = Number(image.width || 0)
    var h = Number(image.height || 0)
    return w > 0 && h > 0
      ? Math.max(Style.space(32), Math.min(Style.space(280), h * Math.min(1, root.width / w)))
      : Style.space(180)
  }

  signal linkActivated(string url)

  function load() { consent = true }
  function queueLoad() {
    if (shouldLoad && !requested) loadTimer.restart()
    else loadTimer.stop()
  }
  onShouldLoadChanged: queueLoad()
  onUrlChanged: { requested = false; consent = false; queueLoad() }
  Component.onCompleted: queueLoad()

  // Positioners initially create every row at y=0. Wait for layout before
  // latching requests, otherwise a long thread would eagerly fetch every image.
  Timer {
    id: loadTimer
    interval: 50
    onTriggered: { if (root.shouldLoad) root.requested = true }
  }

  spacing: Style.space(4)

  Rectangle {
    Layout.fillWidth: true
    implicitHeight: root.previewHeight
    radius: Style.cornerRadius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)

    Image {
      id: preview
      objectName: "messageImagePreview"
      anchors.fill: parent
      source: root.imagesEnabled && root.requested && root.nearViewport ? root.url : ""
      asynchronous: true
      autoTransform: true
      fillMode: Image.PreserveAspectFit
      sourceSize: Qt.size(1024, 1024)
    }

    Text {
      anchors.centerIn: parent
      width: Math.max(0, parent.width - Style.space(16))
      visible: preview.status !== Image.Ready
      text: preview.status === Image.Error ? "Image unavailable · refresh the conversation or open original"
        : preview.status === Image.Loading ? "Loading image…"
        : !root.automatic && !root.consent ? "External image · click to load"
        : "Image preview"
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.themeFont.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (!root.requested) root.load()
        else root.linkActivated(Model.safeImageUrl(root.image.linkUrl) || root.url)
      }
    }
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(8)
    Text {
      Layout.fillWidth: true
      text: root.label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.themeFont.caption
      elide: Text.ElideRight
    }
    Button {
      text: "Open original"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: root.themeFont.caption
      onClicked: root.linkActivated(root.url)
    }
  }
}

import QtQuick
import qs.Commons

Item {
  id: root

  property bool active: false
  property color accent: Color.accent

  height: 2
  clip: true
  visible: opacity > 0.01
  opacity: active ? 1 : 0

  Behavior on opacity {
    NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
  }

  Rectangle {
    id: pulse
    property real progress: 0
    width: Math.max(Style.space(48), root.width * 0.28)
    height: parent.height
    x: -width + progress * (root.width + width)
    visible: root.width > 0
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 0.55; color: root.accent }
      GradientStop { position: 1.0; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) }
    }
  }

  SequentialAnimation {
    running: root.active && root.width > 0
    loops: Animation.Infinite
    NumberAnimation {
      target: pulse
      property: "progress"
      from: 0
      to: 1
      duration: 900
      easing.type: Easing.InOutCubic
    }
    PauseAnimation { duration: 240 }
  }
}

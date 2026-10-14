pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

FocusScope {
  id: root
  readonly property var themeFont: Style.font
  readonly property var popupColors: Color.popups

  property bool open: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: root.themeFont.family
  property bool monthFirst: false
  property int weekStart: 1

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property var parsed: {
    // These reads make QML track the inputs used inside currentParse().
    var _text = root.scheduleText
    var _picker = root.usePicker
    var _year = root.selectedYear
    var _month = root.selectedMonth
    var _day = root.selectedDay
    var _hour = root.hour
    var _minute = root.minute
    var _monthFirst = root.monthFirst
    return root.currentParse()
  }
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthCells(viewYear, viewMonth, weekStart)

  property bool usePicker: false
  property bool confirming: false
  property string scheduleText: ""
  property string errorText: ""
  property double pendingAt: 0
  property string pendingLabel: ""
  property int viewYear: 1970
  property int viewMonth: 0
  property int selectedYear: 1970
  property int selectedMonth: 0
  property int selectedDay: 1
  property int hour: 9
  property int minute: 0

  signal cancelled()
  signal scheduled(double sendAt)

  function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }

  function currentParse() {
    if (root.usePicker) {
      return Model.parsePickerDate(
        root.selectedYear, root.selectedMonth, root.selectedDay,
        root.hour, root.minute, Date.now())
    }
    return Model.parseScheduleText(root.scheduleText, Date.now(), { monthFirst: root.monthFirst })
  }

  function resetToDefault() {
    var now = new Date()
    var tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 9, 0, 0, 0)
    root.usePicker = false
    root.confirming = false
    root.scheduleText = ""
    root.errorText = ""
    root.pendingAt = 0
    root.pendingLabel = ""
    root.applyDate(tomorrow)
    if (hourField) hourField.text = Model.pad2(root.hour)
    if (minuteField) minuteField.text = Model.pad2(root.minute)
    if (scheduleField) scheduleField.text = ""
  }

  function applyDate(date) {
    var when = date instanceof Date ? date : new Date()
    root.viewYear = when.getFullYear()
    root.viewMonth = when.getMonth()
    root.selectedYear = when.getFullYear()
    root.selectedMonth = when.getMonth()
    root.selectedDay = when.getDate()
    root.hour = when.getHours()
    root.minute = when.getMinutes()
  }

  function show() {
    root.resetToDefault()
    root.open = true
    Qt.callLater(function() {
      if (root.open) root.focusDefault()
    })
  }

  function hide() {
    root.open = false
    root.confirming = false
    root.errorText = ""
  }

  function requestCancel() {
    if (root.confirming) {
      root.confirming = false
      root.errorText = ""
      Qt.callLater(function() {
        if (root.open && !root.confirming) root.focusDefault()
      })
      return
    }
    root.hide()
    root.cancelled()
  }

  function commitParse() {
    if (root.usePicker) {
      root.applyHourText(hourField ? hourField.text : root.hour)
      root.applyMinuteText(minuteField ? minuteField.text : root.minute)
      if (hourField) hourField.text = Model.pad2(root.hour)
      if (minuteField) minuteField.text = Model.pad2(root.minute)
    }
    var row = root.currentParse()
    if (!row || !row.ok) {
      root.errorText = (row && row.error) ? row.error : "Could not understand that date."
      return
    }
    root.pendingAt = row.at
    root.pendingLabel = row.label !== "" ? row.label : Model.formatScheduleTime(row.at)
    root.errorText = ""
    root.confirming = true
    Qt.callLater(function() {
      if (root.open && root.confirming) root.focusDefault()
    })
  }

  function tabTargets() {
    var items = []
    function add(item) {
      if (!item || !item.visible || item.enabled === false) return
      items.push(item)
    }
    if (root.confirming) {
      add(cancelButton)
      add(sendLaterButton)
      return items
    }
    add(typeTimeButton)
    add(pickDateButton)
    if (root.usePicker) {
      add(prevMonth)
      add(nextMonth)
      add(calendarGrid)
      add(hourField)
      add(minuteField)
    } else {
      add(scheduleField)
    }
    add(cancelButton)
    add(sendLaterButton)
    return items
  }

  function focusTab(direction) {
    var items = root.tabTargets()
    if (items.length === 0) return
    var current = -1
    for (var i = 0; i < items.length; i++) {
      if (items[i].activeFocus) {
        current = i
        break
      }
    }
    var step = direction < 0 ? -1 : 1
    var next = current < 0
      ? (step > 0 ? 0 : items.length - 1)
      : (current + step + items.length) % items.length
    items[next].forceActiveFocus()
  }

  function focusDefault() {
    if (!root.open) return
    if (root.confirming) {
      if (sendLaterButton) sendLaterButton.forceActiveFocus()
      return
    }
    if (root.usePicker) {
      if (calendarGrid) calendarGrid.forceActiveFocus()
      else if (hourField) hourField.forceActiveFocus()
      return
    }
    if (scheduleField) scheduleField.forceActiveFocus()
  }

  function controlHasFocus(item) {
    if (!item || !item.visible) return false
    if (item.activeFocus) return true
    if (item.contentItem && item.contentItem.activeFocus) return true
    return false
  }

  function handleDialogKey(event) {
    if (!event || !root.open) return false
    if (event.key === Qt.Key_Escape) {
      root.requestCancel()
      return true
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      var dir = ((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab) ? -1 : 1
      root.focusTab(dir)
      return true
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.confirming) {
        root.confirmPending()
        return true
      }
      if (root.controlHasFocus(cancelButton)) {
        root.requestCancel()
        return true
      }
      if (root.controlHasFocus(typeTimeButton)) {
        if (root.usePicker) root.togglePicker()
        return true
      }
      if (root.controlHasFocus(pickDateButton)) {
        if (!root.usePicker) root.togglePicker()
        return true
      }
      if (root.controlHasFocus(prevMonth)) {
        root.moveMonth(-1)
        return true
      }
      if (root.controlHasFocus(nextMonth)) {
        root.moveMonth(1)
        return true
      }
      if (root.controlHasFocus(hourField)) {
        if (minuteField) minuteField.forceActiveFocus()
        return true
      }
      root.commitParse()
      return true
    }
    return false
  }

  function moveSelectedDay(deltaDays) {
    var next = new Date(root.selectedYear, root.selectedMonth, root.selectedDay + deltaDays)
    root.selectedYear = next.getFullYear()
    root.selectedMonth = next.getMonth()
    root.selectedDay = next.getDate()
    root.viewYear = next.getFullYear()
    root.viewMonth = next.getMonth()
  }

  function confirmPending() {
    if (!root.confirming || root.pendingAt <= Date.now()) {
      root.confirming = false
      root.errorText = "Choose a time in the future."
      return
    }
    var at = root.pendingAt
    root.hide()
    root.scheduled(at)
  }

  function togglePicker() {
    if (root.confirming) return
    if (!root.usePicker) {
      var row = Model.parseScheduleText(root.scheduleText, Date.now(), { monthFirst: root.monthFirst })
      if (row && row.ok) root.applyDate(new Date(row.at))
      if (hourField) hourField.text = Model.pad2(root.hour)
      if (minuteField) minuteField.text = Model.pad2(root.minute)
      root.usePicker = true
      Qt.callLater(function() {
        if (root.open) root.focusDefault()
      })
      return
    }
    root.scheduleText = root.selectedYear
      + "-" + Model.pad2(root.selectedMonth + 1)
      + "-" + Model.pad2(root.selectedDay)
      + " " + Model.pad2(root.hour)
      + ":" + Model.pad2(root.minute)
    if (scheduleField) scheduleField.text = root.scheduleText
    root.usePicker = false
    Qt.callLater(function() {
      if (root.open) root.focusDefault()
    })
  }

  function selectDay(cell) {
    if (!cell || !cell.inMonth) return
    root.selectedYear = cell.year
    root.selectedMonth = cell.month
    root.selectedDay = cell.day
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(root.viewYear, root.viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
  }

  function applyHourText(value) {
    var parsed = parseInt(String(value || ""), 10)
    if (!isFinite(parsed)) return
    root.hour = Math.max(0, Math.min(23, parsed))
  }

  function applyMinuteText(value) {
    var parsed = parseInt(String(value || ""), 10)
    if (!isFinite(parsed)) return
    root.minute = Math.max(0, Math.min(59, parsed))
  }

  function weekdayLabel(weekday) {
    return String(Qt.locale().dayName(weekday, Locale.ShortFormat)).replace(/\.$/, "").toUpperCase()
  }

  visible: open
  focus: open
  anchors.fill: parent
  z: 40

  Keys.enabled: root.open
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.45)

    MouseArea {
      anchors.fill: parent
      onClicked: root.requestCancel()
    }
  }

  BorderSurface {
    id: card
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(24), Style.space(380))
    implicitHeight: inner.implicitHeight + Style.space(24)
    color: root.popupColors.background
    borderSpec: Border.controlSpec("focus", root.foreground, root.accent)
    radius: Style.cornerRadius
    padding: Style.space(12)

    MouseArea {
      anchors.fill: parent
      onClicked: {}
    }

    Column {
      id: inner
      width: parent.width - Style.space(24)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(12)
      spacing: Style.space(10)

      Text {
        width: parent.width
        text: root.confirming ? "Send later?" : "Send later"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.themeFont.body
        font.bold: true
      }

      Text {
        width: parent.width
        visible: root.confirming
        text: "Schedule this reply for " + root.pendingLabel + "?"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.themeFont.bodySmall
        wrapMode: Text.WordWrap
      }

      Column {
        width: parent.width
        visible: !root.confirming
        spacing: Style.space(8)

        Row {
          spacing: Style.space(6)

          Button {
            id: typeTimeButton
            text: "Type a time"
            bordered: true
            selected: !root.usePicker
            focusable: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: root.themeFont.caption
            Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
            onClicked: { if (root.usePicker) root.togglePicker() }
          }

          Button {
            id: pickDateButton
            text: "Pick a date"
            bordered: true
            selected: root.usePicker
            focusable: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: root.themeFont.caption
            Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
            onClicked: { if (!root.usePicker) root.togglePicker() }
          }
        }

        TextField {
          id: scheduleField
          width: parent.width
          visible: !root.usePicker
          placeholderText: "tomorrow at 8, Monday, 22:10…"
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          onTextChanged: {
            root.scheduleText = text
            root.errorText = ""
          }
          onAccepted: root.commitParse()
          Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
        }

        Column {
          width: parent.width
          visible: root.usePicker
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              id: prevMonth
              text: "‹"
              bordered: true
              focusable: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
              onClicked: root.moveMonth(-1)
            }

            Text {
              width: Math.max(0, parent.width - prevMonth.implicitWidth - nextMonth.implicitWidth - parent.spacing * 2)
              height: Math.max(implicitHeight, Style.space(28))
              text: Qt.locale().monthName(root.viewMonth, Locale.LongFormat) + " " + root.viewYear
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.themeFont.bodySmall
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }

            Button {
              id: nextMonth
              text: "›"
              bordered: true
              focusable: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
              onClicked: root.moveMonth(1)
            }
          }

          Row {
            width: parent.width
            spacing: 0

            Repeater {
              model: root.weekdays

              Text {
                required property var modelData
                width: Math.floor(inner.width / 7)
                text: root.weekdayLabel(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.themeFont.caption
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }

          Item {
            id: calendarGrid
            width: parent.width
            implicitHeight: calendarWeeks.implicitHeight
            height: implicitHeight
            activeFocusOnTab: true

            Keys.onPressed: function(event) {
              if (root.handleDialogKey(event)) {
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_Left) {
                root.moveSelectedDay(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Right) {
                root.moveSelectedDay(1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.moveSelectedDay(-7)
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.moveSelectedDay(7)
                event.accepted = true
              }
            }

            Column {
              id: calendarWeeks
              width: parent.width
              spacing: 0

          Repeater {
            model: root.weeks

            Row {
              id: calendarWeek
              required property var modelData
              width: parent.width
              spacing: 0

              Repeater {
                model: calendarWeek.modelData

                Item {
                  id: calendarDay
                  required property var modelData
                  width: Math.floor(inner.width / 7)
                  height: Style.space(28)

                  readonly property bool chosen: modelData.inMonth
                    && modelData.year === root.selectedYear
                    && modelData.month === root.selectedMonth
                    && modelData.day === root.selectedDay

                  BorderSurface {
                    anchors.fill: parent
                    anchors.margins: 1
                    visible: parent.chosen
                    color: root.alpha(root.accent, 0.16)
                    borderSpec: Border.flat(root.alpha(root.accent, calendarGrid.activeFocus ? 0.85 : 0.45), calendarGrid.activeFocus ? 2 : 1)
                    radius: Style.cornerRadius
                  }

                  Text {
                    anchors.centerIn: parent
                    text: String(calendarDay.modelData.day)
                    color: calendarDay.modelData.inMonth ? (parent.chosen ? root.accent : root.foreground) : root.alpha(root.dim, 0.45)
                    font.family: root.fontFamily
                    font.pixelSize: root.themeFont.caption
                    font.bold: parent.chosen
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: calendarDay.modelData.inMonth
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.selectDay(calendarDay.modelData)
                      calendarGrid.forceActiveFocus()
                    }
                  }
                }
              }
            }
          }
            }
          }

          Row {
            spacing: Style.space(8)

            Text {
              text: "Time"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: root.themeFont.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            TextField {
              id: hourField
              width: Style.space(48)
              placeholderText: "09"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              inputMethodHints: Qt.ImhDigitsOnly
              onEditingFinished: {
                root.applyHourText(text)
                text = Model.pad2(root.hour)
              }
              onAccepted: minuteField.forceActiveFocus()
              Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
            }

            Text {
              text: ":"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.themeFont.body
              anchors.verticalCenter: parent.verticalCenter
            }

            TextField {
              id: minuteField
              width: Style.space(48)
              placeholderText: "00"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              inputMethodHints: Qt.ImhDigitsOnly
              onEditingFinished: {
                root.applyMinuteText(text)
                text = Model.pad2(root.minute)
              }
              onAccepted: root.commitParse()
              Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.parsed.ok
          text: "Will send " + root.parsed.label
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.themeFont.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: !root.parsed.ok && String(root.scheduleText || "").trim() !== "" && !root.usePicker
          text: root.parsed.error
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.themeFont.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: !root.parsed.ok && root.usePicker
          text: root.parsed.error
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.themeFont.caption
          wrapMode: Text.WordWrap
        }
      }

      Text {
        width: parent.width
        visible: root.errorText !== ""
        text: root.errorText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: root.themeFont.caption
        wrapMode: Text.WordWrap
      }

      Row {
        spacing: Style.space(8)

        Button {
          id: cancelButton
          text: "Cancel"
          bordered: true
          focusable: true
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: root.themeFont.caption
          Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
          onClicked: root.requestCancel()
        }

        Button {
          id: sendLaterButton
          text: root.confirming ? "Send later" : "Send later…"
          bordered: true
          selected: true
          focusable: true
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: root.themeFont.caption
          Keys.onPressed: function(event) { event.accepted = root.handleDialogKey(event) }
          onClicked: root.confirming ? root.confirmPending() : root.commitParse()
        }
      }
    }
  }
}

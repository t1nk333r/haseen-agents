import QtQuick
import qs.Commons
import qs.Ui

// Vertical chip list for a tab's left rail.
//
// Same contract as the kit's ButtonGroup — a plain string[] or an array of
// { value, label } objects, one selected chip, an external `cursorIndex`,
// one `changed(value)` — but stacked, because the rail is a column and a
// ButtonGroup is a Row. The rail's chips are what j/k moves and h/l clicks
// through, so the paint comes from the same Button states ButtonGroup uses.
Column {
  id: root

  property var options: []
  property string value: ""
  property color foreground: Color.foreground
  property color background: "transparent"
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall

  // -1 disables the external cursor highlight (the panel-cursor case).
  property int cursorIndex: -1

  signal changed(string value)

  spacing: Style.spacing.xxs

  function optionValue(option) {
    return (option && typeof option === "object") ? String(option.value) : String(option)
  }
  function optionLabel(option) {
    return (option && typeof option === "object" && option.label !== undefined) ? String(option.label) : String(option)
  }
  function optionIndex(v) {
    for (var i = 0; i < root.options.length; i++) {
      if (root.optionValue(root.options[i]) === String(v)) return i
    }
    return -1
  }

  Repeater {
    model: root.options

    delegate: Button {
      required property var modelData
      required property int index

      width: root.width
      text: root.optionLabel(modelData)
      selected: root.optionValue(modelData) === root.value
      hasCursor: root.cursorIndex === index
      bordered: true
      foreground: root.foreground
      background: root.background
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: root.fontSize
      verticalPadding: Style.spacing.controlPaddingY
      onClicked: root.changed(root.optionValue(modelData))
    }
  }
}

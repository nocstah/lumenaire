import QtQuick
import QtQuick.Layouts
import qs.Commons

// Every section title in the panel looks the same (DESIGN.md "Layout"): a
// bold sentence-case word on the content's left edge, with an optional
// control or note on the right edge (the default property), centred on the
// title's line.
RowLayout {
    id: root
    property string text: ""
    default property alias trailing: tail.data
    spacing: Style.space(8)
    Layout.fillWidth: true

    Label {
        text: root.text
        font.bold: true
        font.pixelSize: Style.font.subtitle
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        Accessible.role: Accessible.Heading
    }
    RowLayout {
        id: tail
        spacing: Style.space(8)
        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
    }
}

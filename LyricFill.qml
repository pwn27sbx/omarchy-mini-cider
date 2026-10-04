import QtQuick
import "lib/Lyrics.js" as Lyrics

// One lyric line with a position-driven fill (no animations: the host's
// 33 ms position tick drives it). Sung words use sungColor, the active word
// is filled with fillColor up to its progress by a clipped copy of the text
// sized from TextMetrics, upcoming words stay dim. Lines without word timing
// fill at line level. A line wider than the item wraps and falls back to
// per-word colouring, because a clipped width cannot follow wrapped text.
Item {
    id: root

    property var line: null
    property real position: 0
    property color sungColor: "white"
    property color fillColor: "orange"
    property real upcomingOpacity: 0.45
    property string fontFamily: ""
    property real fontSize: 12
    property bool bold: true

    readonly property var proj: Lyrics.projectLine(root.line, root.position)
    readonly property bool fits: fullMetrics.advanceWidth <= root.width
    readonly property real sungWidth: sungMetrics.advanceWidth
    readonly property real activeWidth: activeMetrics.advanceWidth * root.proj.activeProgress

    implicitHeight: root.fits ? fullText.implicitHeight : wrapText.implicitHeight

    TextMetrics { id: fullMetrics; font.family: root.fontFamily; font.pixelSize: root.fontSize; font.bold: root.bold; text: root.proj.text }
    TextMetrics { id: sungMetrics; font.family: root.fontFamily; font.pixelSize: root.fontSize; font.bold: root.bold; text: root.proj.sungText }
    TextMetrics { id: activeMetrics; font.family: root.fontFamily; font.pixelSize: root.fontSize; font.bold: root.bold; text: root.proj.activeText }

    Item {
        visible: root.fits
        width: fullMetrics.advanceWidth
        height: parent.height
        anchors.horizontalCenter: parent.horizontalCenter

        Text {
            id: fullText
            text: root.proj.text
            textFormat: Text.PlainText
            color: root.sungColor
            opacity: root.upcomingOpacity
            font.family: root.fontFamily
            font.pixelSize: root.fontSize
            font.bold: root.bold
        }
        Item {
            width: root.sungWidth
            height: parent.height
            clip: true
            Text {
                text: root.proj.text
                textFormat: Text.PlainText
                color: root.sungColor
                font: fullText.font
            }
        }
        Item {
            x: root.sungWidth
            width: root.activeWidth
            height: parent.height
            clip: true
            Text {
                x: -root.sungWidth
                text: root.proj.text
                textFormat: Text.PlainText
                color: root.fillColor
                font: fullText.font
            }
        }
    }

    Text {
        id: wrapText
        visible: !root.fits
        width: parent.width
        textFormat: Text.StyledText
        text: Lyrics.styledLine(root.proj, root.fillColor.toString(), Qt.alpha(root.sungColor, root.upcomingOpacity).toString())
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        font.bold: root.bold
    }
}

import QtQuick
import Quickshell
import Quickshell.Io
import Qt5Compat.GraphicalEffects
import qs.Ui
import qs.Commons
import "lib/Lyrics.js" as Lyrics

Item {
    id: root
    
    property var hostWidget: null
    property int currentTab: 0
    onHostWidgetChanged: {
        if (hostWidget) currentTab = hostWidget.savedTab;
    }
    onCurrentTabChanged: {
        if (hostWidget) hostWidget.savedTab = currentTab;
    }
    property string searchText: ""

    anchors.fill: parent

    function formatTime(sec) {
        if (isNaN(sec) || sec <= 0) return "0:00";
        var m = Math.floor(sec / 60);
        var s = Math.floor(sec % 60);
        return m + ":" + (s < 10 ? "0" : "") + s;
    }

    property bool hasToken: hostWidget && hostWidget.apiToken && hostWidget.apiToken !== ""

    // Only load images from Apple's own artwork CDN, over https. Anything
    // else (including a malformed URL) is rejected and the Image is left
    // empty rather than fetched.
    function safeArtworkUrl(url) {
        if (!url) return "";
        var text = String(url);
        // Host charset is restricted so "?", "#", "@" or ":" cannot smuggle a
        // different real host past the suffix check.
        var match = text.match(/^https:\/\/([a-z0-9.-]+)\//i);
        if (!match) return "";
        var host = match[1].toLowerCase();
        if (host !== "mzstatic.com" && host.slice(-".mzstatic.com".length) !== ".mzstatic.com") {
            return "";
        }
        return text;
    }

    Column {
        visible: hasToken
        anchors.centerIn: parent
        width: parent.width - Style.space(32)
        spacing: Style.space(20) // Tighter spacing

        // 1. Current Track
        Row {
            width: parent.width
            height: Style.space(110)
            spacing: Style.space(16) // Reduced spacing between art and info

            // Art
            BorderSurface {
                width: Style.space(110)
                height: Style.space(110)
                radius: Style.space(4)
                padding: 0
                color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
                borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)

                Rectangle {
                    id: maskRect
                    anchors.fill: parent
                    anchors.margins: Style.space(3)
                    radius: Style.space(2)
                    visible: false
                }

                Image {
                    id: albumImage
                    anchors.fill: parent
                    anchors.margins: Style.space(3)
                    source: hostWidget ? root.safeArtworkUrl(hostWidget.albumArtUrl) : ""
                    sourceSize.width: 640
                    sourceSize.height: 640
                    fillMode: Image.PreserveAspectCrop
                    visible: source !== ""
                    layer.enabled: true
                    layer.effect: OpacityMask {
                        maskSource: maskRect
                    }
                }

                Text {
                    anchors.centerIn: parent
                    text: "\uf001"
                    font.family: Style.font.family
                    font.pixelSize: Style.space(32)
                    color: "white"
                    opacity: 0.15
                    visible: !(hostWidget && hostWidget.albumArtUrl !== "")
                }
                
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.color: Qt.rgba(255, 255, 255, 0.08)
                    border.width: 1
                    radius: parent.radius
                }
            }

            // Info & Controls
            Column {
                width: parent.width - Style.space(126) // 110 + 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(12)

                Column {
                    width: parent.width
                    spacing: Style.space(2)

                    Text {
                        text: hostWidget ? hostWidget.trackTitle : "Unknown Title"
                        textFormat: Text.PlainText
                        color: Color.foreground
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        font.family: Style.font.family
                        elide: Text.ElideRight
                        width: parent.width
                    }

                    Text {
                        text: hostWidget ? hostWidget.trackArtist : "Unknown Artist"
                        textFormat: Text.PlainText
                        color: Color.foreground
                        opacity: 0.45
                        font.pixelSize: Style.font.bodySmall
                        font.family: Style.font.family
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                // Progress Bar
                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                        text: formatTime(hostWidget ? hostWidget.trackPosition : 0)
                        color: Color.foreground
                        opacity: 0.5
                        font.pixelSize: Style.font.bodySmall - 2
                        font.family: Style.font.family
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(28)
                        horizontalAlignment: Text.AlignRight
                    }

                    Item {
                        width: parent.width - Style.space(72) // 28+28+16
                        height: Style.space(16)
                        anchors.verticalCenter: parent.verticalCenter

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width
                            height: Style.space(4)
                            radius: height / 2
                            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
                            
                            Rectangle {
                                height: parent.height
                                width: hostWidget && hostWidget.trackLength > 0 ? Math.min((hostWidget.trackPosition / hostWidget.trackLength) * parent.width, parent.width) : 0
                                radius: parent.radius
                                color: Color.accent
                            }
                        }

                        MouseArea {
                            id: progressArea
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            
                            Rectangle {
                                visible: progressArea.containsMouse
                                width: Style.space(10)
                                height: Style.space(10)
                                radius: width / 2
                                color: "white"
                                anchors.verticalCenter: parent.verticalCenter
                                x: (hostWidget && hostWidget.trackLength > 0 ? Math.min((hostWidget.trackPosition / hostWidget.trackLength) * parent.width, parent.width) : 0) - (width / 2)
                            }
                            
                            hoverEnabled: true
                            onPositionChanged: function(mouse) {
                                if (mouse.buttons & Qt.LeftButton) {
                                    if (hostWidget && hostWidget.trackLength > 0) {
                                        hostWidget.lastSeekTime = Date.now();
                                        var ratio = Math.max(0, Math.min(1, mouse.x / width));
                                        hostWidget.trackPosition = ratio * hostWidget.trackLength;
                                    }
                                }
                            }
                            onReleased: function(mouse) {
                                if (hostWidget && hostWidget.trackLength > 0) {
                                    var ratio = Math.max(0, Math.min(1, mouse.x / width));
                                    hostWidget.seek(ratio * hostWidget.trackLength);
                                }
                            }
                        }
                    }

                    Text {
                        text: formatTime(hostWidget ? hostWidget.trackLength : 0)
                        color: Color.foreground
                        opacity: 0.5
                        font.pixelSize: Style.font.bodySmall - 2
                        font.family: Style.font.family
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(28)
                    }
                }

                // Controls
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(32)
                    height: Style.font.iconLarge + 4

                    Text {
                        text: "\uf04a" // step-backward
                        font.family: Style.font.family
                        font.pixelSize: Style.font.iconLarge
                        color: Color.foreground
                        opacity: prevMouse.containsMouse ? 1.0 : 0.4
                        anchors.verticalCenter: parent.verticalCenter
                        
                        MouseArea { 
                            id: prevMouse
                            anchors.fill: parent
                            anchors.margins: -10
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (hostWidget) hostWidget.prevTrack()
                        }
                    }

                    Text {
                        text: (hostWidget && hostWidget.isPlaying) ? "\uf04c" : "\uf04b" // pause / play
                        font.family: Style.font.family
                        font.pixelSize: Style.font.iconLarge + 4
                        color: Color.foreground
                        opacity: playMouse.containsMouse ? 1.0 : 0.8
                        anchors.verticalCenter: parent.verticalCenter
                        
                        MouseArea { 
                            id: playMouse
                            anchors.fill: parent
                            anchors.margins: -10
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (hostWidget) hostWidget.playPause()
                        }
                    }

                    Text {
                        text: "\uf04e" // step-forward
                        font.family: Style.font.family
                        font.pixelSize: Style.font.iconLarge
                        color: Color.foreground
                        opacity: nextMouse.containsMouse ? 1.0 : 0.4
                        anchors.verticalCenter: parent.verticalCenter
                        
                        MouseArea { 
                            id: nextMouse
                            anchors.fill: parent
                            anchors.margins: -10
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (hostWidget) hostWidget.nextTrack()
                        }
                    }
                }
            }
        }

        // 2. Tabs
        Row {
            width: parent.width
            height: Style.space(28)
            spacing: Style.space(8)

            // Tab Cola
            Rectangle {
                width: (parent.width - Style.space(8)) / 2
                height: parent.height
                color: root.currentTab === 0 ? Util.alpha(Color.accent, 0.15) : Util.alpha(Color.foreground, 0.05)
                radius: Style.cornerRadius
                border.width: 1
                border.color: root.currentTab === 0 ? Color.accent : Util.alpha(Color.foreground, 0.1)
                
                Text {
                    anchors.centerIn: parent
                    text: "Queue"
                    color: root.currentTab === 0 ? Color.accent : Color.foreground
                    opacity: root.currentTab === 0 ? 1.0 : 0.5
                    font.pixelSize: Style.font.bodySmall
                    font.family: Style.font.family
                    font.bold: root.currentTab === 0
                }
                
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.currentTab = 0
                }
            }

            // Tab Letras
            Rectangle {
                width: (parent.width - Style.space(8)) / 2
                height: parent.height
                color: root.currentTab === 1 ? Util.alpha(Color.accent, 0.15) : Util.alpha(Color.foreground, 0.05)
                radius: Style.cornerRadius
                border.width: 1
                border.color: root.currentTab === 1 ? Color.accent : Util.alpha(Color.foreground, 0.1)
                
                Text {
                    anchors.centerIn: parent
                    text: "Lyrics"
                    color: root.currentTab === 1 ? Color.accent : Color.foreground
                    opacity: root.currentTab === 1 ? 1.0 : 0.5
                    font.pixelSize: Style.font.bodySmall
                    font.family: Style.font.family
                    font.bold: root.currentTab === 1
                }
                
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.currentTab = 1
                }
            }
        }

        // 3. Contenido (Queue or Lyrics)
        Item {
            width: parent.width
            height: (Style.space(42) * 3) + (Style.space(6) * 2) + Style.space(40)
            
            Timer {
                id: searchDebounce
                interval: 500
                onTriggered: {
                    if (hostWidget) hostWidget.searchAppleMusic(root.searchText);
                }
            }

            Timer {
                id: queuedGlobalPlaceholderTimer
                interval: 2500
                onTriggered: searchInput.placeholderText = "Search queue & Apple Music..."
            }

            Timer {
                id: queuedLocalPlaceholderTimer
                interval: 1000
                onTriggered: searchInput.placeholderText = "Search queue & Apple Music..."
            }

            TextField {
                id: searchInput
                visible: root.currentTab === 0
                focus: visible
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: Style.space(32)
                placeholderText: "Search queue & Apple Music..."
                onTextChanged: {
                    root.searchText = text.toLowerCase()
                    if (root.searchText !== "") {
                        searchDebounce.restart();
                    } else if (hostWidget) {
                        hostWidget.searchResults = [];
                    }
                }
                
                Keys.onEscapePressed: function (event) {
                    if (searchInput.text.length > 0) {
                        searchInput.text = "";
                    } else if (hostWidget) {
                        hostWidget.toggle();
                    }
                    event.accepted = true;
                }
                
                Keys.onDownPressed: function (event) {
                    if (queueList.count > 0) {
                        queueList.forceActiveFocus();
                        queueList.currentIndex = 0;
                    }
                    event.accepted = true;
                }
                
                Keys.onLeftPressed: function (event) {
                    if (searchInput.text === "" && hostWidget) {
                        hostWidget.prevTrack();
                        event.accepted = true;
                    }
                }
                
                Keys.onRightPressed: function (event) {
                    if (searchInput.text === "" && hostWidget) {
                        hostWidget.nextTrack();
                        event.accepted = true;
                    }
                }
            }

            ListView {
                id: queueList
                visible: root.currentTab === 0
                anchors.top: searchInput.bottom
                anchors.topMargin: Style.space(8)
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                clip: true
                spacing: Style.space(6)
                interactive: true
                boundsBehavior: Flickable.StopAtBounds
                
                keyNavigationEnabled: true
                highlight: Rectangle {
                    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
                    radius: Style.cornerRadius / 2
                }
                highlightMoveDuration: 100
                
                Keys.onUpPressed: function(event) {
                    if (currentIndex <= 0) {
                        searchInput.forceActiveFocus();
                        currentIndex = -1;
                    } else {
                        currentIndex--;
                    }
                    event.accepted = true;
                }
                
                Keys.onLeftPressed: function(event) {
                    if (hostWidget) hostWidget.prevTrack();
                    event.accepted = true;
                }
                
                Keys.onRightPressed: function(event) {
                    if (hostWidget) hostWidget.nextTrack();
                    event.accepted = true;
                }
                
                Keys.onReturnPressed: function(event) {
                    if (currentIndex >= 0 && currentIndex < count) {
                        var item = model[currentIndex];
                        if (item.isGlobal && hostWidget) {
                            hostWidget.playSearchItem(item.id);
                            searchInput.text = "";
                        } else if (!item.isPlaying && hostWidget) {
                            hostWidget.jumpToQueueIndex(item.originalIndex);
                        }
                    }
                    event.accepted = true;
                }
                
                Keys.onSpacePressed: function(event) {
                    if (currentIndex > 0 && currentIndex < count) { // Prevents queuing the currently playing song (index 0)
                        var item = model[currentIndex];
                        if (hostWidget && item.id) {
                            if (item.isGlobal) {
                                hostWidget.queueSearchItem(item.id);
                                searchInput.text = "";
                                searchInput.placeholderText = "Added to queue! (Wait 2s...)";
                                queuedGlobalPlaceholderTimer.restart();
                            } else {
                                hostWidget.playNext(item.id, item.type || "song");
                                searchInput.placeholderText = "Added to queue!";
                                queuedLocalPlaceholderTimer.restart();
                            }
                            searchInput.forceActiveFocus();
                        }
                    }
                    event.accepted = true;
                }
                
                Keys.onEscapePressed: function(event) {
                    searchInput.forceActiveFocus();
                    currentIndex = -1;
                    event.accepted = true;
                }
                
                model: (function(query, data, searchData) {
                    var mapped = data.map(function(item, idx) {
                        return {
                            title: item.title,
                            artist: item.artist,
                            id: item.id,
                            type: item.type,
                            originalIndex: idx,
                            isPlaying: idx === 0,
                            isGlobal: false,
                            artwork: ""
                        };
                    });
                    if (!query) return mapped;
                    var local = mapped.filter(function(item) {
                        return (item.title && item.title.toLowerCase().indexOf(query) !== -1) ||
                               (item.artist && item.artist.toLowerCase().indexOf(query) !== -1);
                    });
                    var global = (searchData || []).map(function(item) {
                        return {
                            title: item.trackName,
                            artist: item.artistName,
                            id: item.trackId,
                            type: "song",
                            originalIndex: -1,
                            isPlaying: false,
                            isGlobal: true,
                            artwork: item.artworkUrl100
                        };
                    });
                    return local.concat(global);
                })(root.searchText, hostWidget ? hostWidget.queueData : [], hostWidget ? hostWidget.searchResults : [])
                
                delegate: Item {
                    width: queueList.width
                    height: Style.space(42)
                    
                    MouseArea {
                        id: delegateMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        
                        onClicked: {
                            if (modelData.isGlobal && hostWidget) {
                                hostWidget.playSearchItem(modelData.id);
                                searchInput.text = "";
                            } else if (!modelData.isPlaying && hostWidget) {
                                hostWidget.jumpToQueueIndex(modelData.originalIndex);
                            }
                        }
                        
                        // Hover background effect
                        Rectangle {
                            anchors.fill: parent
                            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
                            radius: Style.cornerRadius / 2
                            visible: delegateMouse.containsMouse && (!modelData.isPlaying || modelData.isGlobal)
                        }
                        
                        Row {
                            anchors.fill: parent
                            anchors.margins: Style.space(4)
                            anchors.leftMargin: Style.space(8)
                            spacing: Style.space(12)
                            
                            Item {
                                width: Style.space(16)
                                height: parent.height
                                visible: !modelData.isGlobal
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.isPlaying ? "\uf027" : (modelData.originalIndex + 1)
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.bodySmall
                                    color: modelData.isPlaying ? Color.accent : Color.foreground
                                    opacity: modelData.isPlaying ? 1.0 : 0.3
                                }
                            }
                            
                            Image {
                                visible: modelData.isGlobal
                                width: Style.space(32)
                                height: Style.space(32)
                                anchors.verticalCenter: parent.verticalCenter
                                source: modelData.isGlobal ? root.safeArtworkUrl(modelData.artwork) : ""
                                sourceSize.width: 128
                                sourceSize.height: 128
                                fillMode: Image.PreserveAspectCrop
                            }
                            
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - Style.space(32) - (delegateMouse.containsMouse && !modelData.isPlaying ? Style.space(36) : 0)
                                spacing: 2
                                
                                Text {
                                    text: modelData.isPlaying && hostWidget && hostWidget.trackTitle !== "Waiting for Cider..." ? hostWidget.trackTitle : (modelData.title || "")
                                    textFormat: Text.PlainText
                                    color: modelData.isPlaying ? Color.accent : Color.foreground
                                    opacity: modelData.isPlaying ? 1.0 : 0.7
                                    font.pixelSize: Style.font.bodySmall
                                    font.bold: modelData.isPlaying
                                    font.family: Style.font.family
                                    elide: Text.ElideRight
                                    width: parent.width
                                }

                                Text {
                                    text: modelData.isPlaying && hostWidget && hostWidget.trackArtist !== "No artist playing" ? hostWidget.trackArtist : (modelData.artist || "")
                                    textFormat: Text.PlainText
                                    color: Color.foreground
                                    opacity: 0.35
                                    font.pixelSize: Style.font.bodySmall - 2
                                    font.family: Style.font.family
                                    elide: Text.ElideRight
                                    width: parent.width
                                    visible: text !== ""
                                }
                            }
                        }
                        
                        // Hover Icon (Add to Queue / Next)
                        Item {
                            width: Style.space(36)
                            height: parent.height
                            anchors.right: parent.right
                            visible: delegateMouse.containsMouse && index !== 0
                            
                            Rectangle {
                                anchors.centerIn: parent
                                width: Style.space(24)
                                height: Style.space(24)
                                radius: width / 2
                                color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
                                
                                Text {
                                    anchors.centerIn: parent
                                    text: "\uf067" // Plus icon
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.bodySmall - 1
                                    color: Color.accent
                                }
                            }
                            
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: function(mouse) {
                                    mouse.accepted = true; // Prevent triggering the row click
                                    if (hostWidget && modelData && modelData.id) {
                                        hostWidget.playNext(modelData.id, modelData.type || "song");
                                    }
                                }
                            }
                        }
                    }
                }
            }

            ListView {
                id: lyricsList
                anchors.fill: parent
                visible: root.currentTab === 1
                clip: true
                spacing: Style.space(8)
                interactive: true
                boundsBehavior: Flickable.StopAtBounds
                
                model: hostWidget ? hostWidget.parsedLyrics : []
                
                focus: visible
                Keys.onLeftPressed: function(event) {
                    if (hostWidget) hostWidget.prevTrack();
                    event.accepted = true;
                }
                Keys.onRightPressed: function(event) {
                    if (hostWidget) hostWidget.nextTrack();
                    event.accepted = true;
                }
                Keys.onPressed: function(event) {
                    if (!hostWidget) return;
                    if (event.text === "[") { hostWidget.adjustOffset(-1); event.accepted = true; }
                    else if (event.text === "]") { hostWidget.adjustOffset(1); event.accepted = true; }
                }
                
                currentIndex: hostWidget ? hostWidget.currentLyricIndex : 0
                onCurrentIndexChanged: {
                    if (visible && currentIndex >= 0) {
                        positionViewAtIndex(currentIndex, ListView.Center);
                    }
                }
                
                onVisibleChanged: {
                    if (visible && currentIndex >= 0) {
                        positionViewAtIndex(currentIndex, ListView.Center);
                    }
                }
                
                delegate: Item {
                    width: lyricsList.width
                    readonly property bool isActive: lyricsList.currentIndex === index && modelData.start >= 0
                    // Past the end of the active line (long gap or outro): the
                    // placeholder replaces the frozen, fully lit line.
                    readonly property bool inGap: isActive && hostWidget
                        && (hostWidget.lyricKind === "interlude" || hostWidget.lyricKind === "outro")
                    height: (isActive && !inGap ? lineFill.implicitHeight : (inGap ? gapText.implicitHeight : lineText.implicitHeight)) + Style.space(4)
                    
                    property real relativeY: y - lyricsList.contentY + (height / 2)
                    property real distFromCenter: Math.abs(relativeY - (lyricsList.height / 2))
                    property real halfHeight: lyricsList.height / 2
                    opacity: Math.min(1.0, Math.max(0.0, (halfHeight - distFromCenter) / Style.space(40)))
                    
                    Text {
                        id: lineText
                        width: parent.width - Style.space(32)
                        anchors.centerIn: parent
                        text: modelData.text || ""
                        textFormat: Text.PlainText
                        visible: !isActive
                        color: Color.foreground
                        opacity: modelData.start === -1 ? 0.7 : 0.4
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        font.bold: false
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        
                        Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                    }

                    Text {
                        id: gapText
                        visible: inGap
                        anchors.centerIn: parent
                        textFormat: Text.StyledText
                        text: inGap ? Lyrics.gapMarkup(hostWidget.lyricKind === "outro" ? 1 : hostWidget.lyricGapProgress,
                            Color.accent.toString(), Qt.alpha(Color.foreground, 0.4).toString()) : ""
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall + 1
                        font.bold: true
                    }

                    LyricFill {
                        id: lineFill
                        visible: isActive && !inGap
                        width: parent.width - Style.space(32)
                        anchors.centerIn: parent
                        line: isActive ? modelData : null
                        position: hostWidget ? hostWidget.lyricPosition : 0
                        sungColor: Color.foreground
                        fillColor: Color.accent
                        fontFamily: Style.font.family
                        fontSize: Style.font.bodySmall + 1
                    }
                    
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: modelData.start >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (modelData.start >= 0 && hostWidget) {
                                hostWidget.seekToLine(modelData.start);
                            }
                        }
                    }
                }
                
                header: Item {
                    width: parent.width
                    height: lyricsList.height / 2 - Style.space(16)
                    Text {
                        // Lead-in: the song has not reached its first line yet.
                        visible: hostWidget && hostWidget.lyricKind === "leadin"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(8)
                        textFormat: Text.StyledText
                        text: hostWidget ? Lyrics.gapMarkup(hostWidget.lyricGapProgress,
                            Color.accent.toString(), Qt.alpha(Color.foreground, 0.4).toString()) : ""
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall + 1
                        font.bold: true
                    }
                }
                footer: Item { width: parent.width; height: lyricsList.height / 2 - Style.space(16) }
            }

            // Per-track lyrics offset: "-" / value (click to reset) / "+".
            Row {
                visible: root.currentTab === 1 && hostWidget && hostWidget.lyricKind !== "none"
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Style.space(4)
                spacing: Style.space(2)
                z: 2

                Repeater {
                    model: ["-", "value", "+"]
                    delegate: Rectangle {
                        readonly property bool isValue: modelData === "value"
                        width: isValue ? Style.space(44) : Style.space(22)
                        height: Style.space(22)
                        radius: Style.cornerRadius
                        color: Util.alpha(Color.foreground, 0.08)
                        Text {
                            anchors.centerIn: parent
                            text: isValue ? (hostWidget ? Lyrics.formatOffset(hostWidget.offsetMs) : "0.0s") : modelData
                            color: isValue && hostWidget && hostWidget.offsetMs !== 0 ? Color.accent : Color.foreground
                            opacity: isValue ? 0.8 : 0.9
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall - 1
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!hostWidget) return;
                                if (isValue) hostWidget.resetOffset();
                                else hostWidget.adjustOffset(modelData === "-" ? -1 : 1);
                            }
                        }
                    }
                }
            }
        }
    }

    // ONBOARDING UI
    Column {
        visible: !hasToken
        anchors.centerIn: parent
        width: parent.width - Style.space(32)
        spacing: Style.space(16)
        
        Text {
            text: "\uf179"
            font.family: Style.font.family
            font.pixelSize: Style.space(48)
            color: Color.accent
            anchors.horizontalCenter: parent.horizontalCenter
        }
        
        Text {
            text: "Connect to Cider"
            color: Color.foreground
            font.pixelSize: Style.font.heading
            font.bold: true
            font.family: Style.font.family
            anchors.horizontalCenter: parent.horizontalCenter
        }
        
        Text {
            text: "1. In Cider go to Settings > Connectivity\n2. Enable 'WebSockets API'\n3. Click 'Manage External Application Access...'\n4. Copy your Token from the app\n5. CLICK the box below to paste it:"
            color: Color.foreground
            opacity: 0.6
            font.pixelSize: Style.font.bodySmall
            font.family: Style.font.family
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
        }
        
        Process {
            id: procPaste
            // The helper reads wl-paste through a 4 KiB cap and prints a single
            // validated line of at most 512 chars, so the collector below never
            // holds more than that, whatever is on the clipboard.
            command: ["timeout", "-k", "1", "3", "python3",
                      String(Qt.resolvedUrl("helpers/read_clipboard.py")).replace(/^file:\/\//, "")]
            stdout: StdioCollector {
                id: pasteStdout
                waitForEnd: true
            }
            onExited: function(exitCode, exitStatus) {
                if (exitCode !== 0) return;
                var text = String(pasteStdout.text).trim();
                if (text !== "") {
                    tokenInput.text = text;
                }
            }
        }
        
        Rectangle {
            width: parent.width
            height: Style.space(36)
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.1)
            border.width: 1
            radius: Style.cornerRadius / 2
            
            TextInput {
                id: tokenInput
                anchors.fill: parent
                anchors.margins: Style.space(8)
                verticalAlignment: TextInput.AlignVCenter
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                selectByMouse: true
                clip: true
                readOnly: true
                
                Text {
                    text: "Click here to paste the Token..."
                    color: Color.foreground
                    opacity: 0.5
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: !tokenInput.text
                }
            }
            
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    // Start a new process instance to read clipboard
                    procPaste.running = true;
                }
            }
        }
        
        Rectangle {
            width: parent.width
            height: Style.space(36)
            color: tokenInput.text !== "" ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.1)
            radius: Style.cornerRadius / 2
            
            Text {
                anchors.centerIn: parent
                text: "Save and Connect"
                color: tokenInput.text !== "" ? Color.background : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.5)
                font.bold: true
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
            }
            
            MouseArea {
                anchors.fill: parent
                cursorShape: tokenInput.text !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (tokenInput.text !== "" && hostWidget) {
                        hostWidget.saveToken(tokenInput.text);
                    }
                }
            }
        }
    }
}

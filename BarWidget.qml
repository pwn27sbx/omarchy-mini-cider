import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
    id: root
    moduleName: "pwnsxb.apple-music"

    implicitWidth: 24
    implicitHeight: root.bar ? root.bar.barSize : Style.space(32)

    property bool opened: popup.open

    // Metadata state
    property string trackTitle: "Esperando a Cider..."
    property string trackArtist: "Nadie cantando"
    property string albumArtUrl: ""
    property string apiToken: ""
    property var queueData: []
    property string trackLyrics: ""
    property string currentLyricsSong: ""
    property var parsedLyrics: []
    property int savedTab: 0
    
    property string userCountry: "mx"
    Component.onCompleted: {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", "https://get.geojs.io/v1/ip/country.json");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data.country) {
                        root.userCountry = data.country.toLowerCase();
                    }
                } catch(e) {}
            }
        }
        xhr.send();
    }

    Process {
        id: tokenReader
        command: ["cat", Quickshell.env("HOME") + "/.config/omarchy/plugins/pwnsxb.apple-music/cider_token.txt"]
        running: true
        stdout: StdioCollector {
            id: tokenStdout
            waitForEnd: true
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0) {
                var text = String(tokenStdout.text).trim();
                if (text !== "") {
                    root.apiToken = text;
                }
            }
        }
    }

    Process {
        id: tokenSaver
    }

    function saveToken(token) {
        var cleanToken = token.trim();
        root.apiToken = cleanToken;
        tokenSaver.command = ["env", "CIDER_TOKEN=" + cleanToken, "python3", Quickshell.env("HOME") + "/.config/omarchy/plugins/pwnsxb.apple-music/helpers/save_token.py", Quickshell.env("HOME") + "/.config/omarchy/plugins/pwnsxb.apple-music/cider_token.txt"];
        tokenSaver.running = true;
        // Reiniciar los timers para cargar datos
        refreshTimer.restart();
        queueTimer.restart();
    }

    Timer {
        id: queueTimer
        interval: 3000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            var xhr = new XMLHttpRequest();
            xhr.open("GET", "http://127.0.0.1:10767/api/v1/playback/queue");
            xhr.setRequestHeader("apptoken", root.apiToken);
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                    try {
                        var queue = JSON.parse(xhr.responseText);
                        var newList = [];
                        var limit = queue.length;
                        for (var i = 0; i < limit; i++) {
                            var track = queue[i];
                            if (track && track.attributes) {
                                newList.push({
                                    title: track.attributes.name || "Desconocido",
                                    artist: track.attributes.artistName || "",
                                    id: track.id || "",
                                    type: track.type || "song"
                                });
                            }
                        }
                        root.queueData = newList;
                    } catch(e) {}
                }
            }
            xhr.send();
        }
    }

    function playNext(trackId, trackType) {
        if (!trackId || !root.apiToken) return;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", "http://127.0.0.1:10767/api/v1/playback/play-next");
        xhr.setRequestHeader("apptoken", root.apiToken);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ id: trackId, type: trackType }));
    }

    Process {
        id: ciderLauncher
        command: ["bash", "-c", "cider &"]
    }

    property var searchResults: []

    function searchAppleMusic(query) {
        if (!query) {
            root.searchResults = [];
            return;
        }
        var xhr = new XMLHttpRequest();
        xhr.open("GET", "https://itunes.apple.com/search?term=" + encodeURIComponent(query) + "&entity=song&limit=20&country=" + root.userCountry);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText);
                    root.searchResults = res.results || [];
                } catch(e) {}
            }
        }
        xhr.send();
    }

    function playSearchItem(trackId) {
        if (!root.apiToken) return;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", "http://127.0.0.1:10767/api/v1/playback/play-next");
        xhr.setRequestHeader("apptoken", root.apiToken);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                var timer = Qt.createQmlObject('import QtQml 2.15; Timer { interval: 1500; running: true; onTriggered: { root.nextTrack(); this.destroy(); } }', root);
            }
        }
        xhr.send(JSON.stringify({ id: trackId.toString(), type: "song" }));
    }

    function queueSearchItem(trackId) {
        if (!root.apiToken) return;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", "http://127.0.0.1:10767/api/v1/playback/play-next");
        xhr.setRequestHeader("apptoken", root.apiToken);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ id: trackId.toString(), type: "song" }));
    }

    property bool isPlaying: false
    property real trackPosition: 0
    property real trackLength: 0
    property real lastSeekTime: 0
    property real lastPlaybackTimeCheck: -1

    property int currentLyricIndex: 0
    property real currentLyricProgress: 0.0
    property var lastTimerTick: Date.now()

    Timer {
        id: playbackTimer
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            var now = Date.now();
            var dt = (now - root.lastTimerTick) / 1000.0;
            root.lastTimerTick = now;

            if (root.isPlaying) {
                root.trackPosition += dt;
            }
            
            // Calc current lyric
            if (root.parsedLyrics && root.parsedLyrics.length > 0) {
                var idx = 0;
                for (var i = 0; i < root.parsedLyrics.length; i++) {
                    if (root.parsedLyrics[i].time !== -1 && root.trackPosition >= root.parsedLyrics[i].time) {
                        idx = i;
                    } else if (root.parsedLyrics[i].time !== -1) {
                        break;
                    }
                }
                root.currentLyricIndex = idx;
                
                // Calc progress
                var currentLyric = root.parsedLyrics[idx];
                if (currentLyric && currentLyric.time !== -1) {
                    var startTime = currentLyric.time;
                    var endTime = root.trackLength;
                    for (var j = idx + 1; j < root.parsedLyrics.length; j++) {
                        if (root.parsedLyrics[j].time !== -1) {
                            endTime = root.parsedLyrics[j].time;
                            break;
                        }
                    }
                    var duration = endTime - startTime;
                    if (duration > 0) {
                        var p = (root.trackPosition - startTime) / duration;
                        root.currentLyricProgress = Math.max(0.0, Math.min(1.0, p));
                    } else {
                        root.currentLyricProgress = 1.0;
                    }
                } else {
                    root.currentLyricProgress = 0.0;
                }
            }
        }
    }

    function fetchMetadata() {
        if (!root.apiToken) return;

        var xhr = new XMLHttpRequest();
        xhr.open("GET", "http://127.0.0.1:10767/api/v1/playback/now-playing");
        xhr.setRequestHeader("apptoken", root.apiToken);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data && data.info) {
                        root.trackTitle = data.info.name || "Unknown";
                        root.trackArtist = data.info.artistName || "Cider";
                        
                        if (data.info.artwork && data.info.artwork.url) {
                            var url = data.info.artwork.url;
                            if (url.indexOf("sr.jpg/") !== -1) {
                                url = url.replace("sr.jpg/", "bb.jpg/");
                            }
                            if (url.indexOf("{w}") !== -1) {
                                url = url.replace("{w}", "640").replace("{h}", "640");
                            }
                            root.albumArtUrl = url;
                        }

                        var pos = parseFloat(data.info.currentPlaybackTime);
                        var len = data.info.durationInMillis ? data.info.durationInMillis / 1000 : 0;
                        
                        if (Date.now() - root.lastSeekTime > 2000) {
                            var newPos = isNaN(pos) ? 0 : pos;
                            if (Math.abs(root.trackPosition - newPos) > 0.5) {
                                root.trackPosition = newPos;
                            }
                            root.trackLength = isNaN(len) ? 0 : len;
                        }

                        // Calcular isPlaying detectando si el tiempo avanza
                        if (root.lastPlaybackTimeCheck !== -1) {
                            if (Math.abs(pos - root.lastPlaybackTimeCheck) > 0.05) {
                                root.isPlaying = true;
                            } else {
                                root.isPlaying = false;
                            }
                        } else {
                            // Asumimos que está sonando la primera vez si pos > 0
                            root.isPlaying = pos > 0;
                        }
                        root.lastPlaybackTimeCheck = pos;
                        
                        if (root.trackTitle !== root.currentLyricsSong && root.trackTitle !== "Waiting for Cider..." && root.trackTitle !== "Unknown") {
                            root.currentLyricsSong = root.trackTitle;
                            root.trackLyrics = "Loading lyrics...";
                            var xhrLyrics = new XMLHttpRequest();
                            xhrLyrics.open("GET", "https://lrclib.net/api/get?track_name=" + encodeURIComponent(root.trackTitle) + "&artist_name=" + encodeURIComponent(root.trackArtist));
                            xhrLyrics.onreadystatechange = function() {
                                if (xhrLyrics.readyState === XMLHttpRequest.DONE) {
                                    if (xhrLyrics.status === 200) {
                                        try {
                                            var ldata = JSON.parse(xhrLyrics.responseText);
                                            var pLyrics = [];
                                            if (ldata.syncedLyrics) {
                                                var lines = ldata.syncedLyrics.split('\n');
                                                for (var i = 0; i < lines.length; i++) {
                                                    var line = lines[i];
                                                    var match = line.match(/^\[(\d+):(\d+\.\d+)\](.*)/);
                                                    if (match) {
                                                        var m = parseInt(match[1]);
                                                        var s = parseFloat(match[2]);
                                                        var txt = match[3].trim();
                                                        if (txt === "") txt = "♪";
                                                        pLyrics.push({ time: m * 60 + s, text: txt });
                                                    }
                                                }
                                            } else if (ldata.plainLyrics) {
                                                var plainLines = ldata.plainLyrics.split('\n');
                                                for (var j = 0; j < plainLines.length; j++) {
                                                    pLyrics.push({ time: -1, text: plainLines[j] });
                                                }
                                            }
                                            
                                            if (pLyrics.length === 0) {
                                                pLyrics.push({ time: -1, text: "Instrumental / No lyrics available." });
                                            }
                                            
                                            root.parsedLyrics = pLyrics;
                                            root.trackLyrics = ldata.plainLyrics || "Instrumental / No lyrics available.";
                                        } catch(e) {
                                            root.parsedLyrics = [{time: -1, text: "Error parsing lyrics."}];
                                        }
                                    } else {
                                        root.parsedLyrics = [{time: -1, text: "Lyrics not found."}];
                                    }
                                }
                            }
                            xhrLyrics.send();
                        }
                    }
                } catch(e) {}
            }
        }
        xhr.send();
    }

    Timer {
        id: refreshTimer
        interval: 1000
        running: root.opened && root.apiToken !== ""
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchMetadata()
    }

    // Comandos de control MPRIS (o API)
    Process { id: procPlayPause; command: ["playerctl", "play-pause"] }
    Process { id: procNext; command: ["playerctl", "next"] }
    Process { id: procPrev; command: ["playerctl", "previous"] }


    function playPause() { procPlayPause.running = true; root.fetchMetadata(); }
    function nextTrack() { procNext.running = true; root.fetchMetadata(); }
    function prevTrack() { procPrev.running = true; root.fetchMetadata(); }

    function jumpToQueueIndex(index) {
        if (index <= 0 || !root.apiToken) return;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", "http://127.0.0.1:10767/api/v1/playback/queue/change-to-index");
        xhr.setRequestHeader("apptoken", root.apiToken);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ index: index }));
        // Trigger a faster update of the queue
        queueTimer.restart();
    }

    function seek(positionSecs) {
        if (!root.apiToken) return;
        root.lastSeekTime = Date.now();
        root.trackPosition = positionSecs; // Optimistic update
        var xhr = new XMLHttpRequest();
        xhr.open("POST", "http://127.0.0.1:10767/api/v1/playback/seek");
        xhr.setRequestHeader("apptoken", root.apiToken);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ position: positionSecs }));
    }

    function toggle() {
        popup.open = !popup.open;
    }

    WidgetButton {
        id: button
        width: 24
        height: parent.height
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: -4.5 // Desplazamiento extra a la izquierda para balancear la asimetría de la nota
        horizontalMargin: 0
        bar: root.bar
        text: "\uf001" // fa-music
        tooltipText: "Cider (Apple Music)"
        active: root.opened

        onPressed: function(mouse) { 
            if (mouse === Qt.RightButton || mouse === Qt.MiddleButton) {
                ciderLauncher.running = true;
            } else {
                root.toggle();
            }
        }
    }

    KeyboardPanel {
        id: popup
        anchorItem: button
        bar: root.bar
        owner: root

        contentWidth: Style.space(360)
        contentHeight: Style.space(430)

        Loader {
            id: panelLoader
            anchors.fill: parent
            active: popup.open || popup.visible
            source: Qt.resolvedUrl("Panel.qml")
            onLoaded: {
                if (item) {
                    item.hostWidget = root;
                    item.forceActiveFocus();
                }
            }
        }
    }
}

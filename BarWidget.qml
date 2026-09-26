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

    // Network bounds: every request gets a deadline and a response-size cap
    // so a slow or hostile endpoint cannot hang the widget or exhaust memory.
    readonly property int localTimeoutMs: 3000
    readonly property int remoteTimeoutMs: 8000
    readonly property int capNowPlaying: 64 * 1024
    readonly property int capQueue: 1024 * 1024
    readonly property int capSearch: 512 * 1024
    readonly property int capLyrics: 512 * 1024
    readonly property int maxQueueItems: 200
    readonly property int maxSearchResults: 20
    readonly property int maxLyricsLines: 2000
    readonly property int maxLyricsLineChars: 300
    readonly property int maxFieldChars: 300

    property bool queueRequestInFlight: false
    property bool metadataRequestInFlight: false

    function capString(value, maxChars) {
        var s = String(value === undefined || value === null ? "" : value);
        return s.length > maxChars ? s.substring(0, maxChars) : s;
    }

    // Shared bounded XHR helper: every request gets a timeout, aborts once
    // the in-flight body exceeds maxBytes, requires HTTP 200, and calls
    // onDone exactly once (with the parsed JSON, or null on any failure).
    function requestJson(method, url, headers, body, maxBytes, timeoutMs, onDone) {
        var xhr = new XMLHttpRequest();
        var finished = false;
        function finish(data) {
            if (finished) return;
            finished = true;
            if (onDone) onDone(data);
        }
        xhr.open(method, url);
        xhr.timeout = timeoutMs;
        if (headers) {
            for (var key in headers) {
                xhr.setRequestHeader(key, headers[key]);
            }
        }
        xhr.ontimeout = function() { try { xhr.abort(); } catch(e) {} finish(null); };
        xhr.onerror = function() { finish(null); };
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.LOADING) {
                if (xhr.responseText && xhr.responseText.length > maxBytes) {
                    try { xhr.abort(); } catch(e) {}
                    finish(null);
                }
            } else if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status !== 200) { finish(null); return; }
                var text = xhr.responseText || "";
                if (text.length > maxBytes) { finish(null); return; }
                if (text === "") { finish(null); return; }
                try {
                    finish(JSON.parse(text));
                } catch(e) {
                    finish(null);
                }
            }
        };
        try {
            xhr.send(body || null);
        } catch (e) {
            finish(null);
        }
        return xhr;
    }

    property string legacyTokenPath: String(Qt.resolvedUrl("cider_token.txt")).replace(/^file:\/\//, "")
    property string readTokenHelperPath: String(Qt.resolvedUrl("helpers/read_token.py")).replace(/^file:\/\//, "")
    property string saveTokenHelperPath: String(Qt.resolvedUrl("helpers/save_token.py")).replace(/^file:\/\//, "")

    Process {
        id: tokenReader
        command: ["timeout", "-k", "1", "3", "python3", root.readTokenHelperPath, root.legacyTokenPath]
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
        property string pendingToken: ""
        command: ["timeout", "-k", "1", "3", "python3", root.saveTokenHelperPath, root.legacyTokenPath]
        onStarted: {
            write(pendingToken + "\n");
            // Dropped immediately: this string holds the plugin's only secret.
            pendingToken = "";
            stdinEnabled = false;
        }
    }

    function saveToken(token) {
        var cleanToken = token.trim();
        root.apiToken = cleanToken;
        // The token is sent only through stdin: it must never appear in
        // argv or an environment variable of the spawned process.
        tokenSaver.pendingToken = cleanToken;
        tokenSaver.stdinEnabled = true;
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
            if (!root.apiToken || root.queueRequestInFlight) return;
            root.queueRequestInFlight = true;
            root.requestJson("GET", "http://127.0.0.1:10767/api/v1/playback/queue",
                { "apptoken": root.apiToken }, null, root.capQueue, root.localTimeoutMs,
                function(queue) {
                    root.queueRequestInFlight = false;
                    if (!queue || !queue.length) return;
                    var newList = [];
                    var limit = Math.min(queue.length, root.maxQueueItems);
                    for (var i = 0; i < limit; i++) {
                        var track = queue[i];
                        if (track && track.attributes) {
                            newList.push({
                                title: root.capString(track.attributes.name || "Desconocido", root.maxFieldChars),
                                artist: root.capString(track.attributes.artistName || "", root.maxFieldChars),
                                id: track.id || "",
                                type: track.type || "song"
                            });
                        }
                    }
                    root.queueData = newList;
                });
        }
    }

    function playNext(trackId, trackType) {
        if (!trackId || !root.apiToken) return;
        root.requestJson("POST", "http://127.0.0.1:10767/api/v1/playback/play-next",
            { "apptoken": root.apiToken, "Content-Type": "application/json" },
            JSON.stringify({ id: trackId, type: trackType }),
            root.capNowPlaying, root.localTimeoutMs, function() {});
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
        root.requestJson("GET", "https://itunes.apple.com/search?term=" + encodeURIComponent(query) + "&entity=song&limit=20&country=" + encodeURIComponent(root.userCountry),
            null, null, root.capSearch, root.remoteTimeoutMs,
            function(data) {
                if (!data || !data.results) { root.searchResults = []; return; }
                var capped = [];
                var limit = Math.min(data.results.length, root.maxSearchResults);
                for (var i = 0; i < limit; i++) {
                    var item = data.results[i];
                    capped.push({
                        trackName: root.capString(item.trackName, root.maxFieldChars),
                        artistName: root.capString(item.artistName, root.maxFieldChars),
                        trackId: item.trackId,
                        artworkUrl100: item.artworkUrl100 || ""
                    });
                }
                root.searchResults = capped;
            });
    }

    function playSearchItem(trackId) {
        if (!root.apiToken) return;
        root.requestJson("POST", "http://127.0.0.1:10767/api/v1/playback/play-next",
            { "apptoken": root.apiToken, "Content-Type": "application/json" },
            JSON.stringify({ id: trackId.toString(), type: "song" }),
            root.capNowPlaying, root.localTimeoutMs,
            function() {
                var timer = Qt.createQmlObject('import QtQml 2.15; Timer { interval: 1500; running: true; onTriggered: { root.nextTrack(); this.destroy(); } }', root);
            });
    }

    function queueSearchItem(trackId) {
        if (!root.apiToken) return;
        root.requestJson("POST", "http://127.0.0.1:10767/api/v1/playback/play-next",
            { "apptoken": root.apiToken, "Content-Type": "application/json" },
            JSON.stringify({ id: trackId.toString(), type: "song" }),
            root.capNowPlaying, root.localTimeoutMs, function() {});
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

    function fetchLyrics(trackKey, title, artist) {
        root.requestJson("GET", "https://lrclib.net/api/get?track_name=" + encodeURIComponent(title) + "&artist_name=" + encodeURIComponent(artist),
            null, null, root.capLyrics, root.remoteTimeoutMs,
            function(ldata) {
                // Ignore a response for a track we've since moved past.
                if (trackKey !== (root.trackTitle + "||" + root.trackArtist)) return;
                if (!ldata) {
                    root.parsedLyrics = [{ time: -1, text: "Lyrics not found." }];
                    return;
                }
                try {
                    var pLyrics = [];
                    if (ldata.syncedLyrics) {
                        var lines = String(ldata.syncedLyrics).split('\n');
                        var lineLimit = Math.min(lines.length, root.maxLyricsLines);
                        for (var i = 0; i < lineLimit; i++) {
                            var line = lines[i];
                            var match = line.match(/^\[(\d+):(\d+\.\d+)\](.*)/);
                            if (match) {
                                var m = parseInt(match[1]);
                                var s = parseFloat(match[2]);
                                var txt = root.capString(match[3].trim(), root.maxLyricsLineChars);
                                if (txt === "") txt = "♪";
                                pLyrics.push({ time: m * 60 + s, text: txt });
                            }
                        }
                    } else if (ldata.plainLyrics) {
                        var plainLines = String(ldata.plainLyrics).split('\n');
                        var plainLimit = Math.min(plainLines.length, root.maxLyricsLines);
                        for (var j = 0; j < plainLimit; j++) {
                            pLyrics.push({ time: -1, text: root.capString(plainLines[j], root.maxLyricsLineChars) });
                        }
                    }

                    if (pLyrics.length === 0) {
                        pLyrics.push({ time: -1, text: "Instrumental / No lyrics available." });
                    }

                    root.parsedLyrics = pLyrics;
                    root.trackLyrics = root.capString(ldata.plainLyrics || "Instrumental / No lyrics available.", root.capLyrics);
                } catch (e) {
                    root.parsedLyrics = [{ time: -1, text: "Error parsing lyrics." }];
                }
            });
    }

    function fetchMetadata() {
        if (!root.apiToken || root.metadataRequestInFlight) return;
        root.metadataRequestInFlight = true;

        root.requestJson("GET", "http://127.0.0.1:10767/api/v1/playback/now-playing",
            { "apptoken": root.apiToken }, null, root.capNowPlaying, root.localTimeoutMs,
            function(data) {
                root.metadataRequestInFlight = false;
                if (!data || !data.info) return;

                root.trackTitle = root.capString(data.info.name || "Unknown", root.maxFieldChars);
                root.trackArtist = root.capString(data.info.artistName || "Cider", root.maxFieldChars);

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
                    var trackKey = root.trackTitle + "||" + root.trackArtist;
                    root.fetchLyrics(trackKey, root.trackTitle, root.trackArtist);
                }
            });
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
        root.requestJson("POST", "http://127.0.0.1:10767/api/v1/playback/queue/change-to-index",
            { "apptoken": root.apiToken, "Content-Type": "application/json" },
            JSON.stringify({ index: index }),
            root.capNowPlaying, root.localTimeoutMs, function() {});
        // Trigger a faster update of the queue
        queueTimer.restart();
    }

    function seek(positionSecs) {
        if (!root.apiToken) return;
        root.lastSeekTime = Date.now();
        root.trackPosition = positionSecs; // Optimistic update
        root.requestJson("POST", "http://127.0.0.1:10767/api/v1/playback/seek",
            { "apptoken": root.apiToken, "Content-Type": "application/json" },
            JSON.stringify({ position: positionSecs }),
            root.capNowPlaying, root.localTimeoutMs, function() {});
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

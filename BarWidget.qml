import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Mpris
import "lib/Playback.js" as Playback
import "lib/Lyrics.js" as Lyrics
import qs.Ui
import qs.Commons

BarWidget {
    id: root
    moduleName: "pwnsxb.apple-music"

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    property bool opened: popup.open

    // Metadata state
    property string trackTitle: "Esperando a Cider..."
    property string trackArtist: "Nadie cantando"
    property string albumArtUrl: ""
    property string apiToken: ""
    property var queueData: []
    property string currentLyricsSong: ""
    property string lyricsSource: ""
    property var parsedLyrics: []
    property int savedTab: 0
    
    // Country for the iTunes search API, derived from the system locale
    // instead of an external IP-geolocation lookup (no extra network call,
    // no IP address leaves the machine for this purpose).
    property string userCountry: {
        var name = String(Qt.locale().name || "");
        var parts = name.split("_");
        var code = parts.length > 1 ? parts[1].toLowerCase() : "";
        return /^[a-z]{2}$/.test(code) ? code : "us";
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

    function launchCider() {
        Quickshell.execDetached(["cider"]);
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

    Timer {
        id: playSearchItemAdvanceTimer
        interval: 1500
        onTriggered: root.nextTrack()
    }

    function playSearchItem(trackId) {
        if (!root.apiToken) return;
        root.requestJson("POST", "http://127.0.0.1:10767/api/v1/playback/play-next",
            { "apptoken": root.apiToken, "Content-Type": "application/json" },
            JSON.stringify({ id: trackId.toString(), type: "song" }),
            root.capNowPlaying, root.localTimeoutMs,
            function() {
                playSearchItemAdvanceTimer.restart();
            });
    }

    function queueSearchItem(trackId) {
        if (!root.apiToken) return;
        root.requestJson("POST", "http://127.0.0.1:10767/api/v1/playback/play-next",
            { "apptoken": root.apiToken, "Content-Type": "application/json" },
            JSON.stringify({ id: trackId.toString(), type: "song" }),
            root.capNowPlaying, root.localTimeoutMs, function() {});
    }

    // MPRIS truth: the player whose Identity is "Cider". Null when Cider
    // publishes no player; the REST polling below is then the fallback.
    property var ciderPlayer: Playback.findCider(Mpris.players ? Mpris.players.values : [])
    readonly property bool hasMpris: ciderPlayer !== null
    property real mprisSampleRaw: -1
    property real mprisSampleMs: 0

    Connections {
        target: Mpris.players
        ignoreUnknownSignals: true
        function onValuesChanged() {
            root.ciderPlayer = Playback.findCider(Mpris.players.values);
        }
    }

    // Re-read the player position; project between its ~0.1 s samples.
    function syncFromMpris(force) {
        var player = root.ciderPlayer;
        if (!player) return;
        // While the user drags the slider the optimistic position wins.
        if (!force && Date.now() - root.lastSeekTime < 600) return;
        root.isPlaying = player.isPlaying === true;
        if (player.positionSupported === false) return;
        player.positionChanged();
        var raw = Number(player.position);
        if (!isFinite(raw) || raw < 0) return;
        var now = Date.now();
        if (force || raw !== root.mprisSampleRaw) {
            root.mprisSampleRaw = raw;
            root.mprisSampleMs = now;
        }
        root.trackPosition = Playback.projectPosition(root.mprisSampleRaw, root.mprisSampleMs,
            now, root.isPlaying, root.trackLength);
    }

    Connections {
        target: root.ciderPlayer
        ignoreUnknownSignals: true
        function onIsPlayingChanged() { root.syncFromMpris(true); }
        function onTrackChanged() { root.syncFromMpris(true); root.onCiderTrackChanged(); }
        function onTrackTitleChanged() { root.onCiderTrackChanged(); }
    }

    // Cider's REST metadata (title, artist, duration) is otherwise only read
    // while the panel is open. A track change refreshes it once; REST can lag
    // the MPRIS signal, so an unchanged answer is retried a few times.
    property bool awaitingTrackChange: false
    property int trackChangeRetries: 0

    function onCiderTrackChanged() {
        root.awaitingTrackChange = true;
        root.trackChangeRetries = 0;
        root.fetchMetadata();
    }

    Timer {
        id: trackChangeRetryTimer
        interval: 800
        repeat: false
        onTriggered: root.fetchMetadata()
    }

    onApiTokenChanged: root.fetchMetadata()

    property bool isPlaying: false
    property real trackPosition: 0
    property real trackLength: 0
    property real lastSeekTime: 0
    property real lastPlaybackTimeCheck: -1

    // -1 before the first synced line or for unsynced lyrics.
    property int currentLyricIndex: -1
    property var lastTimerTick: Date.now()

    Timer {
        id: playbackTimer
        interval: 33
        running: true
        repeat: true
        onTriggered: {
            var now = Date.now();
            var dt = (now - root.lastTimerTick) / 1000.0;
            root.lastTimerTick = now;

            if (root.hasMpris) {
                root.syncFromMpris(false);
            } else if (root.isPlaying) {
                // REST fallback: extrapolate between 1 s polls.
                root.trackPosition += dt;
            }
            
            var idx = Lyrics.findLineIndex(root.parsedLyrics, root.trackPosition, root.currentLyricIndex);
            if (idx !== root.currentLyricIndex) root.currentLyricIndex = idx;
        }
    }

    readonly property string neteaseSearchUrl: "https://music.163.com/api/search/get"
    readonly property string neteaseLyricUrl: "https://music.163.com/api/song/lyric/v1"

    function lyricsStatus(text) {
        return [{ start: -1, end: -1, text: text, words: [] }];
    }

    // True while trackKey still names the playing track (stale-response guard).
    function isCurrentTrack(trackKey) {
        return trackKey === (root.trackTitle + "||" + root.trackArtist);
    }

    function applyLyrics(trackKey, result) {
        if (!root.isCurrentTrack(trackKey)) return;
        root.parsedLyrics = result.lines;
        root.currentLyricIndex = -1;
        root.lyricsSource = result.format;
    }

    // NetEase first (word-timed YRC when available), LRCLIB as the fallback.
    // A song can exist without lyrics (same recording, other release), so the
    // best few ranked candidates are tried in order.
    readonly property int neteaseMaxCandidates: 3

    function fetchLyrics(trackKey, title, artist, durationMs) {
        var query = (title + " " + artist).trim();
        root.requestJson("GET", root.neteaseSearchUrl + "?s=" + encodeURIComponent(query) + "&type=1&limit=10",
            root.neteaseHeaders, null, root.capLyrics, root.remoteTimeoutMs,
            function(sdata) {
                if (!root.isCurrentTrack(trackKey)) return;
                var songs = sdata && sdata.result ? sdata.result.songs : null;
                var ids = Lyrics.rankNeteaseSongs(songs, title, artist, durationMs).slice(0, root.neteaseMaxCandidates);
                root.tryNeteaseCandidates(trackKey, title, artist, durationMs, ids, 0);
            });
    }

    readonly property var neteaseHeaders: ({ "Referer": "https://music.163.com" })

    function tryNeteaseCandidates(trackKey, title, artist, durationMs, ids, i) {
        if (i >= ids.length) { root.fetchLrclib(trackKey, title, artist, durationMs); return; }
        root.requestJson("GET", root.neteaseLyricUrl + "?id=" + encodeURIComponent(ids[i]) + "&lv=1&kv=0&tv=1&yv=1",
            root.neteaseHeaders, null, root.capLyrics, root.remoteTimeoutMs,
            function(ldata) {
                if (!root.isCurrentTrack(trackKey)) return;
                var result = null;
                try { result = Lyrics.neteaseLyrics(ldata, root.trackLength); } catch (e) { result = null; }
                if (result) root.applyLyrics(trackKey, result);
                else root.tryNeteaseCandidates(trackKey, title, artist, durationMs, ids, i + 1);
            });
    }

    function fetchLrclib(trackKey, title, artist, durationMs) {
        var url = "https://lrclib.net/api/get?track_name=" + encodeURIComponent(title) + "&artist_name=" + encodeURIComponent(artist);
        if (durationMs > 0) url += "&duration=" + Math.round(durationMs / 1000);
        root.requestJson("GET", url, null, null, root.capLyrics, root.remoteTimeoutMs,
            function(ldata) {
                if (!root.isCurrentTrack(trackKey)) return;
                var result = null;
                try { result = Lyrics.lrclibLyrics(ldata, root.trackLength); } catch (e) { result = null; }
                if (result) {
                    root.applyLyrics(trackKey, result);
                } else {
                    root.applyLyrics(trackKey, { format: "none", lines: root.lyricsStatus(ldata ? "Instrumental / No lyrics available." : "Lyrics not found.") });
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

                var previousTitle = root.trackTitle;
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

                // Duration always comes from REST (MPRIS length is unreliable).
                if (Date.now() - root.lastSeekTime > 2000) {
                    root.trackLength = isNaN(len) ? 0 : len;
                }

                if (!root.hasMpris) {
                    // Fallback without an MPRIS player: REST position, and a
                    // play state guessed from whether the position advances.
                    if (Date.now() - root.lastSeekTime > 2000) {
                        var newPos = isNaN(pos) ? 0 : pos;
                        if (Math.abs(root.trackPosition - newPos) > 0.5) {
                            root.trackPosition = newPos;
                        }
                    }
                    if (root.lastPlaybackTimeCheck !== -1) {
                        root.isPlaying = Math.abs(pos - root.lastPlaybackTimeCheck) > 0.05;
                    } else {
                        root.isPlaying = pos > 0;
                    }
                    root.lastPlaybackTimeCheck = pos;
                }

                var trackKey = root.trackTitle + "||" + root.trackArtist;
                if (trackKey !== root.currentLyricsSong && root.trackTitle !== "Waiting for Cider..." && root.trackTitle !== "Unknown") {
                    root.currentLyricsSong = trackKey;
                    root.lyricsSource = "";
                    root.currentLyricIndex = -1;
                    root.parsedLyrics = root.lyricsStatus("Loading lyrics...");
                    root.fetchLyrics(trackKey, root.trackTitle, root.trackArtist, data.info.durationInMillis || 0);
                }

                // The REST answer can still describe the previous track right
                // after an MPRIS track change; ask again shortly.
                if (root.awaitingTrackChange) {
                    if (root.trackTitle === previousTitle && root.trackChangeRetries < 3) {
                        root.trackChangeRetries++;
                        trackChangeRetryTimer.restart();
                    } else {
                        root.awaitingTrackChange = false;
                    }
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
    Process { id: procPlayPause; command: ["timeout", "-k", "1", "3", "playerctl", "play-pause"] }
    Process { id: procNext; command: ["timeout", "-k", "1", "3", "playerctl", "next"] }
    Process { id: procPrev; command: ["timeout", "-k", "1", "3", "playerctl", "previous"] }


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
        root.lastSeekTime = Date.now();
        root.trackPosition = positionSecs; // Optimistic update
        var player = root.ciderPlayer;
        if (player && player.canSeek === true && player.positionSupported !== false) {
            player.position = positionSecs;
            root.syncFromMpris(true); // re-read right after the seek
            return;
        }
        if (!root.apiToken) return;
        root.requestJson("POST", "http://127.0.0.1:10767/api/v1/playback/seek",
            { "apptoken": root.apiToken, "Content-Type": "application/json" },
            JSON.stringify({ position: positionSecs }),
            root.capNowPlaying, root.localTimeoutMs, function() {});
    }

    function toggle() {
        popup.open = !popup.open;
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\uf001" // fa-music
        tooltipText: "Cider (Apple Music)"
        active: root.opened

        onPressed: function(mouse) {
            if (mouse === Qt.RightButton || mouse === Qt.MiddleButton) {
                root.launchCider();
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

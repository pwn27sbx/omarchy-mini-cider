.pragma library

// Pure playback helpers. Position and play state come from the MPRIS player
// whose Identity is "Cider"; Cider's bus name is a Chromium instance name
// (org.mpris.MediaPlayer2.chromium.instance<pid>), so it is never matched.

// Pick the Cider player from a list of MPRIS players (by identity only).
// If several instances match, prefer the one that is playing.
function findCider(players) {
    if (!players || !players.length) return null
    var first = null
    for (var i = 0; i < players.length; i++) {
        var p = players[i]
        if (!p || p.identity !== "Cider") continue
        if (p.isPlaying === true) return p
        if (first === null) first = p
    }
    return first
}

// Floor at 0, cap at length when known (length <= 0 means unknown).
function clampPosition(pos, length) {
    var n = Number(pos)
    if (!isFinite(n) || n < 0) return 0
    if (length > 0 && n > length) return length
    return n
}

// Project the last sampled position forward by wall-clock time while playing.
function projectPosition(samplePos, sampleMs, nowMs, playing, length) {
    var elapsed = playing ? Math.max(0, (nowMs - sampleMs) / 1000) : 0
    return clampPosition(samplePos + elapsed, length)
}

// Identity of a track as MPRIS reports it; "" while there is no title (a
// transient state between tracks).
function trackKey(title, artist) {
    var t = String(title === undefined || title === null ? "" : title).trim().toLowerCase();
    if (t === "") return "";
    var a = String(artist === undefined || artist === null ? "" : artist).trim().toLowerCase();
    return t + "||" + a;
}

// MPRIS is authoritative for which track is playing; Cider's REST answer only
// enriches it (artwork, duration) and can lag behind. "retry" while REST does
// not describe the MPRIS track yet (or MPRIS has no title), until maxRetries
// is spent, after which REST is taken as-is. Without MPRIS there is nothing to
// compare against.
function metadataAction(mprisTitle, restTitle, retries, maxRetries) {
    if (mprisTitle === null || mprisTitle === undefined) return "apply";
    var m = String(mprisTitle).trim().toLowerCase();
    var r = String(restTitle === undefined || restTitle === null ? "" : restTitle).trim().toLowerCase();
    if (m !== "" && m === r) return "apply";
    return retries >= maxRetries ? "apply" : "retry";
}

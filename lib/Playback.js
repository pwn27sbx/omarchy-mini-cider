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

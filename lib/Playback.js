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
// correction (seconds, default 0) is the measured amount by which the sample
// clock runs behind the player, see probeCorrection.
function projectPosition(samplePos, sampleMs, nowMs, playing, length, correction) {
    var elapsed = playing ? Math.max(0, (nowMs - sampleMs) / 1000) : 0;
    var c = isFinite(correction) ? correction : 0;
    return clampPosition(samplePos + elapsed + c, length);
}

// Quickshell anchors its position clock on one D-Bus read and extrapolates from
// it, so the clock trails the player by an amount that is random per anchor
// (measured 0.0-0.2 s). A probe (a fresh read of the player's Position taken
// at probeTime) tells how far behind the clock is at that moment.
function probeCorrection(clockPos, probePos) {
    var c = Number(clockPos), p = Number(probePos);
    if (clockPos === undefined || clockPos === null || probePos === undefined || probePos === null) return 0;
    if (!isFinite(c) || !isFinite(p)) return 0;
    return p - c;
}

var MAX_LAG_CORRECTION_S = 0.5;

// The player's Position property steps every ~0.1 s, so a probe is stale by
// 0..0.1 s and the largest probe is the closest to the truth. Values beyond
// MAX_LAG_CORRECTION_S are a different problem (restBias), not lag.
function bestCorrection(corrections) {
    if (!corrections || !corrections.length) return 0;
    var best = null;
    for (var i = 0; i < corrections.length; i++) {
        var c = corrections[i];
        if (!isFinite(c) || Math.abs(c) > MAX_LAG_CORRECTION_S) continue;
        if (best === null || c > best) best = c;
    }
    return best === null ? 0 : best;
}

var REST_BIAS_THRESHOLD_S = 3;

// Cider's MPRIS Position can stay offset from the real track position (seen
// after an automatic track change: +218 s). REST's currentPlaybackTime is the
// reference; returns the amount to add to MPRIS, or 0 when they agree within
// REST_BIAS_THRESHOLD_S (REST itself is up to ~1 s old).
function restBias(mprisPos, restPos) {
    var m = Number(mprisPos), r = Number(restPos);
    if (mprisPos === undefined || mprisPos === null || restPos === undefined || restPos === null) return 0;
    if (!isFinite(m) || !isFinite(r)) return 0;
    var d = r - m;
    return Math.abs(d) > REST_BIAS_THRESHOLD_S ? d : 0;
}

// "chromium.instance314583" from "org.mpris.MediaPlayer2.chromium.instance314583",
// for playerctl -p. Anything that could be read as an option or contains
// unusual characters yields null.
function playerctlName(dbusName) {
    var m = /^org\.mpris\.MediaPlayer2\.([A-Za-z0-9_][A-Za-z0-9_.-]{0,99})$/.exec(String(dbusName === undefined || dbusName === null ? "" : dbusName));
    return m ? m[1] : null;
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

.pragma library

// Pure lyrics model: parsers, line lookup and word projection. Times are in
// seconds. A line is {start, end, text, words: [{start, end, text}]}; lines
// without word timing carry words: []. Lines with start < 0 are unsynced
// (plain lyrics or a status message) and are never matched by findLineIndex.

var MAX_LINES = 2000;
var MAX_LINE_CHARS = 300;
var DEFAULT_LAST_LINE_SECONDS = 5;
var BLANK_LINE = "♪";

function clamp01(v) {
    return v < 0 ? 0 : (v > 1 ? 1 : v);
}

function isFiniteNumber(v) {
    return typeof v === "number" && isFinite(v);
}

// Build a line; an oversized text is truncated and loses its word timing,
// because truncated words would no longer concatenate to the line text.
function makeLine(start, end, text, words) {
    if (text.length > MAX_LINE_CHARS) {
        text = text.substring(0, MAX_LINE_CHARS);
        words = [];
    }
    return { start: start, end: Math.max(start, end), text: text, words: words || [] };
}

function sortByStart(entries) {
    var indexed = entries.map(function(e, i) { return { e: e, i: i }; });
    indexed.sort(function(a, b) { return a.e.start - b.e.start || a.i - b.i; });
    return indexed.map(function(x) { return x.e; });
}

// NetEase YRC: [lineStartMs,lineDurMs](wordStartMs,wordDurMs,0)word...
// Word starts are absolute song time in milliseconds. JSON metadata lines
// ({"t":..}) and lines without text are skipped.
function parseYrc(text) {
    var out = [];
    if (typeof text !== "string" || text === "") return out;
    var raw = text.split(/\r?\n/);
    for (var i = 0; i < raw.length && out.length < MAX_LINES; i++) {
        var head = /^\[(\d{1,8}),(\d{1,8})\]/.exec(raw[i]);
        if (!head) continue;
        var start = parseInt(head[1], 10) / 1000;
        var end = (parseInt(head[1], 10) + parseInt(head[2], 10)) / 1000;
        var re = /\((\d{1,8}),(\d{1,8}),\d+\)([^(]*)/g;
        var words = [];
        var full = "";
        var m;
        while ((m = re.exec(raw[i])) !== null) {
            var ws = parseInt(m[1], 10) / 1000;
            words.push({ start: ws, end: ws + parseInt(m[2], 10) / 1000, text: m[3] });
            full += m[3];
        }
        if (words.length === 0 || full.trim() === "") continue;
        out.push(makeLine(start, end, full, words));
    }
    return sortByStart(out);
}

function tagSeconds(min, sec, frac) {
    var ms = frac ? parseInt((frac + "000").substring(0, 3), 10) : 0;
    return parseInt(min, 10) * 60 + parseInt(sec, 10) + ms / 1000;
}

// Enhanced LRC body: <mm:ss.xx>word segments. Each word ends where the next
// tag starts, the last one at the line end. Untagged text before the first
// tag starts with the line.
function lrcWords(content, lineStart, lineEnd) {
    var re = /<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>/g;
    var segs = [];
    var last = 0;
    var m;
    while ((m = re.exec(content)) !== null) {
        if (segs.length === 0 && m.index > 0) segs.push({ start: lineStart, text: content.substring(0, m.index) });
        else if (segs.length > 0) segs[segs.length - 1].text = content.substring(last, m.index);
        segs.push({ start: tagSeconds(m[1], m[2], m[3]), text: "" });
        last = re.lastIndex;
    }
    if (segs.length === 0) return null;
    segs[segs.length - 1].text = content.substring(last);

    var first = -1, lastText = -1;
    for (var i = 0; i < segs.length; i++) {
        if (segs[i].text.trim() !== "") { if (first < 0) first = i; lastText = i; }
    }
    if (first < 0) return { text: "", words: [] };
    segs[first].text = segs[first].text.replace(/^\s+/, "");
    segs[lastText].text = segs[lastText].text.replace(/\s+$/, "");

    var words = [];
    var full = "";
    for (var j = 0; j < segs.length; j++) {
        if (segs[j].text === "") continue;
        var next = j + 1 < segs.length ? segs[j + 1].start : lineEnd;
        words.push({ start: segs[j].start, end: Math.max(segs[j].start, Math.min(lineEnd, next)), text: segs[j].text });
        full += segs[j].text;
    }
    return { text: full, words: words };
}

// Standard or enhanced LRC. A line ends where the next one starts; the last
// line ends at trackLength when it is known and later than the line start,
// otherwise a few seconds after it.
function parseLrc(text, trackLength) {
    if (typeof text !== "string" || text === "") return [];
    var entries = [];
    var raw = text.split(/\r?\n/);
    for (var i = 0; i < raw.length && entries.length < MAX_LINES; i++) {
        var lead = /^(?:\s*\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\])+/.exec(raw[i]);
        if (!lead) continue;
        var content = raw[i].substring(lead[0].length).trim();
        var tagRe = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
        var t;
        while ((t = tagRe.exec(lead[0])) !== null && entries.length < MAX_LINES) {
            entries.push({ start: tagSeconds(t[1], t[2], t[3]), content: content });
        }
    }
    entries = sortByStart(entries);
    var out = [];
    for (var k = 0; k < entries.length; k++) {
        var s = entries[k].start;
        var end;
        if (k + 1 < entries.length) end = entries[k + 1].start;
        else end = trackLength > s ? trackLength : s + DEFAULT_LAST_LINE_SECONDS;
        var parsed = lrcWords(entries[k].content, s, end);
        var lineText = parsed ? parsed.text : entries[k].content;
        var words = parsed ? parsed.words : [];
        if (lineText === "") { lineText = BLANK_LINE; words = []; }
        out.push(makeLine(s, end, lineText, words));
    }
    return out;
}

// Plain (unsynced) lyrics: one line per row, start/end = -1.
function plainLines(text) {
    if (typeof text !== "string") return [];
    var rows = text.split(/\r?\n/);
    var out = [];
    for (var i = 0; i < rows.length && out.length < MAX_LINES; i++) {
        out.push({ start: -1, end: -1, text: rows[i].substring(0, MAX_LINE_CHARS), words: [] });
    }
    return out;
}

// Index of the last line starting at or before pos, -1 before the first
// line or when the lines are unsynced. hint (the previous result) makes the
// steady-state lookup O(1); a wrong hint still gives the right answer.
function findLineIndex(lines, pos, hint) {
    if (!lines || !lines.length || !isFiniteNumber(pos)) return -1;
    if (!(lines[0].start >= 0) || pos < lines[0].start) return -1;
    if (isFiniteNumber(hint) && Math.floor(hint) === hint && hint >= 0 && hint < lines.length) {
        var i = hint;
        if (pos >= lines[i].start) {
            while (i + 1 < lines.length && lines[i + 1].start <= pos) i++;
            return i;
        }
        while (i > 0 && lines[i].start > pos) i--;
        return lines[i].start <= pos ? i : -1;
    }
    var lo = 0, hi = lines.length - 1, res = -1;
    while (lo <= hi) {
        var mid = Math.floor((lo + hi) / 2);
        if (lines[mid].start <= pos) { res = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return res;
}

function spanProgress(start, end, pos) {
    if (end > start) return clamp01((pos - start) / (end - start));
    return pos >= end ? 1 : 0;
}

// Fill state of one line at pos. words[i].progress: sung 1, active fraction,
// upcoming 0. The line is also split as sungText + activeText + restText
// with the active word's progress, so a renderer only needs three widths.
// Lines without words are one active "word" with the line-level progress.
function projectLine(line, pos) {
    var empty = { hasWords: false, text: "", progress: 0, words: [], activeIndex: 0,
                  activeProgress: 0, sungText: "", activeText: "", restText: "" };
    if (!line || typeof line.text !== "string") return empty;
    var p = isFiniteNumber(pos) ? pos : line.start;
    var progress = spanProgress(line.start, line.end, p);
    var words = line.words || [];
    if (words.length === 0) {
        empty.text = line.text;
        empty.progress = progress;
        empty.activeProgress = progress;
        empty.activeText = line.text;
        return empty;
    }
    var out = [];
    var active = words.length - 1;
    var found = false;
    for (var i = 0; i < words.length; i++) {
        var wp = spanProgress(words[i].start, words[i].end, p);
        out.push({ text: words[i].text, progress: wp });
        if (!found && wp < 1) { active = i; found = true; }
    }
    var sung = "", rest = "";
    for (var a = 0; a < active; a++) sung += words[a].text;
    for (var b = active + 1; b < words.length; b++) rest += words[b].text;
    return { hasWords: true, text: line.text, progress: progress, words: out, activeIndex: active,
             activeProgress: out[active].progress, sungText: sung, activeText: words[active].text, restText: rest };
}

function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// StyledText for lines too wide for the clipped fill (they wrap): words that
// have started are coloured sung, the rest upcoming.
function styledLine(proj, sungColor, restColor) {
    if (!proj.hasWords) return "<font color=\"" + restColor + "\">" + escapeHtml(proj.text) + "</font>";
    var html = "";
    for (var i = 0; i < proj.words.length; i++) {
        var color = proj.words[i].progress > 0 ? sungColor : restColor;
        html += "<font color=\"" + color + "\">" + escapeHtml(proj.words[i].text) + "</font>";
    }
    return html;
}

function normalize(s) {
    return String(s === undefined || s === null ? "" : s).toLowerCase().replace(/[\s!-\/:-@\[-`{-~]+/g, "");
}

function artistsOverlap(songArtists, artist) {
    var wanted = String(artist || "").split(/[\/,&;]|\bfeat\.?\b/i).map(normalize).filter(function(x) { return x !== ""; });
    for (var i = 0; i < songArtists.length; i++) {
        var name = normalize(songArtists[i] && songArtists[i].name);
        if (name === "") continue;
        for (var j = 0; j < wanted.length; j++) {
            if (name.indexOf(wanted[j]) !== -1 || wanted[j].indexOf(name) !== -1) return true;
        }
    }
    return false;
}

// Pick the NetEase song id for a track from search results. A candidate needs
// a related title plus either an exact title or an artist overlap, and must
// be within ~8 s of durationMs when that is known. Best score wins, then the
// closest duration. Returns null when nothing qualifies.
function pickNeteaseSong(songs, title, artist, durationMs) {
    if (!songs || !songs.length) return null;
    var wantTitle = normalize(title);
    if (wantTitle === "") return null;
    var best = null;
    for (var i = 0; i < songs.length; i++) {
        var s = songs[i];
        if (!s || s.id === undefined || s.id === null) continue;
        var delta = 0;
        if (durationMs > 0) {
            if (!isFiniteNumber(s.duration)) continue;
            delta = Math.abs(s.duration - durationMs);
            if (delta > 8000) continue;
        }
        var name = normalize(s.name);
        if (name === "" || (name.indexOf(wantTitle) === -1 && wantTitle.indexOf(name) === -1)) continue;
        var exact = name === wantTitle;
        var overlap = artistsOverlap(s.artists || [], artist);
        if (!exact && !overlap) continue;
        var score = (exact ? 4 : 0) + (overlap ? 2 : 0);
        if (best === null || score > best.score || (score === best.score && delta < best.delta)) {
            best = { id: s.id, score: score, delta: delta };
        }
    }
    return best ? best.id : null;
}

// NetEase lyric response: word-timed YRC first, its LRC otherwise.
function neteaseLyrics(data, trackLength) {
    if (!data || typeof data !== "object") return null;
    var yrc = data.yrc && data.yrc.lyric ? parseYrc(data.yrc.lyric) : [];
    if (yrc.length > 0) return { format: "yrc", lines: yrc };
    var lrc = data.lrc && data.lrc.lyric ? parseLrc(data.lrc.lyric, trackLength) : [];
    if (lrc.length > 0) return { format: "lrc", lines: lrc };
    return null;
}

// LRCLIB /api/get response: synced lyrics, else plain, else null.
function lrclibLyrics(data, trackLength) {
    if (!data || typeof data !== "object") return null;
    var synced = data.syncedLyrics ? parseLrc(String(data.syncedLyrics), trackLength) : [];
    if (synced.length > 0) return { format: "lrclib", lines: synced };
    var plain = data.plainLyrics ? plainLines(String(data.plainLyrics)) : [];
    if (plain.length > 0) return { format: "lrclib-plain", lines: plain };
    return null;
}

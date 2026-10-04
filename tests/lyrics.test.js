// Run: node tests/lyrics.test.js
const fs = require("fs")
const path = require("path")
const assert = require("assert")

function load(file) {
  const src = fs.readFileSync(path.join(__dirname, "..", "lib", file), "utf8").replace(/^\.pragma library\s*/m, "")
  // Top-level functions of a .pragma library file become the module API.
  const names = [...src.matchAll(/^function\s+(\w+)/gm)].map(m => m[1])
  return new Function(src + "\nreturn {" + names.join(",") + "}")()
}

let failed = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message) }
}

const P = load("Playback.js")

test("findCider matches by identity, not bus name", () => {
  const a = { identity: "Spotify", dbusName: "org.mpris.MediaPlayer2.spotify" }
  const b = { identity: "Cider", dbusName: "org.mpris.MediaPlayer2.chromium.instance1234" }
  assert.strictEqual(P.findCider([a, b]), b)
})

test("findCider returns null when absent or input invalid", () => {
  assert.strictEqual(P.findCider([{ identity: "Spotify" }]), null)
  assert.strictEqual(P.findCider([]), null)
  assert.strictEqual(P.findCider(null), null)
  assert.strictEqual(P.findCider(undefined), null)
})

test("findCider ignores a bus name that merely looks like Cider", () => {
  assert.strictEqual(P.findCider([{ identity: "Chromium", dbusName: "org.mpris.MediaPlayer2.Cider" }]), null)
})

test("findCider prefers the playing instance when several match", () => {
  const idle = { identity: "Cider", isPlaying: false }
  const live = { identity: "Cider", isPlaying: true }
  assert.strictEqual(P.findCider([idle, live]), live)
})

test("clampPosition floors at 0 and caps at length when known", () => {
  assert.strictEqual(P.clampPosition(-1, 200), 0)
  assert.strictEqual(P.clampPosition(250, 200), 200)
  assert.strictEqual(P.clampPosition(50, 200), 50)
})

test("clampPosition without length only floors at 0", () => {
  assert.strictEqual(P.clampPosition(999, 0), 999)
  assert.strictEqual(P.clampPosition(-5, 0), 0)
})

test("clampPosition rejects non-finite values", () => {
  assert.strictEqual(P.clampPosition(NaN, 100), 0)
  assert.strictEqual(P.clampPosition(Infinity, 0), 0)
  assert.strictEqual(P.clampPosition(undefined, 100), 0)
})

test("projectPosition advances by elapsed seconds from the last sample", () => {
  assert.strictEqual(P.projectPosition(10, 1000, 1500, true, 0), 10.5)
})

test("projectPosition holds when paused", () => {
  assert.strictEqual(P.projectPosition(10, 1000, 1500, false, 0), 10)
})

test("projectPosition never goes backwards in time and clamps to length", () => {
  assert.strictEqual(P.projectPosition(10, 2000, 1000, true, 0), 10)
  assert.strictEqual(P.projectPosition(199.9, 0, 1000, true, 200), 200)
})


// ---- Lyrics model ----------------------------------------------------------

const L = load("Lyrics.js")
const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, a + " != " + b)

const YRC = [
  '{"t":0,"c":[{"tx":"Composer: "},{"tx":"Someone"}]}',
  '[1000,2000](1000,500,0)Hel(1500,500,0)lo (2000,1000,0)world',
  '[3500,1500](3500,700,0)Good(4200,800,0) bye',
  ''
].join("\n")

test("parseYrc reads absolute word times and skips JSON metadata", () => {
  const lines = L.parseYrc(YRC)
  assert.strictEqual(lines.length, 2)
  near(lines[0].start, 1); near(lines[0].end, 3)
  assert.strictEqual(lines[0].text, "Hello world")
  assert.deepStrictEqual(lines[0].words.map(w => w.text), ["Hel", "lo ", "world"])
  near(lines[0].words[1].start, 1.5); near(lines[0].words[1].end, 2)
  near(lines[0].words[2].start, 2); near(lines[0].words[2].end, 3)
  assert.strictEqual(lines[1].text, "Good bye")
})

test("parseYrc orders lines by start and drops lines without text", () => {
  const lines = L.parseYrc("[5000,1000](5000,1000,0)B\n[1000,1000](1000,1000,0)A\n[9000,500](9000,500,0) ")
  assert.deepStrictEqual(lines.map(l => l.text), ["A", "B"])
})

test("parseYrc returns [] for empty or junk input", () => {
  assert.deepStrictEqual(L.parseYrc(""), [])
  assert.deepStrictEqual(L.parseYrc(null), [])
  assert.deepStrictEqual(L.parseYrc("not lyrics"), [])
})

test("parseLrc reads plain lines with end = next start", () => {
  const lines = L.parseLrc("[ar:x]\n[00:01.50]First\n[00:04.00]Second\n[01:02.25]Third")
  assert.strictEqual(lines.length, 3)
  near(lines[0].start, 1.5); near(lines[0].end, 4)
  near(lines[2].start, 62.25)
  assert.deepStrictEqual(lines[0].words, [])
  assert.strictEqual(lines[1].text, "Second")
})

test("parseLrc last line ends at track length when known, else start + 5", () => {
  near(L.parseLrc("[00:10.00]A", 0)[0].end, 15)
  near(L.parseLrc("[00:10.00]A", 40)[0].end, 40)
  near(L.parseLrc("[00:10.00]A", 8)[0].end, 15)
})

test("parseLrc supports repeated tags, blank lines and out-of-order input", () => {
  const lines = L.parseLrc("[00:20.00]B\n[00:05.00][00:30.00]A\n[00:12.00]")
  assert.deepStrictEqual(lines.map(l => l.text), ["A", "♪", "B", "A"])
  assert.deepStrictEqual(lines.map(l => l.start), [5, 12, 20, 30])
})

test("parseLrc reads enhanced word tags; word end = next word start or line end", () => {
  const lines = L.parseLrc("[00:10.00]<00:10.00>Hel<00:10.40>lo <00:11.00>you\n[00:12.00]next")
  const w = lines[0].words
  assert.strictEqual(lines[0].text, "Hello you")
  assert.deepStrictEqual(w.map(x => x.text), ["Hel", "lo ", "you"])
  near(w[0].start, 10); near(w[0].end, 10.4)
  near(w[1].start, 10.4); near(w[1].end, 11)
  near(w[2].start, 11); near(w[2].end, 12)
  assert.deepStrictEqual(lines[1].words, [])
})

test("parseLrc times untagged text before the first word tag from the line start", () => {
  const w = L.parseLrc("[00:10.00]Oh <00:10.50>yeah\n[00:12.00]x")[0].words
  assert.deepStrictEqual(w.map(x => x.text), ["Oh ", "yeah"])
  near(w[0].start, 10); near(w[0].end, 10.5)
})

test("parseLrc caps line count and drops words on oversized text", () => {
  let big = ""
  for (let i = 0; i < 2100; i++) big += "[" + String(Math.floor(i / 60)).padStart(2, "0") + ":" + String(i % 60).padStart(2, "0") + ".00]x\n"
  assert.strictEqual(L.parseLrc(big).length, 2000)
  const long = L.parseLrc("[00:01.00]<00:01.00>" + "a".repeat(400))[0]
  assert.strictEqual(long.text.length, 300)
  assert.deepStrictEqual(long.words, [])
})

const LINES = [{ start: 1 }, { start: 4 }, { start: 8 }, { start: 12 }]

test("findLineIndex returns -1 before the first line and for bad input", () => {
  assert.strictEqual(L.findLineIndex(LINES, 0.5), -1)
  assert.strictEqual(L.findLineIndex([], 3), -1)
  assert.strictEqual(L.findLineIndex(null, 3), -1)
  assert.strictEqual(L.findLineIndex(LINES, NaN), -1)
  assert.strictEqual(L.findLineIndex([{ start: -1 }], 3), -1)
})

test("findLineIndex finds the last line starting at or before pos", () => {
  assert.strictEqual(L.findLineIndex(LINES, 1), 0)
  assert.strictEqual(L.findLineIndex(LINES, 7.99), 1)
  assert.strictEqual(L.findLineIndex(LINES, 8), 2)
  assert.strictEqual(L.findLineIndex(LINES, 999), 3)
})

test("findLineIndex uses the hint forward and survives a backward jump", () => {
  assert.strictEqual(L.findLineIndex(LINES, 9, 1), 2)
  assert.strictEqual(L.findLineIndex(LINES, 13, 0), 3)
  assert.strictEqual(L.findLineIndex(LINES, 2, 3), 0)
  assert.strictEqual(L.findLineIndex(LINES, 0.2, 3), -1)
  assert.strictEqual(L.findLineIndex(LINES, 9, 99), 2)
  assert.strictEqual(L.findLineIndex(LINES, 9, -3), 2)
})

const WORDLINE = {
  start: 10, end: 14, text: "ab cd ef",
  words: [{ start: 10, end: 11, text: "ab " }, { start: 11, end: 13, text: "cd " }, { start: 13.5, end: 14, text: "ef" }]
}

test("projectLine: before the line nothing is sung", () => {
  const p = L.projectLine(WORDLINE, 9)
  assert.strictEqual(p.hasWords, true)
  assert.deepStrictEqual(p.words.map(w => w.progress), [0, 0, 0])
  assert.strictEqual(p.sungText, ""); assert.strictEqual(p.activeText, "ab ")
  assert.strictEqual(p.activeProgress, 0); assert.strictEqual(p.restText, "cd ef")
})

test("projectLine: mid word gives sung 1, active fraction, upcoming 0", () => {
  const p = L.projectLine(WORDLINE, 12)
  assert.deepStrictEqual(p.words.map(w => w.progress), [1, 0.5, 0])
  assert.strictEqual(p.activeIndex, 1)
  assert.strictEqual(p.sungText, "ab "); assert.strictEqual(p.activeText, "cd ")
  assert.strictEqual(p.restText, "ef"); near(p.activeProgress, 0.5)
})

test("projectLine: word boundaries and gaps between words", () => {
  assert.strictEqual(L.projectLine(WORDLINE, 11).words[0].progress, 1)
  assert.strictEqual(L.projectLine(WORDLINE, 11).words[1].progress, 0)
  const gap = L.projectLine(WORDLINE, 13.2)
  assert.deepStrictEqual(gap.words.map(w => w.progress), [1, 1, 0])
  assert.strictEqual(gap.activeIndex, 2); assert.strictEqual(gap.activeProgress, 0)
})

test("projectLine: after the line everything is sung and the last word is active", () => {
  const p = L.projectLine(WORDLINE, 99)
  assert.deepStrictEqual(p.words.map(w => w.progress), [1, 1, 1])
  assert.strictEqual(p.activeIndex, 2); assert.strictEqual(p.activeProgress, 1)
  assert.strictEqual(p.sungText, "ab cd "); assert.strictEqual(p.restText, "")
  assert.strictEqual(p.progress, 1)
})

test("projectLine: zero-length words are binary", () => {
  const line = { start: 0, end: 2, text: "ab", words: [{ start: 1, end: 1, text: "ab" }] }
  assert.strictEqual(L.projectLine(line, 0.9).words[0].progress, 0)
  assert.strictEqual(L.projectLine(line, 1).words[0].progress, 1)
})

test("projectLine: line without words fills at line level", () => {
  const line = { start: 4, end: 8, text: "plain", words: [] }
  let p = L.projectLine(line, 6)
  assert.strictEqual(p.hasWords, false)
  near(p.progress, 0.5); near(p.activeProgress, 0.5)
  assert.strictEqual(p.sungText, ""); assert.strictEqual(p.activeText, "plain")
  assert.strictEqual(L.projectLine(line, 1).progress, 0)
  assert.strictEqual(L.projectLine(line, 20).progress, 1)
  assert.strictEqual(L.projectLine({ start: 4, end: 4, text: "x", words: [] }, 4).progress, 1)
})

test("projectLine tolerates missing input", () => {
  const p = L.projectLine(null, 3)
  assert.strictEqual(p.hasWords, false); assert.strictEqual(p.activeText, "")
})

test("styledLine colours sung and active words and escapes markup", () => {
  const line = { start: 0, end: 2, text: "a<b c", words: [{ start: 0, end: 1, text: "a<b " }, { start: 1, end: 2, text: "c" }] }
  const html = L.styledLine(L.projectLine(line, 1.5), "#f00", "#888")
  assert.strictEqual(html, '<font color="#f00">a&lt;b </font><font color="#f00">c</font>')
  const before = L.styledLine(L.projectLine(line, 0.5), "#f00", "#888")
  assert.strictEqual(before, '<font color="#f00">a&lt;b </font><font color="#888">c</font>')
})

const NE = [
  { id: 1, name: "Hello (Live)", artists: [{ name: "Other" }], duration: 300000 },
  { id: 2, name: "Hello", artists: [{ name: "Adele" }], duration: 295000 },
  { id: 3, name: "Hello", artists: [{ name: "Adele" }], duration: 330000 }
]

test("pickNeteaseSong prefers title and artist match inside the duration window", () => {
  assert.strictEqual(L.pickNeteaseSong(NE, "Hello", "Adele", 296000), 2)
})

test("pickNeteaseSong rejects candidates beyond ~8 s and unrelated titles", () => {
  assert.strictEqual(L.pickNeteaseSong(NE, "Hello", "Adele", 310000), null)
  assert.strictEqual(L.pickNeteaseSong(NE, "Goodbye", "Adele", 295000), null)
})

test("pickNeteaseSong ignores duration when unknown and tolerates bad input", () => {
  assert.strictEqual(L.pickNeteaseSong(NE, "Hello", "Adele", 0), 2)
  assert.strictEqual(L.pickNeteaseSong(null, "Hello", "Adele", 0), null)
  assert.strictEqual(L.pickNeteaseSong([{ name: "Hello" }], "Hello", "", 0), null)
})

test("rankNeteaseSongs lists every qualifying song, best first", () => {
  const songs = NE.concat([{ id: 4, name: "Hello", artists: [{ name: "Adele" }], duration: 292000 }])
  assert.deepStrictEqual(L.rankNeteaseSongs(songs, "Hello", "Adele", 296000), [2, 4])
  assert.deepStrictEqual(L.rankNeteaseSongs(songs, "Nope", "Adele", 296000), [])
  assert.deepStrictEqual(L.rankNeteaseSongs(null, "Hello", "Adele", 0), [])
})

test("neteaseLyrics prefers YRC over LRC and falls back to LRC", () => {
  const both = L.neteaseLyrics({ yrc: { lyric: YRC }, lrc: { lyric: "[00:01.00]x" } }, 0)
  assert.strictEqual(both.format, "yrc"); assert.strictEqual(both.lines.length, 2)
  const lrc = L.neteaseLyrics({ yrc: { lyric: "" }, lrc: { lyric: "[00:01.00]x" } }, 0)
  assert.strictEqual(lrc.format, "lrc"); assert.strictEqual(lrc.lines.length, 1)
  assert.strictEqual(L.neteaseLyrics({}, 0), null)
  assert.strictEqual(L.neteaseLyrics(null, 0), null)
})

test("lrclibLyrics prefers synced lyrics, then plain, then null", () => {
  const synced = L.lrclibLyrics({ syncedLyrics: "[00:01.00]a", plainLyrics: "a" }, 0)
  assert.strictEqual(synced.format, "lrclib"); assert.strictEqual(synced.lines[0].start, 1)
  const plain = L.lrclibLyrics({ plainLyrics: "a\nb" }, 0)
  assert.strictEqual(plain.format, "lrclib-plain"); assert.deepStrictEqual(plain.lines.map(l => l.start), [-1, -1])
  assert.strictEqual(L.lrclibLyrics({}, 0), null)
  assert.strictEqual(L.lrclibLyrics(null, 0), null)
})

if (failed) { console.log(failed + " failed"); process.exit(1) }
console.log("all passed")

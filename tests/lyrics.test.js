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

if (failed) { console.log(failed + " failed"); process.exit(1) }
console.log("all passed")

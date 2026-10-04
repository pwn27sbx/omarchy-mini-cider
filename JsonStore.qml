import QtQuick
import Quickshell.Io
import "lib/Lyrics.js" as Lyrics

// A small persistent key/value store backed by helpers/json_store.py (the
// helper owns the path and the file safety; this item only moves JSON over
// stdin/stdout). entries is {key: {v, t}}; it is loaded once at startup and
// merged beneath whatever was stored meanwhile, then rewritten on every change.
Item {
    id: store

    property string name: ""
    property string helperPath: ""
    property int cap: 500
    property var entries: ({})
    property bool loaded: false

    // The helper refuses payloads over 16 MiB; stay below it.
    readonly property int maxPayloadChars: 15 * 1024 * 1024
    property bool dirty: false

    function get(key) {
        return Lyrics.getEntry(store.entries, key);
    }

    function put(key, value) {
        store.entries = Lyrics.putEntry(store.entries, key, value, Date.now(), store.cap);
        store.save();
    }

    function remove(key) {
        store.entries = Lyrics.removeEntry(store.entries, key);
        store.save();
    }

    function save() {
        if (writer.running) { store.dirty = true; return; }
        var payload = JSON.stringify(store.entries);
        var count = Object.keys(store.entries).length;
        while (payload.length > store.maxPayloadChars && count > 1) {
            count = Math.floor(count * 0.9);
            store.entries = Lyrics.trimStore(store.entries, count);
            payload = JSON.stringify(store.entries);
        }
        writer.pendingPayload = payload;
        writer.stdinEnabled = true;
        writer.running = true;
    }

    Process {
        id: reader
        command: ["timeout", "-k", "1", "3", "python3", store.helperPath, "read", store.name]
        running: store.helperPath !== "" && store.name !== ""
        stdout: StdioCollector { id: readerOut; waitForEnd: true }
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0)
                store.entries = Lyrics.mergeStores(Lyrics.parseStore(String(readerOut.text)), store.entries, store.cap);
            store.loaded = true;
        }
    }

    Process {
        id: writer
        property string pendingPayload: ""
        command: ["timeout", "-k", "1", "5", "python3", store.helperPath, "write", store.name]
        onStarted: {
            write(pendingPayload);
            pendingPayload = "";
            stdinEnabled = false;
        }
        onExited: function(exitCode, exitStatus) {
            if (store.dirty) { store.dirty = false; store.save(); }
        }
    }
}

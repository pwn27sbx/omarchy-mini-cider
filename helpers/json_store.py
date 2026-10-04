#!/usr/bin/env python3
"""Read or write one of the widget's two JSON stores.

Usage: json_store.py read|write offsets|lyrics   (write takes JSON on stdin)

  offsets -> $XDG_STATE_HOME/mini-cider/offsets.json (default ~/.local/state)
  lyrics  -> $XDG_CACHE_HOME/mini-cider/lyrics.json  (default ~/.cache)

Safety model (same as save_token.py):
  - Only the two fixed store names are accepted; no path ever comes from the
    caller, so there is nothing to inject.
  - The directory is created 0700, opened with O_DIRECTORY | O_NOFOLLOW and
    checked to be owned by the current user; every file operation is relative
    to that descriptor.
  - Reads open the file with O_NOFOLLOW, require a regular file owned by the
    user and are bounded; anything unsafe, missing or corrupt reads as {}.
  - Writes are bounded, must be a UTF-8 JSON object, go to a private temp file
    (0600, O_EXCL | O_NOFOLLOW), are fsynced and renamed over the store, which
    replaces a symlinked entry instead of following it.
Exit codes: 0 ok, 1 invalid or unsafe input, 2 usage error.
"""
import json
import os
import stat
import sys

MAX_BYTES = 16 * 1024 * 1024
STORES = {
    "offsets": ("XDG_STATE_HOME", (".local", "state"), "offsets.json"),
    "lyrics": ("XDG_CACHE_HOME", (".cache",), "lyrics.json"),
}


def store_dir(name):
    env, fallback, _ = STORES[name]
    base = os.environ.get(env) or os.path.join(os.environ.get("HOME", ""), *fallback)
    return os.path.join(base, "mini-cider")


def open_dir(path, create):
    if create:
        try:
            os.makedirs(path, mode=0o700, exist_ok=True)
        except OSError as e:
            raise RuntimeError(f"cannot create store dir: {e}")
    try:
        dfd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as e:
        raise RuntimeError(f"store directory unavailable: {e}")
    try:
        st = os.fstat(dfd)
        if st.st_uid != os.getuid():
            raise RuntimeError("store directory is not owned by the current user")
        if create:
            os.fchmod(dfd, 0o700)
    except BaseException:
        os.close(dfd)
        raise
    return dfd


def read_store(name):
    try:
        dfd = open_dir(store_dir(name), create=False)
    except RuntimeError:
        return b"{}"
    try:
        fd = os.open(STORES[name][2], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dfd)
    except OSError:
        os.close(dfd)
        return b"{}"
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > MAX_BYTES:
            return b"{}"
        data = os.read(fd, MAX_BYTES + 1)
        while len(data) <= MAX_BYTES:
            more = os.read(fd, MAX_BYTES + 1 - len(data))
            if not more:
                break
            data += more
        if len(data) > MAX_BYTES:
            return b"{}"
        try:
            if not isinstance(json.loads(data.decode("utf-8")), dict):
                return b"{}"
        except (UnicodeDecodeError, ValueError):
            return b"{}"
        return data
    finally:
        os.close(fd)
        os.close(dfd)


def read_payload(stream=None):
    stream = stream if stream is not None else sys.stdin.buffer
    data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("payload exceeds maximum size")
    try:
        parsed = json.loads(data.decode("utf-8", errors="strict"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("payload is not valid UTF-8 JSON")
    if not isinstance(parsed, dict):
        raise ValueError("payload must be a JSON object")
    return data


def write_store(name, payload):
    dfd = open_dir(store_dir(name), create=True)
    try:
        tmp = ".tmp-" + os.urandom(8).hex()
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dfd)
        try:
            try:
                os.fchmod(fd, 0o600)
                view = memoryview(payload)
                while view:
                    view = view[os.write(fd, view):]
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(tmp, STORES[name][2], src_dir_fd=dfd, dst_dir_fd=dfd)
            os.fsync(dfd)
        except BaseException:
            try:
                os.unlink(tmp, dir_fd=dfd)
            except OSError:
                pass
            raise
    finally:
        os.close(dfd)


def main(argv):
    if len(argv) != 3 or argv[1] not in ("read", "write") or argv[2] not in STORES:
        sys.stderr.write("usage: json_store.py read|write offsets|lyrics\n")
        return 2
    if argv[1] == "read":
        sys.stdout.buffer.write(read_store(argv[2]))
        return 0
    try:
        payload = read_payload()
        write_store(argv[2], payload)
    except (ValueError, RuntimeError, OSError) as e:
        sys.stderr.write(str(e) + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

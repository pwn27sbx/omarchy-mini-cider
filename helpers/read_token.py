#!/usr/bin/env python3
"""Read the Cider API token.

Security model (marketplace review):
  - The token file is opened with O_NOFOLLOW so a symlink swapped in at the
    expected path cannot redirect the read elsewhere.
  - The opened descriptor is validated with fstat() to be a regular file
    owned by the current user before any bytes are read.
  - Reads are bounded to MAX_TOKEN_BYTES.
  - The current location (`$XDG_STATE_HOME/mini-cider/token`) is tried
    first; the legacy plugin-directory path (argv[1], if given) is a
    read-only fallback for tokens saved by older plugin versions.
"""
import os
import stat
import sys

MAX_TOKEN_BYTES = 4 * 1024


def _state_home():
    xdg = os.environ.get("XDG_STATE_HOME")
    if xdg:
        return xdg
    home = os.environ.get("HOME", "")
    return os.path.join(home, ".local", "state")


def _token_path():
    return os.path.join(_state_home(), "mini-cider", "token")


def read_token_file(path):
    """Return the bounded token text at `path`, or None if unreadable/unsafe."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return None

    try:
        try:
            st = os.fstat(fd)
        except OSError:
            return None
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            return None

        chunks = []
        remaining = MAX_TOKEN_BYTES
        while remaining > 0:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
    finally:
        os.close(fd)

    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None
    token = text.strip()
    return token or None


def get_token(legacy_path=None):
    token = read_token_file(_token_path())
    if token is not None:
        return token
    if legacy_path:
        return read_token_file(legacy_path)
    return None


def main(argv):
    legacy_path = argv[1] if len(argv) > 1 else None
    token = get_token(legacy_path)
    if token:
        print(token)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Securely persist the Cider API token.

Security model (marketplace review):
  - The token is read only from stdin (bounded to MAX_TOKEN_BYTES), never
    from argv or an environment variable, so it never appears in `ps`
    output or a process environment listing.
  - The token is stored under `$XDG_STATE_HOME/mini-cider/token` (falls
    back to `~/.local/state`), never inside the plugin's own directory.
  - The state directory is created 0700 and must be owned by the current
    user and not a symlink; saving refuses otherwise.
  - Writes are atomic: write to a private mkstemp() file in the same
    directory (mode 0600), fsync, then os.replace() into place -- a
    symlinked destination path is never opened for writing directly, since
    os.replace() swaps the directory entry rather than following it.
  - After a successful save, the legacy plugin-directory token file (if
    given as argv[1]) is removed, but only when it is a regular file owned
    by the current user and not a symlink, so a symlinked legacy path is
    left untouched.
"""
import os
import stat
import sys
import tempfile

MAX_TOKEN_BYTES = 4 * 1024


def _state_home():
    xdg = os.environ.get("XDG_STATE_HOME")
    if xdg:
        return xdg
    home = os.environ.get("HOME", "")
    return os.path.join(home, ".local", "state")


def _token_dir():
    return os.path.join(_state_home(), "mini-cider")


def _token_path():
    return os.path.join(_token_dir(), "token")


def _ensure_token_dir():
    d = _token_dir()
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
    except OSError as e:
        raise RuntimeError(f"cannot create token dir: {e}")

    try:
        st = os.lstat(d)
    except OSError as e:
        raise RuntimeError(f"cannot stat token dir: {e}")

    if stat.S_ISLNK(st.st_mode):
        raise RuntimeError("token directory must not be a symlink")
    if not stat.S_ISDIR(st.st_mode):
        raise RuntimeError("token path is not a directory")
    if st.st_uid != os.getuid():
        raise RuntimeError("token directory is not owned by the current user")

    # Tighten permissions if they were looser than expected (pre-existing dir).
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def read_stdin_token(stream=None):
    """Read and validate the token from stdin: bounded, non-empty, no control chars."""
    stream = stream if stream is not None else sys.stdin.buffer
    data = stream.read(MAX_TOKEN_BYTES + 1)
    if len(data) > MAX_TOKEN_BYTES:
        raise ValueError("token exceeds maximum size")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise ValueError("token is not valid utf-8")
    token = text.strip()
    if not token:
        raise ValueError("token is empty")
    if any(ord(ch) < 0x20 or ord(ch) == 0x7f for ch in token):
        raise ValueError("token contains control characters")
    return token


def save_token(token):
    d = _ensure_token_dir()
    payload = token.encode("utf-8")

    fd, tmp_path = tempfile.mkstemp(prefix=".token-", dir=d)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, _token_path())
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def remove_legacy_token(path):
    """Remove the legacy plugin-directory token file, only when it is safe."""
    if not path:
        return
    try:
        st = os.lstat(path)
    except OSError:
        return
    if stat.S_ISLNK(st.st_mode):
        return
    if not stat.S_ISREG(st.st_mode):
        return
    if st.st_uid != os.getuid():
        return
    try:
        os.remove(path)
    except OSError:
        pass


def main(argv):
    legacy_path = argv[1] if len(argv) > 1 else None
    try:
        token = read_stdin_token()
    except ValueError as e:
        sys.stderr.write(str(e) + "\n")
        return 1
    try:
        save_token(token)
    except RuntimeError as e:
        sys.stderr.write(str(e) + "\n")
        return 1
    remove_legacy_token(legacy_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

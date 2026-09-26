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
  - The directory is opened once with O_DIRECTORY | O_NOFOLLOW and every
    write is relative to that descriptor: a private temp file is created
    with O_CREAT | O_EXCL | O_NOFOLLOW (0600), fsynced, then renamed over
    `token` with os.replace(), which swaps the entry and never follows a
    symlinked destination.
  - After a successful save, the legacy plugin-directory token file (if
    given as argv[1]) is removed, but only when it is a regular file owned
    by the current user and not a symlink, so a symlinked legacy path is
    left untouched.
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


def _token_dir():
    return os.path.join(_state_home(), "mini-cider")


def _token_path():
    return os.path.join(_token_dir(), "token")


def _open_token_dir():
    """Create (0700) and open the token directory without following links.

    Returns a directory fd; every later operation is relative to it, so the
    directory cannot be swapped for a symlink between the check and the write.
    """
    d = _token_dir()
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
    except OSError as e:
        raise RuntimeError(f"cannot create token dir: {e}")
    try:
        dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as e:
        raise RuntimeError(f"token directory must be a real directory: {e}")
    try:
        st = os.fstat(dfd)
        if not stat.S_ISDIR(st.st_mode):
            raise RuntimeError("token path is not a directory")
        if st.st_uid != os.getuid():
            raise RuntimeError("token directory is not owned by the current user")
        os.fchmod(dfd, 0o700)
    except BaseException:
        os.close(dfd)
        raise
    return dfd


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
    dfd = _open_token_dir()
    try:
        payload = token.encode("utf-8")
        tmp_name = ".token-" + os.urandom(8).hex()
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
        fd = os.open(tmp_name, flags, 0o600, dir_fd=dfd)
        try:
            try:
                os.fchmod(fd, 0o600)
                os.write(fd, payload)
                os.fsync(fd)
            finally:
                os.close(fd)
            # rename(2) replaces the directory entry; it never follows a
            # symlink at the destination.
            os.replace(tmp_name, "token", src_dir_fd=dfd, dst_dir_fd=dfd)
            os.fsync(dfd)
        except BaseException:
            try:
                os.unlink(tmp_name, dir_fd=dfd)
            except OSError:
                pass
            raise
    finally:
        os.close(dfd)


def remove_legacy_token(path):
    """Remove the legacy plugin-directory token file, only when it is safe.

    The parent is opened without following links and the entry is checked
    and unlinked relative to that descriptor, so a symlink is never removed
    through or followed.
    """
    if not path:
        return
    parent, name = os.path.split(path)
    if not parent or not name:
        return
    try:
        dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return
    try:
        st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            return
        os.unlink(name, dir_fd=dfd)
    except OSError:
        return
    finally:
        os.close(dfd)


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

#!/usr/bin/env python3
"""Read a Cider API token candidate from the Wayland clipboard.

Security properties:
  - wl-paste output is read from the pipe in bounded chunks; at most
    MAX_CLIPBOARD_BYTES + 1 bytes are ever buffered, so a large clipboard
    never reaches the shell process.
  - An oversized payload is rejected (and wl-paste killed), not truncated.
  - The whole read has a wall-clock deadline; a stalled wl-paste is killed.
  - The candidate must be valid UTF-8, a single line without control
    characters, and at most MAX_TOKEN_CHARS characters after trimming.
  - On success the token is printed to stdout; on any failure nothing is
    printed and the exit status is non-zero.
"""

import os
import select
import shutil
import subprocess
import sys
import time

MAX_CLIPBOARD_BYTES = 4 * 1024
MAX_TOKEN_CHARS = 512
DEADLINE_SECONDS = 2.0
READ_CHUNK = 1024


def read_bounded(proc):
    """Return at most MAX_CLIPBOARD_BYTES bytes from proc.stdout, or None."""
    fd = proc.stdout.fileno()
    deadline = time.monotonic() + DEADLINE_SECONDS
    data = bytearray()
    while True:
        remaining_time = deadline - time.monotonic()
        if remaining_time <= 0:
            return None
        ready, _, _ = select.select([fd], [], [], remaining_time)
        if not ready:
            return None
        chunk = os.read(fd, min(READ_CHUNK, MAX_CLIPBOARD_BYTES + 1 - len(data)))
        if not chunk:
            return bytes(data)
        data.extend(chunk)
        if len(data) > MAX_CLIPBOARD_BYTES:
            return None


def stop(proc, grace):
    # After a clean EOF, give wl-paste a moment to exit on its own so a valid
    # read is not turned into a kill (-9) and rejected.
    if grace:
        try:
            proc.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
    if proc.poll() is None:
        proc.kill()
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def validate(raw):
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    token = text.strip()
    if not token or len(token) > MAX_TOKEN_CHARS:
        return None
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in token):
        return None
    return token


def main():
    wl_paste = shutil.which("wl-paste")
    if wl_paste is None:
        return 1
    try:
        proc = subprocess.Popen(
            [wl_paste, "-n", "-t", "text/plain"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return 1
    raw = None
    try:
        raw = read_bounded(proc)
    finally:
        stop(proc, grace=raw is not None)
        proc.stdout.close()
    if raw is None or proc.returncode != 0:
        return 1
    token = validate(raw)
    if token is None:
        return 1
    sys.stdout.write(token + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

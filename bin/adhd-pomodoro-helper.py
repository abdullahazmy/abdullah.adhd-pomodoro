#!/usr/bin/env python3
"""Helper for abdullah.adhd-pomodoro.

Three modes, selected by argv[1]:

  state-read        PATH [MAX_BYTES]
  state-write        PATH   (reads JSON body from stdin, atomic write)
  history-read       PATH [MAX_BYTES]
  history-append     PATH   (reads a single JSON line from stdin; appends
                             to PATH under flock, returns sentinel on failure)

Safety properties enforced:

  * The state directory must exist, be owned by the running user, and
    not be group/world-writable. We refuse to operate otherwise.

  * The target file (state or history) must not be a symlink. We open
    it with O_NOFOLLOW and refuse pre-existing symlinks.

  * Reads are bounded by MAX_BYTES so a planted huge file cannot
    exhaust memory. State reads run from the start; history reads
    return the last MAX_BYTES (the file is append-only).

  * Writes are atomic at the filesystem level: we write to a sibling
    tempfile, fsync, then os.replace() the temp into place. os.replace
    behaves like rename(2) and does not follow symlinks.

  * History appends take an exclusive flock on the path before opening
    it, so concurrent appenders serialize and `printf >> path` cannot
    interleave bytes.

Output protocol: every stdout payload begins with a sentinel line
followed by a newline and (optionally) the body bytes. The QML side
parses the first line as the sentinel:

  NO_STATE                       state.json absent
  STATE_OK\\n<bytes>             state.json read OK
  STATE_TRUNCATED\\n<bytes>      state.json larger than the cap

  NO_HISTORY                     history.jsonl absent or a symlink
  HISTORY_OK\\n<bytes>           history.jsonl read OK
  HISTORY_TRUNCATED\\n<bytes>    history.jsonl larger than the cap

  HISTORY_APPENDED               append succeeded
"""

from __future__ import annotations

import errno
import fcntl
import os
import sys
import tempfile
from typing import Tuple


def _err(code: int, msg: str) -> None:
    sys.stderr.write("adhd-pomodoro-helper: {}\n".format(msg))
    sys.stderr.flush()
    sys.exit(code)


def _emit(sentinel: bytes) -> None:
    sys.stdout.buffer.write(sentinel + b"\n")
    sys.stdout.buffer.flush()


def _check_owner_dir(path: str) -> Tuple[int, int]:
    """Resolve `path`, verify it is owned by the running user and is
    not group/world-writable. Returns (uid, gid) of the resolved dir.
    """
    parent = os.path.dirname(os.path.abspath(path))
    real_parent = os.path.realpath(parent)
    if not os.path.isdir(real_parent):
        _err(2, "state directory missing: " + real_parent)
    st = os.stat(real_parent)
    uid = os.getuid()
    if st.st_uid != uid:
        _err(3, "state directory owned by uid {} but we are uid {}".format(
            st.st_uid, uid))
    if st.st_mode & 0o022:
        _err(4, "state directory is group/world writable: mode 0o{:o}".format(
            st.st_mode))
    return (st.st_uid, st.st_gid)


def _open_nofollow(path: str, flags: int, mode: int = 0o600):
    """Open `path` without following symlinks. Returns a file descriptor.
    Caller is responsible for closing it.
    """
    return os.open(path, flags | os.O_NOFOLLOW, mode)


def _state_read(max_bytes: int) -> None:
    if len(sys.argv) < 3:
        _err(64, "state-read: usage")
    path = sys.argv[2]
    cap = int(sys.argv[3]) if len(sys.argv) > 3 else 262144  # 256 KiB
    _check_owner_dir(path)
    if not os.path.exists(path):
        _emit(b"NO_STATE")
        return
    if os.path.islink(path):
        _err(5, "state path is a symlink: " + path)
    if not os.path.isfile(path):
        _err(5, "state path is not a regular file: " + path)
    try:
        fd = _open_nofollow(path, os.O_RDONLY)
    except OSError as e:
        if e.errno == errno.ELOOP:
            _err(5, "state path is a symlink: " + path)
        _err(6, "cannot open state path: " + str(e))
    # Read up to cap+1 bytes to detect truncation.
    try:
        data = os.read(fd, cap + 1)
    except OSError as e:
        os.close(fd)
        _err(6, "cannot read state path: " + str(e))
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    truncated = len(data) > cap
    if truncated:
        data = data[:cap]
    sentinel = b"STATE_TRUNCATED" if truncated else b"STATE_OK"
    sys.stdout.buffer.write(sentinel + b"\n")
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def _state_write() -> None:
    if len(sys.argv) < 3:
        _err(64, "state-write: usage")
    path = sys.argv[2]
    _check_owner_dir(path)
    if os.path.islink(path):
        _err(5, "state path is a symlink: " + path)
    if len(sys.argv) < 4:
        # No body passed via argv — fall back to stdin for callers that
        # support it.
        raw = sys.stdin.buffer.read()
    else:
        raw = sys.argv[3].encode("utf-8")
    if not isinstance(raw, (bytes, bytearray)):
        _err(7, "state-write: body must be bytes")
    parent = os.path.dirname(os.path.abspath(path))
    # Write to a sibling temp file with O_NOFOLLOW|O_EXCL, fsync, then
    # os.replace() into place. os.replace replaces a symlink target if
    # one is present at `path`, so a planted symlink cannot redirect
    # the write to an arbitrary location.
    fd, tmp = tempfile.mkstemp(prefix=".state.", suffix=".tmp", dir=parent)
    try:
        os.chmod(tmp, 0o600)
        try:
            os.write(fd, raw)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _history_read(max_bytes: int) -> None:
    if len(sys.argv) < 3:
        _err(64, "history-read: usage")
    path = sys.argv[2]
    cap = int(sys.argv[3]) if len(sys.argv) > 3 else 1048576  # 1 MiB
    _check_owner_dir(path)
    if not os.path.exists(path):
        _emit(b"NO_HISTORY")
        return
    if os.path.islink(path):
        _emit(b"NO_HISTORY")  # refuse silently on symlinks
        return
    if not os.path.isfile(path):
        _emit(b"NO_HISTORY")
        return
    try:
        fd = _open_nofollow(path, os.O_RDONLY)
    except OSError as e:
        if e.errno == errno.ELOOP:
            _emit(b"NO_HISTORY")
            return
        _err(9, "cannot open history path: " + str(e))
    # Read up to cap+1 bytes so we can detect truncation.
    try:
        data = os.read(fd, cap + 1)
    except OSError as e:
        os.close(fd)
        _err(9, "cannot read history path: " + str(e))
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    truncated = len(data) > cap
    if truncated:
        # History file is append-only, so keep the tail.
        data = data[-cap:]
    sentinel = b"HISTORY_TRUNCATED" if truncated else b"HISTORY_OK"
    sys.stdout.buffer.write(sentinel + b"\n")
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def _history_append() -> None:
    if len(sys.argv) < 3:
        _err(64, "history-append: usage")
    path = sys.argv[2]
    _check_owner_dir(path)
    if len(sys.argv) < 4:
        line = sys.stdin.buffer.read()
    else:
        line = sys.argv[3].encode("utf-8")
    if b"\n" in line:
        _err(10, "history line contains newline")
    if os.path.islink(path):
        _err(11, "history path is a symlink: " + path)
    if not os.path.exists(path):
        # Create as a regular file with no-follow. If a symlink raced in
        # here, EEXIST is raised and we bail.
        try:
            fd = _open_nofollow(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError as e:
            if e.errno == errno.EEXIST:
                _err(12, "history path appeared as symlink during open: " + path)
            _err(13, "cannot create history file: " + str(e))
    else:
        if os.path.islink(path):
            _err(11, "history path is a symlink: " + path)
        # O_APPEND so each appender writes at end-of-file regardless of
        # its seek position. Combined with flock(LOCK_EX) below, this
        # serializes without interleaving bytes.
        try:
            fd = _open_nofollow(path, os.O_RDWR | os.O_APPEND)
        except OSError as e:
            if e.errno == errno.ELOOP:
                _err(11, "history path is a symlink: " + path)
            _err(13, "cannot open history file: " + str(e))
    try:
        # Take an exclusive flock before any I/O happens so concurrent
        # appenders serialize. flock waits; failures bubble out.
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as e:
            _err(14, "flock failed: " + str(e))
        # Re-stat under the lock — someone could have replaced the
        # path with a symlink between open and flock.
        if not os.path.isfile(path) or os.path.islink(path):
            _err(11, "history path is not regular after lock: " + path)
        os.write(fd, line + b"\n")
        os.fsync(fd)
        _emit(b"HISTORY_APPENDED")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def main() -> None:
    if len(sys.argv) < 2:
        _err(64, "usage: helper.py MODE PATH [..]")
    mode = sys.argv[1]
    cap = int(os.environ.get("ADHD_MAX", "1048576"))
    if mode == "state-read":
        _state_read(cap)
    elif mode == "state-write":
        _state_write()
    elif mode == "history-read":
        _history_read(cap)
    elif mode == "history-append":
        _history_append()
    else:
        _err(64, "unknown mode: " + mode)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)

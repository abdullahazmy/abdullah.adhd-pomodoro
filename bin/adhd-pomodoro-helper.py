#!/usr/bin/env python3
"""Helper for abdullah.adhd-pomodoro.

Four modes, selected by argv[1]:

  state-read        PATH [MAX_BYTES]
  state-write       PATH [BODY]      (BODY from argv, or stdin if omitted;
                                      atomic write)
  history-read      PATH [MAX_BYTES] [SINCE_ISO]
  history-append    PATH [LINE]      (LINE from argv, or stdin if omitted;
                                      appended under flock)

Safety properties enforced:

  * The state directory must exist, be owned by the running user, and
    not be group/world-writable. We refuse to operate otherwise.

  * The target file (state or history) must not be a symlink. We open
    it with O_NOFOLLOW and refuse pre-existing symlinks.

  * Reads are bounded by MAX_BYTES so a planted huge file cannot
    exhaust memory. State reads run from the start; history reads
    seek to the last MAX_BYTES (the file is append-only).

  * Writes are atomic at the filesystem level: we write to a sibling
    tempfile created with O_EXCL|O_NOFOLLOW, fsync, then os.replace()
    the temp into place. os.replace behaves like rename(2) and does not
    follow symlinks.

  * History appends take an exclusive flock on the path before writing,
    so concurrent appenders serialize and cannot interleave bytes.

Output protocol: every stdout payload begins with a sentinel line
followed by a newline and (optionally) the body bytes. The QML side
parses the first line as the sentinel:

  NO_STATE                       state.json absent
  STATE_OK\\n<bytes>             state.json read OK
  STATE_TRUNCATED\\n<bytes>      state.json larger than the cap

  NO_HISTORY                     history.jsonl absent or a symlink
  HISTORY_OK\\n<lines>           history.jsonl read OK
  HISTORY_TRUNCATED\\n<lines>    history.jsonl larger than the cap

  HISTORY_APPENDED               append succeeded

When SINCE_ISO is given, history-read only returns lines whose `ts`
field sorts at or after it (ISO-8601 UTC strings compare
lexicographically). The QML side passes local midnight, so the shell
only ever holds today's entries in memory instead of the whole tail.

The helper deliberately imports only os/sys/errno/fcntl/json so the
interpreter starts fast when invoked with `python3 -I -S`.
"""

import errno
import fcntl
import json
import os
import sys

STATE_CAP_DEFAULT = 262144      # 256 KiB
HISTORY_CAP_DEFAULT = 65536     # 64 KiB — weeks of sessions


def _err(code, msg):
    sys.stderr.write("adhd-pomodoro-helper: {}\n".format(msg))
    sys.stderr.flush()
    sys.exit(code)


def _emit(sentinel, body=b""):
    out = sys.stdout.buffer
    out.write(sentinel + b"\n")
    if body:
        out.write(body)
    out.flush()


def _arg(index, default=None):
    return sys.argv[index] if len(sys.argv) > index else default


def _cap(index, default):
    try:
        value = int(_arg(index, default))
    except ValueError:
        _err(64, "invalid byte cap")
    if value <= 0:
        _err(64, "invalid byte cap")
    return value


def _check_owner_dir(path):
    """Verify the parent directory of `path` is owned by the running user
    and is not group/world-writable.
    """
    real_parent = os.path.realpath(os.path.dirname(os.path.abspath(path)))
    try:
        st = os.stat(real_parent)
    except OSError:
        _err(2, "state directory missing: " + real_parent)
    if not os.path.isdir(real_parent):
        _err(2, "state directory missing: " + real_parent)
    uid = os.getuid()
    if st.st_uid != uid:
        _err(3, "state directory owned by uid {} but we are uid {}".format(
            st.st_uid, uid))
    if st.st_mode & 0o022:
        _err(4, "state directory is group/world writable: mode 0o{:o}".format(
            st.st_mode))


def _open_regular_ro(path):
    """Open `path` read-only without following symlinks. Returns an fd,
    or None if the path is absent, a symlink, or not a regular file.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as e:
        if e.errno in (errno.ENOENT, errno.ELOOP):
            return None
        raise
    st = os.fstat(fd)
    if not (st.st_mode & 0o170000 == 0o100000):  # S_ISREG
        os.close(fd)
        return None
    return fd


def _read_all(fd, limit):
    chunks = []
    remaining = limit
    while remaining > 0:
        chunk = os.read(fd, min(remaining, 65536))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _state_read():
    path = _arg(2)
    if path is None:
        _err(64, "state-read: usage")
    cap = _cap(3, STATE_CAP_DEFAULT)
    _check_owner_dir(path)
    if os.path.islink(path):
        _err(5, "state path is a symlink: " + path)
    try:
        fd = _open_regular_ro(path)
    except OSError as e:
        _err(6, "cannot open state path: " + str(e))
    if fd is None:
        if os.path.lexists(path):
            _err(5, "state path is not a regular file: " + path)
        _emit(b"NO_STATE")
        return
    try:
        # Read up to cap+1 bytes to detect truncation.
        data = _read_all(fd, cap + 1)
    except OSError as e:
        _err(6, "cannot read state path: " + str(e))
    finally:
        os.close(fd)
    if len(data) > cap:
        _emit(b"STATE_TRUNCATED", data[:cap])
    else:
        _emit(b"STATE_OK", data)


def _state_write():
    path = _arg(2)
    if path is None:
        _err(64, "state-write: usage")
    _check_owner_dir(path)
    if os.path.islink(path):
        _err(5, "state path is a symlink: " + path)
    body = _arg(3)
    raw = sys.stdin.buffer.read() if body is None else body.encode("utf-8")
    parent = os.path.dirname(os.path.abspath(path))
    tmp = os.path.join(parent, ".state.{}.tmp".format(os.getpid()))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        fd = os.open(tmp, flags, 0o600)
    except FileExistsError:
        # Leftover from a crashed writer that had our pid. unlink()
        # removes a symlink itself, never its target.
        try:
            os.unlink(tmp)
            fd = os.open(tmp, flags, 0o600)
        except OSError as e:
            _err(7, "cannot create temp state file: " + str(e))
    except OSError as e:
        _err(7, "cannot create temp state file: " + str(e))
    try:
        try:
            view = memoryview(raw)
            while view:
                written = os.write(fd, view)
                view = view[written:]
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


def _history_read():
    path = _arg(2)
    if path is None:
        _err(64, "history-read: usage")
    cap = _cap(3, HISTORY_CAP_DEFAULT)
    since = _arg(4, "")
    _check_owner_dir(path)
    try:
        fd = _open_regular_ro(path)
    except OSError as e:
        _err(9, "cannot open history path: " + str(e))
    if fd is None:
        _emit(b"NO_HISTORY")
        return
    try:
        size = os.fstat(fd).st_size
        truncated = size > cap
        if truncated:
            # Append-only file: only the tail can contain recent entries.
            os.lseek(fd, size - cap, os.SEEK_SET)
        data = _read_all(fd, cap)
    except OSError as e:
        _err(9, "cannot read history path: " + str(e))
    finally:
        os.close(fd)

    lines = data.split(b"\n")
    if truncated and lines:
        lines = lines[1:]  # first line is probably a partial record
    out = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if since:
            try:
                ts = json.loads(line).get("ts")
            except (ValueError, AttributeError):
                continue
            if not isinstance(ts, str) or ts < since:
                continue
        out.append(line)
    body = b"\n".join(out) + b"\n" if out else b""
    _emit(b"HISTORY_TRUNCATED" if truncated else b"HISTORY_OK", body)


def _history_append():
    path = _arg(2)
    if path is None:
        _err(64, "history-append: usage")
    _check_owner_dir(path)
    arg_line = _arg(3)
    line = sys.stdin.buffer.read() if arg_line is None else arg_line.encode("utf-8")
    if b"\n" in line:
        _err(10, "history line contains newline")
    if os.path.islink(path):
        _err(11, "history path is a symlink: " + path)
    # O_APPEND so each appender writes at end-of-file regardless of its
    # seek position. O_NOFOLLOW refuses a symlink that raced in.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as e:
        if e.errno == errno.ELOOP:
            _err(11, "history path is a symlink: " + path)
        _err(13, "cannot open history file: " + str(e))
    try:
        if os.fstat(fd).st_mode & 0o170000 != 0o100000:
            _err(11, "history path is not a regular file: " + path)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as e:
            _err(14, "flock failed: " + str(e))
        os.write(fd, line + b"\n")
        os.fsync(fd)
        _emit(b"HISTORY_APPENDED")
    finally:
        os.close(fd)


MODES = {
    "state-read": _state_read,
    "state-write": _state_write,
    "history-read": _history_read,
    "history-append": _history_append,
}


def main():
    if len(sys.argv) < 2:
        _err(64, "usage: helper.py MODE PATH [..]")
    handler = MODES.get(sys.argv[1])
    if handler is None:
        _err(64, "unknown mode: " + sys.argv[1])
    handler()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)

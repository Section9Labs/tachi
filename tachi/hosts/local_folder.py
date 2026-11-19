"""Mac-side executor for opt-in access to direct children of a selected folder."""

import ctypes
import errno
import os
import stat
import sys
import tempfile
from contextlib import AbstractContextManager
from threading import Lock
from uuid import uuid4

from tachi.runtime.queue import HostScope

from .store import AccessDenied, HostSession, _relative_path


MAX_BYTES = 1024 * 1024


def capabilities() -> dict:
    return {
        "actions": {"read": "regular-file", "write": "exclusive-create"},
        "path_scope": "direct-children-only",
        "max_bytes": MAX_BYTES,
        "hard_links": False,
        "write_volume": "clone-capable, same filesystem as private temporary storage",
    }


def _check_file(info):
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise AccessDenied("a single-link regular file is required")
    if info.st_size > MAX_BYTES:
        raise ValueError("file exceeds the byte limit")


class FolderExecutor(AbstractContextManager):
    """Keep a fresh folder handle bound to one selected directory inode and host."""

    def __init__(self, folder, host_id: str, authorize):
        if sys.platform != "darwin" or not hasattr(os, "O_NOFOLLOW_ANY"):
            raise NotImplementedError("Mac folder confinement unavailable")
        if not os.path.isabs(folder):
            raise ValueError("select an absolute directory path")
        self._clone = ctypes.CDLL(None, use_errno=True).fclonefileat
        self._clone.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32)
        self._clone.restype = ctypes.c_int
        self._host_id = host_id
        self._folder_id = uuid4().hex
        self._authorize = authorize
        self._lock = Lock()
        self._root = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW_ANY)

    @property
    def folder_id(self) -> str:
        return self._folder_id

    def __exit__(self, exc_type, exc_value, traceback):
        with self._lock:
            if self._root is not None:
                os.close(self._root)
                self._root = None

    def execute(self, scope: HostScope, session: HostSession, *, body: bytes | None = None) -> bytes | None:
        """Use the local session and coordinator-issued scope for one bounded operation."""
        if scope.host_id != self._host_id or session.host_id != self._host_id or scope.folder_id != self.folder_id:
            raise AccessDenied()
        if "/" in scope.relative_path:
            raise AccessDenied("only direct children of the selected folder are supported")
        _relative_path(scope.relative_path)

        def check():
            result = self._authorize(scope.owner_id, session, scope.grant_id, scope.folder_id,
                                     scope.action, scope.relative_path)
            if result is not None:
                raise AccessDenied("unexpected authorization response")

        with self._lock:
            if self._root is None:
                raise AccessDenied("folder selection is closed")
            check()
            if scope.action == "read" and body is None:
                return self._read(scope.relative_path, check)
            if scope.action == "write" and isinstance(body, bytes):
                if len(body) > MAX_BYTES:
                    raise ValueError("body exceeds the byte limit")
                self._create(scope.relative_path, body, check)
                return None
            raise ValueError("read takes no body and write requires bytes")

    def _read(self, name, check):
        def entry():
            return os.stat(name, dir_fd=self._root, follow_symlinks=False)

        # Preflight avoids opening special files in ordinary use. Verify the opened
        # descriptor too, since the directory entry can change at any time.
        selected = entry()
        _check_file(selected)
        flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY | os.O_NOFOLLOW
        check()
        fd = os.open(name, flags, dir_fd=self._root)
        with os.fdopen(fd, "rb") as source:
            opened = os.fstat(fd)
            _check_file(opened)
            if not os.path.samestat(opened, selected):
                raise AccessDenied("file changed during open")
            def verify_entry():
                current = entry()
                _check_file(current)
                if not os.path.samestat(current, opened) or current.st_ctime_ns != opened.st_ctime_ns:
                    raise AccessDenied("file changed during read")

            check()
            verify_entry()
            data = source.read(MAX_BYTES + 1)
            check()
            verify_entry()
            if len(data) != opened.st_size:
                raise AccessDenied("file changed during read")
            return data

    def _create(self, name, body, check):
        # Publish fully prepared bytes in one exclusive operation. There is no
        # writable destination FD to follow if someone later moves the new file.
        with tempfile.TemporaryFile() as staged:
            if os.fstat(staged.fileno()).st_nlink != 0:
                raise AccessDenied("private unlinked staging file required")
            staged.write(body)
            staged.flush()
            check()
            if self._clone(staged.fileno(), self._root, os.fsencode(name), 0) != 0:
                error = ctypes.get_errno()
                if error in (errno.EXDEV, errno.ENOTSUP):
                    raise OSError(error, "selected volume cannot clone from the temporary volume")
                raise OSError(error, os.strerror(error))

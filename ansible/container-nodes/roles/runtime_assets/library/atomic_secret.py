#!/usr/bin/python
from __future__ import annotations

import hashlib
import os
import pathlib
import pwd
import grp
import stat
import tempfile

from ansible.module_utils.basic import AnsibleModule


def identity(value, database, attribute):
    if isinstance(value, int) or str(value).isdigit():
        return int(value)
    return getattr(database(str(value)), attribute)


def main():
    module = AnsibleModule(
        argument_spec={
            "path": {"type": "path", "required": True},
            "content": {"type": "str", "required": True, "no_log": True},
            "owner": {"type": "raw", "default": "root"},
            "group": {"type": "raw", "default": "root"},
            "parent_owner": {"type": "raw", "default": "root"},
            "parent_group": {"type": "raw", "default": "root"},
            "mode": {"type": "str", "required": True},
            "parent_mode": {"type": "str", "default": "0700"},
        },
        supports_check_mode=False,
    )
    path = pathlib.Path(module.params["path"])
    parent = path.parent
    temporary = None
    try:
        if not parent.is_absolute() or path.name in ("", ".", ".."):
            raise ValueError("secret path must be an absolute file path")
        if parent.is_symlink() or path.is_symlink():
            raise ValueError("secret destination or parent is a symlink")
        parent.mkdir(parents=True, mode=int(module.params["parent_mode"], 8), exist_ok=True)
        metadata = parent.stat()
        if not stat.S_ISDIR(metadata.st_mode):
            raise ValueError("secret parent is not a directory")
        parent_uid = identity(module.params["parent_owner"], pwd.getpwnam, "pw_uid")
        parent_gid = identity(module.params["parent_group"], grp.getgrnam, "gr_gid")
        os.chown(parent, parent_uid, parent_gid)
        os.chmod(parent, int(module.params["parent_mode"], 8))
        uid = identity(module.params["owner"], pwd.getpwnam, "pw_uid")
        gid = identity(module.params["group"], grp.getgrnam, "gr_gid")
        payload = module.params["content"].encode("utf-8")
        current = path.read_bytes() if path.exists() else None
        desired_mode = int(module.params["mode"], 8)
        unchanged = current == payload
        if unchanged:
            file_meta = path.stat()
            unchanged = stat.S_IMODE(file_meta.st_mode) == desired_mode and file_meta.st_uid == uid and file_meta.st_gid == gid
        if unchanged:
            module.exit_json(changed=False, sha256=hashlib.sha256(payload).hexdigest())
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
        temporary = pathlib.Path(temporary_name)
        os.fchmod(descriptor, desired_mode)
        os.fchown(descriptor, uid, gid)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
        directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        module.exit_json(changed=True, sha256=hashlib.sha256(payload).hexdigest())
    except (KeyError, OSError, ValueError) as error:
        module.fail_json(msg=f"atomic secret installation failed: {error}")
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    main()

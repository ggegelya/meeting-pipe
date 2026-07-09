"""Is the meeting library sitting inside a cloud-sync folder? (SEC12)

The zero-egress promise is enforced inside this process (`egress_guard`), but the
filesystem can undo it from underneath: the default library at
`~/Documents/Meetings/` sits inside iCloud's Desktop & Documents scope, and if
that setting is on, every WAV and transcript uploads to Apple with nothing in
meeting-pipe aware of it. Dropbox, Google Drive, and OneDrive do the same to any
library placed inside them.

Detection walks the library path and its ancestors up to `$HOME`. Signals, in
descending confidence:

1. `~/Library/CloudStorage/<Provider>-<account>`, the modern File Provider root
   every third-party client now uses. The provider is in the directory name.
2. `~/Library/Mobile Documents/`, iCloud Drive proper.
3. The extended attribute `com.apple.icloud.desktop`, which macOS stamps on
   `~/Documents` and `~/Desktop` when Desktop & Documents sync is on.
4. The extended attribute `com.apple.file-provider-domain-id`, the generic "some
   sync client owns this directory" marker. Names the provider only if 1 or 2
   already did; otherwise it reports an unnamed provider, which is still enough
   to warn.
5. A directory literally named `Dropbox` / `Google Drive` / `OneDrive...`, for
   older clients that predate File Provider.

Two dead ends, recorded so nobody re-walks them. `Path.resolve()` does not reveal
Desktop & Documents sync: macOS leaves `~/Documents` at its own path and symlinks
`~/Library/Mobile Documents/com~apple~CloudDocs/Documents` *back to it*, so the
resolution goes the wrong way. And `MobileMeAccounts.plist`'s `MOBILE_DOCUMENTS`
service being enabled means iCloud *Drive* is on, not Desktop & Documents; keying
on it flags every Mac with iCloud Drive. The service that governs Desktop &
Documents is `CLOUDDESKTOP`, which is consulted only as a last-resort corroborator
because its shape has changed across macOS releases (`Enabled: True` on older
systems, `status: "active"` on macOS 26).
"""
from __future__ import annotations

import ctypes
import ctypes.util
import plistlib
from dataclasses import dataclass
from pathlib import Path

#: Stamped by macOS on `~/Documents` and `~/Desktop` under Desktop & Documents sync.
ICLOUD_DESKTOP_XATTR = "com.apple.icloud.desktop"
#: Present on every File Provider sync root, Apple's and third-party alike.
FILE_PROVIDER_XATTR = "com.apple.file-provider-domain-id"

#: `~/Library/CloudStorage/OneDrive-Contoso` -> "OneDrive". Display names for the
#: prefixes clients actually use.
_CLOUD_STORAGE_NAMES = {
    "iCloudDrive": "iCloud Drive",
    "GoogleDrive": "Google Drive",
    "OneDrive": "OneDrive",
    "Dropbox": "Dropbox",
    "Box": "Box",
    "Egnyte": "Egnyte",
    "pCloud": "pCloud",
    "ProtonDrive": "Proton Drive",
}

#: Legacy, pre-File-Provider clients that just make a plain directory.
_LEGACY_DIRECTORY_NAMES = {
    "Dropbox": "Dropbox",
    "Google Drive": "Google Drive",
    "GoogleDrive": "Google Drive",
    "Box Sync": "Box",
    "pCloud Drive": "pCloud",
    "Sync": "Sync.com",
}


@dataclass(frozen=True)
class SyncProvider:
    """A sync client that owns the library path."""

    #: "iCloud Drive", "Dropbox", ... or "an unidentified sync client".
    name: str
    #: Why we think so, phrased for a doctor line the user can act on.
    evidence: str
    #: The ancestor that is actually the sync root.
    root: Path


def _listxattr(path: Path) -> set[str]:
    """Extended-attribute names on `path`.

    CPython's `os.listxattr` is Linux-only, so this calls libc directly rather
    than shelling out to `/usr/bin/xattr` once per ancestor. Any failure reads as
    "no attributes": the path-shape rules below still catch the common cases, and
    a detector that raises is worse than one that misses.
    """
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        libc.listxattr.restype = ctypes.c_ssize_t
        libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
        raw = str(path).encode()
        size = libc.listxattr(raw, None, 0, 0)
        if size <= 0:
            return set()
        buf = ctypes.create_string_buffer(size)
        size = libc.listxattr(raw, buf, size, 0)
        if size <= 0:
            return set()
        return {name.decode() for name in buf.raw[:size].split(b"\0") if name}
    except Exception:  # noqa: BLE001 - a detector must never be the thing that crashes doctor
        return set()


def icloud_desktop_sync_enabled(home: Path | None = None) -> bool:
    """Does `MobileMeAccounts.plist` say Desktop & Documents sync is on?

    Corroboration only. `CLOUDDESKTOP` reports `Enabled: True` on older macOS and
    `status: "active"` on macOS 26, so both shapes are accepted; an absent or
    unreadable plist reads as off.
    """
    plist = (home or Path.home()) / "Library" / "Preferences" / "MobileMeAccounts.plist"
    try:
        data = plistlib.loads(plist.read_bytes())
    except Exception:  # noqa: BLE001 - missing, unreadable, or a shape we don't know
        return False
    for account in data.get("Accounts", []):
        for service in account.get("Services", []):
            if service.get("Name") != "CLOUDDESKTOP":
                continue
            if service.get("Enabled") is True or service.get("status") == "active":
                return True
    return False


def _cloud_storage_provider(directory: Path) -> str | None:
    """`OneDrive-Contoso` -> "OneDrive". None when the name matches no known client."""
    prefix = directory.name.split("-", 1)[0]
    return _CLOUD_STORAGE_NAMES.get(prefix)


def detect_sync_provider(path: Path, *, home: Path | None = None) -> SyncProvider | None:
    """The sync client that would upload `path`, or None when it stays local.

    Walks `path` and its ancestors up to and including `home`, then stops. Home is
    checked (a home directory that is itself a sync root syncs everything in it)
    but nothing above it is: a Mac whose home happens to live under a folder named
    `Dropbox` is not evidence about the library.

    `home` is injectable so tests can build a whole fake home under `tmp_path`.
    """
    home = home or Path.home()
    # Follow symlinks first: a library symlinked into a sync folder still syncs.
    # Home is resolved too, so the `ancestor == home` stop still fires on a Mac
    # whose home directory is itself reached through a symlink.
    try:
        path = path.expanduser().resolve()
        home = home.expanduser().resolve()
    except OSError:
        path = path.expanduser()
        home = home.expanduser()
    cloud_storage = home / "Library" / "CloudStorage"
    mobile_documents = home / "Library" / "Mobile Documents"

    for ancestor in [path, *path.parents]:
        if ancestor.parent == cloud_storage:
            provider = _cloud_storage_provider(ancestor) or "an unidentified sync client"
            return SyncProvider(
                name=provider,
                evidence=f"the library is inside the {provider} sync folder at {ancestor}",
                root=ancestor,
            )
        if ancestor == mobile_documents:
            return SyncProvider(
                name="iCloud Drive",
                evidence=f"the library is inside iCloud Drive at {ancestor}",
                root=ancestor,
            )

        attrs = _listxattr(ancestor)
        if ICLOUD_DESKTOP_XATTR in attrs:
            return SyncProvider(
                name="iCloud Drive",
                evidence=(
                    f"{ancestor} is synced by iCloud's Desktop & Documents Folders setting"
                ),
                root=ancestor,
            )
        if FILE_PROVIDER_XATTR in attrs:
            return SyncProvider(
                name="an unidentified sync client",
                evidence=f"{ancestor} is managed by a macOS File Provider sync extension",
                root=ancestor,
            )

        legacy = _LEGACY_DIRECTORY_NAMES.get(ancestor.name)
        if legacy is not None:
            return SyncProvider(
                name=legacy,
                evidence=f"the library is inside a {legacy} folder at {ancestor}",
                root=ancestor,
            )

        if ancestor == home:
            break
    return None

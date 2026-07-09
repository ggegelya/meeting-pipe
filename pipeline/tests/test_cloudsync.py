"""Cloud-sync detection over a fake `$HOME` (SEC12).

The xattr tests stamp real extended attributes with `/usr/bin/xattr` and skip
where that is unavailable, so they exercise the same `listxattr(2)` path the
detector uses in production rather than a mock of it.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from mp.cloudsync import (
    FILE_PROVIDER_XATTR,
    ICLOUD_DESKTOP_XATTR,
    detect_sync_provider,
    icloud_desktop_sync_enabled,
)

_XATTR = shutil.which("xattr")
requires_xattr = pytest.mark.skipif(_XATTR is None, reason="/usr/bin/xattr unavailable")


def _stamp(path: Path, name: str) -> None:
    subprocess.run([_XATTR, "-w", name, "1", str(path)], check=True)


def _library(home: Path, *parts: str) -> Path:
    path = home.joinpath(*parts)
    path.mkdir(parents=True, exist_ok=True)
    return path


# ---------- the negative case, which has to stay negative --------------------


def test_a_plain_library_is_not_synced(tmp_path: Path) -> None:
    library = _library(tmp_path, "Meetings", "raw")
    assert detect_sync_provider(library, home=tmp_path) is None


def test_a_library_under_a_plain_documents_folder_is_not_synced(tmp_path: Path) -> None:
    # The regression that matters: `~/Documents` with iCloud Drive on but
    # Desktop & Documents OFF must not be flagged. Nothing is stamped here.
    library = _library(tmp_path, "Documents", "Meetings", "raw")
    assert detect_sync_provider(library, home=tmp_path) is None


# ---------- CloudStorage roots ----------------------------------------------


@pytest.mark.parametrize(
    ("directory", "expected"),
    [
        ("OneDrive-Contoso", "OneDrive"),
        ("GoogleDrive-me@example.com", "Google Drive"),
        ("Dropbox-Personal", "Dropbox"),
        ("iCloudDrive", "iCloud Drive"),
        ("Box-Work", "Box"),
    ],
)
def test_cloudstorage_roots_name_their_provider(tmp_path: Path, directory: str, expected: str) -> None:
    library = _library(tmp_path, "Library", "CloudStorage", directory, "Meetings", "raw")
    provider = detect_sync_provider(library, home=tmp_path)
    assert provider is not None
    assert provider.name == expected
    assert provider.root.name == directory


def test_an_unknown_cloudstorage_provider_still_warns(tmp_path: Path) -> None:
    library = _library(tmp_path, "Library", "CloudStorage", "Weirdsync-acct", "raw")
    provider = detect_sync_provider(library, home=tmp_path)
    assert provider is not None
    assert provider.name == "an unidentified sync client"


def test_the_cloudstorage_directory_itself_is_not_a_provider(tmp_path: Path) -> None:
    # `~/Library/CloudStorage` is the container, not a sync root.
    library = _library(tmp_path, "Library", "CloudStorage")
    assert detect_sync_provider(library, home=tmp_path) is None


# ---------- iCloud Drive proper ---------------------------------------------


def test_mobile_documents_is_icloud_drive(tmp_path: Path) -> None:
    library = _library(tmp_path, "Library", "Mobile Documents", "com~apple~CloudDocs", "raw")
    provider = detect_sync_provider(library, home=tmp_path)
    assert provider is not None
    assert provider.name == "iCloud Drive"


# ---------- extended attributes ---------------------------------------------


@requires_xattr
def test_the_icloud_desktop_xattr_on_an_ancestor_is_detected(tmp_path: Path) -> None:
    # This is how macOS actually marks Desktop & Documents sync: an xattr on
    # `~/Documents`, not a symlink and not anything `resolve()` can see.
    documents = _library(tmp_path, "Documents")
    library = _library(tmp_path, "Documents", "Meetings", "raw")
    _stamp(documents, ICLOUD_DESKTOP_XATTR)

    provider = detect_sync_provider(library, home=tmp_path)
    assert provider is not None
    assert provider.name == "iCloud Drive"
    assert provider.root == documents
    assert "Desktop & Documents" in provider.evidence


def test_a_bare_file_provider_xattr_warns_without_naming_a_provider(tmp_path, monkeypatch) -> None:
    # `com.apple.file-provider-domain-id` is a protected attribute an unprivileged
    # process cannot write, so this one has to fake the read rather than the disk.
    root = _library(tmp_path, "Somewhere")
    library = _library(tmp_path, "Somewhere", "raw")
    monkeypatch.setattr(
        "mp.cloudsync._listxattr",
        lambda path: {FILE_PROVIDER_XATTR} if path == root else set(),
    )
    provider = detect_sync_provider(library, home=tmp_path)
    assert provider is not None
    assert provider.name == "an unidentified sync client"


def test_detection_does_not_walk_above_home(tmp_path: Path) -> None:
    # A folder named "Dropbox" *above* $HOME is somebody else's business. Walking
    # into it would flag every library on a Mac whose home happens to sit under
    # one, so the walk stops at home.
    home = tmp_path / "Dropbox" / "user"
    library = home / "Meetings" / "raw"
    library.mkdir(parents=True)
    assert detect_sync_provider(library, home=home) is None


@requires_xattr
def test_a_synced_home_is_itself_detected(tmp_path: Path) -> None:
    # Home is the last ancestor checked, not the first one skipped: if the whole
    # home directory is a sync root, the library inside it syncs too.
    _stamp(tmp_path, ICLOUD_DESKTOP_XATTR)
    library = _library(tmp_path, "Meetings", "raw")
    provider = detect_sync_provider(library, home=tmp_path)
    assert provider is not None
    assert provider.root == tmp_path


# ---------- legacy, pre-FileProvider clients ---------------------------------


@pytest.mark.parametrize(
    ("directory", "expected"),
    [("Dropbox", "Dropbox"), ("Google Drive", "Google Drive"), ("Box Sync", "Box")],
)
def test_legacy_directory_names_are_detected(tmp_path: Path, directory: str, expected: str) -> None:
    library = _library(tmp_path, directory, "Meetings", "raw")
    provider = detect_sync_provider(library, home=tmp_path)
    assert provider is not None
    assert provider.name == expected


# ---------- symlinks ---------------------------------------------------------


def test_a_library_symlinked_into_a_sync_folder_is_detected(tmp_path: Path) -> None:
    real = _library(tmp_path, "Library", "CloudStorage", "Dropbox-Personal", "raw")
    link = tmp_path / "Meetings"
    link.symlink_to(real)
    provider = detect_sync_provider(link, home=tmp_path)
    assert provider is not None
    assert provider.name == "Dropbox"


# ---------- MobileMeAccounts corroborator ------------------------------------


def test_icloud_desktop_sync_enabled_reads_the_clouddesktop_service(tmp_path: Path) -> None:
    import plistlib

    prefs = tmp_path / "Library" / "Preferences"
    prefs.mkdir(parents=True)
    plist = prefs / "MobileMeAccounts.plist"

    # macOS 26 shape: `status: active`. Note MOBILE_DOCUMENTS (iCloud Drive) is on
    # here too, and must not be what we key on.
    plist.write_bytes(plistlib.dumps({"Accounts": [{"Services": [
        {"Name": "MOBILE_DOCUMENTS", "Enabled": True},
        {"Name": "CLOUDDESKTOP", "status": "active"},
    ]}]}))
    assert icloud_desktop_sync_enabled(tmp_path) is True

    # Older shape: `Enabled: True`.
    plist.write_bytes(plistlib.dumps({"Accounts": [{"Services": [
        {"Name": "CLOUDDESKTOP", "Enabled": True},
    ]}]}))
    assert icloud_desktop_sync_enabled(tmp_path) is True

    # Desktop & Documents off, iCloud Drive on. The false-positive we must avoid.
    plist.write_bytes(plistlib.dumps({"Accounts": [{"Services": [
        {"Name": "MOBILE_DOCUMENTS", "Enabled": True},
        {"Name": "CLOUDDESKTOP", "status": "inactive"},
    ]}]}))
    assert icloud_desktop_sync_enabled(tmp_path) is False


def test_icloud_desktop_sync_enabled_is_false_without_a_plist(tmp_path: Path) -> None:
    assert icloud_desktop_sync_enabled(tmp_path) is False

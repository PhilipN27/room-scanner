#!/usr/bin/env python3
"""Inspect a compiled RoomScanStudio app for the Slice 4 local boundary."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import sys
from typing import Any


EXPECTED_BUNDLE_IDENTIFIER = "org.roomscanstudio.app"
REQUIRED_SYMBOLS = (
    "ProfessionalEnvironmentFactory",
    "DeviceAuthenticationCoordinator",
    "AppleDeviceAuthenticationContextFactory",
    "ProfessionalHTTPTransport",
    "FoundationProfessionalHTTPTransport",
)


class ArtifactInspectionError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(128 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _compiled_images(app: Path) -> list[Path]:
    images = [app / "RoomScanStudio", app / "RoomScanStudio.debug.dylib"]
    present = [image for image in images if image.is_file()]
    if not present:
        raise ArtifactInspectionError(f"no RoomScanStudio executable image in {app}")
    return present


def inspect_app(app: Path) -> dict[str, Any]:
    app = app.resolve()
    info_path = app / "Info.plist"
    if not app.is_dir() or not info_path.is_file():
        raise ArtifactInspectionError(f"missing compiled app bundle or Info.plist: {app}")
    try:
        with info_path.open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ArtifactInspectionError(f"cannot parse built Info.plist: {error}") from error
    bundle_identifier = info.get("CFBundleIdentifier")
    if bundle_identifier != EXPECTED_BUNDLE_IDENTIFIER:
        raise ArtifactInspectionError(f"unexpected compiled bundle identifier: {bundle_identifier!r}")
    face_id_copy = str(info.get("NSFaceIDUsageDescription", ""))
    if "Face ID or" not in face_id_copy or "device passcode" not in face_id_copy:
        raise ArtifactInspectionError("compiled app lost the Face ID-or-device-passcode usage copy")
    images = _compiled_images(app)
    bytes_to_scan = b"".join(image.read_bytes() for image in images)
    missing = [symbol for symbol in REQUIRED_SYMBOLS if symbol.encode("utf-8") not in bytes_to_scan]
    if missing:
        raise ArtifactInspectionError("compiled app lost required Slice 4 symbols: " + ", ".join(missing))
    return {
        "schemaVersion": 1,
        "app": str(app),
        "bundleIdentifier": bundle_identifier,
        "faceIdUsage": "PASS",
        "missingSymbols": [],
        "images": [
            {"path": str(image), "bytes": image.stat().st_size, "sha256": _sha256(image)}
            for image in images
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        result = inspect_app(arguments.app)
    except ArtifactInspectionError as error:
        print(str(error), file=sys.stderr)
        return 1
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Inspect a compiled RoomScanStudio app for the Slice 6 delivery boundary."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts import inspect_ios_artifact, inspect_slice5_ios_artifact


SLICE4_REQUIRED_MARKERS = inspect_ios_artifact.REQUIRED_SYMBOLS
SLICE5_REQUIRED_MARKERS = inspect_slice5_ios_artifact.SLICE5_REQUIRED_MARKERS
SLICE6_REQUIRED_MARKERS = (
    "roomscan-published-room-snapshot-v2",
    "roomscan-published-property-snapshot-v1",
    "roomscan-publication-selection-manifest-v1",
    "roomscan-publication-archive-v1",
    "roomscan-publication-operation-journal-root-v1",
    "/publications/snapshots/allocate",
    "/publications/snapshots/complete",
    "/publications/snapshots/status",
    "/publications/links/create",
    "/publications/links/list",
    "/publications/links/revoke",
    "publication.title",
    "publication.independentRooms",
    "publication.snapshotUnavailable",
    "publication.aiDownload",
    "Presented with RoomScanStudio",
    (
        "Rooms are presented independently; they do not share coordinates, "
        "alignment, connectivity, or reconstruction."
    ),
)
FORBIDDEN_MARKERS = (
    "lastWriterWins",
    "continuousMultiRoomReconstruction",
    "browserCaptureEnabled",
    "completeWhiteLabeling",
    "customPublicationDomain",
)


class ArtifactInspectionError(RuntimeError):
    """The compiled app does not preserve the Slice 6 boundary."""


def _compiled_bytes(app: Path) -> bytes:
    images = inspect_ios_artifact._compiled_images(app)  # noqa: SLF001 - shared verifier primitive
    return b"".join(image.read_bytes() for image in images)


def _marker_findings(payload: bytes, markers: Iterable[str]) -> list[str]:
    return sorted(marker for marker in set(markers) if marker.encode("utf-8") in payload)


def run_forbidden_marker_positive_control() -> bool:
    payload = b"safe\x00" + b"\x00".join(marker.encode("utf-8") for marker in FORBIDDEN_MARKERS)
    findings = _marker_findings(payload, FORBIDDEN_MARKERS)
    if findings != sorted(FORBIDDEN_MARKERS) or _marker_findings(b"safe", FORBIDDEN_MARKERS):
        raise ArtifactInspectionError("forbidden-marker positive control did not discriminate")
    return True


def inspect_app(
    app: Path,
    *,
    require_markers: Iterable[str] = (),
    forbid_markers: Iterable[str] = (),
) -> dict[str, Any]:
    """Inspect real compiled images while retaining all Slice 4/5 requirements."""

    app = app.resolve()
    try:
        base = inspect_ios_artifact.inspect_app(app)
    except inspect_ios_artifact.ArtifactInspectionError as error:
        raise ArtifactInspectionError(str(error)) from error
    run_forbidden_marker_positive_control()
    payload = _compiled_bytes(app)
    required = tuple(
        dict.fromkeys((*SLICE5_REQUIRED_MARKERS, *SLICE6_REQUIRED_MARKERS, *require_markers))
    )
    forbidden = tuple(dict.fromkeys((*FORBIDDEN_MARKERS, *forbid_markers)))
    present = _marker_findings(payload, required)
    missing = sorted(set(required) - set(present))
    forbidden_found = _marker_findings(payload, forbidden)
    if missing:
        raise ArtifactInspectionError(
            "compiled app lost required Slice 5/6 markers: " + ", ".join(missing)
        )
    if forbidden_found:
        raise ArtifactInspectionError(
            "compiled app contains excluded architecture markers: "
            + ", ".join(forbidden_found)
        )
    return {
        **base,
        "schemaVersion": 3,
        "status": "PASS",
        "requiredMarkers": [*SLICE4_REQUIRED_MARKERS, *required],
        "missingMarkers": [],
        "forbiddenMarkers": list(forbidden),
        "forbiddenMarkersFound": [],
        "forbiddenMarkerPositiveControl": "PASS",
        "slice5RequiredMarkersRetained": "PASS",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--require-marker", action="append", default=[])
    parser.add_argument("--forbid-marker", action="append", default=[])
    arguments = parser.parse_args()
    try:
        result = inspect_app(
            arguments.app,
            require_markers=arguments.require_marker,
            forbid_markers=arguments.forbid_marker,
        )
    except ArtifactInspectionError as error:
        print(str(error), file=sys.stderr)
        return 1
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

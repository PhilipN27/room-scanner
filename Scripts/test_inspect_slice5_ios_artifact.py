"""Self-tests for the compiled iOS Slice 5 boundary inspector."""

from __future__ import annotations

import plistlib
from pathlib import Path
import tempfile
import unittest

from Scripts import inspect_slice5_ios_artifact


class Slice5IOSArtifactInspectionTests(unittest.TestCase):
    def make_app(self, root: Path, payload: bytes) -> Path:
        app = root / "RoomScanStudio.app"
        app.mkdir()
        with (app / "Info.plist").open("wb") as destination:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "org.roomscanstudio.app",
                    "NSFaceIDUsageDescription": (
                        "Use Face ID or device passcode to unlock professional access."
                    ),
                },
                destination,
            )
        (app / "RoomScanStudio").write_bytes(payload)
        return app

    def test_inspector_requires_slice4_and_every_slice5_compiled_marker(self) -> None:
        payload = b"\x00".join(
            marker.encode("utf-8")
            for marker in (
                *inspect_slice5_ios_artifact.SLICE4_REQUIRED_MARKERS,
                *inspect_slice5_ios_artifact.SLICE5_REQUIRED_MARKERS,
            )
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app(Path(temporary_directory), payload)
            inspection = inspect_slice5_ios_artifact.inspect_app(app)

        self.assertEqual(inspection["status"], "PASS")
        self.assertEqual(inspection["missingMarkers"], [])
        self.assertEqual(inspection["forbiddenMarkersFound"], [])

    def test_inspector_rejects_missing_conflict_action_and_forbidden_slice6_marker(self) -> None:
        markers = [
            *inspect_slice5_ios_artifact.SLICE4_REQUIRED_MARKERS,
            *inspect_slice5_ios_artifact.SLICE5_REQUIRED_MARKERS,
        ]
        markers.remove("professional.sync.conflict.duplicate")
        markers.append("roomscan-slice6")
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app(
                Path(temporary_directory),
                b"\x00".join(marker.encode("utf-8") for marker in markers),
            )
            with self.assertRaises(inspect_slice5_ios_artifact.ArtifactInspectionError):
                inspect_slice5_ios_artifact.inspect_app(app)

    def test_positive_control_proves_forbidden_marker_detector_is_live(self) -> None:
        self.assertTrue(inspect_slice5_ios_artifact.run_forbidden_marker_positive_control())


if __name__ == "__main__":
    unittest.main()

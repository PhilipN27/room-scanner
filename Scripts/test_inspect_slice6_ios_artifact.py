"""Self-tests for the compiled iOS Slice 6 boundary inspector."""

from __future__ import annotations

import plistlib
from pathlib import Path
import tempfile
import unittest

from Scripts import inspect_slice6_ios_artifact


class Slice6IOSArtifactInspectionTests(unittest.TestCase):
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

    def complete_payload(self) -> bytes:
        return b"\x00".join(
            marker.encode("utf-8")
            for marker in (
                *inspect_slice6_ios_artifact.SLICE4_REQUIRED_MARKERS,
                *inspect_slice6_ios_artifact.SLICE5_REQUIRED_MARKERS,
                *inspect_slice6_ios_artifact.SLICE6_REQUIRED_MARKERS,
                "roomscan-slice6",
            )
        )

    def test_inspector_requires_slice4_slice5_and_every_slice6_compiled_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app(Path(temporary_directory), self.complete_payload())
            inspection = inspect_slice6_ios_artifact.inspect_app(app)

        self.assertEqual(inspection["status"], "PASS")
        self.assertEqual(inspection["missingMarkers"], [])
        self.assertEqual(inspection["forbiddenMarkersFound"], [])
        self.assertEqual(inspection["slice5RequiredMarkersRetained"], "PASS")

    def test_inspector_rejects_a_missing_slice5_marker(self) -> None:
        payload = self.complete_payload().replace(b"professional.sync.conflict.duplicate", b"")
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app(Path(temporary_directory), payload)
            with self.assertRaises(inspect_slice6_ios_artifact.ArtifactInspectionError):
                inspect_slice6_ios_artifact.inspect_app(app)

    def test_inspector_rejects_an_excluded_architecture_marker(self) -> None:
        payload = self.complete_payload() + b"\x00continuousMultiRoomReconstruction"
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = self.make_app(Path(temporary_directory), payload)
            with self.assertRaises(inspect_slice6_ios_artifact.ArtifactInspectionError):
                inspect_slice6_ios_artifact.inspect_app(app)

    def test_positive_control_proves_forbidden_marker_detector_is_live(self) -> None:
        self.assertTrue(inspect_slice6_ios_artifact.run_forbidden_marker_positive_control())


if __name__ == "__main__":
    unittest.main()

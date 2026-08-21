"""Self-tests for the compiled iOS Slice 4 boundary inspector."""

from __future__ import annotations

import plistlib
from pathlib import Path
import tempfile
import unittest

from Scripts import inspect_ios_artifact


class IOSArtifactInspectionTests(unittest.TestCase):
    def test_inspector_requires_bundle_identity_faceid_copy_and_compiled_boundary_symbols(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = Path(temporary_directory) / "RoomScanStudio.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as destination:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "org.roomscanstudio.app",
                        "NSFaceIDUsageDescription": "Use Face ID or device passcode to unlock professional access.",
                    },
                    destination,
                )
            (app / "RoomScanStudio").write_bytes(
                b"\x00ProfessionalEnvironmentFactory\x00DeviceAuthenticationCoordinator\x00"
                b"AppleDeviceAuthenticationContextFactory\x00ProfessionalHTTPTransport\x00"
                b"FoundationProfessionalHTTPTransport\x00"
            )

            inspection = inspect_ios_artifact.inspect_app(app)

        self.assertEqual(inspection["bundleIdentifier"], "org.roomscanstudio.app")
        self.assertEqual(inspection["missingSymbols"], [])
        self.assertEqual(inspection["faceIdUsage"], "PASS")

    def test_inspector_rejects_a_bundle_that_loses_a_required_compiled_symbol(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = Path(temporary_directory) / "RoomScanStudio.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as destination:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "org.roomscanstudio.app",
                        "NSFaceIDUsageDescription": "Face ID or device passcode.",
                    },
                    destination,
                )
            (app / "RoomScanStudio").write_bytes(b"ProfessionalEnvironmentFactory")

            with self.assertRaises(inspect_ios_artifact.ArtifactInspectionError):
                inspect_ios_artifact.inspect_app(app)


if __name__ == "__main__":
    unittest.main()

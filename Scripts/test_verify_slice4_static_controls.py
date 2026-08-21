"""Positive controls for the Slice 4 static detectors used by CI."""

from __future__ import annotations

import unittest
from unittest import mock
import subprocess
import sys
from pathlib import Path

from Scripts import verify_slice4_static_controls


class StaticControlTests(unittest.TestCase):
    def test_release_projection_removes_only_debug_branch_and_keeps_release_else(self) -> None:
        source = """let alwaysPresent = DefaultGuestFactory()
#if DEBUG
let evidenceOnly = AppleDeviceAuthenticationContextFactory()
#if targetEnvironment(simulator)
let nestedDebugOnly = ProfessionalKeychainAccessPolicy()
#endif
#else
let releaseDefault = DefaultGuestFactory()
#endif
"""

        projected = (
            verify_slice4_static_controls.verify_xcode_scaffold
            .swift_release_projection(source)
        )

        self.assertIn("alwaysPresent", projected)
        self.assertIn("releaseDefault", projected)
        self.assertNotIn("evidenceOnly", projected)
        self.assertNotIn("nestedDebugOnly", projected)
        self.assertEqual(projected.count("\n"), source.count("\n"))

    def test_release_projection_keeps_unconditional_guest_violation_detectable(self) -> None:
        source = """#if DEBUG
let evidenceOnly = AppleDeviceAuthenticationContextFactory()
#endif
let unsafe = URLSession.shared
"""

        projected = (
            verify_slice4_static_controls.verify_xcode_scaffold
            .swift_release_projection(source)
        )

        self.assertNotIn("AppleDeviceAuthenticationContextFactory", projected)
        self.assertIn("URLSession.shared", projected)

    def test_unguarded_guest_to_auth_adapter_edge_remains_detectable(self) -> None:
        verifier = verify_slice4_static_controls.verify_xcode_scaffold
        sources = verifier.read_guest_production_sources()
        app_environment = (
            verifier.ROOT
            / "RoomScanStudio"
            / "App"
            / "AppEnvironment.swift"
        )
        unsafe = dict(sources)
        unsafe[app_environment] += (
            "\nprivate let unguardedAuthenticationAdapter = "
            "AppleDeviceAuthenticationContextFactory()\n"
        )

        errors = verifier.guest_hosted_boundary_errors(unsafe)

        self.assertTrue(
            any(
                "guest composition reaches dedicated professional/auth adapter"
                in error
                and "AppleDeviceAuthenticationContext.swift" in error
                for error in errors
            ),
            errors,
        )

    def test_real_guest_network_and_secret_detectors_reach_their_positive_controls(self) -> None:
        result = verify_slice4_static_controls.run_controls()

        self.assertEqual(result["guestNetworkScanner"], "PASS")
        self.assertEqual(result["structuredSecretScanner"], "PASS")

    def test_cli_runs_from_the_repository_root(self) -> None:
        root = Path(__file__).resolve().parents[1]
        completed = subprocess.run(
            [sys.executable, "-B", "Scripts/verify_slice4_static_controls.py"],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn('"guestNetworkScanner": "PASS"', completed.stdout)

    def test_existing_guest_violation_fails_before_the_positive_control(self) -> None:
        sources = verify_slice4_static_controls.verify_xcode_scaffold.read_guest_production_sources()
        app_environment = (
            verify_slice4_static_controls.verify_xcode_scaffold.ROOT
            / "RoomScanStudio"
            / "App"
            / "AppEnvironment.swift"
        )
        unsafe = dict(sources)
        unsafe[app_environment] += "\nprivate let task7Unsafe = URLSession.shared\n"

        with mock.patch.object(
            verify_slice4_static_controls.verify_xcode_scaffold,
            "read_guest_production_sources",
            return_value=unsafe,
        ):
            with self.assertRaisesRegex(RuntimeError, "guest-network baseline"):
                verify_slice4_static_controls.run_controls()


if __name__ == "__main__":
    unittest.main()

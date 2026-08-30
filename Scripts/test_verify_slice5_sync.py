"""Self-tests for the Slice 5 component and final evidence verifier."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from Scripts import verify_slice5_sync


class ComponentReportTests(unittest.TestCase):
    def valid_report(self) -> dict[str, object]:
        return {
            "schemaVersion": 1,
            "status": "PASS",
            "postgresql": {"major": 16, "status": "PASS"},
            "logicalClients": ["client-a", "client-b"],
            "swiftTests": {"status": "PASS", "passed": 267},
            "crashCutPoints": {
                point: "PASS" for point in verify_slice5_sync.REQUIRED_CRASH_CUT_POINTS
            },
            "rawInventory": {
                "positiveControl": "PASS",
                "defaultWorkingSet": "PASS",
                "reviewedRawSeparateTier": "PASS",
            },
            "clauses": {
                str(index): {"status": "PASS", "evidence": [f"oracle-{index}"]}
                for index in range(1, 8)
            },
        }

    def test_component_report_requires_all_clauses_and_postgresql_16(self) -> None:
        report = self.valid_report()
        verify_slice5_sync.validate_component_report(report)
        del report["clauses"]["6"]  # type: ignore[index]
        with self.assertRaises(verify_slice5_sync.VerificationError):
            verify_slice5_sync.validate_component_report(report)

        wrong_postgres = self.valid_report()
        wrong_postgres["postgresql"] = {"major": 15, "status": "PASS"}
        with self.assertRaises(verify_slice5_sync.VerificationError):
            verify_slice5_sync.validate_component_report(wrong_postgres)

        regressed_swift = self.valid_report()
        regressed_swift["swiftTests"] = {"status": "PASS", "passed": 266}
        with self.assertRaises(verify_slice5_sync.VerificationError):
            verify_slice5_sync.validate_component_report(regressed_swift)

    def test_negative_raw_claim_requires_live_positive_control(self) -> None:
        report = self.valid_report()
        report["rawInventory"]["positiveControl"] = "FAIL"  # type: ignore[index]
        with self.assertRaises(verify_slice5_sync.VerificationError):
            verify_slice5_sync.validate_component_report(report)

    def test_fixture_digest_manifest_rejects_stale_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = root / "fixture.bin"
            fixture.write_bytes(b"current fixture")
            digest = verify_slice5_sync.sha256_file(fixture)
            self.assertEqual(
                verify_slice5_sync.validate_fixture_digests(
                    root, {"fixture.bin": digest}
                )["fixture.bin"],
                digest,
            )
            with self.assertRaises(verify_slice5_sync.VerificationError):
                verify_slice5_sync.validate_fixture_digests(
                    root, {"fixture.bin": "0" * 64}
                )

    def test_full_swift_count_uses_executed_oracle_and_rejects_log_without_one(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            log = Path(temporary_directory) / "swift.log"
            log.write_text("Executed 273 tests, with 0 failures", encoding="utf-8")
            self.assertEqual(verify_slice5_sync._swift_test_count(log), 273)
            log.write_text("Build complete", encoding="utf-8")
            with self.assertRaises(verify_slice5_sync.VerificationError):
                verify_slice5_sync._swift_test_count(log)


class FinalEvidenceTests(unittest.TestCase):
    def write_json(self, path: Path, value: object) -> Path:
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_xcresult_summary_rejects_regression_failure_and_missing_slice5_tests(self) -> None:
        summary = {
            "result": "Passed",
            "passedTests": 260,
            "failedTests": 0,
            "totalTestCount": 260,
        }
        names = set(verify_slice5_sync.REQUIRED_XCTESTS)
        verify_slice5_sync.validate_xcresult("iPhone", summary, names)

        with self.assertRaises(verify_slice5_sync.VerificationError):
            verify_slice5_sync.validate_xcresult(
                "iPad", {**summary, "passedTests": 259, "totalTestCount": 259}, names
            )
        with self.assertRaises(verify_slice5_sync.VerificationError):
            verify_slice5_sync.validate_xcresult(
                "iPhone", summary, names - {next(iter(names))}
            )

    def test_finalizer_rejects_missing_early_or_stale_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            marker = root / "run-marker.json"
            marker.write_text("{}", encoding="utf-8")
            evidence = root / "evidence.json"
            evidence.write_text("{}", encoding="utf-8")
            os.utime(evidence, (marker.stat().st_mtime - 5, marker.stat().st_mtime - 5))

            with self.assertRaises(verify_slice5_sync.VerificationError):
                verify_slice5_sync.require_fresh_evidence(marker, [evidence])
            with self.assertRaises(verify_slice5_sync.VerificationError):
                verify_slice5_sync.require_fresh_evidence(marker, [root / "missing.json"])

    def test_screenshot_report_requires_mobile_ipad_desktop_width_and_all_scenarios(self) -> None:
        report = {
            "status": "PASS",
            "reviewStatus": "PASS",
            "reviewedDimensions": list(verify_slice5_sync.REQUIRED_REVIEW_DIMENSIONS),
            "captures": [
                {"deviceClass": device, "scenario": scenario, "sha256": "a" * 64}
                for device in verify_slice5_sync.REQUIRED_SCREENSHOT_DEVICE_CLASSES
                for scenario in verify_slice5_sync.REQUIRED_SCREENSHOT_SCENARIOS
            ],
        }
        verify_slice5_sync.validate_screenshot_report(report)
        report["captures"].pop()
        with self.assertRaises(verify_slice5_sync.VerificationError):
            verify_slice5_sync.validate_screenshot_report(report)

    def test_screenshot_recorder_selects_latest_retry_repetition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "screenshots.json"

            def exported_entries(_xcresult: Path, destination: Path) -> list[dict[str, object]]:
                destination.mkdir()
                device = destination.name

                def attachment(scenario: str, repetition: int | None) -> dict[str, object]:
                    filename = f"{device}-{scenario}-{repetition or 0}.png"
                    (destination / filename).write_bytes(
                        f"{device}/{scenario}/repetition-{repetition or 0}".encode("utf-8")
                    )
                    marker = next(
                        marker
                        for marker, value in verify_slice5_sync.SCREENSHOT_ATTACHMENT_SCENARIOS.items()
                        if value == scenario
                    )
                    value: dict[str, object] = {
                        "exportedFileName": filename,
                        "suggestedHumanReadableName": f"{marker}.png",
                    }
                    if repetition is not None:
                        value["repetitionNumber"] = repetition
                    return value

                if device == "desktop-width":
                    return [
                        {
                            "testIdentifier": "testSlice5DesktopWidthLandscapeScenarios()",
                            "attachments": [
                                attachment(scenario, repetition)
                                for repetition in (1, 2)
                                for scenario in verify_slice5_sync.REQUIRED_SCREENSHOT_SCENARIOS
                            ],
                        }
                    ]

                entries: list[dict[str, object]] = []
                for test_name, scenario in verify_slice5_sync.SCREENSHOT_TEST_SCENARIOS.items():
                    repetitions = (1, 2) if device == "tablet-ipad" else (None,)
                    entries.append(
                        {
                            "testIdentifier": f"RoomScanStudioUITests/{test_name}()",
                            "attachments": [attachment(scenario, repetition) for repetition in repetitions],
                        }
                    )
                return entries

            with mock.patch.object(
                verify_slice5_sync,
                "_export_screenshot_attachments",
                side_effect=exported_entries,
            ):
                report = verify_slice5_sync.record_screenshots(
                    inputs={
                        "mobile-iphone": root / "iphone.xcresult",
                        "tablet-ipad": root / "ipad.xcresult",
                        "desktop-width": root / "ipad.xcresult",
                    },
                    screenshots_directory=root / "screenshots",
                    output=output,
                    review_status="PASS",
                )

            self.assertEqual(len(report["captures"]), 9)
            tablet_migration = next(
                capture
                for capture in report["captures"]
                if capture["deviceClass"] == "tablet-ipad"
                and capture["scenario"] == "migration-retry"
            )
            selected = output.parent / tablet_migration["path"]
            self.assertEqual(selected.read_bytes(), b"tablet-ipad/migration-retry/repetition-2")

    def test_finalizer_consumes_reports_and_actual_xcresult_reader(self) -> None:
        component = ComponentReportTests().valid_report()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            marker = self.write_json(root / "marker.json", {"schemaVersion": 1})
            screenshot_captures = []
            for device in verify_slice5_sync.REQUIRED_SCREENSHOT_DEVICE_CLASSES:
                for scenario in verify_slice5_sync.REQUIRED_SCREENSHOT_SCENARIOS:
                    screenshot = root / f"{device}-{scenario}.png"
                    screenshot.write_bytes(f"{device}/{scenario}".encode("utf-8"))
                    screenshot_captures.append(
                        {
                            "deviceClass": device,
                            "scenario": scenario,
                            "path": screenshot.name,
                            "sha256": verify_slice5_sync.sha256_file(screenshot),
                        }
                    )
            inputs = {
                "component_report": self.write_json(root / "component.json", component),
                "mutation_report": self.write_json(root / "mutations.json", {"status": "PASS"}),
                "slice4_report": self.write_json(root / "slice4.json", {"status": "PASS"}),
                "artifact_report": self.write_json(
                    root / "artifact.json",
                    {
                        "status": "PASS",
                        "requiredMarkers": list(verify_slice5_sync.REQUIRED_ARTIFACT_MARKERS),
                        "missingMarkers": [],
                        "forbiddenMarkersFound": [],
                    },
                ),
                "screenshot_report": self.write_json(
                    root / "screenshots.json",
                    {
                        "status": "PASS",
                        "reviewStatus": "PASS",
                        "reviewedDimensions": list(
                            verify_slice5_sync.REQUIRED_REVIEW_DIMENSIONS
                        ),
                        "captures": screenshot_captures,
                    },
                ),
                "iphone_xcresult": root / "iphone.xcresult",
                "ipad_xcresult": root / "ipad.xcresult",
            }
            inputs["iphone_xcresult"].mkdir()
            inputs["ipad_xcresult"].mkdir()
            for path in inputs.values():
                os.utime(path, (marker.stat().st_mtime + 5, marker.stat().st_mtime + 5))
            summary = {
                "result": "Passed",
                "passedTests": 260,
                "failedTests": 0,
                "totalTestCount": 260,
            }
            with mock.patch.object(
                verify_slice5_sync,
                "read_xcresult",
                side_effect=[
                    (summary, set(verify_slice5_sync.REQUIRED_XCTESTS)),
                    (summary, set(verify_slice5_sync.REQUIRED_XCTESTS)),
                ],
            ):
                result = verify_slice5_sync.finalize_evidence(marker=marker, **inputs)

        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["clauses"]["8"]["status"], "PASS")


if __name__ == "__main__":
    unittest.main()

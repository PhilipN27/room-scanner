"""Self-tests for Slice 6 publication evidence aggregation."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from Scripts import verify_slice6_publication


def screenshot_png(pixel: bytes = b"\xff\xff\xff\xff") -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00" + pixel))
            + chunk(b"IEND", b""))


class FixtureAndLogEvidenceTests(unittest.TestCase):
    def test_fixture_digest_inventory_rejects_stale_fixture_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixture = root / "fixtures" / "publication.zip.base64"
            fixture.parent.mkdir()
            fixture.write_bytes(b"current fixture bytes")
            expected = {"fixtures/publication.zip.base64": hashlib.sha256(fixture.read_bytes()).hexdigest()}

            verified = verify_slice6_publication.validate_fixture_digests(root, expected)
            self.assertEqual(verified, expected)

            fixture.write_bytes(b"stale fixture bytes")
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_fixture_digests(root, expected)

    def test_raw_node_output_requires_named_executed_tests_full_count_and_no_skips(self) -> None:
        output = "\n".join(
            [
                "✔ archive closure reaches an injected raw artifact after its archive identity is recomputed",
                "✔ portal delivery emits an exact range only after the live finalizer, including a post-read revocation barrier",
                "ℹ tests 304",
                "ℹ pass 304",
                "ℹ fail 0",
                "ℹ skipped 0",
            ]
        )
        result = verify_slice6_publication.validate_node_test_output(
            output,
            label="service",
            minimum_tests=304,
            required_tests=(
                "archive closure reaches an injected raw artifact after its archive identity is recomputed",
                "portal delivery emits an exact range only after the live finalizer, including a post-read revocation barrier",
            ),
        )
        self.assertEqual(result["passed"], 304)

        skipped = output.replace("ℹ skipped 0", "ℹ skipped 1")
        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_node_test_output(
                skipped,
                label="service",
                minimum_tests=304,
                required_tests=(
                    "archive closure reaches an injected raw artifact after its archive identity is recomputed",
                ),
            )

    def test_ten_clause_report_rejects_a_skipped_clause(self) -> None:
        clauses = {
            str(number): {"status": "PASS", "evidence": [f"oracle-{number}"]}
            for number in range(1, 11)
        }
        verify_slice6_publication.validate_clause_results(clauses)

        clauses["9"] = {"status": "SKIPPED", "evidence": []}
        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_clause_results(clauses)

    def test_swift_and_python_raw_summaries_reject_count_regression_or_failures(self) -> None:
        swift_output = "\n".join(
            [
                "Test Case '-[RoomScanCoreTests.RoomPublishedSnapshotTests testApprovalRequiresExactSourceAndSelectionBindings]' passed",
                "Test Case '-[RoomScanCoreTests.RoomPublishedSnapshotTests testArchiveClosureKeepsPortalPresentationPrivateFieldFree]' passed",
                "Test Case '-[RoomScanCoreTests.RoomPublishedSnapshotTests testPublicationGoldenFixturesMatchExactProductionArchivesAndRelationships]' passed",
                "Executed 318 tests, with 0 failures (0 unexpected) in 12.34 seconds",
            ]
        )
        self.assertEqual(
            verify_slice6_publication.validate_swift_test_output(swift_output)["passed"], 318
        )
        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_swift_test_output(
                swift_output.replace("318 tests", "317 tests")
            )

        python_output = "Ran 51 tests in 0.123s\n\nOK\n"
        self.assertEqual(
            verify_slice6_publication.validate_python_test_output(python_output)["passed"], 51
        )
        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_python_test_output(
                python_output.replace("OK", "FAILED (failures=1)")
            )

    def test_service_log_requires_the_current_368_test_floor_and_property_oracles(self) -> None:
        output = "\n".join(
            [*(f"✔ {name}" for name in verify_slice6_publication.REQUIRED_SERVICE_TESTS), "ℹ tests 368", "ℹ pass 368", "ℹ fail 0", "ℹ skipped 0"]
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "service.log"
            path.write_text(output, encoding="utf-8")
            self.assertEqual(
                verify_slice6_publication._validate_service_log(path)["tests"],  # noqa: SLF001
                368,
            )
            path.write_text(output.replace("ℹ tests 368", "ℹ tests 367").replace("ℹ pass 368", "ℹ pass 367"), encoding="utf-8")
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication._validate_service_log(path)  # noqa: SLF001


class DependencyEvidenceTests(unittest.TestCase):
    def test_runtime_and_prior_oracle_reports_need_real_records_not_pass_booleans(self) -> None:
        self.assertEqual(
            verify_slice6_publication.validate_node_runtime_output("v24.15.0\n")["version"],
            "v24.15.0",
        )
        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_node_runtime_output("v20.0.0\n")

        report = {
            "schemaVersion": 1,
            "status": "PASS",
            "steps": [
                {
                    "label": "full local oracle",
                    "command": ["npm", "test"],
                    "cwd": "/workspace/HostedService",
                    "exitCode": 0,
                    "outputBytes": 123,
                    "outputSha256": "a" * 64,
                    "log": "/workspace/hosted.log",
                }
            ],
        }
        self.assertEqual(
            verify_slice6_publication.validate_step_report(
                report, label="Slice 4", required_labels=("full local oracle",)
            )["status"],
            "PASS",
        )
        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_step_report(
                {"schemaVersion": 1, "status": "PASS"},
                label="Slice 4",
                required_labels=("full local oracle",),
            )


class BrowserEvidenceTests(unittest.TestCase):
    BROWSER_TESTS = (
        "interactive property portal covers floor plan, orientation, comparison, navigation, downloads, feedback, accessibility, and token confinement",
        "PIN gate fails closed, clears each probe, and opens only on the correct value",
        "an already active session and protected asset fail immediately after revocation",
        "verified professional sign-in exposes exactly the eight bounded flows and keeps stored content inert",
        "mobile portal presents bounded static fallback with responsive navigation and accessible controls",
        "mobile professional workspace reflows its bounded navigation and presents signed-in room curation controls",
    )

    def browser_results(self) -> dict[str, object]:
        return {
            "suites": [
                {
                    "specs": [
                        {
                            "title": title,
                            "ok": True,
                            "tests": [{"results": [{"status": "passed"}]}],
                        }
                        for title in self.BROWSER_TESTS
                    ]
                }
            ]
        }

    def test_browser_evidence_rejects_missing_screenshot_or_failed_spec(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            screenshots = Path(temporary_directory)
            for name in (
                "portal-desktop.png",
                "portal-mobile-fallback.png",
                "professional-desktop.png",
                "professional-mobile.png",
                "professional-curation-mobile.png",
            ):
                (screenshots / name).write_bytes(screenshot_png())

            result = verify_slice6_publication.validate_browser_evidence(
                self.browser_results(), screenshots
            )
            self.assertEqual(len(result["screenshots"]), 5)

            for invalid in (b"not a PNG", screenshot_png()[:-5]):
                (screenshots / "portal-desktop.png").write_bytes(invalid)
                with self.assertRaises(verify_slice6_publication.VerificationError):
                    verify_slice6_publication.validate_browser_evidence(self.browser_results(), screenshots)

            (screenshots / "portal-desktop.png").unlink()
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_browser_evidence(
                    self.browser_results(), screenshots
                )

            for name in (
                "portal-desktop.png",
                "portal-mobile-fallback.png",
                "professional-desktop.png",
                "professional-mobile.png",
                "professional-curation-mobile.png",
            ):
                (screenshots / name).write_bytes(screenshot_png())
            failed = self.browser_results()
            failed["suites"][0]["specs"][0]["tests"][0]["results"][0]["status"] = "failed"  # type: ignore[index]
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_browser_evidence(failed, screenshots)


class ScopedFreshnessTests(unittest.TestCase):
    def test_only_the_scope_changed_after_evidence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            core_source = root / "core.swift"
            database_source = root / "0009.sql"
            core_log = root / "core.log"
            database_log = root / "database.log"
            for path in (core_source, database_source, core_log, database_log):
                path.write_text(path.name, encoding="utf-8")
            os.utime(core_source, (10, 10))
            os.utime(database_source, (30, 30))
            os.utime(core_log, (20, 20))
            os.utime(database_log, (20, 20))

            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_scoped_freshness(
                    {"core": [core_source], "database": [database_source]},
                    {"core": [core_log], "database": [database_log]},
                )

            os.utime(database_log, (40, 40))
            result = verify_slice6_publication.validate_scoped_freshness(
                {"core": [core_source], "database": [database_source]},
                {"core": [core_log], "database": [database_log]},
            )
            self.assertEqual(result["database"]["sourceCount"], 1)
            self.assertEqual(result["core"]["evidenceCount"], 1)


class NativeScreenshotEvidenceTests(unittest.TestCase):
    def test_capture_must_match_bytes_exported_from_its_actual_xctest_attachment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            image = root / "attachment.png"
            image.write_bytes(screenshot_png())
            captures = [{"device": "iphone", "scenario": "publication-room-review", "sha256": hashlib.sha256(image.read_bytes()).hexdigest()}]
            entries = [{
                "testIdentifier": "RoomPublicationUITests/testRoomReviewShowsPreparedTitleAndExactPublicRasterCandidates()",
                "attachments": [{"suggestedHumanReadableName": "publication-room-review.png", "exportedFileName": "attachment.png"}],
            }]
            verify_slice6_publication.validate_native_attachment_bindings(captures, {"iphone": (root, entries)})
            image.write_bytes(screenshot_png(b"\x00\x00\x00\xff"))
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_native_attachment_bindings(captures, {"iphone": (root, entries)})
            image.write_bytes(screenshot_png())
            entries[0]["testIdentifier"] = "UnrelatedTests/testSomethingElse()"
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_native_attachment_bindings(captures, {"iphone": (root, entries)})

    def test_native_manifest_requires_all_digest_bound_current_result_captures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            iphone_result = root / "iphone.xcresult"
            ipad_result = root / "ipad.xcresult"
            iphone_result.mkdir()
            ipad_result.mkdir()
            captures: list[dict[str, str]] = []
            for device, result in (("iphone", iphone_result), ("ipad", ipad_result)):
                for scenario in (
                    "publication-failure",
                    "publication-property-warning",
                    "publication-room-review",
                ):
                    image = root / device / f"{scenario}.png"
                    image.parent.mkdir(exist_ok=True)
                    image.write_bytes(screenshot_png())
                    captures.append(
                        {
                            "path": str(image.relative_to(root)),
                            "sourceResult": str(result),
                            "device": "iPhone" if device == "iphone" else "iPad",
                            "sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
                        }
                    )
            manifest_path = root / "screenshots.json"
            manifest_path.write_text(
                json.dumps({"review": {"status": "PASS"}, "captures": captures}),
                encoding="utf-8",
            )

            result = verify_slice6_publication.validate_native_screenshot_manifest(
                json.loads(manifest_path.read_text(encoding="utf-8")),
                manifest_path,
                iphone_result,
                ipad_result,
            )
            self.assertEqual(len(result["captures"]), 6)

            first_image = root / captures[0]["path"]
            first_image.write_bytes(b"not a PNG")
            invalid = json.loads(manifest_path.read_text(encoding="utf-8"))
            invalid["captures"][0]["sha256"] = hashlib.sha256(first_image.read_bytes()).hexdigest()
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_native_screenshot_manifest(
                    invalid, manifest_path, iphone_result, ipad_result
                )
            first_image.write_bytes(screenshot_png())

            nested = root / "nested"
            nested.mkdir()
            escaped = json.loads(manifest_path.read_text(encoding="utf-8"))
            for capture in escaped["captures"]:
                capture["path"] = "../" + capture["path"]
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_native_screenshot_manifest(
                    escaped, nested / "screenshots.json", iphone_result, ipad_result
                )

            incomplete = json.loads(manifest_path.read_text(encoding="utf-8"))
            incomplete["captures"].pop()
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_native_screenshot_manifest(
                    incomplete, manifest_path, iphone_result, ipad_result
                )


class SourceInventoryTests(unittest.TestCase):
    def test_source_inventory_hashes_real_files_and_rejects_absent_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "Core" / "Publication.swift"
            source.parent.mkdir()
            source.write_text("public struct Publication {}\n", encoding="utf-8")

            inventory = verify_slice6_publication.collect_source_inventory(
                root, {"core": ("Core/Publication.swift",)}
            )
            self.assertEqual(inventory["core"][0]["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())

            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.collect_source_inventory(
                    root, {"core": ("Core/missing.swift",)}
                )

    def test_app_freshness_includes_ai_analyzer_tests_and_cloud_ui(self) -> None:
        required = {
            "RoomScanStudio/Infrastructure/AIRedesign/RoomAISensitiveContentAnalyzer.swift",
            "RoomScanStudio/RoomScanStudioTests/RoomAISensitiveContentAnalyzerTests.swift",
            "RoomScanStudio/RoomScanStudioUITests/RoomScanStudioUITests.swift",
        }
        self.assertTrue(required.issubset(verify_slice6_publication.RUNTIME_SOURCE_PATHS["app"]))


class NativeResultTests(unittest.TestCase):
    def test_native_result_requires_nonregressed_count_and_named_publication_tests(self) -> None:
        summary = {
            "result": "Passed",
            "passedTests": 337,
            "failedTests": 0,
            "totalTestCount": 337,
        }
        names = {
            "RoomPublicationUITests/testPropertyReviewShowsIndependentRoomDisclaimerAndBoundedControls()",
            "RoomPublicationUITests/testRoomReviewShowsPreparedTitleAndExactPublicRasterCandidates()",
            "RoomPublicationUITests/testPendingRevokedFailureAndLinkRecoveryFixturesExposeAccessibleStatus()",
        }
        names.update(
            f"RoomPublicationTests/testPublicationBoundary{index}()" for index in range(45)
        )
        result = verify_slice6_publication.validate_native_result("iPhone", summary, names)
        self.assertEqual(result["passed"], 337)
        self.assertEqual(result["publicationTestCases"], 45)

        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_native_result(
                "iPhone", {**summary, "passedTests": 336, "totalTestCount": 336}, names
            )
        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_native_result(
                "iPad",
                summary,
                names
                - {"RoomPublicationUITests/testPropertyReviewShowsIndependentRoomDisclaimerAndBoundedControls()"},
            )
        with self.assertRaises(verify_slice6_publication.VerificationError):
            verify_slice6_publication.validate_native_result(
                "iPad", summary, names - {"RoomPublicationTests/testPublicationBoundary41()"}
            )


class SystemChainEvidenceTests(unittest.TestCase):
    def test_system_chain_summary_requires_real_events_and_fixture_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            chain_log = root / "chain.log"
            summary = {
                "schemaVersion": 1,
                "status": "pass",
                "startedAt": "2026-09-20T10:00:00Z",
                "completedAt": "2026-09-20T10:01:00Z",
                "postgresVersion": "16.13 (Homebrew)",
                "fixtureSHA256": "a" * 64,
                "rooms": 2,
                "roles": 4,
                "promotedAssets": 12,
                "privateTruth": {
                    "beforeSHA256": "b" * 64,
                    "afterSHA256": "b" * 64,
                    "positiveControlDetected": True,
                    "tables": ["memberships", "professional_projects", "project_raw_archives", "project_revisions", "projects"],
                },
                "events": list(verify_slice6_publication.REQUIRED_SYSTEM_CHAIN_EVENTS),
                "syntheticPorts": ["object-storage", "email-transport", "clock"],
                "realComponents": ["publication-route-application", "publication-worker"],
            }
            chain_log.write_text(
                "\n".join(
                    [
                        'SYSTEM_CHAIN_SQL_FAILURE {"role":"roomscan_portal_runtime","code":"42501","reason":"PORTAL_ACCESS_DENIED","reducer":"portal_authorize_asset_v1"}',
                        'SYSTEM_CHAIN_SQL_FAILURE {"role":"roomscan_portal_runtime","code":"42501","reason":"PORTAL_ACCESS_DENIED","reducer":"portal_get_snapshot_v2"}',
                        'SYSTEM_CHAIN_SQL_FAILURE {"role":"roomscan_portal_runtime","code":"42501","reason":"PORTAL_ACCESS_DENIED","reducer":"portal_create_feedback_v1"}',
                        "SYSTEM_CHAIN_SUMMARY " + json.dumps(summary),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = verify_slice6_publication.validate_system_chain_output(
                chain_log.read_text(encoding="utf-8"), expected_fixture_sha256="a" * 64
            )
            self.assertEqual(result["status"], "PASS")

            original_output = chain_log.read_text(encoding="utf-8")
            for changed in (
                {"promotedAssets": 11},
                {"privateTruth": None},
                {"privateTruth": {**summary["privateTruth"], "afterSHA256": "c" * 64}},
                {"privateTruth": {**summary["privateTruth"], "positiveControlDetected": False}},
            ):
                with self.subTest(changed=changed), self.assertRaises(verify_slice6_publication.VerificationError):
                    verify_slice6_publication.validate_system_chain_output(
                        original_output.replace(json.dumps(summary), json.dumps({**summary, **changed})),
                        expected_fixture_sha256="a" * 64,
                    )

            incomplete = dict(summary)
            incomplete["events"] = [
                event
                for event in incomplete["events"]
                if event != "unpublished-synced-room-inventory"
            ]
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_system_chain_output(
                    "SYSTEM_CHAIN_SUMMARY " + json.dumps(incomplete),
                    expected_fixture_sha256="a" * 64,
                )

            revocation_red = """AssertionError [ERR_ASSERTION]: revoked chunk must be denied immediately

200 !== 503

  actual: 200,
  expected: 503,
"""
            self.assertEqual(
                verify_slice6_publication.validate_system_chain_revocation_control(revocation_red)["status"],
                "PASS",
            )
            with self.assertRaises(verify_slice6_publication.VerificationError):
                verify_slice6_publication.validate_system_chain_revocation_control(
                    revocation_red.replace("200 !== 503", "503 !== 503")
                )


class CompletionReportTests(unittest.TestCase):
    def evidence(self) -> dict[str, object]:
        return {
            "core": {"status": "PASS"},
            "service": {"status": "PASS"},
            "database": {"status": "PASS"},
            "infrastructure": {"status": "PASS"},
            "web": {"status": "PASS"},
            "browser": {"status": "PASS"},
            "native": {"status": "PASS"},
            "artifact": {"status": "PASS"},
            "fixtures": {"status": "PASS"},
            "mutations": {"status": "PASS"},
            "python": {"status": "PASS"},
            "node": {"status": "PASS"},
            "slice4": {"status": "PASS"},
            "slice5": {"status": "PASS"},
            "sourceInventory": {"status": "PASS"},
            "freshness": {"status": "PASS"},
        }

    def test_missing_composed_chain_makes_finalization_incomplete_not_passing(self) -> None:
        incomplete = verify_slice6_publication.build_completion_report(self.evidence(), chain=None)
        self.assertEqual(incomplete["status"], "INCOMPLETE")
        self.assertEqual(incomplete["clauses"]["1"]["status"], "INCOMPLETE")
        self.assertEqual(incomplete["clauses"]["3"]["status"], "INCOMPLETE")
        self.assertEqual(incomplete["clauses"]["9"]["status"], "PASS")

        complete = verify_slice6_publication.build_completion_report(
            self.evidence(),
            chain={
                "status": "PASS",
                "events": list(verify_slice6_publication.REQUIRED_SYSTEM_CHAIN_EVENTS),
            },
        )
        self.assertEqual(complete["status"], "INCOMPLETE")
        self.assertEqual(complete["clauses"]["5"]["status"], "INCOMPLETE")

        complete = verify_slice6_publication.build_completion_report(
            self.evidence(),
            chain={
                "status": "PASS",
                "events": list(verify_slice6_publication.REQUIRED_SYSTEM_CHAIN_EVENTS),
            },
            chain_control={"status": "PASS"},
        )
        self.assertEqual(complete["status"], "PASS")
        verify_slice6_publication.validate_clause_results(complete["clauses"])


class AggregationModeTests(unittest.TestCase):
    def test_aggregate_without_inputs_writes_an_honest_incomplete_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            artifacts = Path(temporary_directory) / "publication"
            report = verify_slice6_publication.aggregate_publication_evidence(artifacts)

            self.assertEqual(report["status"], "INCOMPLETE")
            self.assertEqual(report["completion"]["status"], "INCOMPLETE")
            self.assertIn("core", report["incomplete"])
            self.assertTrue((artifacts / "publication-verification.json").is_file())


if __name__ == "__main__":
    unittest.main()

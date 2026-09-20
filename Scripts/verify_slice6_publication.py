#!/usr/bin/env python3
"""Assemble honest Slice 6 publication-verification evidence."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping
import zlib


class VerificationError(RuntimeError):
    """Required publication evidence is missing, stale, or invalid."""


ROOT = Path(__file__).resolve().parents[1]
NODE24_BIN = "/Users/philipnora/.nvm/versions/node/v24.15.0/bin"
EXPECTED_NODE_VERSION = "v24.15.0"
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

REQUIRED_BROWSER_TESTS = (
    "interactive property portal covers floor plan, orientation, comparison, navigation, downloads, feedback, accessibility, and token confinement",
    "PIN gate fails closed, clears each probe, and opens only on the correct value",
    "an already active session and protected asset fail immediately after revocation",
    "verified professional sign-in exposes exactly the eight bounded flows and keeps stored content inert",
    "mobile portal presents bounded static fallback with responsive navigation and accessible controls",
    "mobile professional workspace reflows its bounded navigation and presents signed-in room curation controls",
)
REQUIRED_BROWSER_SCREENSHOTS = (
    "portal-desktop.png",
    "portal-mobile-fallback.png",
    "professional-desktop.png",
    "professional-mobile.png",
    "professional-curation-mobile.png",
)
REQUIRED_NATIVE_SCREENSHOT_SCENARIOS = (
    "publication-failure",
    "publication-property-warning",
    "publication-room-review",
)
REQUIRED_NATIVE_TESTS = (
    "testPropertyReviewShowsIndependentRoomDisclaimerAndBoundedControls",
    "testRoomReviewShowsPreparedTitleAndExactPublicRasterCandidates",
    "testPendingRevokedFailureAndLinkRecoveryFixturesExposeAccessibleStatus",
)
NATIVE_FULL_SCHEME_MINIMUM = 337
NATIVE_PUBLICATION_CASE_MINIMUM = 45
CORE_FULL_PACKAGE_MINIMUM = 318
SERVICE_FULL_SUITE_MINIMUM = 368
REQUIRED_CORE_TESTS = (
    "testApprovalRequiresExactSourceAndSelectionBindings",
    "testArchiveClosureKeepsPortalPresentationPrivateFieldFree",
    "testPublicationGoldenFixturesMatchExactProductionArchivesAndRelationships",
)
REQUIRED_SYSTEM_CHAIN_EVENTS = (
    "built-portal-shell",
    "unpublished-synced-room-inventory",
    "approved-core-archive-allocated",
    "validation-wake",
    "validated-promoted-published",
    "link-exchanged",
    "exact-version-chunk-delivered",
    "feedback-wake",
    "encrypted-outbox-delivered",
    "feedback-recorded-private-heads-unchanged",
    "revoked-immediate-denial",
)
REQUIRED_SYSTEM_CHAIN_DENIALS = frozenset(
    {
        ("roomscan_portal_runtime", "42501", "PORTAL_ACCESS_DENIED", "portal_authorize_asset_v1"),
        ("roomscan_portal_runtime", "42501", "PORTAL_ACCESS_DENIED", "portal_get_snapshot_v2"),
        ("roomscan_portal_runtime", "42501", "PORTAL_ACCESS_DENIED", "portal_create_feedback_v1"),
    }
)
PUBLICATION_FIXTURE_DIGESTS = {
    "HostedService/fixtures/publication/expectations.json": "a2b77c692b8ebf278f6e475634adf9db18c3472fc4992a1f62577df5fce2999d",
    "HostedService/fixtures/publication/room-v2-ai-ready.zip.base64": "d88bbee134e563fd24a2727097cb624437ed7a30228c4f1277e1b26ea7e1f370",
    "HostedService/fixtures/publication/property-v1.zip.base64": "7a431383089392d7e9b71a0006c538cfa24bb4ba77c97612d450672d37ea3cd2",
}
RUNTIME_SOURCE_PATHS = {
    "core": (
        "RoomScanCore/Sources/RoomScanCore/RoomPublicationArchive.swift",
        "RoomScanCore/Sources/RoomScanCore/RoomPublishedSnapshotContracts.swift",
    ),
    "app": (
        "RoomScanStudio/Features/Publication/RoomPublicationModel.swift",
        "RoomScanStudio/Features/Publication/RoomPublicationReviewView.swift",
        "RoomScanStudio/Infrastructure/Publication/PublicationOperationJournal.swift",
        "RoomScanStudio/Infrastructure/Publication/PublicationSourceIdentityResolver.swift",
        "RoomScanStudio/Infrastructure/Publication/RoomPublicationService.swift",
        "RoomScanStudio/Infrastructure/Publication/RoomPublicationTransport.swift",
        "RoomScanStudio/Infrastructure/AIRedesign/RoomAISensitiveContentAnalyzer.swift",
        "RoomScanStudio/RoomScanStudioTests/RoomAISensitiveContentAnalyzerTests.swift",
        "RoomScanStudio/RoomScanStudioTests/RoomPublicationTests.swift",
        "RoomScanStudio/RoomScanStudioUITests/RoomScanStudioUITests.swift",
        "RoomScanStudio/RoomScanStudioUITests/RoomPublicationUITests.swift",
    ),
    "service": (
        "HostedService/service/src/contracts/openapi.ts",
        "HostedService/service/src/contracts/route-manifest.ts",
        "HostedService/service/src/publication/archive-validator.ts",
        "HostedService/service/src/publication/capabilities.ts",
        "HostedService/service/src/publication/contracts.ts",
        "HostedService/service/src/publication/feedback-service.ts",
        "HostedService/service/src/publication/portal-document.ts",
        "HostedService/service/src/publication/route-application.ts",
        "HostedService/service/src/publication/worker.ts",
        "HostedService/service/src/composition/publication-application.ts",
        "HostedService/service/src/persistence/publication-worker-store.ts",
    ),
    "database": (
        "HostedService/db/migrations/0009_publication_portal.up.sql",
        "HostedService/db/test/integration-0009-publication.mjs",
        "HostedService/db/test/integration-0009-system-chain.mjs",
        "HostedService/db/test/mutations-0009-publication.mjs",
    ),
    "infrastructure": (
        "HostedService/infra/src/aws/publication-object-provider.ts",
        "HostedService/infra/src/functions/publication-validation.ts",
        "HostedService/infra/src/stacks/platform-stack.ts",
    ),
    "web": (
        "HostedService/web/src/portal/application.ts",
        "HostedService/web/src/portal/renderers.ts",
        "HostedService/web/src/professional/application.ts",
        "HostedService/web/src/shared/dom.ts",
        "HostedService/web/src/shared/professional-client.ts",
        "HostedService/web/src/shared/portal-security.ts",
    ),
    "fixtures": tuple(PUBLICATION_FIXTURE_DIGESTS),
}
REQUIRED_SERVICE_TESTS = (
    "publication archive validator consumes exact Core room/property fixtures, preserves independent-room order, and detects a real archive-byte mutation",
    "publication archive closure reaches an injected raw artifact after its archive identity is recomputed",
    "portal delivery emits an exact range only after the live finalizer, including a post-read revocation barrier",
    "feedback capability repository exposes only immutable portal feedback SQL, never project mutation capability",
    "publication finalization encodes absent download kinds as JSON null, not a SQL-invalid empty string",
    "professional property paging matches the live database twenty-property bound",
    "room candidate reads expose only bounded project identity and title through professional credentials",
    "professional property inventory includes bounded safe synced-room candidates without a new route",
)
REQUIRED_WEB_TESTS = (
    "safe DOM renders stored markup canaries as literal text and rejects unsafe URLs",
    "portal snapshot response is closed and preserves only live capability flags",
    "property portal navigation requires independent contiguous room ordering",
    "professional navigation is bounded to the eight approved lightweight flows",
)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_node_runtime_output(output: str) -> dict[str, str]:
    """Require the exact raw Node runtime line used by hosted evidence."""

    versions = [line.strip() for line in output.splitlines() if line.strip().startswith("v")]
    if versions != [EXPECTED_NODE_VERSION]:
        raise VerificationError(
            f"hosted evidence requires exactly Node {EXPECTED_NODE_VERSION}, got {versions!r}"
        )
    return {"status": "PASS", "version": EXPECTED_NODE_VERSION}


def validate_step_report(
    document: Any, *, label: str, required_labels: Iterable[str]
) -> dict[str, Any]:
    """Reject a bare prior-oracle PASS without its executed command records."""

    if not isinstance(document, Mapping) or document.get("schemaVersion") != 1 or document.get("status") != "PASS":
        raise VerificationError(f"{label} report is not a terminal schema-v1 PASS")
    steps = document.get("steps")
    if not isinstance(steps, list) or not steps:
        raise VerificationError(f"{label} report lacks executed command records")
    observed: dict[str, Mapping[str, Any]] = {}
    for step in steps:
        if not isinstance(step, Mapping):
            raise VerificationError(f"{label} command record is not an object")
        step_label = step.get("label")
        command = step.get("command")
        digest = step.get("outputSha256")
        if (
            not isinstance(step_label, str)
            or not step_label
            or step_label in observed
            or not isinstance(command, list)
            or not command
            or any(not isinstance(part, str) or not part for part in command)
            or not isinstance(step.get("cwd"), str)
            or not step["cwd"]
            or step.get("exitCode") != 0
            or not isinstance(step.get("outputBytes"), int)
            or step["outputBytes"] < 0
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            or not isinstance(step.get("log"), str)
            or not step["log"]
        ):
            raise VerificationError(f"{label} command record is incomplete or not clean")
        observed[step_label] = step
    missing = [required for required in required_labels if required not in observed]
    if missing:
        raise VerificationError(f"{label} report lacks required commands: {missing}")
    return {"status": "PASS", "steps": sorted(observed)}


def collect_source_inventory(
    root: Path, source_paths: Mapping[str, Iterable[str]]
) -> dict[str, list[dict[str, Any]]]:
    """Hash named runtime sources without accepting absent or redirected files."""

    resolved_root = root.resolve()
    inventory: dict[str, list[dict[str, Any]]] = {}
    for scope, relative_paths in source_paths.items():
        records: list[dict[str, Any]] = []
        for relative_path in relative_paths:
            path = root / relative_path
            try:
                path.resolve().relative_to(resolved_root)
            except ValueError as error:
                raise VerificationError(f"{scope} source escapes repository root: {relative_path}") from error
            if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
                raise VerificationError(f"{scope} source is missing, redirected, or empty: {relative_path}")
            records.append(
                {
                    "path": relative_path,
                    "sha256": sha256_file(path),
                    "bytes": path.stat().st_size,
                    "mtimeNs": path.stat().st_mtime_ns,
                }
            )
        if not records:
            raise VerificationError(f"{scope} source inventory is empty")
        inventory[scope] = records
    return inventory


def validate_fixture_digests(root: Path, expected: Mapping[str, str]) -> dict[str, str]:
    """Hash fixture files directly and reject a changed byte sequence."""

    observed: dict[str, str] = {}
    for relative_path, digest in expected.items():
        path = root / relative_path
        if not path.is_file():
            raise VerificationError(f"required fixture is missing: {relative_path}")
        actual = sha256_file(path)
        if actual != digest:
            raise VerificationError(f"fixture digest is stale or invalid: {relative_path}")
        observed[relative_path] = actual
    return observed


def validate_property_fixture_archive(root: Path) -> str:
    """Bind the composed-chain archive hash to the checked-in Core golden fixture."""

    expectations_path = root / "HostedService/fixtures/publication/expectations.json"
    archive_path = root / "HostedService/fixtures/publication/property-v1.zip.base64"
    try:
        document = json.loads(expectations_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError("publication fixture expectations are unreadable") from error
    fixtures = document.get("fixtures") if isinstance(document, Mapping) else None
    property_fixture = next(
        (
            item
            for item in fixtures
            if isinstance(item, Mapping) and item.get("name") == "property-v1"
        ),
        None,
    ) if isinstance(fixtures, list) else None
    archive = property_fixture.get("archive") if isinstance(property_fixture, Mapping) else None
    expected = archive.get("sha256") if isinstance(archive, Mapping) else None
    if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        raise VerificationError("property fixture has no valid archive digest")
    try:
        encoded = "".join(archive_path.read_text(encoding="utf-8").split())
        decoded = base64.b64decode(encoded, validate=True)
    except (OSError, ValueError) as error:
        raise VerificationError("property fixture archive is not valid base64") from error
    actual = hashlib.sha256(decoded).hexdigest()
    if actual != expected:
        raise VerificationError("property fixture archive bytes do not match expectations.json")
    return actual


def _node_count(output: str, label: str) -> int:
    matches = re.findall(rf"^\s*(?:ℹ\s+|#\s*)?{re.escape(label)}\s+(\d+)\s*$", output, re.MULTILINE)
    if not matches:
        raise VerificationError(f"raw node output lacks a {label!r} count")
    return int(matches[-1])


def validate_node_test_output(
    output: str,
    *,
    label: str,
    minimum_tests: int,
    required_tests: Iterable[str],
) -> dict[str, int]:
    """Require actual Node test-summary fields and named passing test output."""

    tests = _node_count(output, "tests")
    passed = _node_count(output, "pass")
    failed = _node_count(output, "fail")
    skipped = _node_count(output, "skipped")
    missing = [test for test in required_tests if test not in output]
    if missing:
        raise VerificationError(f"{label} output lacks required executed tests: {missing}")
    if tests < minimum_tests or passed != tests or failed != 0 or skipped != 0:
        raise VerificationError(
            f"{label} test summary regressed: tests={tests} pass={passed} fail={failed} skipped={skipped}"
        )
    return {"tests": tests, "passed": passed, "failed": failed, "skipped": skipped}


def validate_swift_test_output(output: str) -> dict[str, int]:
    """Require the terminal full-package XCTest summary and real Slice 6 cases."""

    summaries = re.findall(
        r"Executed\s+(\d+)\s+tests,\s+with\s+(\d+)\s+failures?(?:\s+\((\d+)\s+unexpected\))?",
        output,
    )
    if not summaries:
        raise VerificationError("raw Swift output lacks a full XCTest summary")
    total_text, failures_text, unexpected_text = summaries[-1]
    total = int(total_text)
    failures = int(failures_text)
    unexpected = int(unexpected_text or "0")
    missing = [
        name
        for name in REQUIRED_CORE_TESTS
        if re.search(rf"^Test Case .*{re.escape(name)}.*\bpassed\b", output, re.MULTILINE)
        is None
    ]
    if missing:
        raise VerificationError(f"raw Swift output lacks required passing Slice 6 tests: {missing}")
    if total < CORE_FULL_PACKAGE_MINIMUM or failures != 0 or unexpected != 0:
        raise VerificationError(
            f"Swift package test summary regressed: tests={total} failures={failures} unexpected={unexpected}"
        )
    return {"status": "PASS", "passed": total, "failed": failures, "total": total}


def validate_python_test_output(output: str) -> dict[str, int]:
    """Require a terminal unittest success summary above the Slice 6 baseline."""

    summaries = re.findall(r"^Ran\s+(\d+)\s+tests?\s+in\s+.+$", output, re.MULTILINE)
    if not summaries:
        raise VerificationError("raw Python output lacks a unittest summary")
    tests = int(summaries[-1])
    if re.search(r"^(?:FAILED|ERROR)(?:\s|$)", output, re.MULTILINE) or re.search(
        r"^FAILED\s*\(", output, re.MULTILINE
    ):
        raise VerificationError("Python verifier output reports failures or errors")
    if not re.search(r"^OK$", output, re.MULTILINE) or tests <= 46:
        raise VerificationError(f"Python verifier test summary regressed: tests={tests}")
    return {"status": "PASS", "passed": tests, "failed": 0, "total": tests}


def validate_clause_results(clauses: Mapping[str, Any]) -> None:
    """Reject absent, skipped, or unsupported completion-oracle clauses."""

    expected = {str(number) for number in range(1, 11)}
    if set(clauses) != expected:
        raise VerificationError("publication report must contain exactly clauses 1 through 10")
    for number in sorted(expected, key=int):
        clause = clauses[number]
        if not isinstance(clause, Mapping):
            raise VerificationError(f"clause {number} is not an evidence record")
        evidence = clause.get("evidence")
        if clause.get("status") != "PASS" or not isinstance(evidence, list) or not evidence:
            raise VerificationError(f"clause {number} is skipped, failed, or lacks evidence")


def _walk_browser_records(value: Any) -> Iterable[Mapping[str, Any]]:
    if isinstance(value, Mapping):
        yield value
        for nested in value.values():
            yield from _walk_browser_records(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from _walk_browser_records(nested)


def validate_screenshot_png(path: Path) -> None:
    """Validate the bounded, non-interlaced 8-bit RGB/RGBA captures we retain."""
    if not path.is_file() or path.is_symlink() or not 0 < path.stat().st_size <= 32 * 1024 * 1024:
        raise VerificationError(f"screenshot is missing, unsafe, or oversized: {path}")
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise VerificationError(f"screenshot is not a PNG: {path}")
    offset = 8
    kinds: list[bytes] = []
    compressed = bytearray()
    row_bytes = height = 0
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        end = offset + 12 + length
        if end > len(data):
            raise VerificationError(f"truncated PNG chunk: {path}")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:end - 4]
        checksum = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) != checksum:
            raise VerificationError(f"PNG chunk checksum mismatch: {path}")
        if not kinds and kind != b"IHDR":
            raise VerificationError(f"PNG must start with its image header: {path}")
        if kind == b"IHDR":
            if kinds or length != 13:
                raise VerificationError(f"invalid PNG image header: {path}")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if not (0 < width <= 20000 and 0 < height <= 20000 and width * height <= 20_000_000
                    and depth == 8 and color in (2, 6) and compression == filtering == interlace == 0):
                raise VerificationError(f"unsupported screenshot PNG format or dimensions: {path}")
            row_bytes = width * (3 if color == 2 else 4) + 1
        elif kind == b"IDAT":
            if b"IDAT" in kinds and kinds[-1] != b"IDAT":
                raise VerificationError(f"noncontiguous PNG image data: {path}")
            compressed.extend(payload)
        elif kind == b"IEND":
            if length or end != len(data) or not compressed:
                raise VerificationError(f"invalid PNG image end: {path}")
        elif kind not in (b"PLTE",) and not kind[0] & 32:
            raise VerificationError(f"unknown critical PNG chunk: {path}")
        kinds.append(kind)
        offset = end
    if offset != len(data) or not kinds or kinds[-1] != b"IEND":
        raise VerificationError(f"incomplete screenshot PNG: {path}")
    expected = row_bytes * height
    try:
        decoder = zlib.decompressobj()
        pixels = decoder.decompress(bytes(compressed), expected + 1)
    except zlib.error as error:
        raise VerificationError(f"invalid PNG compressed image: {path}") from error
    if (len(pixels) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail
            or any(pixels[row * row_bytes] > 4 for row in range(height))):
        raise VerificationError(f"invalid PNG scanlines: {path}")


def validate_browser_evidence(document: Any, screenshots_directory: Path) -> dict[str, Any]:
    """Require a clean real browser result and each reviewed browser capture."""

    if not isinstance(document, Mapping):
        raise VerificationError("browser result is not a JSON object")
    titles: set[str] = set()
    for record in _walk_browser_records(document):
        title = record.get("title")
        if isinstance(title, str) and "tests" in record:
            if record.get("ok") is not True:
                raise VerificationError(f"browser spec did not pass: {title}")
            titles.add(title)
        status = record.get("status")
        if status in {"failed", "unexpected", "timedOut", "interrupted", "skipped"}:
            raise VerificationError(f"browser result contains non-passing status: {status}")
    missing = sorted(set(REQUIRED_BROWSER_TESTS) - titles)
    if missing:
        raise VerificationError(f"browser result lacks required executed specs: {missing}")
    screenshots: list[dict[str, str]] = []
    for name in REQUIRED_BROWSER_SCREENSHOTS:
        path = screenshots_directory / name
        validate_screenshot_png(path)
        screenshots.append({"path": str(path.resolve()), "sha256": sha256_file(path)})
    return {"status": "PASS", "specs": sorted(titles), "screenshots": screenshots}


def validate_scoped_freshness(
    source_paths: Mapping[str, Iterable[Path]], evidence_paths: Mapping[str, Iterable[Path]]
) -> dict[str, Any]:
    """Timestamp sanity check and post-hoc inventory for trusted local runs.

    This is not an execution-time digest attestation: copying or touching an old
    log can defeat its ordering check. Actual command execution must be observed
    by the caller; untrusted submitted logs are not a supported closure source.
    """

    records: dict[str, Any] = {}
    for scope, paths in source_paths.items():
        sources = list(paths)
        evidence = list(evidence_paths.get(scope, ()))
        if not sources or not evidence:
            raise VerificationError(f"{scope} freshness binding lacks sources or evidence")
        source_records: list[dict[str, Any]] = []
        for path in sources:
            if not path.is_file() or path.is_symlink():
                raise VerificationError(f"{scope} source is missing or unsafe: {path}")
            source_records.append(
                {
                    "path": str(path.resolve()),
                    "sha256": sha256_file(path),
                    "mtimeNs": path.stat().st_mtime_ns,
                }
            )
        evidence_times: list[int] = []
        for path in evidence:
            if not path.exists():
                raise VerificationError(f"{scope} evidence is missing: {path}")
            evidence_times.append(path.stat().st_mtime_ns)
        newest_source = max(record["mtimeNs"] for record in source_records)
        oldest_evidence = min(evidence_times)
        if newest_source > oldest_evidence:
            raise VerificationError(
                f"{scope} runtime source changed after its evidence was captured"
            )
        records[scope] = {
            "sourceCount": len(source_records),
            "evidenceCount": len(evidence),
            "sources": source_records,
            "oldestEvidenceMtimeNs": oldest_evidence,
        }
    return records


def validate_native_screenshot_manifest(
    document: Any,
    manifest_path: Path,
    iphone_xcresult: Path,
    ipad_xcresult: Path,
) -> dict[str, Any]:
    """Validate reviewed native captures against the exact supplied result bundles."""

    if not isinstance(document, Mapping):
        raise VerificationError("native screenshot manifest is not a JSON object")
    review = document.get("review")
    captures = document.get("captures")
    if not isinstance(review, Mapping) or review.get("status") != "PASS":
        raise VerificationError("native screenshot review is absent or not passing")
    if not isinstance(captures, list):
        raise VerificationError("native screenshot manifest has no captures array")
    expected_results = {
        "iphone": iphone_xcresult.resolve(),
        "ipad": ipad_xcresult.resolve(),
    }
    expected_pairs = {
        (device, scenario)
        for device in expected_results
        for scenario in REQUIRED_NATIVE_SCREENSHOT_SCENARIOS
    }
    observed_pairs: set[tuple[str, str]] = set()
    verified: list[dict[str, str]] = []
    for capture in captures:
        if not isinstance(capture, Mapping):
            raise VerificationError("native screenshot capture is not an object")
        path_value = capture.get("path")
        source_value = capture.get("sourceResult")
        device_value = capture.get("device", capture.get("deviceClass"))
        digest = capture.get("sha256")
        if not all(isinstance(value, str) for value in (path_value, source_value, device_value, digest)):
            raise VerificationError("native screenshot capture has incomplete provenance")
        device = "iphone" if "iphone" in device_value.lower() else "ipad" if "ipad" in device_value.lower() else ""
        scenario = Path(path_value).stem
        pair = (device, scenario)
        if pair not in expected_pairs or pair in observed_pairs:
            raise VerificationError("native screenshot capture has an unexpected or duplicate device/scenario")
        image = Path(path_value)
        if image.is_absolute():
            raise VerificationError("native screenshot path must be relative to its manifest")
        image = (manifest_path.parent / image).resolve()
        if not image.is_relative_to(manifest_path.parent.resolve()):
            raise VerificationError("native screenshot escapes its evidence directory")
        source_result = Path(source_value)
        if not source_result.is_absolute():
            source_result = manifest_path.parent / source_result
        if source_result.resolve() != expected_results[device]:
            raise VerificationError("native screenshot is not bound to the supplied current XCTest result")
        if not image.is_file() or sha256_file(image) != digest:
            raise VerificationError("native screenshot bytes do not match their declared digest")
        validate_screenshot_png(image)
        observed_pairs.add(pair)
        verified.append({"device": device, "scenario": scenario, "path": str(image), "sha256": digest})
    if observed_pairs != expected_pairs:
        raise VerificationError("native screenshot manifest lacks an exact iPhone/iPad scenario set")
    return {"status": "PASS", "captures": sorted(verified, key=lambda item: (item["device"], item["scenario"]))}


def validate_native_attachment_bindings(
    captures: Iterable[Mapping[str, str]],
    exports: Mapping[str, tuple[Path, list[Mapping[str, Any]]]],
) -> None:
    """Match reviewed image bytes to the named test in the supplied result."""
    tests = {
        "publication-failure": "testPendingRevokedFailureAndLinkRecoveryFixturesExposeAccessibleStatus",
        "publication-property-warning": "testPropertyReviewShowsIndependentRoomDisclaimerAndBoundedControls",
        "publication-room-review": "testRoomReviewShowsPreparedTitleAndExactPublicRasterCandidates",
    }
    for capture in captures:
        directory, entries = exports[capture["device"]]
        scenario = capture["scenario"]
        matching: list[Path] = []
        for entry in entries:
            identifier = str(entry.get("testIdentifier", ""))
            if "RoomPublicationUITests/" + tests[scenario] + "(" not in identifier:
                continue
            for attachment in entry.get("attachments", []):
                if scenario not in str(attachment.get("suggestedHumanReadableName", "")):
                    continue
                filename = attachment.get("exportedFileName")
                if not isinstance(filename, str):
                    raise VerificationError("native attachment lacks an exported filename")
                path = (directory / filename).resolve()
                if not path.is_relative_to(directory.resolve()) or not path.is_file():
                    raise VerificationError("native attachment export is missing or outside its directory")
                matching.append(path)
        if len(matching) != 1 or sha256_file(matching[0]) != capture["sha256"]:
            raise VerificationError(f"reviewed {capture['device']}/{scenario} is not its actual XCTest attachment")


def validate_native_result(
    label: str, summary: Mapping[str, Any], test_names: set[str]
) -> dict[str, int]:
    """Validate a fresh iPhone/iPad XCTest summary and its Slice 6 UI coverage."""

    passed = summary.get("passedTests")
    failed = summary.get("failedTests")
    total = summary.get("totalTestCount")
    skipped = summary.get("skippedTests", 0)
    expected_failures = summary.get("expectedFailures", 0)
    if (
        summary.get("result") != "Passed"
        or not all(isinstance(value, int) for value in (passed, failed, total, skipped, expected_failures))
        or passed < NATIVE_FULL_SCHEME_MINIMUM
        or total != passed
        or failed != 0
        or skipped != 0
        or expected_failures != 0
    ):
        raise VerificationError(f"{label} XCTest summary regressed or is incomplete")
    missing = [
        required
        for required in REQUIRED_NATIVE_TESTS
        if not any(required in name for name in test_names)
    ]
    if missing:
        raise VerificationError(f"{label} XCTest result lacks Slice 6 publication tests: {missing}")
    publication_cases: set[str] = set()
    for name in test_names:
        lowered = name.lower()
        if "publication" not in lowered and "publishedsnapshot" not in lowered:
            continue
        match = re.search(r"([A-Za-z_][A-Za-z0-9_]*)/(test[A-Za-z0-9_]+)", name)
        if match is not None and not match.group(1).endswith("UITests"):
            publication_cases.add("/".join(match.groups()))
    if len(publication_cases) < NATIVE_PUBLICATION_CASE_MINIMUM:
        raise VerificationError(
            f"{label} XCTest tree has only {len(publication_cases)} publication app cases; "
            f"expected at least {NATIVE_PUBLICATION_CASE_MINIMUM}"
        )
    return {
        "passed": passed,
        "failed": failed,
        "total": total,
        "publicationTestCases": len(publication_cases),
    }


def validate_system_chain_output(output: str, *, expected_fixture_sha256: str) -> dict[str, Any]:
    """Validate the actual production-handler/PG16 system-chain summary.

    This establishes service/database composition only. Browser rendering,
    injection behavior, and native-app UI remain separate evidence boundaries.
    """

    lines = [
        line.removeprefix("SYSTEM_CHAIN_SUMMARY ")
        for line in output.splitlines()
        if line.startswith("SYSTEM_CHAIN_SUMMARY ")
    ]
    if len(lines) != 1:
        raise VerificationError("system-chain log must contain exactly one final summary")
    try:
        summary = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise VerificationError("system-chain summary is not valid JSON") from error
    if not isinstance(summary, Mapping) or summary.get("schemaVersion") != 1 or summary.get("status") != "pass":
        raise VerificationError("system-chain summary is not a passing schema-v1 result")
    started = summary.get("startedAt")
    completed = summary.get("completedAt")
    postgres_version = summary.get("postgresVersion")
    if (
        not isinstance(started, str)
        or not isinstance(completed, str)
        or started >= completed
        or not isinstance(postgres_version, str)
        or re.fullmatch(r"(?:PostgreSQL\s+)?16\.\d+(?:\.\d+)?(?:\s+\([^)]+\))?", postgres_version) is None
    ):
        raise VerificationError("system-chain timing or PostgreSQL 16 identity is invalid")
    if summary.get("fixtureSHA256") != expected_fixture_sha256 or summary.get("rooms") != 2 or summary.get("roles") != 4:
        raise VerificationError("system-chain fixture, room, or PostgreSQL-role binding is invalid")
    promoted_assets = summary.get("promotedAssets")
    if promoted_assets != 12:
        raise VerificationError("system-chain did not promote the exact twelve fixture assets")
    private_truth = summary.get("privateTruth")
    if (
        not isinstance(private_truth, Mapping)
        or not isinstance(private_truth.get("beforeSHA256"), str)
        or re.fullmatch(r"[0-9a-f]{64}", private_truth["beforeSHA256"]) is None
        or private_truth.get("afterSHA256") != private_truth["beforeSHA256"]
        or private_truth.get("positiveControlDetected") is not True
        or private_truth.get("tables") != [
            "memberships", "professional_projects", "project_raw_archives", "project_revisions", "projects"
        ]
    ):
        raise VerificationError("system-chain private truth digest lacks equality or its live positive control")
    events = summary.get("events")
    if not isinstance(events, list) or any(not isinstance(event, str) for event in events):
        raise VerificationError("system-chain events are malformed")
    if len(events) != len(set(events)) or not set(REQUIRED_SYSTEM_CHAIN_EVENTS).issubset(events):
        raise VerificationError("system-chain lacks a required production flow event")
    ports = summary.get("syntheticPorts")
    components = summary.get("realComponents")
    if (
        not isinstance(ports, list)
        or not {"object-storage", "email-transport", "clock"}.issubset(ports)
        or not isinstance(components, list)
        or not components
        or any(not isinstance(component, str) or not component for component in components)
    ):
        raise VerificationError("system-chain synthetic ports or real-component inventory is invalid")
    denials: set[tuple[str, str, str, str]] = set()
    for line in output.splitlines():
        if not line.startswith("SYSTEM_CHAIN_SQL_FAILURE "):
            continue
        try:
            record = json.loads(line.removeprefix("SYSTEM_CHAIN_SQL_FAILURE "))
        except json.JSONDecodeError as error:
            raise VerificationError("system-chain denial record is not valid JSON") from error
        if not isinstance(record, Mapping):
            raise VerificationError("system-chain denial record is not an object")
        values = tuple(record.get(field) for field in ("role", "code", "reason", "reducer"))
        if not all(isinstance(value, str) for value in values):
            raise VerificationError("system-chain denial record has incomplete provenance")
        denials.add(values)  # type: ignore[arg-type]
    if not REQUIRED_SYSTEM_CHAIN_DENIALS.issubset(denials):
        raise VerificationError("system-chain lacks each live post-revoke PostgreSQL denial")
    return {
        "status": "PASS",
        "summary": dict(summary),
        "postRevokeDenials": [
            {"role": role, "code": code, "reason": reason, "reducer": reducer}
            for role, code, reason, reducer in sorted(REQUIRED_SYSTEM_CHAIN_DENIALS)
        ],
        "boundary": (
            "Production service/database handlers and PostgreSQL roles are exercised; "
            "browser rendering/injection and native-app UI are separate evidence."
        ),
    }


def validate_system_chain_revocation_control(output: str) -> dict[str, Any]:
    """Require the controlled no-revoke run to fail at the live denial oracle."""

    if "SYSTEM_CHAIN_SUMMARY " in output:
        raise VerificationError("revocation negative control unexpectedly reached a passing chain summary")
    if (
        "revoked chunk must be denied immediately" not in output
        or re.search(r"\b200\s*!==\s*503\b", output) is None
        or re.search(r"\bactual:\s*200\b", output) is None
        or re.search(r"\bexpected:\s*503\b", output) is None
    ):
        raise VerificationError("revocation negative control did not prove the live guard was reached")
    return {
        "status": "PASS",
        "control": "skip-revoke",
        "observed": 200,
        "expected": 503,
    }


def build_completion_report(
    evidence: Mapping[str, Any],
    *,
    chain: Mapping[str, Any] | None,
    chain_control: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Build the ten-clause report without treating absent chain evidence as passing."""

    clause_requirements = {
        "1": (("core", "service", "database", "fixtures"), True),
        "2": (("core", "service"), False),
        "3": (("web", "browser"), True),
        "4": (("service", "database", "browser"), False),
        "5": (("service", "database", "browser"), True),
        "6": (("service", "database", "infrastructure"), False),
        "7": (("service", "database"), False),
        "8": (("service", "database", "infrastructure"), False),
        "9": (("web", "browser"), False),
        "10": (
            (
                "core", "native", "artifact", "database", "infrastructure", "service", "web", "python", "node", "slice4", "slice5", "mutations", "sourceInventory", "freshness"
            ),
            False,
        ),
    }
    clauses: dict[str, dict[str, Any]] = {}
    for number, (required, needs_chain) in clause_requirements.items():
        missing = [
            name
            for name in required
            if not isinstance(evidence.get(name), Mapping) or evidence[name].get("status") != "PASS"
        ]
        chain_ok = not needs_chain or (isinstance(chain, Mapping) and chain.get("status") == "PASS")
        control_required = number == "5"
        control_ok = not control_required or (
            isinstance(chain_control, Mapping) and chain_control.get("status") == "PASS"
        )
        if needs_chain and not chain_ok:
            missing.append("system-chain")
        if control_required and not control_ok:
            missing.append("system-chain-revocation-control")
        status = "PASS" if not missing and chain_ok and control_ok else "INCOMPLETE"
        clause_evidence = [*required]
        if needs_chain:
            clause_evidence.append("system-chain")
        if control_required:
            clause_evidence.append("system-chain-revocation-control")
        clauses[number] = {"status": status, "evidence": clause_evidence, "missing": missing}
    return {
        "schemaVersion": 1,
        "status": "PASS" if all(clause["status"] == "PASS" for clause in clauses.values()) else "INCOMPLETE",
        "clauses": clauses,
        "systemChainBoundary": (
            chain.get("boundary") if isinstance(chain, Mapping) else "No composed production system-chain evidence was supplied."
        ),
    }


def _read_text_evidence(path: Path, label: str) -> str:
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise VerificationError(f"{label} is missing, redirected, or empty: {path}")
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{label} is not UTF-8 text: {path}") from error


def _read_json_evidence(path: Path, label: str) -> Any:
    try:
        return json.loads(_read_text_evidence(path, label))
    except json.JSONDecodeError as error:
        raise VerificationError(f"{label} is not valid JSON: {path}") from error


def _file_evidence(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise VerificationError(f"evidence file is missing, redirected, or empty: {path}")
    return {
        "path": str(path.resolve()),
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size,
        "mtimeNs": path.stat().st_mtime_ns,
    }


def _directory_evidence(path: Path, label: str) -> dict[str, Any]:
    if not path.is_dir() or path.is_symlink():
        raise VerificationError(f"{label} is missing or redirected: {path}")
    return {"path": str(path.resolve()), "mtimeNs": path.stat().st_mtime_ns}


def _raw_log_record(path: Path, validator: Any, label: str) -> dict[str, Any]:
    result = validator(_read_text_evidence(path, label))
    if not isinstance(result, Mapping):
        raise VerificationError(f"{label} validator did not return a record")
    return {"status": "PASS", **dict(result), "rawLog": _file_evidence(path)}


def _validate_service_log(path: Path) -> dict[str, Any]:
    return _raw_log_record(
        path,
        lambda output: validate_node_test_output(
            output,
            label="service",
            minimum_tests=SERVICE_FULL_SUITE_MINIMUM,
            required_tests=REQUIRED_SERVICE_TESTS,
        ),
        "service raw log",
    )


def _validate_web_log(path: Path) -> dict[str, Any]:
    return _raw_log_record(
        path,
        lambda output: validate_node_test_output(
            output,
            label="web",
            minimum_tests=18,
            required_tests=REQUIRED_WEB_TESTS,
        ),
        "web raw log",
    )


def _validate_core_log(path: Path) -> dict[str, Any]:
    return _raw_log_record(path, validate_swift_test_output, "Core raw log")


def _validate_python_log(path: Path) -> dict[str, Any]:
    return _raw_log_record(path, validate_python_test_output, "Python raw log")


def _validate_database_log(path: Path) -> dict[str, Any]:
    from Scripts import verify_slice6_mutation_controls

    return _raw_log_record(
        path,
        verify_slice6_mutation_controls.validate_database_output,
        "database raw log",
    )


def _validate_infrastructure_log(path: Path) -> dict[str, Any]:
    from Scripts import verify_slice6_mutation_controls

    return _raw_log_record(
        path,
        verify_slice6_mutation_controls.validate_infrastructure_output,
        "infrastructure raw log",
    )


def _validate_browser_results(results_path: Path, screenshots_directory: Path) -> dict[str, Any]:
    result = validate_browser_evidence(
        _read_json_evidence(results_path, "browser result"), screenshots_directory
    )
    return {"status": "PASS", **result, "results": _file_evidence(results_path)}


def _validate_native_evidence(
    iphone_xcresult: Path,
    ipad_xcresult: Path,
    screenshot_manifest: Path,
) -> dict[str, Any]:
    from Scripts import verify_slice5_sync

    try:
        iphone_summary, iphone_names = verify_slice5_sync.read_xcresult(iphone_xcresult)
        ipad_summary, ipad_names = verify_slice5_sync.read_xcresult(ipad_xcresult)
    except verify_slice5_sync.VerificationError as error:
        raise VerificationError(str(error)) from error
    iphone = validate_native_result("iPhone", iphone_summary, iphone_names)
    ipad = validate_native_result("iPad", ipad_summary, ipad_names)
    screenshots = validate_native_screenshot_manifest(
        _read_json_evidence(screenshot_manifest, "native screenshot manifest"),
        screenshot_manifest,
        iphone_xcresult,
        ipad_xcresult,
    )
    with tempfile.TemporaryDirectory(prefix="roomscan-slice6-attachment-proof-") as temporary_directory:
        root = Path(temporary_directory)
        try:
            exports = {
                device: (root / device, verify_slice5_sync._export_screenshot_attachments(result, root / device))
                for device, result in (("iphone", iphone_xcresult), ("ipad", ipad_xcresult))
            }
        except verify_slice5_sync.VerificationError as error:
            raise VerificationError(str(error)) from error
        validate_native_attachment_bindings(screenshots["captures"], exports)
    return {
        "status": "PASS",
        "iphone": iphone,
        "ipad": ipad,
        "iphoneResult": _directory_evidence(iphone_xcresult, "iPhone XCTest result"),
        "ipadResult": _directory_evidence(ipad_xcresult, "iPad XCTest result"),
        "screenshots": screenshots,
        "screenshotManifest": _file_evidence(screenshot_manifest),
    }


def _validate_artifact(app: Path) -> dict[str, Any]:
    from Scripts import inspect_slice6_ios_artifact

    try:
        inspection = inspect_slice6_ios_artifact.inspect_app(app)
    except inspect_slice6_ios_artifact.ArtifactInspectionError as error:
        raise VerificationError(str(error)) from error
    return {
        "status": "PASS",
        "inspection": inspection,
        "app": _directory_evidence(app, "generic iOS app"),
    }


def _validate_slice4_report(path: Path) -> dict[str, Any]:
    document = _read_json_evidence(path, "Slice 4 report")
    required_labels = (
        "Task 7 orchestration self-tests",
        "hosted service security tests",
        "professional web tests",
        "PostgreSQL 16 role and RLS integration",
        "Slice 6 composed publication system chain",
        "infrastructure assertions",
    )
    result = validate_step_report(document, label="Slice 4", required_labels=required_labels)
    steps = document["steps"]
    self_tests = next(step for step in steps if step.get("label") == "Task 7 orchestration self-tests")
    command = self_tests.get("command")
    if not isinstance(command, list) or not {
        "Scripts/test_verify_slice6_publication.py",
        "Scripts/test_verify_slice6_mutation_controls.py",
    }.issubset(command):
        raise VerificationError("Slice 4 self-test command does not wire both Slice 6 verifier tests")
    if document.get("node") != EXPECTED_NODE_VERSION:
        raise VerificationError("Slice 4 report does not record the exact Node 24.15.0 runtime")
    return {"status": "PASS", **result, "report": _file_evidence(path)}


def _validate_slice5_mutation_report(path: Path) -> dict[str, Any]:
    document = _read_json_evidence(path, "Slice 5 mutation report")
    if not isinstance(document, Mapping) or document.get("schemaVersion") != 1 or document.get("status") != "PASS":
        raise VerificationError("Slice 5 mutation report is not a terminal PASS")
    for name in ("database", "infrastructure"):
        record = document.get(name)
        if (
            not isinstance(record, Mapping)
            or record.get("status") != "PASS"
            or not isinstance(record.get("detected"), int)
            or record.get("detected", 0) < 1
            or record.get("restored") != record.get("detected")
            or not isinstance(record.get("guards"), list)
            or len(record["guards"]) != record["detected"]
        ):
            raise VerificationError(f"Slice 5 mutation report lacks a complete {name} ledger")
    raw = document.get("rawArtifactDetector")
    logs = document.get("logs")
    if not isinstance(raw, Mapping) or raw.get("status") != "PASS" or not isinstance(logs, list) or not logs:
        raise VerificationError("Slice 5 mutation report lacks detector or raw-log evidence")
    return {"status": "PASS", "report": _file_evidence(path)}


def _validate_slice5_sync_report(path: Path) -> dict[str, Any]:
    from Scripts import verify_slice5_sync

    document = _read_json_evidence(path, "Slice 5 sync report")
    try:
        verify_slice5_sync.validate_component_report(document)
    except verify_slice5_sync.VerificationError as error:
        raise VerificationError(str(error)) from error
    return {"status": "PASS", "report": _file_evidence(path)}


def _validate_mutation_report(
    path: Path, database_log: Path, infrastructure_log: Path
) -> dict[str, Any]:
    from Scripts import verify_slice6_mutation_controls

    document = _read_json_evidence(path, "Slice 6 mutation report")
    if not isinstance(document, Mapping) or document.get("schemaVersion") != 1 or document.get("status") != "PASS":
        raise VerificationError("Slice 6 mutation report is not a terminal PASS")
    evidence = document.get("evidence")
    if not isinstance(evidence, Mapping):
        raise VerificationError("Slice 6 mutation report lacks raw-log bindings")
    for name, raw_log in (("database", database_log), ("infrastructure", infrastructure_log)):
        binding = evidence.get(name)
        ledger = document.get(name)
        expected_guards = (
            verify_slice6_mutation_controls.EXPECTED_DATABASE_GUARDS
            if name == "database"
            else verify_slice6_mutation_controls.EXPECTED_INFRASTRUCTURE_GUARDS
        )
        if (
            not isinstance(binding, Mapping)
            or binding.get("sha256") != sha256_file(raw_log)
            or not isinstance(ledger, Mapping)
            or ledger.get("status") != "PASS"
            or ledger.get("detected") != len(expected_guards)
            or ledger.get("restored") != len(expected_guards)
            or ledger.get("guards") != sorted(expected_guards)
        ):
            raise VerificationError(f"Slice 6 mutation report does not bind the exact {name} ledger")
    return {"status": "PASS", "report": _file_evidence(path)}


def _write_private(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o600)


def _normalise_path(path: Path | None) -> Path | None:
    if path is None:
        return None
    return path if path.is_absolute() else ROOT / path


def _failure_record(error: BaseException) -> dict[str, str]:
    message = " ".join(str(error).split())
    return {"status": "FAIL", "failure": message[:512] or type(error).__name__}


def _capture_evidence(label: str, present: bool, action: Any) -> dict[str, Any]:
    if not present:
        return {"status": "MISSING", "reason": f"{label} was not supplied"}
    try:
        record = action()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        return _failure_record(error)
    if not isinstance(record, Mapping) or record.get("status") != "PASS":
        return {"status": "FAIL", "failure": f"{label} did not produce a terminal PASS record"}
    return dict(record)


def _freshness_paths(
    *,
    core_log: Path | None,
    service_log: Path | None,
    database_log: Path | None,
    infrastructure_log: Path | None,
    web_log: Path | None,
    browser_results: Path | None,
    browser_screenshots_dir: Path | None,
    iphone_xcresult: Path | None,
    ipad_xcresult: Path | None,
    generic_app: Path | None,
    screenshot_manifest: Path | None,
    chain_log: Path | None,
    chain_red_log: Path | None,
    mutation_report: Path | None,
) -> dict[str, list[Path]] | None:
    required = (
        core_log,
        service_log,
        database_log,
        infrastructure_log,
        web_log,
        browser_results,
        browser_screenshots_dir,
        iphone_xcresult,
        ipad_xcresult,
        generic_app,
        screenshot_manifest,
        chain_log,
        chain_red_log,
        mutation_report,
    )
    if any(path is None for path in required):
        return None
    assert all(path is not None for path in required)
    screenshots = [browser_screenshots_dir / name for name in REQUIRED_BROWSER_SCREENSHOTS]  # type: ignore[operator]
    return {
        "core": [core_log],
        "app": [iphone_xcresult, ipad_xcresult, generic_app, screenshot_manifest],
        "service": [service_log, chain_log, chain_red_log],
        "database": [database_log, mutation_report, chain_log, chain_red_log],
        "infrastructure": [infrastructure_log, mutation_report],
        "web": [web_log, browser_results, *screenshots],
        "fixtures": [core_log, service_log, chain_log],
    }


def aggregate_publication_evidence(
    artifacts: Path,
    *,
    core_log: Path | None = None,
    service_log: Path | None = None,
    database_log: Path | None = None,
    infrastructure_log: Path | None = None,
    web_log: Path | None = None,
    node_log: Path | None = None,
    chain_log: Path | None = None,
    chain_red_log: Path | None = None,
    browser_results: Path | None = None,
    browser_screenshots_dir: Path | None = None,
    iphone_xcresult: Path | None = None,
    ipad_xcresult: Path | None = None,
    generic_app: Path | None = None,
    screenshot_manifest: Path | None = None,
    python_log: Path | None = None,
    mutation_report: Path | None = None,
    slice4_report: Path | None = None,
    slice5_mutation_report: Path | None = None,
    slice5_sync_report: Path | None = None,
) -> dict[str, Any]:
    """Aggregate raw Slice 6 evidence without rerunning an already-complete matrix."""

    artifacts = _normalise_path(artifacts)
    assert artifacts is not None
    artifacts.mkdir(parents=True, exist_ok=True)
    core_log = _normalise_path(core_log)
    service_log = _normalise_path(service_log)
    database_log = _normalise_path(database_log)
    infrastructure_log = _normalise_path(infrastructure_log)
    web_log = _normalise_path(web_log)
    node_log = _normalise_path(node_log)
    chain_log = _normalise_path(chain_log)
    chain_red_log = _normalise_path(chain_red_log)
    browser_results = _normalise_path(browser_results)
    browser_screenshots_dir = _normalise_path(browser_screenshots_dir)
    iphone_xcresult = _normalise_path(iphone_xcresult)
    ipad_xcresult = _normalise_path(ipad_xcresult)
    generic_app = _normalise_path(generic_app)
    screenshot_manifest = _normalise_path(screenshot_manifest)
    python_log = _normalise_path(python_log)
    mutation_report = _normalise_path(mutation_report)
    slice4_report = _normalise_path(slice4_report)
    slice5_mutation_report = _normalise_path(slice5_mutation_report)
    slice5_sync_report = _normalise_path(slice5_sync_report)

    fixtures = _capture_evidence(
        "publication fixtures",
        True,
        lambda: {
            "status": "PASS",
            "digests": validate_fixture_digests(ROOT, PUBLICATION_FIXTURE_DIGESTS),
            "propertyArchiveSHA256": validate_property_fixture_archive(ROOT),
        },
    )
    evidence: dict[str, Any] = {
        "fixtures": fixtures,
        "node": _capture_evidence(
            "Node runtime log",
            node_log is not None,
            lambda: {
                **validate_node_runtime_output(_read_text_evidence(node_log, "Node runtime log")),  # type: ignore[arg-type]
                "rawLog": _file_evidence(node_log),  # type: ignore[arg-type]
            },
        ),
        "core": _capture_evidence("Core raw log", core_log is not None, lambda: _validate_core_log(core_log)),  # type: ignore[arg-type]
        "service": _capture_evidence("service raw log", service_log is not None, lambda: _validate_service_log(service_log)),  # type: ignore[arg-type]
        "database": _capture_evidence("database raw log", database_log is not None, lambda: _validate_database_log(database_log)),  # type: ignore[arg-type]
        "infrastructure": _capture_evidence("infrastructure raw log", infrastructure_log is not None, lambda: _validate_infrastructure_log(infrastructure_log)),  # type: ignore[arg-type]
        "web": _capture_evidence("web raw log", web_log is not None, lambda: _validate_web_log(web_log)),  # type: ignore[arg-type]
        "python": _capture_evidence("Python raw log", python_log is not None, lambda: _validate_python_log(python_log)),  # type: ignore[arg-type]
        "browser": _capture_evidence(
            "browser results and screenshots",
            browser_results is not None and browser_screenshots_dir is not None,
            lambda: _validate_browser_results(browser_results, browser_screenshots_dir),  # type: ignore[arg-type]
        ),
        "native": _capture_evidence(
            "native XCTest and screenshot evidence",
            iphone_xcresult is not None and ipad_xcresult is not None and screenshot_manifest is not None,
            lambda: _validate_native_evidence(iphone_xcresult, ipad_xcresult, screenshot_manifest),  # type: ignore[arg-type]
        ),
        "artifact": _capture_evidence(
            "generic iOS app",
            generic_app is not None,
            lambda: _validate_artifact(generic_app),  # type: ignore[arg-type]
        ),
        "slice4": _capture_evidence(
            "Slice 4 report",
            slice4_report is not None,
            lambda: _validate_slice4_report(slice4_report),  # type: ignore[arg-type]
        ),
    }
    chain = _capture_evidence(
        "composed system-chain log",
        chain_log is not None and fixtures.get("status") == "PASS",
        lambda: {
            **validate_system_chain_output(
                _read_text_evidence(chain_log, "system-chain log"),  # type: ignore[arg-type]
                expected_fixture_sha256=fixtures["propertyArchiveSHA256"],
            ),
            "rawLog": _file_evidence(chain_log),  # type: ignore[arg-type]
        },
    )
    chain_control = _capture_evidence(
        "system-chain revocation control",
        chain_red_log is not None,
        lambda: {
            **validate_system_chain_revocation_control(
                _read_text_evidence(chain_red_log, "system-chain revocation control")  # type: ignore[arg-type]
            ),
            "rawLog": _file_evidence(chain_red_log),  # type: ignore[arg-type]
        },
    )
    evidence["mutations"] = _capture_evidence(
        "Slice 6 mutation report",
        mutation_report is not None and database_log is not None and infrastructure_log is not None,
        lambda: _validate_mutation_report(mutation_report, database_log, infrastructure_log),  # type: ignore[arg-type]
    )
    slice5_mutations = _capture_evidence(
        "Slice 5 mutation report",
        slice5_mutation_report is not None,
        lambda: _validate_slice5_mutation_report(slice5_mutation_report),  # type: ignore[arg-type]
    )
    slice5_sync = _capture_evidence(
        "Slice 5 sync report",
        slice5_sync_report is not None,
        lambda: _validate_slice5_sync_report(slice5_sync_report),  # type: ignore[arg-type]
    )
    slice5_statuses = {slice5_mutations.get("status"), slice5_sync.get("status")}
    evidence["slice5"] = {
        "status": "FAIL"
        if "FAIL" in slice5_statuses
        else "PASS"
        if slice5_statuses == {"PASS"}
        else "INCOMPLETE",
        "mutation": slice5_mutations,
        "sync": slice5_sync,
    }

    source_inventory = _capture_evidence(
        "runtime source inventory",
        True,
        lambda: {"status": "PASS", "scopes": collect_source_inventory(ROOT, RUNTIME_SOURCE_PATHS)},
    )
    freshness_paths = _freshness_paths(
        core_log=core_log,
        service_log=service_log,
        database_log=database_log,
        infrastructure_log=infrastructure_log,
        web_log=web_log,
        browser_results=browser_results,
        browser_screenshots_dir=browser_screenshots_dir,
        iphone_xcresult=iphone_xcresult,
        ipad_xcresult=ipad_xcresult,
        generic_app=generic_app,
        screenshot_manifest=screenshot_manifest,
        chain_log=chain_log,
        chain_red_log=chain_red_log,
        mutation_report=mutation_report,
    )
    if freshness_paths is not None and evidence["native"].get("status") == "PASS":
        freshness_paths["app"].extend(
            Path(capture["path"]) for capture in evidence["native"]["screenshots"]["captures"]
        )
    required_fresh_components = (
        "fixtures", "core", "service", "database", "infrastructure", "web", "browser", "native", "artifact", "mutations"
    )
    if (
        freshness_paths is None
        or source_inventory.get("status") != "PASS"
        or any(evidence[name].get("status") != "PASS" for name in required_fresh_components)
        or chain.get("status") != "PASS"
        or chain_control.get("status") != "PASS"
    ):
        freshness = {
            "status": "INCOMPLETE",
            "bindingMode": "posthoc-mtime-and-sha256",
            "executionAttested": False,
            "reason": "all scoped runtime evidence must pass before freshness can be bound",
        }
    else:
        freshness = _capture_evidence(
            "scoped runtime freshness",
            True,
            lambda: {
                "status": "PASS",
                "bindingMode": "posthoc-mtime-and-sha256",
                "executionAttested": False,
                "scopes": validate_scoped_freshness(
                    {scope: [ROOT / path for path in paths] for scope, paths in RUNTIME_SOURCE_PATHS.items()},
                    freshness_paths,
                ),
            },
        )

    evidence["sourceInventory"] = source_inventory
    evidence["freshness"] = freshness
    completion = build_completion_report(evidence, chain=chain, chain_control=chain_control)
    if completion["status"] == "PASS":
        validate_clause_results(completion["clauses"])
    records = {**evidence, "systemChain": chain, "systemChainControl": chain_control}
    failures = sorted(name for name, record in records.items() if record.get("status") == "FAIL")
    incomplete = sorted(name for name, record in records.items() if record.get("status") in {"MISSING", "INCOMPLETE"})
    status = "FAIL" if failures else "PASS" if completion["status"] == "PASS" and not incomplete else "INCOMPLETE"
    report = {
        "schemaVersion": 1,
        "status": status,
        "completion": completion,
        "evidence": records,
        "sourceBinding": {
            "mode": "posthoc-mtime-and-sha256",
            "note": "Only scoped runtime and fixture sources are compared; docs, CI, and verifier files are excluded.",
        },
        "failures": failures,
        "incomplete": incomplete,
    }
    _write_private(artifacts / "publication-verification.json", json.dumps(report, indent=2) + "\n")
    return report


def _local_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not (key.startswith("AWS_") or key.startswith("CDK_") or key.startswith("ROOMSCAN_"))
    }
    environment["PATH"] = f"{NODE24_BIN}{os.pathsep}{environment.get('PATH', '')}"
    environment["AWS_EC2_METADATA_DISABLED"] = "true"
    environment["CI"] = "true"
    return environment


def _run_default_step(
    label: str, command: tuple[str, ...], artifacts: Path
) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=_local_environment(),
        check=False,
        capture_output=True,
        text=True,
    )
    output = completed.stdout + completed.stderr
    log = artifacts / "raw" / f"{label}.log"
    _write_private(log, output)
    record = {
        "label": label,
        "command": list(command),
        "exitCode": completed.returncode,
        "rawLog": _file_evidence(log) if output else {"path": str(log.resolve()), "bytes": 0},
    }
    if completed.returncode != 0:
        raise VerificationError(f"{label} failed with exit {completed.returncode}; inspect {log}")
    return record


def run_default_collection(artifacts: Path) -> dict[str, Any]:
    """Run the local non-device command matrix and preserve raw command output.

    Native result bundles and reviewed screenshots are intentionally not fabricated
    here; feed those real artifacts to ``--aggregate`` after their owner exports
    them.
    """

    artifacts = _normalise_path(artifacts)
    assert artifacts is not None
    artifacts.mkdir(parents=True, exist_ok=True)
    commands = (
        ("00-node", ("node", "--version")),
        (
            "01-core",
            (
                "swift",
                "test",
                "--package-path",
                ".",
                "--scratch-path",
                "/private/tmp/roomscan-slice6-publication-core",
                "--disable-sandbox",
                "--no-parallel",
            ),
        ),
        ("02-service-typecheck", ("npm", "--prefix", "HostedService", "run", "typecheck")),
        ("03-service-build", ("npm", "--prefix", "HostedService", "run", "build")),
        ("04-service-tests", ("npm", "--prefix", "HostedService", "test")),
        ("05-database", ("npm", "--prefix", "HostedService/db", "test")),
        ("06-infrastructure", ("npm", "--prefix", "HostedService/infra", "run", "verify")),
        ("07-web-typecheck", ("npm", "--prefix", "HostedService/web", "run", "typecheck")),
        ("08-web-tests", ("npm", "--prefix", "HostedService/web", "test")),
        ("09-web-build", ("npm", "--prefix", "HostedService/web", "run", "build")),
        ("10-web-browser", ("npm", "--prefix", "HostedService/web", "run", "test:e2e")),
        (
            "11-python",
            ("python3", "-B", "-m", "unittest", "discover", "-s", "Scripts", "-p", "test_*.py"),
        ),
    )
    records: list[dict[str, Any]] = []
    for label, command in commands:
        record = _run_default_step(label, command, artifacts)
        records.append(record)
        _write_private(
            artifacts / "publication-command-collection.json",
            json.dumps({"schemaVersion": 1, "status": "RUNNING", "steps": records}, indent=2) + "\n",
        )
    report = {
        "schemaVersion": 1,
        "status": "COLLECTED",
        "steps": records,
        "next": "Run --aggregate with the resulting raw logs plus native/artifact/review/prior-oracle evidence.",
    }
    _write_private(
        artifacts / "publication-command-collection.json", json.dumps(report, indent=2) + "\n"
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", required=True, type=Path)
    parser.add_argument("--aggregate", action="store_true")
    parser.add_argument("--core-log", type=Path)
    parser.add_argument("--service-log", type=Path)
    parser.add_argument("--database-log", type=Path)
    parser.add_argument("--infrastructure-log", type=Path)
    parser.add_argument("--web-log", type=Path)
    parser.add_argument("--node-log", type=Path)
    parser.add_argument("--chain-log", type=Path)
    parser.add_argument("--chain-red-log", type=Path)
    parser.add_argument("--browser-results", type=Path)
    parser.add_argument("--browser-screenshots-dir", type=Path)
    parser.add_argument("--iphone-xcresult", type=Path)
    parser.add_argument("--ipad-xcresult", type=Path)
    parser.add_argument("--generic-app", type=Path)
    parser.add_argument("--screenshot-manifest", type=Path)
    parser.add_argument("--python-log", type=Path)
    parser.add_argument("--mutation-report", type=Path)
    parser.add_argument("--slice4-report", type=Path)
    parser.add_argument("--slice5-mutation-report", type=Path)
    parser.add_argument("--slice5-sync-report", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.aggregate:
            report = aggregate_publication_evidence(
                arguments.artifacts_dir,
                core_log=arguments.core_log,
                service_log=arguments.service_log,
                database_log=arguments.database_log,
                infrastructure_log=arguments.infrastructure_log,
                web_log=arguments.web_log,
                node_log=arguments.node_log,
                chain_log=arguments.chain_log,
                chain_red_log=arguments.chain_red_log,
                browser_results=arguments.browser_results,
                browser_screenshots_dir=arguments.browser_screenshots_dir,
                iphone_xcresult=arguments.iphone_xcresult,
                ipad_xcresult=arguments.ipad_xcresult,
                generic_app=arguments.generic_app,
                screenshot_manifest=arguments.screenshot_manifest,
                python_log=arguments.python_log,
                mutation_report=arguments.mutation_report,
                slice4_report=arguments.slice4_report,
                slice5_mutation_report=arguments.slice5_mutation_report,
                slice5_sync_report=arguments.slice5_sync_report,
            )
            exit_code = 0 if report["status"] == "PASS" else 1
        else:
            report = run_default_collection(arguments.artifacts_dir)
            exit_code = 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        failure = {"schemaVersion": 1, "status": "FAIL", "failure": " ".join(str(error).split())[:512]}
        _write_private(
            _normalise_path(arguments.artifacts_dir) / "publication-verification.json",  # type: ignore[operator]
            json.dumps(failure, indent=2) + "\n",
        )
        print(failure["failure"], file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

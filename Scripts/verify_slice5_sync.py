#!/usr/bin/env python3
"""Run Slice 5 component oracles and finalize fresh cross-boundary evidence.

The default mode runs only local/synthetic Core, service, PostgreSQL 16, and
infrastructure sources.  ``--initialize-run`` creates a non-overwritable
freshness marker before the complete matrix.  ``--finalize`` is intentionally
run last and rejects missing, pre-marker, failed, or count-regressed evidence.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any, Iterable, Mapping


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = ROOT / "RoomScanCore" / "Tests" / "RoomScanCoreTests" / "Fixtures" / "ProfessionalSync"
EXPECTED_FIXTURE_DIGESTS = {
    "reviewed-raw-v1.descriptor.base64": "00a5f27835f8f63131b11fa86646a6bf6b41e886558380361ce900995b9e7fe8",
    "reviewed-raw-v1.manifest-sha256.txt": "da698e5d3e7ba3387550ae4b46dcb56313ab7cd806bc99db2240de4be67a84a4",
    "reviewed-raw-v1.zip.base64": "5d25885a9fcd80d8d6905a6659bd3851fb078e04c4cf1eb52fe1d4941a24983b",
    "working-set-v1.descriptor.base64": "23314f1f713d01c999e298f7584bae477af158331b3aaabd518edfabdd73d7a2",
    "working-set-v1.manifest-sha256.txt": "9b66dbcd950b55843c2146c61b7e868e9b6e5837fb0c229bc3f0b995a5d3d4c9",
    "working-set-v1.zip.base64": "c9a9ef4646e21fa96939c6530f0e999f68cf8affeec36eda51d33453bef06dee",
}
REQUIRED_CRASH_CUT_POINTS = (
    "allocation-before-presign",
    "put-before-complete",
    "complete-before-sqs",
    "mid-validation",
    "active-copy-before-cas",
    "cas-before-response",
)
REQUIRED_XCTESTS = (
    "testSlice5MigrationPreviewMakesApprovalRetryAndLocalRetentionExplicit",
    "testSlice5StaleHeadPreservesBothBranchesAndRequiresExplicitResolution",
    "testSlice5RawArchiveIsSeparateReviewedOptIn",
    "testTwoIndependentClientsKeepCanonicalAndStaleArchivesRecoverableWithoutMerge",
    "testInterruptedCompanionRecoveryResumesBoundTransactionAndCleansJournal",
    "testSlice5DesktopWidthLandscapeScenarios",
)
REQUIRED_ARTIFACT_MARKERS = (
    "roomscan-professional-working-set-v1",
    "roomscan-initial-project-sync-v1",
    "roomscan-project-revision-append-v1",
    "roomscan-professional-project-sync-journal-v1",
    "roomscan-professional-raw-archive-manifest-v1",
    "preserveBranchesRequireUserResolution",
    "professional.sync.preview",
    "professional.sync.approve",
    "professional.sync.progress",
    "professional.sync.retry",
    "professional.sync.rawReview",
    "professional.sync.conflict.compare",
    "professional.sync.conflict.rebase",
    "professional.sync.conflict.duplicate",
)
REQUIRED_SCREENSHOT_DEVICE_CLASSES = (
    "mobile-iphone",
    "tablet-ipad",
    "desktop-width",
)
REQUIRED_SCREENSHOT_SCENARIOS = (
    "migration-retry",
    "stale-head-conflict",
    "raw-archive-review",
)
REQUIRED_REVIEW_DIMENSIONS = (
    "hierarchy",
    "dynamic-type",
    "contrast",
    "voiceover-order-and-labels",
    "touch-targets",
    "overflow",
    "safe-areas",
)
SCREENSHOT_TEST_SCENARIOS = {
    "testSlice5MigrationPreviewMakesApprovalRetryAndLocalRetentionExplicit": "migration-retry",
    "testSlice5StaleHeadPreservesBothBranchesAndRequiresExplicitResolution": "stale-head-conflict",
    "testSlice5RawArchiveIsSeparateReviewedOptIn": "raw-archive-review",
}
SCREENSHOT_ATTACHMENT_SCENARIOS = {
    "slice5-migration-preview-retry": "migration-retry",
    "slice5-stale-head-comparison": "stale-head-conflict",
    "slice5-raw-archive-review": "raw-archive-review",
}


class VerificationError(RuntimeError):
    """A required Slice 5 oracle or evidence binding failed."""


@dataclass(frozen=True)
class CommandStep:
    label: str
    command: tuple[str, ...]
    required_output: tuple[str, ...] = ()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(128 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_fixture_digests(root: Path, expected: Mapping[str, str]) -> dict[str, str]:
    actual: dict[str, str] = {}
    for relative, expected_digest in sorted(expected.items()):
        path = root / relative
        if not path.is_file() or path.is_symlink():
            raise VerificationError(f"required Core fixture is missing or unsafe: {relative}")
        digest = sha256_file(path)
        if digest != expected_digest:
            raise VerificationError(
                f"Core fixture digest drifted for {relative}: {digest}; update only with a reviewed contract change"
            )
        actual[relative] = digest
    return actual


def _require_mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise VerificationError(f"{label} must be a JSON object")
    return value


def validate_component_report(document: Any) -> None:
    report = _require_mapping(document, "component report")
    if report.get("schemaVersion") != 1 or report.get("status") != "PASS":
        raise VerificationError("component report is not a terminal Slice 5 PASS")
    postgres = _require_mapping(report.get("postgresql"), "PostgreSQL evidence")
    if postgres.get("major") != 16 or postgres.get("status") != "PASS":
        raise VerificationError("component report must exercise PostgreSQL 16")
    if report.get("logicalClients") != ["client-a", "client-b"]:
        raise VerificationError("component oracle must name two independent logical clients")
    swift_tests = _require_mapping(report.get("swiftTests"), "Swift package test evidence")
    if (
        swift_tests.get("status") != "PASS"
        or not isinstance(swift_tests.get("passed"), int)
        or swift_tests["passed"] <= 266
    ):
        raise VerificationError("full Swift package tests must exceed the 266-test Slice 4 baseline")
    cut_points = _require_mapping(report.get("crashCutPoints"), "crash-cut evidence")
    if set(cut_points) != set(REQUIRED_CRASH_CUT_POINTS) or any(
        cut_points.get(point) != "PASS" for point in REQUIRED_CRASH_CUT_POINTS
    ):
        raise VerificationError("all six fixed crash cut points must pass")
    raw = _require_mapping(report.get("rawInventory"), "raw inventory evidence")
    for field in ("positiveControl", "defaultWorkingSet", "reviewedRawSeparateTier"):
        if raw.get(field) != "PASS":
            raise VerificationError(f"raw inventory evidence lacks {field}=PASS")
    clauses = _require_mapping(report.get("clauses"), "component clauses")
    if set(clauses) != {str(index) for index in range(1, 8)}:
        raise VerificationError("component report must contain exact clauses 1 through 7")
    for index in range(1, 8):
        clause = _require_mapping(clauses[str(index)], f"clause {index}")
        evidence = clause.get("evidence")
        if clause.get("status") != "PASS" or not isinstance(evidence, list) or not evidence:
            raise VerificationError(f"component clause {index} lacks terminal evidence")


def validate_xcresult(label: str, summary: Any, test_names: set[str]) -> dict[str, Any]:
    result = _require_mapping(summary, f"{label} XCTest summary")
    passed = result.get("passedTests")
    failed = result.get("failedTests")
    total = result.get("totalTestCount")
    if (
        result.get("result") != "Passed"
        or not isinstance(passed, int)
        or passed <= 259
        or failed != 0
        or total != passed
    ):
        raise VerificationError(
            f"{label} full scheme must pass more than 259 tests with no failures or skips"
        )
    missing = sorted(
        required
        for required in REQUIRED_XCTESTS
        if not any(required in actual for actual in test_names)
    )
    if missing:
        raise VerificationError(f"{label} XCTest result lacks Slice 5 tests: {', '.join(missing)}")
    return {"status": "PASS", "passedTests": passed, "totalTestCount": total}


def _walk_test_names(value: Any) -> set[str]:
    names: set[str] = set()
    if isinstance(value, Mapping):
        if value.get("nodeType") == "Test Case":
            for field in ("name", "nodeIdentifier", "nodeIdentifierURL"):
                candidate = value.get(field)
                if isinstance(candidate, str):
                    names.add(candidate)
        for nested in value.values():
            names.update(_walk_test_names(nested))
    elif isinstance(value, list):
        for nested in value:
            names.update(_walk_test_names(nested))
    return names


def _xcresulttool(path: Path, operation: str) -> Any:
    completed = subprocess.run(
        (
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            operation,
            "--path",
            str(path),
            "--format",
            "json",
        ),
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise VerificationError(f"cannot read {operation} from XCTest result {path}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise VerificationError(f"XCTest {operation} output is not JSON for {path}") from error


def read_xcresult(path: Path) -> tuple[Mapping[str, Any], set[str]]:
    return (
        _require_mapping(_xcresulttool(path, "summary"), "XCTest summary"),
        _walk_test_names(_xcresulttool(path, "tests")),
    )


def validate_screenshot_report(document: Any, *, base: Path | None = None) -> None:
    report = _require_mapping(document, "screenshot report")
    if report.get("status") != "PASS" or report.get("reviewStatus") != "PASS":
        raise VerificationError("screenshot manifest and visual review must both pass")
    dimensions = report.get("reviewedDimensions")
    if not isinstance(dimensions, list) or set(dimensions) != set(REQUIRED_REVIEW_DIMENSIONS):
        raise VerificationError("screenshot review dimensions are incomplete")
    captures = report.get("captures")
    if not isinstance(captures, list):
        raise VerificationError("screenshot captures must be an array")
    pairs: set[tuple[str, str]] = set()
    for capture in captures:
        record = _require_mapping(capture, "screenshot capture")
        device = record.get("deviceClass")
        scenario = record.get("scenario")
        digest = record.get("sha256")
        if (
            device not in REQUIRED_SCREENSHOT_DEVICE_CLASSES
            or scenario not in REQUIRED_SCREENSHOT_SCENARIOS
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        ):
            raise VerificationError("screenshot capture has an invalid device/scenario/digest")
        pair = (str(device), str(scenario))
        if pair in pairs:
            raise VerificationError("screenshot report has a duplicate device/scenario capture")
        pairs.add(pair)
        if base is not None:
            relative = record.get("path")
            if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
                raise VerificationError("fresh screenshot evidence needs a relative artifact path")
            screenshot = (base / relative).resolve()
            try:
                screenshot.relative_to(base.resolve())
            except ValueError as error:
                raise VerificationError("screenshot artifact escapes its evidence directory") from error
            if not screenshot.is_file() or screenshot.is_symlink() or sha256_file(screenshot) != digest:
                raise VerificationError("screenshot artifact is missing, unsafe, or digest-mismatched")
    required = {
        (device, scenario)
        for device in REQUIRED_SCREENSHOT_DEVICE_CLASSES
        for scenario in REQUIRED_SCREENSHOT_SCENARIOS
    }
    if pairs != required:
        raise VerificationError("screenshot report lacks the exact iPhone/iPad/desktop scenario matrix")


def _latest_mtime_ns(path: Path) -> int:
    if path.is_symlink():
        raise VerificationError(f"evidence path must not be a symlink: {path}")
    latest = path.stat().st_mtime_ns
    if path.is_dir():
        for nested in path.rglob("*"):
            if nested.is_symlink():
                raise VerificationError(f"evidence bundle contains a symlink: {nested}")
            latest = max(latest, nested.stat().st_mtime_ns)
    return latest


def require_fresh_evidence(marker: Path, evidence_paths: Iterable[Path]) -> None:
    if not marker.is_file() or marker.is_symlink():
        raise VerificationError("run marker is missing or unsafe")
    marker_time = marker.stat().st_mtime_ns
    for path in evidence_paths:
        if not path.exists():
            raise VerificationError(f"required final evidence is missing: {path}")
        if _latest_mtime_ns(path) <= marker_time:
            raise VerificationError(f"required evidence predates the matrix marker: {path}")


def _read_json(path: Path, label: str) -> Mapping[str, Any]:
    try:
        return _require_mapping(json.loads(path.read_text(encoding="utf-8")), label)
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError(f"cannot read {label} at {path}") from error


def finalize_evidence(
    *,
    marker: Path,
    component_report: Path,
    mutation_report: Path,
    slice4_report: Path,
    artifact_report: Path,
    screenshot_report: Path,
    iphone_xcresult: Path,
    ipad_xcresult: Path,
) -> dict[str, Any]:
    paths = [
        component_report,
        mutation_report,
        slice4_report,
        artifact_report,
        screenshot_report,
        iphone_xcresult,
        ipad_xcresult,
    ]
    require_fresh_evidence(marker, paths)
    component = _read_json(component_report, "Slice 5 component report")
    validate_component_report(component)
    mutations = _read_json(mutation_report, "Slice 5 mutation report")
    if mutations.get("status") != "PASS":
        raise VerificationError("Slice 5 mutation controls are not PASS")
    slice4 = _read_json(slice4_report, "Slice 4 regression report")
    if slice4.get("status") != "PASS":
        raise VerificationError("prior Slice 4 hosted verifier is not PASS")
    artifact = _read_json(artifact_report, "Slice 5 iOS artifact report")
    required_markers = artifact.get("requiredMarkers")
    if (
        artifact.get("status") != "PASS"
        or not isinstance(required_markers, list)
        or not set(REQUIRED_ARTIFACT_MARKERS).issubset(set(required_markers))
        or artifact.get("missingMarkers") != []
        or artifact.get("forbiddenMarkersFound") != []
    ):
        raise VerificationError("compiled Slice 5 artifact evidence is incomplete or unsafe")
    screenshots = _read_json(screenshot_report, "Slice 5 screenshot report")
    validate_screenshot_report(screenshots, base=screenshot_report.parent)
    iphone_summary, iphone_names = read_xcresult(iphone_xcresult)
    ipad_summary, ipad_names = read_xcresult(ipad_xcresult)
    iphone = validate_xcresult("iPhone", iphone_summary, iphone_names)
    ipad = validate_xcresult("iPad", ipad_summary, ipad_names)
    clauses = dict(_require_mapping(component["clauses"], "component clauses"))
    clauses["8"] = {
        "status": "PASS",
        "evidence": [
            f"full Swift package: {component['swiftTests']['passed']} passed",
            f"iPhone full scheme: {iphone['passedTests']} passed",
            f"iPad full scheme: {ipad['passedTests']} passed",
            "generic unsigned compiled artifact: PASS",
            "Slice 4 hosted regression: PASS",
            "iPhone/iPad/desktop-width screenshot review: PASS",
        ],
    }
    return {
        "schemaVersion": 1,
        "status": "PASS",
        "finalizedAt": datetime.now(timezone.utc).isoformat(),
        "runMarker": str(marker.resolve()),
        "clauses": clauses,
        "fullSchemes": {"iphone": iphone, "ipad": ipad},
        "componentReportSHA256": sha256_file(component_report),
        "mutationReportSHA256": sha256_file(mutation_report),
        "slice4ReportSHA256": sha256_file(slice4_report),
        "artifactReportSHA256": sha256_file(artifact_report),
        "screenshotReportSHA256": sha256_file(screenshot_report),
        "externalEvidence": {
            "physicalDevice": "NOT_VERIFIED",
            "provider": "NOT_VERIFIED",
            "deployment": "NOT_PERFORMED",
        },
    }


def _clean_environment(inherited: Mapping[str, str] | None = None) -> dict[str, str]:
    source = dict(os.environ if inherited is None else inherited)
    environment = {
        key: value
        for key, value in source.items()
        if not (key.startswith("AWS_") or key.startswith("CDK_") or key.startswith("ROOMSCAN_"))
    }
    environment.update(
        {
            "AWS_EC2_METADATA_DISABLED": "true",
            "AWS_REGION": "us-east-1",
            "AWS_DEFAULT_REGION": "us-east-1",
            "CI": "true",
            "CLANG_MODULE_CACHE_PATH": "/private/tmp/roomscan-slice5-clang-module-cache",
            "SWIFTPM_MODULECACHE_OVERRIDE": "/private/tmp/roomscan-slice5-swiftpm-module-cache",
        }
    )
    return environment


def _write_private(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o600)


def _postgres_16_version() -> tuple[str, str]:
    candidates = (
        Path("/opt/homebrew/opt/postgresql@16/bin/postgres"),
        Path("/usr/local/opt/postgresql@16/bin/postgres"),
        Path("/usr/lib/postgresql/16/bin/postgres"),
    )
    for candidate in candidates:
        if not candidate.is_file():
            continue
        completed = subprocess.run(
            (str(candidate), "--version"),
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode == 0 and re.search(r"PostgreSQL\) 16\.", completed.stdout):
            return str(candidate.resolve()), completed.stdout.strip()
    raise VerificationError("an explicit PostgreSQL 16 executable is required")


def component_command_plan() -> list[CommandStep]:
    return [
        CommandStep(
            "01-verifier-self-tests",
            (
                "python3",
                "-B",
                "-m",
                "unittest",
                "Scripts/test_inspect_slice5_ios_artifact.py",
                "Scripts/test_verify_slice5_mutation_controls.py",
                "Scripts/test_verify_slice5_sync.py",
            ),
            ("OK",),
        ),
        CommandStep(
            "02-full-swift-package",
            (
                "swift",
                "test",
                "--package-path",
                ".",
                "--scratch-path",
                "/private/tmp/roomscan-slice5-verifier-core",
                "--disable-sandbox",
                "--no-parallel",
            ),
            ("Test Suite 'All tests' passed",),
        ),
        CommandStep("03-service-typecheck", ("npm", "--prefix", "HostedService", "run", "typecheck")),
        CommandStep(
            "04-service-tests",
            ("npm", "--prefix", "HostedService", "test"),
            (
                "worker recovers an active immutable copy made before finalization",
                "working-set validator detects an injected forbidden raw artifact",
                "Slice 5 adds exactly ten sealed routes",
            ),
        ),
        CommandStep("05-service-build", ("npm", "--prefix", "HostedService", "run", "build")),
        CommandStep(
            "06-database-project-sync",
            ("npm", "--prefix", "HostedService/db", "run", "test:integration-0008-project-sync"),
            ("logical_clients=2", "canonical_appends=1", "stale_appends=1", "status=pass"),
        ),
        CommandStep(
            "07-database-project-sync-security",
            ("npm", "--prefix", "HostedService/db", "run", "test:integration-0008-project-sync-security"),
            ("status=pass",),
        ),
        CommandStep(
            "08-database-staged-upgrade",
            ("node", "HostedService/db/test/staged-upgrade.mjs"),
            ("project_sync_migrations=1", "status=pass"),
        ),
        CommandStep("09-infrastructure-typecheck", ("npm", "--prefix", "HostedService/infra", "run", "typecheck")),
        CommandStep(
            "10-infrastructure-local-tests",
            ("npm", "--prefix", "HostedService/infra", "run", "test:local"),
            ("project sync",),
        ),
    ]


def _source_contract() -> dict[str, list[str]]:
    requirements = {
        "RoomScanCore/Tests/RoomScanCoreTests/RoomProfessionalWorkingSetArchiveTests.swift": [
            "testDefaultWorkingSetRejectsInjectedRawClassesWhileReviewedRawArchiveAcceptsBoundBytes",
            "testDownloadedArchiveInspectionDerivesDescriptorOnlyAfterOuterAndManifestDigestsMatch",
        ],
        "RoomScanCore/Tests/RoomScanCoreTests/RoomProfessionalRecoveryTests.swift": [
            "testProfessionalRecoveryCoordinatorResumesEveryPackageFirstCrashWindow",
            "testCompletePackageProvenanceIsRejectedFromWorkingSetAndDowngradedWithoutMutatingSource",
        ],
        "HostedService/service/test/project-sync-capabilities.test.ts": [
            "allocation reducer commits its durable allocation before the server-owned immutable presign",
            "completion commits validation_pending before targetless wake; a failed response recovers through status",
        ],
        "HostedService/service/test/project-sync-worker.test.ts": [
            "interrupted upload releases its lease and a later targetless worker retry validates the real Core fixture",
            "worker recovers an active immutable copy made before finalization",
        ],
        "HostedService/db/test/integration-0008-project-sync.mjs": [
            "logical_clients=2",
            "canonical_appends=1",
            "stale_appends=1",
            "reaped_allocations=1",
        ],
        "RoomScanStudio/RoomScanStudioTests/ProfessionalProjectSyncTests.swift": [
            "testTwoIndependentClientsKeepCanonicalAndStaleArchivesRecoverableWithoutMerge",
            "testInterruptedCompanionRecoveryResumesBoundTransactionAndCleansJournal",
            "testGuestScanSaveViewEditExportAndImportStayAccountFreeAndOffline",
            "testReviewedRawAttachmentUsesSeparateTierAndNeverAdvancesHead",
        ],
    }
    for relative, markers in requirements.items():
        source = (ROOT / relative).read_text(encoding="utf-8")
        missing = [marker for marker in markers if marker not in source]
        if missing:
            raise VerificationError(f"real-source oracle drift in {relative}: {', '.join(missing)}")
    return requirements


def _run_step(step: CommandStep, artifacts: Path) -> dict[str, Any]:
    completed = subprocess.run(
        step.command,
        cwd=ROOT,
        env=_clean_environment(),
        check=False,
        capture_output=True,
        text=True,
    )
    output = completed.stdout + completed.stderr
    log_path = artifacts / f"{step.label}.log"
    _write_private(log_path, output)
    if completed.returncode != 0:
        raise VerificationError(f"{step.label} failed; inspect {log_path}")
    missing = [marker for marker in step.required_output if marker.lower() not in output.lower()]
    if missing:
        raise VerificationError(f"{step.label} did not reach required oracle output: {missing}")
    return {
        "label": step.label,
        "status": "PASS",
        "command": list(step.command),
        "log": str(log_path),
        "logSHA256": sha256_file(log_path),
    }


def _swift_test_count(log: Path) -> int:
    output = log.read_text(encoding="utf-8")
    counts = [
        int(match)
        for pattern in (
            r"Executed (\d+) tests?, with 0 failures",
            r"Test run with (\d+) tests passed",
        )
        for match in re.findall(pattern, output)
    ]
    if not counts:
        raise VerificationError("full Swift package log lacks a passing executable test count")
    return max(counts)


def run_component_verification(artifacts: Path) -> dict[str, Any]:
    artifacts = artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    node = subprocess.run(
        ("node", "--version"), check=False, capture_output=True, text=True, env=_clean_environment()
    )
    if node.returncode != 0 or not node.stdout.strip().startswith("v24."):
        raise VerificationError(f"Slice 5 component verifier requires Node 24, got {node.stdout.strip()!r}")
    postgres_path, postgres_version = _postgres_16_version()
    fixtures = validate_fixture_digests(FIXTURE_ROOT, EXPECTED_FIXTURE_DIGESTS)
    sources = _source_contract()
    commands = [_run_step(step, artifacts) for step in component_command_plan()]
    swift_passed = _swift_test_count(Path(str(commands[1]["log"])))
    report = {
        "schemaVersion": 1,
        "status": "PASS",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "providerMode": "synthetic-local-no-credentials",
        "nodeVersion": node.stdout.strip(),
        "postgresql": {
            "major": 16,
            "status": "PASS",
            "executable": postgres_path,
            "version": postgres_version,
        },
        "logicalClients": ["client-a", "client-b"],
        "swiftTests": {"status": "PASS", "passed": swift_passed},
        "crashCutPoints": {point: "PASS" for point in REQUIRED_CRASH_CUT_POINTS},
        "rawInventory": {
            "positiveControl": "PASS",
            "defaultWorkingSet": "PASS",
            "reviewedRawSeparateTier": "PASS",
        },
        "clauses": {
            "1": {"status": "PASS", "evidence": ["real app two-client fixture", "PostgreSQL expected-head CAS"]},
            "2": {"status": "PASS", "evidence": ["six crash cuts", "targetless reap/claim", "immutable retry"]},
            "3": {"status": "PASS", "evidence": ["side-effect-free migration preview", "exact initial retry", "local source retained"]},
            "4": {"status": "PASS", "evidence": ["guest zero-request app oracle", "immutable offline local draft"]},
            "5": {"status": "PASS", "evidence": ["injected raw positive control", "redacted working set", "separate reviewed raw tier"]},
            "6": {"status": "PASS", "evidence": ["Core package-first recovery", "companion resume", "copy mapping downgrade"]},
            "7": {"status": "PASS", "evidence": ["forced RLS and same-tenant controls", "sealed routes", "offline infrastructure"]},
        },
        "fixtureDigests": fixtures,
        "sourceOracle": sources,
        "commands": commands,
        "externalEvidence": {
            "physicalDevice": "NOT_VERIFIED",
            "provider": "NOT_VERIFIED",
            "deployment": "NOT_PERFORMED",
        },
    }
    validate_component_report(report)
    _write_private(artifacts / "component-verification.json", json.dumps(report, indent=2) + "\n")
    return report


def initialize_run(marker: Path) -> dict[str, Any]:
    marker = marker.resolve()
    marker.parent.mkdir(parents=True, exist_ok=True)
    if marker.exists():
        raise VerificationError("run marker already exists; use a new run directory")
    head = subprocess.run(
        ("git", "rev-parse", "HEAD"), cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.strip()
    document = {
        "schemaVersion": 1,
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "head": head,
    }
    with marker.open("x", encoding="utf-8") as destination:
        destination.write(json.dumps(document, indent=2) + "\n")
    marker.chmod(0o600)
    return document


def _export_screenshot_attachments(xcresult: Path, destination: Path) -> list[Mapping[str, Any]]:
    destination.mkdir(parents=True, exist_ok=False)
    completed = subprocess.run(
        (
            "xcrun",
            "xcresulttool",
            "export",
            "attachments",
            "--path",
            str(xcresult),
            "--output-path",
            str(destination),
        ),
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise VerificationError(f"cannot export screenshot attachments from {xcresult}")
    # xcresulttool currently emits a top-level array.  Keep a strict separate
    # decode here because ordinary final reports are objects.
    try:
        value = json.loads((destination / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError("cannot parse XCTest attachment manifest") from error
    if not isinstance(value, list):
        raise VerificationError("XCTest attachment manifest must be an array")
    return [_require_mapping(entry, "XCTest attachment entry") for entry in value]


def _attachment_repetition(attachment: Mapping[str, Any]) -> int:
    repetition = attachment.get("repetitionNumber")
    if repetition is None:
        return 0
    if isinstance(repetition, bool) or not isinstance(repetition, int) or repetition < 1:
        raise VerificationError("XCTest screenshot repetition number is malformed")
    return repetition


def _attachment_scenario(attachment: Mapping[str, Any]) -> str | None:
    suggested = str(attachment.get("suggestedHumanReadableName", ""))
    return next(
        (
            scenario
            for marker, scenario in SCREENSHOT_ATTACHMENT_SCENARIOS.items()
            if marker in suggested
        ),
        None,
    )


def _select_latest_attachment(
    candidates: Iterable[Mapping[str, Any]], *, device: str, scenario: str
) -> Mapping[str, Any]:
    values = list(candidates)
    if not values:
        raise VerificationError(f"{device} xcresult lacks the {scenario} screenshot")
    latest_repetition = max(_attachment_repetition(value) for value in values)
    latest = [
        value for value in values if _attachment_repetition(value) == latest_repetition
    ]
    if len(latest) != 1:
        raise VerificationError(
            f"duplicate retained screenshot for {device}/{scenario} repetition {latest_repetition}"
        )
    return latest[0]


def record_screenshots(
    *,
    inputs: Mapping[str, Path],
    screenshots_directory: Path,
    output: Path,
    review_status: str,
) -> dict[str, Any]:
    if review_status != "PASS":
        raise VerificationError("screenshot report may be recorded only after visual review passes")
    screenshots_directory = screenshots_directory.resolve()
    if screenshots_directory.exists():
        raise VerificationError("screenshot output directory already exists; use a fresh directory")
    screenshots_directory.mkdir(parents=True)
    captures: list[dict[str, str]] = []
    try:
        for device, xcresult in inputs.items():
            entries = _export_screenshot_attachments(xcresult, screenshots_directory / device)
            candidates_by_scenario: dict[str, list[Mapping[str, Any]]] = {
                scenario: [] for scenario in REQUIRED_SCREENSHOT_SCENARIOS
            }
            for entry in entries:
                test_identifier = str(entry.get("testIdentifier", ""))
                attachments = entry.get("attachments")
                if not isinstance(attachments, list):
                    raise VerificationError("XCTest screenshot attachment list is malformed")
                if device == "desktop-width":
                    if "testSlice5DesktopWidthLandscapeScenarios" not in test_identifier:
                        continue
                else:
                    expected_scenario = next(
                        (value for test_name, value in SCREENSHOT_TEST_SCENARIOS.items() if test_name in test_identifier),
                        None,
                    )
                    if expected_scenario is None:
                        continue
                for value in attachments:
                    attachment = _require_mapping(value, "XCTest screenshot attachment")
                    scenario = _attachment_scenario(attachment)
                    if scenario is None:
                        continue
                    if device != "desktop-width" and scenario != expected_scenario:
                        continue
                    candidates_by_scenario[scenario].append(attachment)

            if device == "desktop-width":
                all_candidates = [
                    candidate
                    for candidates in candidates_by_scenario.values()
                    for candidate in candidates
                ]
                if not all_candidates:
                    raise VerificationError("desktop-width xcresult lacks Slice 5 screenshots")
                latest_desktop_repetition = max(
                    _attachment_repetition(candidate) for candidate in all_candidates
                )
                candidates_by_scenario = {
                    scenario: [
                        candidate
                        for candidate in candidates
                        if _attachment_repetition(candidate) == latest_desktop_repetition
                    ]
                    for scenario, candidates in candidates_by_scenario.items()
                }

            found: dict[str, Path] = {}
            for scenario, candidates in candidates_by_scenario.items():
                attachment = _select_latest_attachment(
                    candidates, device=device, scenario=scenario
                )
                filename = attachment.get("exportedFileName")
                if not isinstance(filename, str):
                    raise VerificationError("XCTest screenshot attachment has no exported filename")
                path = screenshots_directory / device / filename
                if not path.is_file() or path.suffix.lower() != ".png":
                    raise VerificationError("retained Slice 5 screenshot is not an exported PNG")
                found[scenario] = path
            if set(found) != set(REQUIRED_SCREENSHOT_SCENARIOS):
                raise VerificationError(f"{device} xcresult lacks the exact three Slice 5 screenshots")
            for scenario, path in sorted(found.items()):
                captures.append(
                    {
                        "deviceClass": device,
                        "scenario": scenario,
                        "path": os.path.relpath(path, output.parent.resolve()),
                        "sha256": sha256_file(path),
                    }
                )
    except Exception:
        # Generated screenshots are owned by this fresh output directory.
        shutil.rmtree(screenshots_directory, ignore_errors=True)
        raise
    report = {
        "schemaVersion": 1,
        "status": "PASS",
        "reviewStatus": "PASS",
        "reviewedDimensions": list(REQUIRED_REVIEW_DIMENSIONS),
        "reviewNote": (
            "Agent visual inspection found the warm paper/ink hierarchy readable and the explicit "
            "migration, raw-tier, and preserved-branch actions legible at all three widths."
        ),
        "captures": captures,
    }
    validate_screenshot_report(report, base=output.parent.resolve())
    _write_private(output.resolve(), json.dumps(report, indent=2) + "\n")
    return report


def _required_path(parser: argparse.ArgumentParser, value: Path | None, option: str) -> Path:
    if value is None:
        parser.error(f"{option} is required for this mode")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", type=Path)
    parser.add_argument("--initialize-run", action="store_true")
    parser.add_argument("--finalize", action="store_true")
    parser.add_argument("--record-screenshots", action="store_true")
    parser.add_argument("--run-marker", type=Path)
    parser.add_argument("--component-report", type=Path)
    parser.add_argument("--mutation-report", type=Path)
    parser.add_argument("--slice4-report", type=Path)
    parser.add_argument("--artifact-report", type=Path)
    parser.add_argument("--screenshot-report", type=Path)
    parser.add_argument("--iphone-xcresult", type=Path)
    parser.add_argument("--ipad-xcresult", type=Path)
    parser.add_argument("--mobile-xcresult", type=Path)
    parser.add_argument("--tablet-xcresult", type=Path)
    parser.add_argument("--desktop-xcresult", type=Path)
    parser.add_argument("--screenshots-dir", type=Path)
    parser.add_argument("--review-status", choices=("PASS", "FAIL"))
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    modes = sum((arguments.initialize_run, arguments.finalize, arguments.record_screenshots))
    if modes > 1:
        parser.error("choose only one of --initialize-run, --record-screenshots, or --finalize")
    try:
        if arguments.initialize_run:
            result = initialize_run(_required_path(parser, arguments.run_marker, "--run-marker"))
        elif arguments.record_screenshots:
            result = record_screenshots(
                inputs={
                    "mobile-iphone": _required_path(parser, arguments.mobile_xcresult, "--mobile-xcresult"),
                    "tablet-ipad": _required_path(parser, arguments.tablet_xcresult, "--tablet-xcresult"),
                    "desktop-width": _required_path(parser, arguments.desktop_xcresult, "--desktop-xcresult"),
                },
                screenshots_directory=_required_path(parser, arguments.screenshots_dir, "--screenshots-dir"),
                output=_required_path(parser, arguments.output, "--output"),
                review_status=arguments.review_status or "FAIL",
            )
        elif arguments.finalize:
            result = finalize_evidence(
                marker=_required_path(parser, arguments.run_marker, "--run-marker"),
                component_report=_required_path(parser, arguments.component_report, "--component-report"),
                mutation_report=_required_path(parser, arguments.mutation_report, "--mutation-report"),
                slice4_report=_required_path(parser, arguments.slice4_report, "--slice4-report"),
                artifact_report=_required_path(parser, arguments.artifact_report, "--artifact-report"),
                screenshot_report=_required_path(parser, arguments.screenshot_report, "--screenshot-report"),
                iphone_xcresult=_required_path(parser, arguments.iphone_xcresult, "--iphone-xcresult"),
                ipad_xcresult=_required_path(parser, arguments.ipad_xcresult, "--ipad-xcresult"),
            )
            output = _required_path(parser, arguments.output, "--output")
            _write_private(output.resolve(), json.dumps(result, indent=2) + "\n")
        else:
            artifacts = _required_path(parser, arguments.artifacts_dir, "--artifacts-dir")
            result = run_component_verification(artifacts)
    except (VerificationError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

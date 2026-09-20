#!/usr/bin/env python3
"""Validate Slice 6 database and infrastructure mutation ledgers."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any


class MutationVerificationError(RuntimeError):
    """A mutation ledger is incomplete, escaped, or inconsistent."""


EXPECTED_DATABASE_GUARDS = frozenset(
    {
        "source-binding",
        "approval-binding",
        "revoked-session-generation",
        "portal-snapshot-live-capabilities",
        "professional-finalization-session-revoke",
        "professional-exact-range",
        "professional-exact-version",
        "professional-portal-quota",
        "targetless-api-completion",
        "worker-live-quarantine-bind",
        "link-expiry-intent-replay",
        "link-replay-preserves-expiry",
        "feedback-v3-policy-owner",
        "feedback-v3-portal-acl",
        "feedback-runtime-guard-acl",
        "feedback-v3-live-validation",
        "feedback-v3-throttle",
        "publication-kill-grant",
        "property-cas",
        "property-create-concurrency",
        "editor-policy-scope",
        "root-project-identity",
        "source-public-identity",
        "approval-public-identity",
        "pin-snapshot-identity",
        "rotation-session-revoke",
        "concurrent-finalize-recheck",
        "finalize-flag-lock-barrier",
        "finalize-source-lock-barrier",
        "pin-throttle",
        "forced-rls",
        "feedback-isolation",
    }
)
EXPECTED_INFRASTRUCTURE_GUARDS = frozenset(
    {
        "S3 Block Public Access removed",
        "S3 TLS-only deny removed",
        "us-east-1 region invariant neutralized",
        "Stripe raw-envelope marker removed",
        "Lambda IAM wildcard resource introduced",
        "Lambda role receives an unconditional SecretsKey decrypt grant",
        "forced log retention removed",
        "Lambda log group changed from LogsKey to SecretsKey",
        "CloudWatch Logs service KMS statement removed",
        "CloudWatch Logs GenerateDataKeyWithoutPlaintext permission removed",
        "CloudWatch alarm topic publication removed",
        "CloudTrail status heartbeat alarm removed",
        "unsupported AWS CloudTrail DeliveryErrors metric introduced",
        "Cognito federation domain removed",
        "Cognito native local-user provider added to managed login",
        "audit version lifetime extended beyond 400 days",
        "S3 CMK override denies removed",
        "project-sync bucket public access block removed",
        "project-sync object deletion retention deny removed",
        "project-sync validation queue encryption removed",
        "project-sync validation queue falls back to the legacy CMK",
        "project-sync EventBridge producer source binding removed",
        "project-sync EventBridge producer source account is another workload",
        "project-sync EventBridge producer broadens its exact rule ARN",
        "project-sync EventBridge producer gains queue discovery",
        "project-sync EventBridge KMS grant gains an unnecessary encrypt action",
        "project-sync EventBridge KMS grant trusts another workload account",
        "project-sync validation queue redrive count weakened",
        "project-sync validation batch delivery broadened",
        "project-sync CloudTrail quarantine data events removed",
        "API project-sync list authority introduced",
        "API project-sync recovery broadens from exact-version read",
        "published-derivative immutable object deletion deny removed",
        "private API gains published active-object read authority",
        "portal delivery gains published write authority",
        "publication validation worker gains bucket discovery",
        "publication validation queue redrive count weakened",
    }
)
ROOT = Path(__file__).resolve().parents[1]
NODE24_BIN = "/Users/philipnora/.nvm/versions/node/v24.15.0/bin"


def _line_names(output: str, prefix: str) -> list[str]:
    names: list[str] = []
    for line in output.splitlines():
        if line.startswith(prefix):
            name = line[len(prefix) :].split(":", maxsplit=1)[0].strip()
            if not name:
                raise MutationVerificationError(f"empty mutation label after {prefix!r}")
            names.append(name)
    return names


def validate_mutation_pairs(
    output: str,
    *,
    red_prefix: str,
    green_prefix: str,
    expected: set[str] | None = None,
) -> dict[str, Any]:
    """Require one detected red and one restored green result per guard."""

    if any(line.startswith("MUTATION_ESCAPED ") for line in output.splitlines()):
        raise MutationVerificationError("a neutralized live guard escaped its focused oracle")
    red = _line_names(output, red_prefix)
    green = _line_names(output, green_prefix)
    if not red or len(red) != len(set(red)) or len(green) != len(set(green)):
        raise MutationVerificationError("mutation output contains missing or duplicate guard labels")
    if set(red) != set(green):
        raise MutationVerificationError("every detected mutant needs one restored green oracle")
    if expected is not None and set(red) != expected:
        raise MutationVerificationError("mutation inventory drifted from its exact expected guards")
    return {
        "status": "PASS",
        "detected": len(red),
        "restored": len(green),
        "guards": sorted(red),
    }


def _summary_fields(output: str, prefix: str) -> dict[str, str]:
    lines = [line for line in output.splitlines() if line.startswith(prefix)]
    if len(lines) != 1:
        raise MutationVerificationError(f"expected exactly one {prefix.strip()} summary")
    fields: dict[str, str] = {}
    for token in lines[0][len(prefix) :].split():
        key, separator, value = token.partition("=")
        if not key or separator != "=" or not value or key in fields:
            raise MutationVerificationError("mutation summary has an invalid or duplicate field")
        fields[key] = value
    return fields


def _postgres_16_process_record(output: str) -> dict[str, Any]:
    records: list[Any] = []
    for line in output.splitlines():
        if line.startswith("DIRTY_ROLE_PROCESS_CLEANUP "):
            try:
                parsed = json.loads(line.removeprefix("DIRTY_ROLE_PROCESS_CLEANUP "))
            except json.JSONDecodeError as error:
                raise MutationVerificationError("PostgreSQL process record is not valid JSON") from error
            if not isinstance(parsed, list):
                raise MutationVerificationError("PostgreSQL process record is not an array")
            records.extend(parsed)
    if not records:
        raise MutationVerificationError("database evidence lacks the PostgreSQL process identity record")
    images: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            raise MutationVerificationError("PostgreSQL process record contains a non-object entry")
        exit_status = record.get("exit")
        processes = record.get("resolvedProcesses")
        if (
            not isinstance(exit_status, dict)
            or exit_status.get("code") != 0
            or record.get("survivingPids") != []
            or not isinstance(processes, list)
            or not processes
        ):
            raise MutationVerificationError("PostgreSQL process cleanup was not clean")
        for process in processes:
            image = process.get("image") if isinstance(process, dict) else None
            if not isinstance(image, str):
                raise MutationVerificationError("PostgreSQL process record lacks a resolved image")
            major_match = re.search(r"postgresql@(\d+)(?:/|$)", image)
            if major_match is None or major_match.group(1) != "16" or not image.endswith("/postgres"):
                raise MutationVerificationError(
                    "PostgreSQL process record did not resolve every process to PostgreSQL 16"
                )
            images.add(image)
    return {"major": 16, "status": "PASS", "recordCount": len(records), "images": sorted(images)}


def _positive_summary_fields(output: str, prefix: str, required: set[str]) -> dict[str, str]:
    fields = _summary_fields(output, prefix)
    if fields.get("status") != "pass":
        raise MutationVerificationError(f"{prefix.strip()} did not pass")
    for key in required:
        value = fields.get(key)
        if value is None or not value.isdecimal() or int(value) < 1:
            raise MutationVerificationError(f"{prefix.strip()} lacks a positive {key} control")
    return fields


def _node_summary_count(output: str, label: str) -> int:
    matches = re.findall(
        rf"^\s*(?:ℹ\s+|#\s*)?{re.escape(label)}\s+(\d+)\s*$",
        output,
        re.MULTILINE,
    )
    if not matches:
        raise MutationVerificationError(f"infrastructure output lacks a {label} count")
    return int(matches[-1])


def validate_database_output(output: str) -> dict[str, Any]:
    """Validate raw full-database output, including the 0009 mutation ledger."""

    if re.search(r"^> @roomscan/hosted-db@[^\n]* test$", output, re.MULTILINE) is None:
        raise MutationVerificationError("database evidence is not the full hosted-db test command")
    database = validate_mutation_pairs(
        output,
        red_prefix="MUTATION_0009_RED ",
        green_prefix="MUTATION_0009_RESTORE_GREEN ",
        expected=set(EXPECTED_DATABASE_GUARDS),
    )
    summary = _summary_fields(output, "MUTATIONS_0009_PUBLICATION_SUMMARY ")
    required_detected = {guard.replace("-", "_") for guard in EXPECTED_DATABASE_GUARDS}
    if (
        {key for key, value in summary.items() if value == "detected"} != required_detected
        or summary.get("restored_controls") != "32"
        or summary.get("status") != "pass"
        or len(summary) != len(required_detected) + 2
    ):
        raise MutationVerificationError("database 0009 mutation summary does not match its exact ledger")
    database["postgresql"] = _postgres_16_process_record(output)
    database["publicationIntegration"] = _positive_summary_fields(
        output,
        "INTEGRATION_0009_PUBLICATION_SUMMARY ",
        {"schema", "roles", "source_lock_controls"},
    )
    database["portalSecurityIntegration"] = _positive_summary_fields(
        output,
        "INTEGRATION_0009_PORTAL_SECURITY_SUMMARY ",
        {"forced_rls"},
    )
    return database


def validate_infrastructure_output(output: str) -> dict[str, Any]:
    """Validate raw infrastructure mutation output and its exact 37-guard summary."""

    infrastructure = validate_mutation_pairs(
        output,
        red_prefix="MUTATION_RED ",
        green_prefix="RESTORE_GREEN ",
        expected=set(EXPECTED_INFRASTRUCTURE_GUARDS),
    )
    summary = _summary_fields(output, "MUTATION_SUMMARY ")
    expected_summary = {
        "detected": "37",
        "restored": "37",
        "total": "37",
    }
    if summary != expected_summary:
        raise MutationVerificationError("infrastructure mutation summary does not match its exact ledger")
    tests = _node_summary_count(output, "tests")
    passed = _node_summary_count(output, "pass")
    failed = _node_summary_count(output, "fail")
    skipped = _node_summary_count(output, "skipped")
    required_tests = (
        "Slice 6 synthesizes the exact additive runtime, credential, and queue topology",
        "Slice 6 publication IAM is prefix-exact, non-destructive, and keeps API/portal/worker capabilities disjoint",
        "Slice 6 remains one private origin with no CDN, public asset bucket, or browser identity pool",
        '"migration0009AssetAndRuntimeRoles": "PASS"',
    )
    missing = [name for name in required_tests if name not in output]
    if missing or tests <= 110 or passed != tests or failed != 0 or skipped != 0:
        raise MutationVerificationError(
            "infrastructure full verification regressed: "
            f"tests={tests} pass={passed} fail={failed} skipped={skipped} missing={missing}"
        )
    infrastructure["tests"] = {"tests": tests, "passed": passed, "failed": failed, "skipped": skipped}
    return infrastructure


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_private(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o600)


def _clean_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not (key.startswith("AWS_") or key.startswith("CDK_") or key.startswith("ROOMSCAN_"))
    }
    environment["PATH"] = f"{NODE24_BIN}{os.pathsep}{environment.get('PATH', '')}"
    return environment


def _run_to_log(label: str, command: tuple[str, ...], artifacts: Path) -> Path:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=_clean_environment(),
        check=False,
        capture_output=True,
        text=True,
    )
    output = completed.stdout + completed.stderr
    path = artifacts / f"{label}.log"
    _write_private(path, output)
    if completed.returncode != 0:
        raise MutationVerificationError(f"{label} failed; inspect {path}")
    return path


def _evidence_record(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise MutationVerificationError(f"raw mutation log is missing: {path}")
    return {"path": str(path.resolve()), "sha256": sha256_file(path)}


def run_verification(
    artifacts: Path,
    *,
    database_log: Path | None = None,
    infrastructure_log: Path | None = None,
) -> dict[str, Any]:
    """Run Slice 6 mutation suites or aggregate their supplied raw output."""

    if (database_log is None) != (infrastructure_log is None):
        raise MutationVerificationError(
            "aggregation requires both --database-log and --infrastructure-log"
        )
    artifacts = artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    if database_log is None:
        database_log = _run_to_log(
            "database-full-suite",
            ("npm", "--prefix", "HostedService/db", "test"),
            artifacts,
        )
        infrastructure_log = _run_to_log(
            "infrastructure-full-verification",
            ("npm", "--prefix", "HostedService/infra", "run", "verify"),
            artifacts,
        )
    assert infrastructure_log is not None
    database_output = database_log.read_text(encoding="utf-8")
    infrastructure_output = infrastructure_log.read_text(encoding="utf-8")
    report = {
        "schemaVersion": 1,
        "status": "PASS",
        "database": validate_database_output(database_output),
        "infrastructure": validate_infrastructure_output(infrastructure_output),
        "evidence": {
            "database": _evidence_record(database_log),
            "infrastructure": _evidence_record(infrastructure_log),
        },
    }
    _write_private(artifacts / "mutation-verification.json", json.dumps(report, indent=2) + "\n")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", required=True, type=Path)
    parser.add_argument("--database-log", type=Path)
    parser.add_argument("--infrastructure-log", type=Path)
    arguments = parser.parse_args()
    try:
        report = run_verification(
            arguments.artifacts_dir,
            database_log=arguments.database_log,
            infrastructure_log=arguments.infrastructure_log,
        )
    except (MutationVerificationError, OSError, subprocess.SubprocessError) as error:
        failure = {"schemaVersion": 1, "status": "FAIL", "failure": str(error)[:512]}
        _write_private(
            arguments.artifacts_dir.resolve() / "mutation-verification.json",
            json.dumps(failure, indent=2) + "\n",
        )
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

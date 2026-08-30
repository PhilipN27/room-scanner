#!/usr/bin/env python3
"""Run and record Slice 5 guard-neutralization and detector controls."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Iterable, Mapping


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_DATABASE_MUTATIONS = {
    "expected-head-cas",
    "targetless-claim",
    "forced-rls",
    "raw-target-uniqueness",
    "claim-source-binding",
    "opaque-version-schema",
    "opaque-version-finalizer-input",
    "unified-64-mib-archive-ceiling",
    "raw-upload-target-revision-status",
}
RAW_POSITIVE_TEST = (
    "working-set validator detects an injected forbidden raw artifact while reviewed raw "
    "accepts its separate fixture"
)
RAW_SAFE_TEST = "working-set validator accepts the real Core-generated raw-redacted fixture"


class MutationVerificationError(RuntimeError):
    """A mutant escaped, a restored source failed, or a detector was not reached."""


def _line_names(output: str, prefix: str) -> list[str]:
    names: list[str] = []
    for line in output.splitlines():
        if not line.startswith(prefix):
            continue
        name = line[len(prefix) :].split(":", maxsplit=1)[0].strip()
        if not name:
            raise MutationVerificationError(f"empty mutation label after {prefix!r}")
        names.append(name)
    return names


def parse_mutation_pairs(
    output: str,
    *,
    red_prefix: str,
    green_prefix: str,
    expected: set[str] | None = None,
) -> dict[str, Any]:
    red = _line_names(output, red_prefix)
    green = _line_names(output, green_prefix)
    if len(red) != len(set(red)) or len(green) != len(set(green)):
        raise MutationVerificationError("mutation output contains duplicate guard labels")
    if not red or set(red) != set(green):
        raise MutationVerificationError("every detected mutant needs one restored green oracle")
    if expected is not None and set(red) != expected:
        missing = sorted(expected - set(red))
        unexpected = sorted(set(red) - expected)
        raise MutationVerificationError(
            f"mutation inventory drifted; missing={missing}, unexpected={unexpected}"
        )
    return {
        "status": "PASS",
        "detected": len(red),
        "restored": len(green),
        "guards": sorted(red),
    }


def validate_raw_detector_output(output: str) -> dict[str, Any]:
    if RAW_POSITIVE_TEST not in output or RAW_SAFE_TEST not in output:
        raise MutationVerificationError(
            "raw negative claim lacks its injected-artifact positive control or safe control"
        )
    failed = re.search(r"(?:# fail|fail)\s+([1-9][0-9]*)", output)
    if failed:
        raise MutationVerificationError("raw detector service test run contains failures")
    return {
        "status": "PASS",
        "positiveControl": RAW_POSITIVE_TEST,
        "safeControl": RAW_SAFE_TEST,
    }


def _clean_environment(inherited: Mapping[str, str] | None = None) -> dict[str, str]:
    source = dict(os.environ if inherited is None else inherited)
    return {
        key: value
        for key, value in source.items()
        if not (key.startswith("AWS_") or key.startswith("CDK_") or key.startswith("ROOMSCAN_"))
    }


def _write_private(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")
    path.chmod(0o600)


def _run(label: str, command: Iterable[str], cwd: Path, artifacts: Path) -> str:
    completed = subprocess.run(
        tuple(command),
        cwd=cwd,
        env=_clean_environment(),
        check=False,
        capture_output=True,
        text=True,
    )
    output = completed.stdout + completed.stderr
    log_path = artifacts / f"{label}.log"
    _write_private(log_path, output)
    if completed.returncode != 0:
        raise MutationVerificationError(f"{label} failed; inspect {log_path}")
    return output


def run_verification(artifacts: Path) -> dict[str, Any]:
    artifacts = artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    node_version = _run("00-node-version", ("node", "--version"), ROOT, artifacts).strip()
    if not node_version.startswith("v24."):
        raise MutationVerificationError(f"Slice 5 mutation controls require Node 24, got {node_version!r}")
    service_output = _run(
        "01-service-tests",
        ("npm", "--prefix", "HostedService", "test"),
        ROOT,
        artifacts,
    )
    raw = validate_raw_detector_output(service_output)
    database_output = _run(
        "02-database-0008-mutations",
        ("npm", "--prefix", "HostedService/db", "run", "test:mutations-0008-project-sync"),
        ROOT,
        artifacts,
    )
    database = parse_mutation_pairs(
        database_output,
        red_prefix="MUTATION_0008_RED ",
        green_prefix="MUTATION_0008_RESTORE_GREEN ",
        expected=EXPECTED_DATABASE_MUTATIONS,
    )
    infrastructure_output = _run(
        "03-infrastructure-mutations",
        ("npm", "--prefix", "HostedService/infra", "run", "test:mutations"),
        ROOT,
        artifacts,
    )
    infrastructure = parse_mutation_pairs(
        infrastructure_output,
        red_prefix="MUTATION_RED ",
        green_prefix="RESTORE_GREEN ",
    )
    summary = re.search(
        r"MUTATION_SUMMARY detected=(\d+) restored=(\d+) total=(\d+)",
        infrastructure_output,
    )
    if summary is None or len(set(summary.groups())) != 1 or int(summary.group(1)) != infrastructure["detected"]:
        raise MutationVerificationError("infrastructure mutation summary does not match red/green pairs")
    report = {
        "schemaVersion": 1,
        "status": "PASS",
        "nodeVersion": node_version,
        "database": database,
        "infrastructure": infrastructure,
        "rawArtifactDetector": raw,
        "logs": [
            {
                "path": str(path),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            for path in sorted(artifacts.glob("*.log"))
        ],
    }
    _write_private(artifacts / "mutation-verification.json", json.dumps(report, indent=2) + "\n")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        report = run_verification(arguments.artifacts_dir)
    except (MutationVerificationError, OSError) as error:
        failure = {
            "schemaVersion": 1,
            "status": "FAIL",
            "failure": str(error)[:512],
        }
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

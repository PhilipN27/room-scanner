"""Self-tests for the local Slice 4 hosted/static verification entrypoint."""

from __future__ import annotations

import hashlib
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from Scripts import verify_slice4_hosted


ROOT = Path(__file__).resolve().parents[1]


class OfflineEnvironmentTests(unittest.TestCase):
    def test_offline_environment_replaces_roomscan_and_aws_values(self) -> None:
        inherited = {
            "PATH": "/usr/bin",
            "ROOMSCAN_ACCOUNT_ID": "999999999999",
            "ROOMSCAN_UNDECLARED_SECRET": "must-not-survive",
            "AWS_ACCESS_KEY_ID": "AKIAEXAMPLEEXAMPLE",
            "AWS_SECRET_ACCESS_KEY": "must-not-survive",
            "CDK_DEFAULT_ACCOUNT": "999999999999",
        }

        environment = verify_slice4_hosted.offline_environment(ROOT, inherited)

        self.assertEqual(environment["ROOMSCAN_ACCOUNT_ID"], "444444444444")
        self.assertEqual(environment["ROOMSCAN_REGION"], "us-east-1")
        self.assertEqual(environment["CDK_DEFAULT_ACCOUNT"], "444444444444")
        self.assertEqual(environment["AWS_EC2_METADATA_DISABLED"], "true")
        self.assertEqual(
            environment["ROOMSCAN_STRIPE_DEFAULT_ACCOUNT_ID"],
            "acct_0000000000000000",
        )
        self.assertEqual(environment["ROOMSCAN_STRIPE_API_VERSION"], "2025-06-30.basil")
        self.assertEqual(
            environment["ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON"],
            '[{"priceId":"price_test0001","planKey":"professional-test-only"}]',
        )
        self.assertEqual(
            environment["ROOMSCAN_MAGIC_DELIVERY_KEY_ID"],
            "magic-envelope-local-test-v1",
        )
        self.assertEqual(environment["ROOMSCAN_POLICY_VALUES_STATUS"], "local-test-values-v1")
        self.assertEqual(
            environment["ROOMSCAN_SES_SENDER_ADDRESS"],
            "professional@example.invalid",
        )
        self.assertNotIn("ROOMSCAN_UNDECLARED_SECRET", environment)
        self.assertNotIn("AWS_ACCESS_KEY_ID", environment)
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", environment)
        self.assertTrue(environment["PATH"].startswith(verify_slice4_hosted.NODE24_BIN + os.pathsep))


class PostgreSQLPortabilityTests(unittest.TestCase):
    def test_portability_probe_does_not_require_a_developer_specific_node_path(self) -> None:
        source = Path(__file__).read_text(encoding="utf-8")

        self.assertNotIn("/Users/" + "philipnora/.nvm", source)

    def test_database_harness_uses_portable_temp_and_linux_process_image_contracts(self) -> None:
        database_tests = ROOT / "HostedService" / "db" / "test"
        sources = {
            path: path.read_text(encoding="utf-8")
            for path in database_tests.glob("*.mjs")
        }

        hardcoded_private_tmp = [
            str(path.relative_to(ROOT))
            for path, source in sources.items()
            if "/private/tmp" in source
        ]
        self.assertEqual(hardcoded_private_tmp, [])

        cluster_source = sources[database_tests / "pg-cluster.mjs"]
        self.assertIn("tmpdir()", cluster_source)
        self.assertIn("/proc", cluster_source)
        self.assertIn("/usr/lib/postgresql/16/bin", cluster_source)
        self.assertNotIn("export const PG_BIN", cluster_source)

    def test_linux_process_image_probe_resolves_an_exact_proc_executable(self) -> None:
        script = """
          import assert from 'node:assert/strict';
          import { mkdtempSync, mkdirSync, rmSync, symlinkSync } from 'node:fs';
          import { tmpdir } from 'node:os';
          import path from 'node:path';
          import { resolveProcessImage } from './HostedService/db/test/pg-cluster.mjs';
          const root = mkdtempSync(path.join(tmpdir(), 'rss-proc-probe-'));
          try {
            const pid = 123;
            const processRoot = path.join(root, String(pid));
            mkdirSync(processRoot);
            symlinkSync(process.execPath, path.join(processRoot, 'exe'));
            assert.equal(
              await resolveProcessImage(pid, { platform: 'linux', procRoot: root }),
              process.execPath,
            );
          } finally {
            rmSync(root, { recursive: true, force: true });
          }
        """
        node = shutil.which("node")
        self.assertIsNotNone(node)
        completed = subprocess.run(
            [
                node,
                "--input-type=module",
                "--eval",
                script,
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)


class CommandPlanTests(unittest.TestCase):
    def test_command_plan_uses_the_real_role_isolation_and_artifact_oracles(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            evidence_directory = Path(temporary_directory)
            plan = verify_slice4_hosted.command_plan(ROOT, evidence_directory, install=False)

        labels = [step.label for step in plan]
        self.assertEqual(
            labels,
            [
                "Task 7 orchestration self-tests",
                "hosted service typecheck",
                "hosted service security tests",
                "hosted service build",
                "PostgreSQL 16 role and RLS integration",
                "infrastructure typecheck",
                "infrastructure assertions",
                "infrastructure mutation controls",
                "offline infrastructure synth and bundle inspection",
                "guest and secret scanner positive controls",
            ],
        )
        database_step = next(step for step in plan if step.label.startswith("PostgreSQL"))
        self.assertEqual(database_step.cwd, ROOT / "HostedService" / "db")
        self.assertEqual(database_step.command, ("npm", "test"))
        synth_step = next(step for step in plan if step.label.startswith("offline infrastructure"))
        self.assertEqual(synth_step.cwd, ROOT / "HostedService" / "infra")
        self.assertEqual(synth_step.command, ("npm", "run", "verify"))
        controls_step = plan[-1]
        self.assertEqual(
            controls_step.command,
            ("python3", "-B", "Scripts/verify_slice4_static_controls.py"),
        )
        self.assertNotIn(
            ("python3", "-B", "Scripts/verify_xcode_scaffold.py"),
            [step.command for step in plan],
        )


class StaticSecretCanaryTests(unittest.TestCase):
    def test_secret_scanner_finds_a_nested_credential_canary_but_not_a_digest(self) -> None:
        unsafe = {
            "request": {"authorization": "Bearer roomscan-secret-canary-value"},
            "nested": ["whsec_roomscan-secret-canary-value"],
        }
        safe = {"event": "session.revoked", "tokenDigest": "a" * 64}

        unsafe_hits = verify_slice4_hosted.find_secret_canary_hits(unsafe)
        safe_hits = verify_slice4_hosted.find_secret_canary_hits(safe)

        self.assertEqual(len(unsafe_hits), 2)
        self.assertEqual(safe_hits, [])

    def test_secret_scanner_positive_control_is_required_by_the_entrypoint(self) -> None:
        self.assertTrue(verify_slice4_hosted.run_secret_scanner_positive_control())

    def test_built_artifact_detector_positive_control_fails_if_patterns_are_empty(self) -> None:
        with mock.patch.object(verify_slice4_hosted, "ARTIFACT_SECRET_PATTERNS", ()):
            with self.assertRaises(verify_slice4_hosted.VerificationFailure):
                verify_slice4_hosted.run_artifact_secret_scanner_positive_control()


class VerificationOrchestrationTests(unittest.TestCase):
    def test_exact_generated_outputs_are_cleaned_without_touching_siblings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            generated = [
                root / "HostedService" / "dist",
                root / "HostedService" / ".test-dist",
                root / "HostedService" / "infra" / "dist",
                root / "HostedService" / "infra" / ".test-dist",
                root / "HostedService" / "infra" / "cdk.out",
            ]
            for directory in generated:
                directory.mkdir(parents=True)
                (directory / "stale-sentinel.txt").write_text("stale\n", encoding="utf-8")
            sibling = root / "HostedService" / "infra" / "operator-owned"
            sibling.mkdir()
            (sibling / "keep.txt").write_text("keep\n", encoding="utf-8")

            cleaned = verify_slice4_hosted.clean_generated_outputs(root)

            self.assertEqual(set(cleaned), {str(path) for path in generated})
            self.assertTrue(all(not path.exists() for path in generated))
            self.assertEqual((sibling / "keep.txt").read_text(encoding="utf-8"), "keep\n")

    def test_missing_command_records_terminal_bounded_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            evidence = root / ".artifacts" / "evidence"
            missing = "roomscan-command-that-does-not-exist"
            with mock.patch.object(
                verify_slice4_hosted,
                "command_plan",
                return_value=[verify_slice4_hosted.CommandStep("missing executable", root, (missing,))],
            ):
                return_code = verify_slice4_hosted.run_verification(root, evidence, install=False)
            result = json.loads((evidence / "verification.json").read_text(encoding="utf-8"))

        self.assertEqual(return_code, 1)
        self.assertEqual(result["status"], "FAIL")
        self.assertLessEqual(len(result["failure"]), 256)
        self.assertNotIn(missing, result["failure"])

    def test_missing_node_probe_still_writes_terminal_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            evidence = root / ".artifacts" / "evidence"
            with mock.patch.object(
                verify_slice4_hosted,
                "offline_environment",
                return_value={"PATH": str(root)},
            ):
                return_code = verify_slice4_hosted.run_verification(root, evidence, install=False)
            result = json.loads((evidence / "verification.json").read_text(encoding="utf-8"))

        self.assertEqual(return_code, 1)
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("Node 24.15.0", result["failure"])

    def test_child_output_canaries_never_enter_success_or_failure_evidence(self) -> None:
        token = "Bearer task7-raw-access-token-canary-1234567890"
        request_body = '{"email":"victim@example.com","magicToken":"raw-secret"}'
        command = (
            sys.executable,
            "-c",
            "import os,sys; print(os.environ['TASK7_TOKEN']); "
            "print(os.environ['TASK7_BODY']); sys.exit(int(os.environ['TASK7_EXIT']))",
        )
        expected_output = f"{token}\n{request_body}\n".encode("utf-8")

        for exit_code in (0, 7):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                evidence = root / ".artifacts" / f"run-{exit_code}"
                environment = {
                    "PATH": os.environ.get("PATH", ""),
                    "TASK7_TOKEN": token,
                    "TASK7_BODY": request_body,
                    "TASK7_EXIT": str(exit_code),
                }
                with (
                    mock.patch.object(verify_slice4_hosted, "offline_environment", return_value=environment),
                    mock.patch.object(verify_slice4_hosted, "_require_node24", return_value="v24.15.0"),
                    mock.patch.object(
                        verify_slice4_hosted,
                        "command_plan",
                        return_value=[
                            verify_slice4_hosted.CommandStep("controlled child", root, command)
                        ],
                    ),
                    mock.patch.object(
                        verify_slice4_hosted,
                        "write_generated_evidence",
                        return_value={"status": "fixture"},
                    ),
                ):
                    return_code = verify_slice4_hosted.run_verification(
                        root, evidence, install=False
                    )

                evidence_bytes = b"\n".join(
                    path.read_bytes() for path in sorted(evidence.rglob("*")) if path.is_file()
                )
                self.assertNotIn(token.encode("utf-8"), evidence_bytes)
                self.assertNotIn(request_body.encode("utf-8"), evidence_bytes)
                log = json.loads((evidence / "logs" / "controlled-child.log").read_text())
                self.assertEqual(log["outputBytes"], len(expected_output))
                self.assertEqual(log["outputSha256"], hashlib.sha256(expected_output).hexdigest())
                result = json.loads((evidence / "verification.json").read_text())
                self.assertEqual(result["status"], "PASS" if exit_code == 0 else "FAIL")
                self.assertEqual(return_code, 0 if exit_code == 0 else 1)


class ArtifactDirectoryPolicyTests(unittest.TestCase):
    def test_allows_only_repo_artifact_descendants_or_resolved_out_of_tree_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            outer = Path(temporary_directory)
            root = outer / "repository"
            root.mkdir()
            inside = root / ".artifacts" / "slice4-run"
            outside = outer / "ci-runner-temp" / "slice4-run"

            self.assertEqual(
                verify_slice4_hosted.validate_evidence_directory(root, inside),
                inside.resolve(),
            )
            self.assertEqual(
                verify_slice4_hosted.validate_evidence_directory(root, outside),
                outside.resolve(),
            )

    def test_rejects_repo_root_docs_other_in_tree_and_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            outer = Path(temporary_directory)
            root = outer / "repository"
            artifacts = root / ".artifacts"
            docs = root / "Docs"
            outside = outer / "outside"
            artifacts.mkdir(parents=True)
            docs.mkdir()
            outside.mkdir()
            (artifacts / "escape").symlink_to(outside, target_is_directory=True)

            rejected = (
                root,
                artifacts,
                docs / "evidence",
                root / "other" / "evidence",
                artifacts / "escape" / "evidence",
            )
            for candidate in rejected:
                with self.subTest(candidate=candidate):
                    with self.assertRaises(verify_slice4_hosted.VerificationFailure):
                        verify_slice4_hosted.validate_evidence_directory(root, candidate)


class ArtifactEvidenceTests(unittest.TestCase):
    def test_dependency_inventory_and_artifact_manifest_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            package = root / "HostedService"
            node_package = package / "node_modules" / "example-lib"
            node_package.mkdir(parents=True)
            (package / "package.json").write_text(
                '{"name":"example","dependencies":{"example-lib":"1.2.3"}}\n',
                encoding="utf-8",
            )
            (package / "package-lock.json").write_text(
                json.dumps(
                    {
                        "lockfileVersion": 3,
                        "packages": {
                            "": {"name": "example", "dependencies": {"example-lib": "1.2.3"}},
                            "node_modules/example-lib": {
                                "version": "1.2.3",
                                "integrity": "sha512-"
                                + base64.b64encode(b"x" * 64).decode("ascii"),
                            },
                        },
                    }
                ),
                encoding="utf-8",
            )
            (node_package / "package.json").write_text(
                '{"name":"example-lib","version":"1.2.3","license":"MIT"}\n',
                encoding="utf-8",
            )
            artifact = root / "artifact.mjs"
            artifact.write_text("export const answer = 42;\n", encoding="utf-8")

            inventory = verify_slice4_hosted.dependency_inventory([package])
            verify_slice4_hosted.validate_cyclonedx_1_6(inventory)
            manifest = verify_slice4_hosted.artifact_manifest([artifact])
            expected_lock_hash = verify_slice4_hosted.sha256_file(package / "package-lock.json")

        component = inventory["components"][0]
        self.assertEqual(component["name"], "example-lib")
        self.assertEqual(component["version"], "1.2.3")
        self.assertEqual(component["licenses"], [{"license": {"name": "MIT"}}])
        self.assertIn(
            {"name": "roomscan:directKinds", "value": "dependencies"},
            component["properties"],
        )
        self.assertNotIn("integrity", component)
        self.assertNotIn("roots", inventory)
        self.assertNotIn("lockfiles", inventory)
        lock_component = next(
            candidate for candidate in inventory["components"] if candidate["type"] == "file"
        )
        self.assertEqual(
            lock_component["hashes"],
            [{"alg": "SHA-256", "content": expected_lock_hash}],
        )
        self.assertEqual(manifest["artifacts"][0]["path"], "artifact.mjs")
        self.assertEqual(manifest["artifacts"][0]["sha256"], hashlib.sha256(b"export const answer = 42;\n").hexdigest())

    def test_cyclonedx_validator_rejects_previous_nonstandard_shapes(self) -> None:
        valid = {
            "$schema": "https://cyclonedx.org/schema/bom-1.6.schema.json",
            "bomFormat": "CycloneDX",
            "specVersion": "1.6",
            "version": 1,
            "metadata": {"component": {"type": "application", "name": "example"}},
            "components": [
                {
                    "type": "library",
                    "bom-ref": "roomscan:example:1",
                    "name": "example",
                    "version": "1.0.0",
                    "hashes": [{"alg": "SHA-512", "content": "ab" * 64}],
                    "licenses": [{"license": {"name": "MIT"}}],
                    "properties": [{"name": "roomscan:sourcePackage", "value": "example"}],
                }
            ],
        }
        verify_slice4_hosted.validate_cyclonedx_1_6(valid)
        invalid_documents = [
            {**valid, "roots": []},
            {**valid, "components": [{**valid["components"][0], "integrity": "sha512-bad"}]},
            {**valid, "components": [{**valid["components"][0], "licenses": ["MIT"]}]},
            {**valid, "components": [{**valid["components"][0], "properties": {"x": "y"}}]},
        ]
        for document in invalid_documents:
            with self.subTest(document=document):
                with self.assertRaises(verify_slice4_hosted.VerificationFailure):
                    verify_slice4_hosted.validate_cyclonedx_1_6(document)

    def test_artifact_secret_scan_rejects_real_credential_shapes_without_rejecting_digests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            unsafe = root / "unsafe.mjs"
            safe = root / "safe.mjs"
            unsafe.write_text('const webhook = "whsec_1234567890abcdef";\n', encoding="utf-8")
            safe.write_text('const digest = "' + ("a" * 64) + '";\n', encoding="utf-8")

            unsafe_hits = verify_slice4_hosted.find_artifact_secret_hits([unsafe])
            safe_hits = verify_slice4_hosted.find_artifact_secret_hits([safe])

        self.assertEqual(unsafe_hits[0]["kind"], "Stripe webhook secret")
        self.assertEqual(safe_hits, [])


if __name__ == "__main__":
    unittest.main()

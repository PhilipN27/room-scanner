"""Self-tests for Slice 6 mutation-control evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from Scripts import verify_slice6_mutation_controls


class MutationLedgerTests(unittest.TestCase):
    DATABASE_GUARDS = (
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
    )
    INFRASTRUCTURE_GUARDS = (
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
    )

    def database_output(self, *, postgres_major: int = 16) -> str:
        lines = [
            "> @roomscan/hosted-db@0.0.0-private test",
            "DIRTY_ROLE_PROCESS_CLEANUP "
            + json.dumps(
                [
                    {
                        "resolvedProcesses": [
                            {
                                "image": (
                                    "/opt/homebrew/Cellar/"
                                    f"postgresql@{postgres_major}/{postgres_major}.13/bin/postgres"
                                )
                            }
                        ],
                        "exit": {"code": 0, "signal": None},
                        "survivingPids": [],
                    }
                ]
            )
        ]
        lines.extend(
            [
                "INTEGRATION_0009_PUBLICATION_SUMMARY schema=17 roles=3 source_lock_controls=3 status=pass",
                "INTEGRATION_0009_PORTAL_SECURITY_SUMMARY forced_rls=23 status=pass",
            ]
        )
        for guard in self.DATABASE_GUARDS:
            lines.extend(
                [
                    f"MUTATION_0009_RED {guard}",
                    f"MUTATION_0009_RESTORE_GREEN {guard}",
                ]
            )
        summary = " ".join(
            f"{guard.replace('-', '_')}=detected" for guard in self.DATABASE_GUARDS
        )
        lines.append(
            "MUTATIONS_0009_PUBLICATION_SUMMARY "
            f"{summary} restored_controls=32 status=pass"
        )
        return "\n".join(lines)

    def infrastructure_output(self) -> str:
        lines = [
            "✔ Slice 6 synthesizes the exact additive runtime, credential, and queue topology",
            "✔ Slice 6 publication IAM is prefix-exact, non-destructive, and keeps API/portal/worker capabilities disjoint",
            "✔ Slice 6 remains one private origin with no CDN, public asset bucket, or browser identity pool",
            '"migration0009AssetAndRuntimeRoles": "PASS"',
            "ℹ tests 118",
            "ℹ pass 118",
            "ℹ fail 0",
            "ℹ skipped 0",
        ]
        for guard in self.INFRASTRUCTURE_GUARDS:
            lines.extend(
                [
                    f"MUTATION_RED {guard}: focused infrastructure policy rejected mutant",
                    f"RESTORE_GREEN {guard}",
                ]
            )
        lines.append("MUTATION_SUMMARY detected=37 restored=37 total=37")
        return "\n".join(lines)

    def test_neutralized_live_guard_is_rejected_even_after_a_restore_line(self) -> None:
        """An escaped mutation must invalidate a ledger, not merely be reported."""

        output = "\n".join(
            [
                "MUTATION_0009_RED source-binding",
                "MUTATION_0009_RESTORE_GREEN source-binding",
                "MUTATION_ESCAPED source-binding: focused guard accepted mutant",
            ]
        )

        with self.assertRaises(verify_slice6_mutation_controls.MutationVerificationError):
            verify_slice6_mutation_controls.validate_mutation_pairs(
                output,
                red_prefix="MUTATION_0009_RED ",
                green_prefix="MUTATION_0009_RESTORE_GREEN ",
                expected={"source-binding"},
            )

    def test_database_ledger_requires_postgres16_exact_32_guards_and_summary(self) -> None:
        result = verify_slice6_mutation_controls.validate_database_output(self.database_output())

        self.assertEqual(result["detected"], 32)
        self.assertEqual(result["restored"], 32)
        self.assertEqual(result["postgresql"]["major"], 16)

        missing_restore = self.database_output().replace(
            "MUTATION_0009_RESTORE_GREEN source-binding\n", "", 1
        )
        with self.assertRaises(verify_slice6_mutation_controls.MutationVerificationError):
            verify_slice6_mutation_controls.validate_database_output(missing_restore)

        missing_source_lock = self.database_output().replace(" source_lock_controls=3", "")
        with self.assertRaises(verify_slice6_mutation_controls.MutationVerificationError):
            verify_slice6_mutation_controls.validate_database_output(missing_source_lock)

    def test_database_ledger_rejects_a_wrong_postgres_major(self) -> None:
        with self.assertRaises(verify_slice6_mutation_controls.MutationVerificationError):
            verify_slice6_mutation_controls.validate_database_output(
                self.database_output(postgres_major=15)
                + "\nPostgreSQL 16 was mentioned by an unrelated historical diagnostic"
            )

    def test_infrastructure_ledger_requires_exact_37_pairs_and_matching_summary(self) -> None:
        result = verify_slice6_mutation_controls.validate_infrastructure_output(
            self.infrastructure_output()
        )

        self.assertEqual(result["detected"], 37)
        self.assertEqual(result["restored"], 37)

        wrong_summary = self.infrastructure_output().replace(
            "detected=37 restored=37 total=37", "detected=36 restored=37 total=37"
        )
        with self.assertRaises(verify_slice6_mutation_controls.MutationVerificationError):
            verify_slice6_mutation_controls.validate_infrastructure_output(wrong_summary)

        with self.assertRaises(verify_slice6_mutation_controls.MutationVerificationError):
            verify_slice6_mutation_controls.validate_infrastructure_output(
                self.infrastructure_output().replace("ℹ tests 118", "ℹ tests 110")
            )

    def test_aggregate_records_the_actual_raw_log_digests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database_log = root / "database.log"
            infrastructure_log = root / "infrastructure.log"
            database_log.write_text(self.database_output(), encoding="utf-8")
            infrastructure_log.write_text(self.infrastructure_output(), encoding="utf-8")

            report = verify_slice6_mutation_controls.run_verification(
                root / "artifacts",
                database_log=database_log,
                infrastructure_log=infrastructure_log,
            )

            self.assertEqual(report["status"], "PASS")
            self.assertEqual(
                report["evidence"]["database"]["sha256"],
                hashlib.sha256(database_log.read_bytes()).hexdigest(),
            )
            self.assertTrue((root / "artifacts" / "mutation-verification.json").is_file())


if __name__ == "__main__":
    unittest.main()

"""Static contracts for the Slice 4 CI additions."""

from __future__ import annotations

from pathlib import Path
import re
import unittest

from Scripts import verify_xcode_scaffold


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class Slice4CIContractTests(unittest.TestCase):
    def test_hosted_job_uses_pinned_node24_real_postgres_and_offline_entrypoint(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("hosted-verification:", workflow)
        self.assertIn("runs-on: ubuntu-24.04", workflow)
        self.assertIn("node-version: '24.15.0'", workflow)
        self.assertIn("postgresql-16", workflow)
        self.assertIn("/usr/lib/postgresql/16/bin/postgres --version", workflow)
        self.assertNotIn("/opt/homebrew/opt/postgresql@16/bin", workflow)
        self.assertNotIn("sudo ln", workflow)
        self.assertIn("Scripts/verify_slice4_hosted.py", workflow)
        self.assertNotIn("secrets.", workflow)
        for action in re.findall(r"uses:\s+[^\s@]+@([^\s#]+)", workflow):
            self.assertRegex(action, r"^[0-9a-f]{40}$")

    def test_hosted_evidence_is_always_uploaded_with_the_pinned_action(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        marker = "- name: Upload hosted verification evidence"

        self.assertIn(marker, workflow)
        upload = workflow[workflow.index(marker) :]
        self.assertIn("if: always()", upload)
        self.assertIn(
            "uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
            upload,
        )
        self.assertIn("${{ runner.temp }}/roomscan-slice4-hosted", upload)
        self.assertIn("if-no-files-found: error", upload)
        self.assertIn("retention-days: 7", upload)

    def test_hosted_wrapper_executes_task7_self_tests(self) -> None:
        verifier = (ROOT / "Scripts" / "verify_slice4_hosted.py").read_text(encoding="utf-8")

        for test_module in (
            "Scripts/test_verify_slice4_hosted.py",
            "Scripts/test_verify_slice4_static_controls.py",
            "Scripts/test_inspect_ios_artifact.py",
            "Scripts/test_slice4_ci_contract.py",
            "Scripts/test_inspect_slice5_ios_artifact.py",
            "Scripts/test_inspect_slice6_ios_artifact.py",
            "Scripts/test_verify_slice5_mutation_controls.py",
            "Scripts/test_verify_slice5_sync.py",
            "Scripts/test_verify_slice6_mutation_controls.py",
            "Scripts/test_verify_slice6_publication.py",
        ):
            self.assertIn(test_module, verifier)

    def test_existing_ios_build_emits_and_inspects_a_slice6_compiled_bundle(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("-derivedDataPath \"$RUNNER_TEMP/RoomScanStudio-build-derived\"", workflow)
        self.assertIn("Scripts/inspect_slice6_ios_artifact.py", workflow)
        self.assertIn("RoomScanStudio-slice6-artifact-inspection.json", workflow)

    def test_slice6_web_job_runs_unit_build_and_real_browser_oracles(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("  web-verification:", workflow)
        web_start = workflow.index("  web-verification:")
        web = workflow[web_start:]
        self.assertIn("runs-on: ubuntu-24.04", web)
        self.assertIn("node-version: '24.15.0'", web)
        self.assertIn("working-directory: HostedService", web)
        self.assertIn("working-directory: HostedService/web", web)
        self.assertIn("run: npm ci", web)
        self.assertIn("run: npx playwright install --with-deps chromium", web)
        for command in ("npm run typecheck", "npm test", "npm run build", "npm run test:e2e"):
            self.assertIn(f"run: {command}", web)
        self.assertIn("- name: Upload web screenshots and interaction evidence", web)
        self.assertIn("if: always()", web)
        self.assertIn("${{ github.workspace }}/HostedService/web/screenshots", web)
        self.assertIn("${{ github.workspace }}/HostedService/web/test-results", web)
        self.assertIn("if-no-files-found: error", web)

    def test_legacy_scanner_scopes_xctest_upload_contract_to_its_named_step(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertEqual(verify_xcode_scaffold.workflow_structure_errors(workflow), [])

        legacy_start = workflow.index("- name: Upload XCTest results")
        hosted_start = workflow.index("  hosted-verification:")
        legacy = workflow[legacy_start:hosted_start]
        broken_action = (
            workflow[:legacy_start]
            + legacy.replace(
                "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
                "actions/upload-artifact@" + ("0" * 40),
                1,
            )
            + workflow[hosted_start:]
        )
        broken_path = workflow.replace(
            "${{ runner.temp }}/RoomScanStudio-iPhone.xcresult",
            "${{ runner.temp }}/wrong.xcresult",
            1,
        )

        self.assertTrue(verify_xcode_scaffold.workflow_structure_errors(broken_action))
        self.assertTrue(verify_xcode_scaffold.workflow_structure_errors(broken_path))


if __name__ == "__main__":
    unittest.main()

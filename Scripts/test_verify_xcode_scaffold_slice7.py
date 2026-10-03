"""Paired negative and safe controls for the Slice 7 release configuration checks.

Every mutation is applied to an in-memory copy or a temporary directory; the
live repository files are only read.
"""

from pathlib import Path
import tempfile
import unittest

from Scripts import verify_xcode_scaffold as verifier


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "RoomScanStudio.xcodeproj" / "project.pbxproj"
OPERATOR = ROOT / "Configs" / "Operator.xcconfig"
SETUP = ROOT / "Docs" / "setup.md"
APP_DEBUG = "A62000000000000000000001"
APP_RELEASE = "A62000000000000000000002"
BASE_REFERENCE = "\t\t\tbaseConfigurationReference = A90000000000000000000102 /* Operator.xcconfig */;\n"


class Slice7ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.pbx = PROJECT.read_text(encoding="utf-8")
        self.operator = OPERATOR.read_text(encoding="utf-8")
        self.setup_doc = SETUP.read_text(encoding="utf-8")

    def errors(self, pbx: str | None = None, operator: str | None = "", setup: str | None = None) -> list[str]:
        return verifier.slice7_release_configuration_errors(
            self.pbx if pbx is None else pbx,
            self.operator if operator == "" else operator,
            self.setup_doc if setup is None else setup,
        )

    def replace_in_configuration(self, config_id: str, old: str, new: str) -> str:
        body = verifier.object_body(self.pbx, config_id)
        self.assertIsNotNone(body)
        self.assertIn(old, body, "Mutation must reach the real configuration body.")
        return self.pbx.replace(body, body.replace(old, new, 1), 1)

    def test_live_configuration_passes(self) -> None:
        self.assertEqual(self.errors(), [])

    # (1) Runpath in the app target configurations.
    def test_app_configuration_without_runpath_fails(self) -> None:
        for config_id in (APP_DEBUG, APP_RELEASE):
            with self.subTest(config_id=config_id):
                mutated = self.replace_in_configuration(config_id, verifier.APP_RUNPATH_SETTING + "\n", "")
                self.assertIn(
                    f"app configuration {config_id} must declare {verifier.APP_RUNPATH_SETTING}",
                    self.errors(pbx=mutated),
                )

    def test_runpath_without_inherited_fails_and_test_runpath_safe_control_passes(self) -> None:
        dropped = self.replace_in_configuration(
            APP_DEBUG, verifier.APP_RUNPATH_SETTING, 'LD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks";'
        )
        self.assertTrue(self.errors(pbx=dropped))
        safe = self.replace_in_configuration(
            "A63000000000000000000001",
            "BUNDLE_LOADER = \"$(TEST_HOST)\";\n",
            "BUNDLE_LOADER = \"$(TEST_HOST)\";\n\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "
            + verifier.TEST_RUNPATH_VALUE + ";\n",
        )
        self.assertEqual(self.errors(pbx=safe), [])
        unsafe = safe.replace(verifier.TEST_RUNPATH_VALUE, '"@executable_path/Frameworks"', 1)
        self.assertIn(
            "test configuration A63000000000000000000001 has an unexpected LD_RUNPATH_SEARCH_PATHS value",
            self.errors(pbx=unsafe),
        )

    # (2) Base configuration on all six target configurations.
    def test_each_target_configuration_without_base_reference_fails(self) -> None:
        for config_id in verifier.APP_CONFIGURATION_IDS + verifier.TEST_CONFIGURATION_IDS:
            with self.subTest(config_id=config_id):
                mutated = self.replace_in_configuration(config_id, BASE_REFERENCE, "")
                self.assertIn(
                    f"target configuration {config_id} must use Configs/Operator.xcconfig as baseConfigurationReference",
                    self.errors(pbx=mutated),
                )

    def test_project_level_base_reference_and_absolute_reference_fail(self) -> None:
        project_level = self.replace_in_configuration(
            "A61000000000000000000001",
            "\t\t\tisa = XCBuildConfiguration;\n",
            "\t\t\tisa = XCBuildConfiguration;\n" + BASE_REFERENCE,
        )
        self.assertIn(
            "project configuration A61000000000000000000001 must not use a base configuration",
            self.errors(pbx=project_level),
        )
        absolute = self.pbx.replace(
            "path = Operator.xcconfig; sourceTree = \"<group>\";",
            "path = /Users/operator/Operator.xcconfig; sourceTree = \"<absolute>\";",
            1,
        )
        self.assertNotEqual(absolute, self.pbx)
        self.assertIn(
            "project needs exactly one relative Operator.xcconfig file reference",
            self.errors(pbx=absolute),
        )

    # (3) Entitlements exemption is limited to Configs/*.local.entitlements.
    def test_only_local_entitlements_inside_configs_are_spared(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Configs").mkdir()
            local = root / "Configs" / "RoomScanStudio.local.entitlements"
            local.write_text("<plist/>", encoding="utf-8")
            self.assertEqual(verifier.active_entitlements_errors(root), [])
            for stray in (
                root / "Foo.entitlements",
                root / "Configs" / "Foo.entitlements",
                root / "RoomScanStudio" / "RoomScanStudio.local.entitlements",
                root / "Configs" / "Nested" / "RoomScanStudio.local.entitlements",
            ):
                with self.subTest(stray=str(stray.relative_to(root))):
                    stray.parent.mkdir(parents=True, exist_ok=True)
                    stray.write_text("<plist/>", encoding="utf-8")
                    errors = verifier.active_entitlements_errors(root)
                    self.assertEqual(len(errors), 1)
                    self.assertIn(str(stray.relative_to(root)), errors[0])
                    self.assertNotIn("Configs/RoomScanStudio.local.entitlements", errors[0])
                    stray.unlink()
            self.assertEqual(verifier.active_entitlements_errors(root), [])

    # (4) Signing settings stay out of the project file.
    def test_team_identifier_in_project_fails_with_forbidden_setting_message(self) -> None:
        self.assertEqual(verifier.forbidden_project_setting_errors(self.pbx), [])
        mutated = self.replace_in_configuration(
            APP_DEBUG, "CURRENT_PROJECT_VERSION = 1;\n", "CURRENT_PROJECT_VERSION = 1;\n\t\t\t\tDEVELOPMENT_TEAM = ABCDE12345;\n"
        )
        self.assertIn(
            "forbidden active signing/cloud setting: DEVELOPMENT_TEAM",
            verifier.forbidden_project_setting_errors(mutated),
        )
        for setting in ("CODE_SIGN_STYLE = Automatic;", "CODE_SIGN_IDENTITY = \"Apple Development\";"):
            with self.subTest(setting=setting):
                signed = self.pbx.replace("CURRENT_PROJECT_VERSION = 1;", f"CURRENT_PROJECT_VERSION = 1;\n{setting}", 1)
                self.assertTrue(verifier.forbidden_project_setting_errors(signed))

    # (5) Privacy URL comes only from the xcconfig chain.
    def test_literal_privacy_url_fails_and_inherited_passes(self) -> None:
        for literal in ('"https://example.invalid"', '""'):
            with self.subTest(literal=literal):
                mutated = self.replace_in_configuration(
                    APP_RELEASE, verifier.INHERITED_PRIVACY_URL_SETTING, f"ROOMSCANSTUDIO_PRIVACY_POLICY_URL = {literal};"
                )
                errors = self.errors(pbx=mutated)
                self.assertIn(
                    f"app configuration {APP_RELEASE} must inherit ROOMSCANSTUDIO_PRIVACY_POLICY_URL from the xcconfig chain",
                    errors,
                )
                self.assertIn("project must not assign a literal ROOMSCANSTUDIO_PRIVACY_POLICY_URL", errors)
        self.assertEqual(self.pbx.count(verifier.INHERITED_PRIVACY_URL_SETTING), 2)
        self.assertEqual(self.errors(), [])

    # (6) The committed base xcconfig exists and only includes the local file.
    def test_missing_operator_xcconfig_or_include_fails(self) -> None:
        self.assertIn("missing Configs/Operator.xcconfig", self.errors(operator=None))
        self.assertIn(verifier.OPERATOR_LOCAL_INCLUDE, self.operator)
        without_include = self.operator.replace(verifier.OPERATOR_LOCAL_INCLUDE, "", 1)
        self.assertIn(
            f"Configs/Operator.xcconfig must contain {verifier.OPERATOR_LOCAL_INCLUDE}",
            self.errors(operator=without_include),
        )
        required_include = self.operator.replace(verifier.OPERATOR_LOCAL_INCLUDE, '#include "Operator.local.xcconfig"', 1)
        self.assertTrue(self.errors(operator=required_include))
        assigning = self.operator + "\nDEVELOPMENT_TEAM = ABCDE12345\n"
        self.assertIn("Configs/Operator.xcconfig must not assign build settings", self.errors(operator=assigning))

    # (7) Docs/setup.md documents the signing channel.
    def test_setup_without_signing_channel_documentation_fails(self) -> None:
        for marker in verifier.SETUP_SIGNING_CHANNEL_MARKERS:
            with self.subTest(marker=marker):
                self.assertIn(marker, self.setup_doc)
                errors = self.errors(setup=self.setup_doc.replace(marker, "removed"))
                self.assertIn(f"Docs/setup.md must document the operator signing channel: {marker}", errors)


if __name__ == "__main__":
    unittest.main()

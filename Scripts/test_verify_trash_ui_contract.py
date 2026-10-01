"""Negative controls for the trash lifecycle UI scaffold contract."""

from pathlib import Path
import shutil
import tempfile
import unittest

from Scripts import verify_xcode_scaffold as verifier


ROOT = Path(__file__).resolve().parents[1]
UI_TESTS = ROOT / "RoomScanStudio" / "RoomScanStudioUITests" / "RoomScanStudioUITests.swift"


class TrashUIContractTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.fixture = Path(temporary.name) / UI_TESTS.name
        shutil.copy2(UI_TESTS, self.fixture)
        self.source = self.fixture.read_text(encoding="utf-8")

    def errors(self, needle: str = "", replacement: str = "") -> list[str]:
        source = self.source
        if needle:
            self.assertIn(needle, source, "Negative-control setup must reach real UI code.")
            source = source.replace(needle, replacement, 1)
        self.fixture.write_text(source, encoding="utf-8")
        return verifier.trash_ui_contract_errors(self.fixture.read_text(encoding="utf-8"))

    def test_current_lifecycle_and_metadata_successors_pass(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_missing_successor_tests_fail(self) -> None:
        for name in (
            "testTrashLifecycleConfirmationRestoreArchiveAndDeleteNowPreserveOtherProject",
            "testMetadataDuplicateArchiveAndUnarchiveRemainExplicit",
        ):
            with self.subTest(name=name):
                self.assertIn(f"required UI test is missing: {name}", self.errors(name, "removedTest"))

    def test_duplicate_membership_call_must_follow_duplicate_action(self) -> None:
        needle = 'assertTrashTestMembership(in: app, present: ["ui-project-001", "ui-project-002"])'
        self.assertIn(
            "UI synchronization contract is missing: duplicate project wait",
            self.errors(needle, 'XCTAssertTrue(app.buttons["library.project.ui-project-002"].exists)'),
        )

    def test_duplicate_helper_must_bind_each_present_project_row(self) -> None:
        self.assertIn(
            "UI synchronization contract is missing: duplicate project wait",
            self.errors(
                'for id in present {\n            let row = app.buttons["library.project.\\(id)"]',
                'for id in present {\n            let row = app.buttons["library.project.ui-project-001"]',
            ),
        )

    def test_duplicate_helper_immediate_exists_is_rejected(self) -> None:
        self.assertIn(
            "UI synchronization contract is missing: duplicate project wait",
            self.errors(
                'XCTAssertTrue(row.waitForExistence(timeout: 10), "Expected \\(id) in the selected filter.")',
                'XCTAssertTrue(row.exists, "Expected \\(id) in the selected filter.")',
            ),
        )

    def test_unarchive_replacement_action_immediate_exists_is_rejected(self) -> None:
        self.assertIn(
            "UI synchronization contract is missing: unarchive replacement-action wait",
            self.errors(
                'XCTAssertTrue(app.buttons["detail.archive"].waitForExistence(timeout: 10))',
                'XCTAssertTrue(app.buttons["detail.archive"].exists)',
            ),
        )

    def test_replacement_action_wait_must_follow_unarchive(self) -> None:
        self.assertIn(
            "UI synchronization contract is missing: unarchive replacement-action wait",
            self.errors(
                'setTrashTestArchived(false, in: app)\n        openTrashTestInfo(in: app)',
                'setTrashTestArchived(true, in: app)\n        openTrashTestInfo(in: app)',
            ),
        )


if __name__ == "__main__":
    unittest.main()

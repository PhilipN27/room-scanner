"""Self-tests for Slice 5 guard-neutralization evidence."""

from __future__ import annotations

import unittest

from Scripts import verify_slice5_mutation_controls


class MutationOutputTests(unittest.TestCase):
    def test_exact_red_restore_pairs_are_required(self) -> None:
        output = "\n".join(
            [
                "MUTATION_0008_RED expected-head-cas",
                "MUTATION_0008_RESTORE_GREEN expected-head-cas",
                "MUTATION_0008_RED targetless-claim",
                "MUTATION_0008_RESTORE_GREEN targetless-claim",
            ]
        )
        result = verify_slice5_mutation_controls.parse_mutation_pairs(
            output,
            red_prefix="MUTATION_0008_RED ",
            green_prefix="MUTATION_0008_RESTORE_GREEN ",
            expected={"expected-head-cas", "targetless-claim"},
        )
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["detected"], 2)

    def test_missing_restore_or_expected_guard_is_rejected(self) -> None:
        with self.assertRaises(verify_slice5_mutation_controls.MutationVerificationError):
            verify_slice5_mutation_controls.parse_mutation_pairs(
                "MUTATION_0008_RED expected-head-cas\n",
                red_prefix="MUTATION_0008_RED ",
                green_prefix="MUTATION_0008_RESTORE_GREEN ",
                expected={"expected-head-cas", "targetless-claim"},
            )

    def test_raw_negative_claim_needs_positive_and_safe_controls(self) -> None:
        passing = "\n".join(
            [
                "working-set validator detects an injected forbidden raw artifact while reviewed raw accepts its separate fixture",
                "working-set validator accepts the real Core-generated raw-redacted fixture",
                "# pass 2",
                "# fail 0",
            ]
        )
        self.assertEqual(
            verify_slice5_mutation_controls.validate_raw_detector_output(passing)["status"],
            "PASS",
        )
        with self.assertRaises(verify_slice5_mutation_controls.MutationVerificationError):
            verify_slice5_mutation_controls.validate_raw_detector_output(
                "working-set validator accepts the real Core-generated raw-redacted fixture\n# pass 1\n# fail 0"
            )


if __name__ == "__main__":
    unittest.main()

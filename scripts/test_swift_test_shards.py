#!/usr/bin/env python3
"""Safety checks for the full-gate XCTest coverage reconciler."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "run_swift_tests", Path(__file__).with_name("run-swift-tests.py"),
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ShardResultsTests(unittest.TestCase):
    expected = {
        "HamiiTests.FirstTests/testWorks",
        "HamiiTests.SecondTests/testWorker",
    }

    def assess(self, first: str, second: str, first_exit: int = 0):
        return module.assess_results(self.expected, [
            ("first", first_exit, first), ("second", 0, second),
        ])

    def test_complete_partition_counts_intentional_skip(self):
        executed, skipped, problems = self.assess(
            "Test Case '-[HamiiTests.FirstTests testWorks]' passed (0.001 seconds)",
            "Test Case '-[HamiiTests.SecondTests testWorker]' skipped (0.001 seconds)",
        )
        self.assertEqual((executed, skipped, problems), (2, 1, []))

    def test_missing_and_duplicate_results_fail(self):
        first = "Test Case '-[HamiiTests.FirstTests testWorks]' passed (0.001 seconds)"
        self.assertTrue(any("Missing" in issue for issue in self.assess(first, "")[2]))
        self.assertTrue(any("Duplicate" in issue for issue in self.assess(first, first)[2]))

    def test_failure_and_all_skip_fail(self):
        failed = "Test Case '-[HamiiTests.FirstTests testWorks]' failed (0.001 seconds)"
        worker = "Test Case '-[HamiiTests.SecondTests testWorker]' skipped (0.001 seconds)"
        self.assertTrue(any("failed" in issue for issue in self.assess(failed, worker)[2]))
        skipped = "Test Case '-[HamiiTests.FirstTests testWorks]' skipped (0.001 seconds)"
        self.assertTrue(any("No non-skipped" in issue for issue in self.assess(skipped, worker)[2]))

    def test_nonzero_shard_exit_fails_even_with_complete_cases(self):
        first = "Test Case '-[HamiiTests.FirstTests testWorks]' passed (0.001 seconds)"
        second = "Test Case '-[HamiiTests.SecondTests testWorker]' passed (0.001 seconds)"
        self.assertTrue(any("exited 2" in issue for issue in self.assess(first, second, first_exit=2)[2]))


if __name__ == "__main__":
    unittest.main()

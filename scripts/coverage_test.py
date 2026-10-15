#!/usr/bin/env python3
"""Check coverage suite auditing and authored-source report normalization."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
from coverage import audit_tests, normalize


class CoverageAuditTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        tests = self.root / "tests"
        tests.mkdir()
        (tests / "browser_test.titan").write_text(
            "function test_normal(context: test.Context)\nend\n"
            "function test_windows_endpoint_treats_exclusive_publisher_as_pending("
            "context: test.Context)\nend\n")
        self.log = self.root / "tests.log"
        self.normal = "tests.browser_test.test_normal"
        self.windows = ("tests.browser_test."
                        "test_windows_endpoint_treats_exclusive_publisher_as_pending")
        self.runs = (f"[ RUN      ] {self.normal}\n"
                     f"[ RUN      ] {self.windows}\n")
        self.skip = (f"[  SKIPPED ] {self.windows} "
                     "(platform: exclusive Windows file sharing)\n")
        self.summary = ("[==========] 2 tests ran.\n"
                        "[  PASSED  ] 1 test.\n[  SKIPPED ] 1 test.\n")

    def audit(self, text):
        self.log.write_text(text)
        audit_tests(self.root, self.log)

    def reject(self, text):
        with self.assertRaises(ValueError):
            self.audit(text)

    def test_complete_suite_without_skips(self):
        self.audit(self.runs + "[==========] 2 tests ran.\n[  PASSED  ] 2 tests.\n")

    @unittest.skipUnless(sys.platform == "linux", "Linux-only exception")
    def test_exact_platform_skip(self):
        self.audit(self.runs + self.skip + self.summary)

    def test_capability_skip_is_rejected(self):
        self.reject(self.runs + self.skip.replace(
            "platform: exclusive Windows file sharing", "capability: Chromium") + self.summary)

    def test_skip_on_another_case_is_rejected(self):
        self.reject(self.runs + self.skip.replace(self.windows, self.normal) + self.summary)

    def test_missing_public_case_is_rejected(self):
        self.reject(f"[ RUN      ] {self.normal}\n"
                    "[==========] 1 test ran.\n[  PASSED  ] 1 test.\n")

    def test_duplicate_execution_is_rejected(self):
        self.reject(self.runs + f"[ RUN      ] {self.normal}\n"
                    "[==========] 3 tests ran.\n[  PASSED  ] 3 tests.\n")

    def test_skip_summary_must_match(self):
        self.reject(self.runs + self.skip + self.summary.replace(
            "[  SKIPPED ] 1 test.", "[  SKIPPED ] 2 tests."))

    def test_failure_is_rejected(self):
        self.reject(self.runs + self.skip + self.summary +
                    f"[  FAILED  ] {self.normal}\n")


class CoveragePathsTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name) / "source"
        self.root.mkdir()
        self.trace = Path(self.workspace.name) / "trace.json"
        self.expected = {Path("main.titan"), Path("relay/service.titan")}

    def normalize(self, files):
        self.trace.write_text(json.dumps({"gcovr/format_version": "0.14", "files": files}))
        return normalize(self.root, self.trace, self.expected)

    def source(self, name, count=0):
        return {"file": str(name), "lines": [{"line_number": 3, "count": count}]}

    def test_original_paths_and_zero_hits_without_source_copies(self):
        files = self.normalize([
            self.source("main.titan"),
            self.source(self.root / "relay/service.titan", 7),
            self.source(Path(self.workspace.name) / "sdk/titan/http.titan", 11),
        ])
        self.assertEqual(set(files), self.expected)
        self.assertEqual(files[Path("main.titan")]["file"], str(self.root / "main.titan"))
        self.assertEqual(files[Path("main.titan")]["lines"], [
            {"line_number": 3, "count": 0, "branches": []}])
        self.assertEqual(files[Path("relay/service.titan")]["lines"][0]["count"], 7)

    def test_missing_production_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Production inventory mismatch"):
            self.normalize([self.source("main.titan")])

    def test_duplicate_relative_and_absolute_source_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate source"):
            self.normalize([
                self.source("main.titan"), self.source(self.root / "main.titan"),
                self.source("relay/service.titan"),
            ])


if __name__ == "__main__":
    unittest.main()

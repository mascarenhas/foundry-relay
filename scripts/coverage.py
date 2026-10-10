#!/usr/bin/env python3
"""Normalize direct executable reports for an external gcovr merge.

Keep production sources, including zero-hit lines. The compiler owns builds,
counter reset/dump, and collection; this helper only verifies and maps copies.
"""
import argparse
import json
from pathlib import Path
import re


def audit_tests(root, logfile):
    text = logfile.read_text()
    runs = re.findall(r"^\[ RUN      \] (.+)$", text, re.M)
    selected = re.findall(r"^\[==========\] (\d+) tests? ran\.$", text, re.M)
    passed = re.findall(r"^\[  PASSED  \] (\d+) tests?\.$", text, re.M)
    expected = {".".join(path.relative_to(root).with_suffix("").parts) + "." + name
                for path in (root / "tests").rglob("*.titan")
                for name in re.findall(r"^function (test_\w+)\(", path.read_text(), re.M)}
    if (len(selected) != 1 or selected != passed or not runs or
            int(selected[0]) != len(runs) or len(set(runs)) != len(runs) or
            not expected or not expected <= set(runs) or
            re.search(r"^\[ (?: SKIPPED | FAILED  )\]", text, re.M)):
        raise ValueError("Coverage requires the complete passing native suite without skips")


def normalize(root, stage, tracefile, expected):
    trace = json.loads(tracefile.read_text())
    if trace.get("gcovr/format_version") != "0.14":
        raise ValueError("Expected gcovr 8.4 trace format")
    files = {}
    for source in trace["files"]:
        path = Path(source["file"])
        path = (stage / path).resolve() if not path.is_absolute() else path.resolve()
        if not path.is_relative_to(stage):
            continue  # Source-owned SDK test support is outside the application.
        relative = path.relative_to(stage)
        if relative not in expected:
            raise ValueError("Unexpected application source: " + str(relative))
        if relative in files:
            raise ValueError("Duplicate source: " + str(relative))
        if path.read_bytes() != (root / relative).read_bytes():
            raise ValueError("Staged source differs: " + str(relative))
        lines = {}
        for line in source["lines"]:
            number, count = line["line_number"], line["count"]
            if type(number) is not int or number < 1 or type(count) is not int or count < 0:
                raise ValueError("Invalid line/count in " + str(relative))
            if number in lines:
                raise ValueError("Duplicate line in " + str(relative))
            lines[number] = {"line_number": number, "count": count, "branches": []}
        files[relative] = {"file": str(root / relative), "functions": [],
                           "lines": [lines[n] for n in sorted(lines)]}
    if set(files) != expected:
        raise ValueError("Production inventory mismatch: " + str(set(files) ^ expected))
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--test-log", type=Path, required=True)
    parser.add_argument("--input", nargs=2, action="append", type=Path, required=True,
                        metavar=("SOURCE_TREE", "TRACEFILE"))
    args = parser.parse_args()
    root = args.root.resolve()
    audit_tests(root, args.test_log)
    expected = {Path("main.titan")} | {p.relative_to(root) for p in (root / "relay").rglob("*.titan")}
    traces = [normalize(root, stage.resolve(), trace, expected) for stage, trace in args.input]
    for relative in expected:
        inventories = [{line["line_number"] for line in trace[relative]["lines"]} for trace in traces]
        if any(lines != inventories[0] for lines in inventories[1:]):
            raise ValueError("Executable-line inventory differs: " + str(relative))
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "gcovr.cfg").write_text("")
    for index, files in enumerate(traces):
        report = {"gcovr/format_version": "0.14", "files": [files[p] for p in sorted(files)]}
        (args.output / ("trace-" + str(index) + ".json")).write_text(json.dumps(report) + "\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit("coverage reports: " + str(error)) from error

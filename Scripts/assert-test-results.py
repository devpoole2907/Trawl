#!/usr/bin/env python3
"""Fail a CI run whose xcresult is not real evidence.

A green exit code from `xcodebuild test` is not enough on its own. A run that
discovered zero tests, or that quietly skipped them, exits 0 and looks like a
pass. This turns those into failures.

Usage: assert-test-results.py <path-to-.xcresult>
"""
import json
import subprocess
import sys


def summary(path: str) -> dict:
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", path],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-.xcresult>", file=sys.stderr)
        return 2

    data = summary(sys.argv[1])
    passed = data.get("passedTests", 0)
    failed = data.get("failedTests", 0)
    skipped = data.get("skippedTests", 0)
    print(f"passed={passed} failed={failed} skipped={skipped} result={data.get('result')}")

    problems = []
    if failed:
        problems.append(f"{failed} test(s) failed")
    if skipped:
        problems.append(f"{skipped} test(s) skipped — skips are not evidence")
    if passed == 0:
        problems.append("no tests executed — an empty run is not a passing run")

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1

    print("Test results accepted.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

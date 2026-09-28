#!/usr/bin/env python3
"""Writes Tests/DaisyCoreTests/TestRunner.swift from the test files next to it.

The Command Line Tools ship no XCTest, so tests run from a plain executable. Rather than
registering every test by hand, this finds each `final class ...Tests` and its `func test...()`
methods (sync or async, throwing or not) plus any setUp/setUpWithError/tearDown/tearDownWithError,
and writes the runner. Add a test file, run this, build. Run: python3 scripts/gen-tests.py
"""

import re
from pathlib import Path

FOLDER = Path(__file__).resolve().parent.parent / "Tests" / "DaisyCoreTests"
SKIP = {"TestRunner.swift", "Assertions.swift"}

suite_re = re.compile(r"^(?:final\s+)?class\s+(\w+Tests)\b", re.M)
test_re = re.compile(r"^\s+func\s+(test\w+)\(\)\s*(async)?\s*(throws)?", re.M)


def setup_lines(source: str):
    """How to prepare and clean up a fresh suite instance, from the methods it defines."""
    has = lambda pattern: re.search(pattern, source, re.M) is not None
    lines, throws = [], False
    if has(r"func setUpWithError\(\)"):
        cleanup = " defer { try? suite.tearDownWithError() }" if has(r"func tearDownWithError\(\)") else ""
        lines.append("try suite.setUpWithError();" + cleanup)
        throws = True
    elif has(r"func setUp\(\)\s*throws"):
        cleanup = " defer { suite.tearDown() }" if has(r"func tearDown\(\)") else ""
        lines.append("try suite.setUp();" + cleanup)
        throws = True
    elif has(r"func setUp\(\)"):
        cleanup = " defer { suite.tearDown() }" if has(r"func tearDown\(\)") else ""
        lines.append("suite.setUp();" + cleanup)
    elif has(r"func tearDown\(\)"):
        lines.append("defer { suite.tearDown() }")
    return lines, throws


blocks = []
for path in sorted(FOLDER.glob("*.swift")):
    if path.name in SKIP:
        continue
    source = path.read_text()
    suite = suite_re.search(source)
    if not suite:
        continue
    prepare, prepare_throws = setup_lines(source)
    for match in test_re.finditer(source):
        name, is_async, is_throws = match.group(1), bool(match.group(2)), bool(match.group(3))
        call = ("try " if is_throws else "") + ("await " if is_async else "") + f"suite.{name}()"
        throwing = is_throws or prepare_throws
        body = [
            "        do {",
            "            let before = TestLog.failures",
            f"            let suite = {suite.group(1)}()",
            *[f"            {line}" for line in prepare],
            f"            {call}",
            "            count += 1",
            f'            print("\\(TestLog.failures == before ? "PASS" : "FAIL") {name}")',
            f'        }} catch {{ fail("{name}: \\(error)") }}' if throwing else "        }",
        ]
        blocks.append("\n".join(body))

runner = """// Written by scripts/gen-tests.py. Don't edit by hand; add tests to a *Tests.swift file and rerun it.
import Foundation

@main struct TestRunner {
    static func main() async {
        // Keep every test away from the real ~/Library/Application Support/Daisy.
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-tests-\\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        setenv("DAISY_DATA_DIR", sandbox.path, 1)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let started = Date()
        var count = 0
""" + "\n".join(blocks) + """
        print("\\(count) tests completed in \\(String(format: "%.2f", Date().timeIntervalSince(started)))s; \\(TestLog.failures) failures")
        if TestLog.failures > 0 { exit(1) }
    }
}
"""
(FOLDER / "TestRunner.swift").write_text(runner)
print(f"TestRunner.swift: {len(blocks)} tests")

#!/usr/bin/env python3
"""Behavior of Scripts/check-dependency-owners.py over fixed SwiftPM JSON."""

import importlib.util
from pathlib import Path
import sys
import unittest

# Loading the script by path would otherwise leave __pycache__ beside it.
sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "check-dependency-owners.py"
spec = importlib.util.spec_from_file_location("check_dependency_owners", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def package(identity, url, *dependencies):
    return {"identity": identity, "url": url, "dependencies": list(dependencies)}


SYNTAX = package("swift-syntax", "https://github.com/swiftlang/swift-syntax.git")
UTILITIES = package("swift-macro-plugin-utilities", "https://github.com/westdorp/swift-macro-plugin-utilities.git", SYNTAX)
REPORTING = package("xctest-dynamic-overlay", "https://github.com/pointfreeco/xctest-dynamic-overlay")
CASE_PATHS = package("swift-case-paths", "https://github.com/pointfreeco/swift-case-paths", REPORTING)
MACRO_TESTING = package("swift-macro-testing", "https://github.com/pointfreeco/swift-macro-testing")


def manifest(*targets, plugins=None):
    """dump-package's shape: a target that uses no plugin has no `pluginUsages` key."""
    result = []
    for name, kind, dependencies in targets:
        target = {"name": name, "type": kind, "dependencies": dependencies}
        if plugins and name in plugins:
            target["pluginUsages"] = plugins[name]
        result.append(target)
    return {"targets": result}


def product(name, package_name, condition=None):
    return {"product": [name, package_name, None, condition]}


def tree(*dependencies):
    return package("root", "/work/root", *dependencies)


class DependencyOwnerTests(unittest.TestCase):
    def test_allowed_owners_through_a_macro_target_pass(self):
        graph = manifest(
            ("Library", "regular", [{"byName": ["Plugin", None]}]),
            ("Plugin", "macro", [product("SwiftSyntax", "swift-syntax"), product("MacroPluginUtilities", "swift-macro-plugin-utilities")]),
        )
        self.assertEqual(gate.violations(graph, tree(SYNTAX, UTILITIES)), [])

    def test_a_third_party_package_and_its_own_dependencies_fail(self):
        graph = manifest(("Library", "regular", [product("CasePaths", "swift-case-paths")]))
        self.assertEqual(
            gate.violations(graph, tree(CASE_PATHS)),
            [
                ("Library", "https://github.com/pointfreeco/swift-case-paths"),
                ("Library", "https://github.com/pointfreeco/xctest-dynamic-overlay"),
            ],
        )

    def test_a_third_party_package_behind_an_allowed_one_fails(self):
        wrapper = package("wrapper", "git@github.com:westdorp/wrapper.git", CASE_PATHS)
        graph = manifest(("Library", "regular", [product("Wrapper", "wrapper")]))
        self.assertIn(("Library", "https://github.com/pointfreeco/swift-case-paths"), gate.violations(graph, tree(wrapper)))

    def test_executables_plugins_and_conditional_dependencies_count(self):
        graph = manifest(
            ("Tool", "executable", [product("CasePaths", "swift-case-paths", {"platformNames": ["macos"]})]),
            ("Lint", "plugin", [{"target": ["Tool", None]}]),
        )
        self.assertIn(("Tool", "https://github.com/pointfreeco/swift-case-paths"), gate.violations(graph, tree(CASE_PATHS)))

    def test_a_third_party_build_plugin_fails_and_a_local_one_passes(self):
        lint = package("swiftlint", "https://github.com/realm/SwiftLint")
        graph = manifest(
            ("Library", "regular", []),
            ("Local", "plugin", []),
            plugins={"Library": [{"plugin": ["SwiftLintBuildToolPlugin", "SwiftLint"]}, {"plugin": ["Local", None]}]},
        )
        self.assertEqual(gate.violations(graph, tree(lint)), [("Library", "https://github.com/realm/SwiftLint")])

    def test_test_targets_are_exempt(self):
        graph = manifest(
            ("Library", "regular", [product("SwiftSyntax", "swift-syntax")]),
            ("LibraryTests", "test", [{"byName": ["Library", None]}, product("MacroTesting", "swift-macro-testing")]),
        )
        self.assertEqual(gate.violations(graph, tree(SYNTAX, MACRO_TESTING)), [])

    def test_a_package_used_twice_is_reported_for_each_target(self):
        graph = manifest(
            ("A", "regular", [product("CasePaths", "swift-case-paths")]),
            ("B", "regular", [product("CasePaths", "Swift-Case-Paths")]),
        )
        self.assertEqual(
            [target for target, url in gate.violations(graph, tree(CASE_PATHS)) if url.endswith("swift-case-paths")],
            ["A", "B"],
        )

    def test_owners_match_case_insensitively_on_github_only(self):
        self.assertEqual(gate.owner("https://github.com/SwiftLang/swift-syntax.git"), "swiftlang")
        self.assertEqual(gate.owner("ssh://git@github.com/apple/swift-log.git"), "apple")
        self.assertEqual(gate.owner("git@GitHub.com:westdorp/x.git"), "westdorp")
        self.assertIsNone(gate.owner("https://gitlab.com/westdorp/x.git"))
        self.assertIsNone(gate.owner("https://www.github.com/westdorp/x.git"))
        self.assertIsNone(gate.owner("/work/local-package"))

    def test_a_local_path_package_fails(self):
        graph = manifest(("Library", "regular", [product("Local", "local")]))
        self.assertEqual(gate.violations(graph, tree(package("local", "/work/local"))), [("Library", "/work/local")])

    def test_an_unattributable_dependency_fails_closed(self):
        by_name_product = manifest(("Library", "regular", [{"byName": ["CasePaths", None]}]))
        with self.assertRaisesRegex(gate.GateError, "by name"):
            gate.violations(by_name_product, tree(CASE_PATHS))
        unresolved = manifest(("Library", "regular", [product("Missing", "missing")]))
        with self.assertRaisesRegex(gate.GateError, "missing from the resolved tree"):
            gate.violations(unresolved, tree())

    def test_a_failing_swift_command_is_a_gate_error(self):
        with self.assertRaisesRegex(gate.GateError, "failed"):
            gate.swift_json("/nonexistent/swift", Path("."), "dump-package")


if __name__ == "__main__":
    unittest.main()

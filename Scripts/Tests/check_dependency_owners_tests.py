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


def manifest(*targets, products):
    return {
        "products": [{"name": name, "targets": names, "type": kind} for name, names, kind in products],
        "targets": [{"name": name, "dependencies": dependencies} for name, dependencies in targets],
    }


def product(name, package_name):
    return {"product": [name, package_name, None, None]}


def by_name(name):
    return {"byName": [name, None]}


def tree(*dependencies):
    return package("root", "/work/root", *dependencies)


LIBRARY = {"library": ["automatic"]}


class DependencyOwnerTests(unittest.TestCase):
    def test_allowed_owners_through_a_macro_target_pass(self):
        graph = manifest(
            ("Library", [by_name("Plugin")]),
            ("Plugin", [product("SwiftSyntax", "swift-syntax"), product("MacroPluginUtilities", "swift-macro-plugin-utilities")]),
            products=[("Library", ["Library"], LIBRARY)],
        )
        self.assertEqual(gate.violations(graph, tree(SYNTAX, UTILITIES)), [])

    def test_a_third_party_package_and_its_own_dependencies_fail(self):
        graph = manifest(
            ("Library", [product("CasePaths", "swift-case-paths")]),
            products=[("Library", ["Library"], LIBRARY)],
        )
        self.assertEqual(
            gate.violations(graph, tree(CASE_PATHS)),
            [
                ("Library", "https://github.com/pointfreeco/swift-case-paths"),
                ("Library", "https://github.com/pointfreeco/xctest-dynamic-overlay"),
            ],
        )

    def test_a_third_party_package_behind_an_allowed_one_fails(self):
        wrapper = package("wrapper", "https://github.com/westdorp/wrapper.git", CASE_PATHS)
        graph = manifest(
            ("Library", [product("Wrapper", "wrapper")]),
            products=[("Library", ["Library"], LIBRARY)],
        )
        self.assertIn(("Library", "https://github.com/pointfreeco/swift-case-paths"), gate.violations(graph, tree(wrapper)))

    def test_test_targets_and_executables_are_exempt(self):
        graph = manifest(
            ("Library", [product("SwiftSyntax", "swift-syntax")]),
            ("LibraryTests", [by_name("Library"), product("MacroTesting", "swift-macro-testing")]),
            ("Tool", [product("CasePaths", "swift-case-paths")]),
            products=[("Library", ["Library"], LIBRARY), ("Tool", ["Tool"], {"executable": None})],
        )
        self.assertEqual(gate.violations(graph, tree(SYNTAX, MACRO_TESTING, CASE_PATHS)), [])

    def test_owners_match_case_insensitively_and_by_ssh(self):
        self.assertEqual(gate.owner("https://github.com/SwiftLang/swift-syntax.git"), "swiftlang")
        self.assertEqual(gate.owner("git@github.com:westdorp/x.git"), "westdorp")
        self.assertIsNone(gate.owner("https://gitlab.com/westdorp/x.git"))
        self.assertIsNone(gate.owner("/work/local-package"))

    def test_a_local_path_package_fails(self):
        local = package("local", "/work/local")
        graph = manifest(("Library", [product("Local", "local")]), products=[("Library", ["Library"], LIBRARY)])
        self.assertEqual(gate.violations(graph, tree(local)), [("Library", "/work/local")])

    def test_an_unattributable_dependency_fails_closed(self):
        by_name_product = manifest(("Library", [by_name("CasePaths")]), products=[("Library", ["Library"], LIBRARY)])
        with self.assertRaisesRegex(gate.GraphError, "by name"):
            gate.violations(by_name_product, tree(CASE_PATHS))
        unresolved = manifest(("Library", [product("Missing", "missing")]), products=[("Library", ["Library"], LIBRARY)])
        with self.assertRaisesRegex(gate.GraphError, "resolved tree lacks"):
            gate.violations(unresolved, tree())


if __name__ == "__main__":
    unittest.main()

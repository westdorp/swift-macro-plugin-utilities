#!/usr/bin/env python3
"""Fail when a non-test target reaches a package outside swiftlang, apple, and westdorp.

This is policy, stricter than what SwiftPM resolves for any one product: every
non-test target counts, because a target can join a product at any time, so the
check stays a property of the package rather than of one product. Test targets
are exempt; SwiftPM never resolves a dependency's test-only packages (SE-0226).

The targets come from `swift package dump-package`; the packages each
dependency brings come from the resolved tree of `swift package
show-dependencies --format json`.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlparse

ALLOWED_OWNERS = frozenset({"swiftlang", "apple", "westdorp"})


class GateError(Exception):
    """A dependency the check cannot attribute to a package in the resolved tree."""


def owner(url):
    """The GitHub owner of a package URL, lowercased, or `None` for any other host."""
    if url.lower().startswith("git@github.com:"):
        path = url[len("git@github.com:"):]
    else:
        parsed = urlparse(url)
        if parsed.hostname != "github.com":
            return None
        path = parsed.path.lstrip("/")
    return path.split("/", 1)[0].lower() or None


def used_packages(manifest):
    """Each package identity a non-test target uses, mapped to the targets that use it."""
    local = {target["name"] for target in manifest["targets"]}
    used = {}
    for target in manifest["targets"]:
        if target["type"] == "test":
            continue
        for dependency in target["dependencies"]:
            if "product" in dependency:
                name, package, *_ = dependency["product"]
                if package is None:
                    raise GateError(f"{target['name']} names product {name} without its package")
                used.setdefault(package.lower(), set()).add(target["name"])
            elif "byName" in dependency and dependency["byName"][0] not in local:
                raise GateError(
                    f"{target['name']} depends on {dependency['byName'][0]} by name, so its package is unknown; "
                    "spell it .product(name:package:)"
                )
        # A build-tool plugin from another package is a dependency too; `None` names a local one.
        for usage in target.get("pluginUsages") or []:
            _, package = usage["plugin"]
            if package is not None:
                used.setdefault(package.lower(), set()).add(target["name"])
    return used


def violations(manifest, tree):
    """`(target, url)` for each package outside the allowed owners a non-test target reaches."""
    direct = {dependency["identity"].lower(): dependency for dependency in tree["dependencies"]}
    found = set()
    for package, targets in used_packages(manifest).items():
        if package not in direct:
            raise GateError(f"package {package} is used by {', '.join(sorted(targets))} but missing from the resolved tree")
        pending = [direct[package]]
        while pending:
            node = pending.pop()
            if owner(node["url"]) not in ALLOWED_OWNERS:
                found.update((target, node["url"]) for target in targets)
            pending.extend(node["dependencies"])
    return sorted(found)


def swift_json(swift, package_path, *arguments):
    command = [swift, "package", "--package-path", str(package_path), *arguments]
    try:
        output = subprocess.run(command, check=True, stdout=subprocess.PIPE, text=True).stdout
        return json.loads(output)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        raise GateError(f"`{' '.join(command)}` failed: {error}") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--package-path", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    try:
        manifest = swift_json(arguments.swift, arguments.package_path, "dump-package")
        tree = swift_json(arguments.swift, arguments.package_path, "show-dependencies", "--format", "json")
        found = violations(manifest, tree)
    except GateError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    for target, url in found:
        print(f"ERROR: target {target} reaches {url}, outside {', '.join(sorted(ALLOWED_OWNERS))}.", file=sys.stderr)
    if found:
        print(
            "Only test targets may use a package outside these owners; move the dependency to a test target or drop it.",
            file=sys.stderr,
        )
        return 1
    print("PASS: every non-test target depends only on swiftlang, apple, and westdorp packages.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

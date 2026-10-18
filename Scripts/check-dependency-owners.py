#!/usr/bin/env python3
"""Fail when a library product reaches a package outside swiftlang, apple, and westdorp.

Consumers resolve every package a library product reaches, so a third-party
package there can conflict with the consumer's own pins. Test targets are
exempt: SwiftPM does not resolve a dependency's test-only packages (SE-0226).

The product graph comes from `swift package dump-package`; the packages each
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


class GraphError(Exception):
    """The manifest names a dependency this check cannot attribute to a package."""


def owner(url):
    """The GitHub owner of a package URL, or `None` for any other host."""
    if url.startswith("git@github.com:"):
        path = url.removeprefix("git@github.com:")
    else:
        parsed = urlparse(url)
        if parsed.hostname != "github.com":
            return None
        path = parsed.path.lstrip("/")
    return path.split("/", 1)[0].lower() or None


def product_packages(manifest):
    """Each library product's name, mapped to the package identities its targets use."""
    targets = {target["name"]: target for target in manifest["targets"]}
    result = {}
    for product in manifest["products"]:
        if "library" not in product["type"]:
            continue
        packages = set()
        seen = set()
        pending = list(product["targets"])
        while pending:
            name = pending.pop()
            if name in seen:
                continue
            seen.add(name)
            for dependency in targets[name]["dependencies"]:
                if "product" in dependency:
                    _, package, *_ = dependency["product"]
                    if package is None:
                        raise GraphError(f"{name} names product {dependency['product'][0]} without its package")
                    packages.add(package.lower())
                else:
                    kind = "target" if "target" in dependency else "byName"
                    dependency_name = dependency[kind][0]
                    if dependency_name not in targets:
                        raise GraphError(
                            f"{name} depends on {dependency_name} by name; spell it .product(name:package:)"
                        )
                    pending.append(dependency_name)
        result[product["name"]] = packages
    return result


def violations(manifest, tree):
    """`(product, url)` for each package outside the allowed owners a library product reaches."""
    direct = {dependency["identity"].lower(): dependency for dependency in tree["dependencies"]}
    found = set()
    for product, packages in product_packages(manifest).items():
        for package in packages:
            if package not in direct:
                raise GraphError(f"{product} uses package {package}, which the resolved tree lacks")
            pending = [direct[package]]
            while pending:
                node = pending.pop()
                if owner(node["url"]) not in ALLOWED_OWNERS:
                    found.add((product, node["url"]))
                pending.extend(node["dependencies"])
    return sorted(found)


def swift_json(swift, package_path, *arguments):
    output = subprocess.run(
        [swift, "package", "--package-path", str(package_path), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout
    return json.loads(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--package-path", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    manifest = swift_json(arguments.swift, arguments.package_path, "dump-package")
    tree = swift_json(arguments.swift, arguments.package_path, "show-dependencies", "--format", "json")
    try:
        found = violations(manifest, tree)
    except GraphError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    for product, url in found:
        print(f"ERROR: library product {product} reaches {url}, outside {', '.join(sorted(ALLOWED_OWNERS))}.", file=sys.stderr)
    if found:
        print("Consumers resolve every package a library product reaches; keep third-party packages in test targets only.", file=sys.stderr)
        return 1
    print("PASS: every library product depends only on swiftlang, apple, and westdorp packages.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

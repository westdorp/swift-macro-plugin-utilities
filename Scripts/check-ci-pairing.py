#!/usr/bin/env python3
"""Check that macOS CI commands and Xcode gate-profile parts are paired."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib


XCODE_SELECTION = '''version="$(cat "$GITHUB_WORKSPACE/.xcode-version")"
developer_dir="/Applications/Xcode_$version.app/Contents/Developer"
test "$(DEVELOPER_DIR="$developer_dir" xcodebuild -version | sed -n 1p)" = "Xcode $version"
echo "DEVELOPER_DIR=$developer_dir" >> "$GITHUB_ENV"'''


class GateError(Exception):
    """The workflow or profile cannot be interpreted for pairing."""


def parse_workflow(source, run):
    result = run(
        ["ruby", "-rpsych", "-rjson", "-e", "puts JSON.generate(Psych.safe_load(STDIN.read, aliases: true))"],
        input=source, text=True, capture_output=True,
    )
    if result.returncode:
        raise GateError(f"workflow YAML: {result.stderr.strip()}")
    return json.loads(result.stdout)


def job_instances(job_id, job):
    strategy = job.get("strategy", {})
    if not isinstance(strategy, dict) or not isinstance(job.get("name", job_id), str):
        raise GateError(f"{job_id}: strategy must be a mapping and name must be a string")
    matrix = strategy.get("matrix")
    if matrix is None:
        return [(job_id, job.get("name", job_id))], f"make ci-{job_id}"
    if not isinstance(matrix, dict) or len(matrix) != 1:
        raise GateError(f"{job_id}: pairing requires a single literal matrix axis")
    key, values = next(iter(matrix.items()))
    if key in {"include", "exclude"} or not isinstance(values, list) or not values:
        raise GateError(f"{job_id}: pairing requires a nonempty literal matrix axis")
    if any(type(value) not in (str, int, float) for value in values):
        raise GateError(f"{job_id}: matrix values must be strings or numbers")
    expression = re.compile(r"\$\{\{\s*matrix\." + re.escape(key) + r"\s*\}\}")
    instances = [
        (f"{job_id}-{value}", expression.sub(str(value), job.get("name", job_id)))
        for value in values
    ]
    return instances, f"make ci-{job_id}-${{{{ matrix.{key} }}}}"


def required_step(step):
    return "if" not in step and step.get("continue-on-error", False) is False


def violations(workflow, profile):
    if not isinstance(workflow, dict) or not isinstance(workflow.get("jobs"), dict):
        raise GateError("workflow must contain a jobs mapping")
    if not isinstance(profile, dict) or not isinstance(profile.get("parts"), list):
        raise GateError("profile must contain a parts array")
    found = []
    for field, expected in (("version", 2), ("platforms", ["aarch64-darwin"])):
        if profile.get(field) != expected:
            found.append(f"profile {field}: expected {expected!r}, got {profile.get(field)!r}")
    parts = {}
    for part in profile["parts"]:
        if not isinstance(part, dict) or not isinstance(part.get("id"), str):
            found.append("profile part must be a table with a string id")
            continue
        parts.setdefault(part["id"], []).append(part)
    expected_ids = set()
    for job_id, job in workflow["jobs"].items():
        if not isinstance(job, dict):
            found.append(f"{job_id}: job must be a mapping")
            continue
        runner = job.get("runs-on", "")
        labels = runner if isinstance(runner, list) else [runner]
        if not any(isinstance(label, str) and label.startswith(("macos-", "xcode-")) for label in labels):
            continue
        try:
            instances, command = job_instances(job_id, job)
        except GateError as error:
            found.append(str(error))
            continue
        steps = job.get("steps")
        if not isinstance(steps, list) or any(not isinstance(step, dict) for step in steps):
            found.append(f"{job_id}: steps must be an array of mappings")
            steps = []
        selector = ["--xcode-version-file", ".xcode-version"]
        env = job.get("env", {})
        if not isinstance(env, dict):
            found.append(f"{job_id}: env must be a mapping")
            env = {}
        gate_steps = [step for step in steps if isinstance(step.get("run"), str) and step["run"].strip() == command]
        for step in gate_steps:
            if not required_step(step):
                found.append(f"{job_id}: {command!r} must run unconditionally and fail on errors")
            step_env = step.get("env", {})
            if isinstance(step_env, dict):
                env = {**env, **step_env}
            else:
                found.append(f"{job_id}: gate step env must be a mapping")
        developer_dir = env.get("DEVELOPER_DIR")
        checkouts = [i for i, step in enumerate(steps) if str(step.get("uses", "")).lower().startswith("actions/checkout@")]
        if len(checkouts) != 1:
            found.append(f"{job_id}: expected exactly one checkout")
        selection_indices = set()
        if developer_dir is not None:
            pinned = re.fullmatch(r"/Applications/Xcode_([0-9]+(?:\.[0-9]+)+)\.app/Contents/Developer", str(developer_dir))
            if pinned:
                selector = ["--xcode", pinned[1]]
            else:
                found.append(f"{job_id}: explicit DEVELOPER_DIR must name a versioned Xcode application")
        for index in checkouts:
            selection = steps[index + 1] if index + 1 < len(steps) else {}
            run = selection.get("run")
            if (selection.get("name") == "Select the committed Xcode"
                    and isinstance(run, str) and run.strip() == XCODE_SELECTION
                    and required_step(selection)):
                selection_indices.add(index + 1)
            elif developer_dir is None:
                found.append(f"{job_id}: select the committed Xcode immediately after checkout")
        commands = [
            step["run"].strip() if isinstance(step["run"], str) else step["run"]
            for index, step in enumerate(steps) if "run" in step and index not in selection_indices
        ]
        if commands != [command]:
            found.append(f"{job_id}: expected exactly one run step {command!r}, got {commands!r}")
        for slug, check in instances:
            expected = [
                {"id": slug, "kind": "local", "host": "aarch64-darwin", "level": "eval",
                 "proves": ["aarch64-darwin"], "argv": ["xcode-test", *selector, "make", f"ci-{slug}"]},
                {"id": f"{slug}-ci", "kind": "ci", "level": "build", "proves": ["aarch64-darwin"],
                 "checks": [{"app": "github-actions", "name": check}]},
            ]
            for wanted in expected:
                part_id = wanted["id"]
                expected_ids.add(part_id)
                matches = parts.get(part_id, [])
                if len(matches) != 1:
                    found.append(f"{part_id}: expected exactly one profile part, got {len(matches)}")
                for part in matches:
                    for field, value in wanted.items():
                        if part.get(field) != value:
                            found.append(f"{part_id} {field}: expected {value!r}, got {part.get(field)!r}")
                    extra = part.keys() - wanted.keys()
                    if extra:
                        found.append(f"{part_id}: unexpected fields {', '.join(sorted(extra))}")
    for part_id, matches in parts.items():
        for part in matches:
            argv = part.get("argv", [])
            if part_id not in expected_ids and (part.get("kind") == "ci" or isinstance(argv, list) and argv[:1] == ["xcode-test"]):
                found.append(f"{part_id}: no corresponding macOS CI instance")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    root = parser.parse_args().repo_root
    try:
        workflow = parse_workflow((root / ".github/workflows/ci.yml").read_text(), subprocess.run)
        profile = tomllib.loads((root / "gate-profile.toml").read_text())
        found = violations(workflow, profile)
    except (GateError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    for error in found:
        print(f"ERROR: {error}", file=sys.stderr)
    if found:
        return 1
    print("PASS: every macOS CI instance has matching Xcode local and CI parts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

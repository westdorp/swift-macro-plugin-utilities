#!/usr/bin/env python3
"""Check that macOS CI commands and Xcode gate-profile parts are paired."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib


class GateError(Exception):
    """The workflow or profile cannot be interpreted for pairing."""


def parse_workflow(source, run):
    result = run(
        ["ruby", "-rpsych", "-rjson", "-e", """
stream = Psych.parse_stream(STDIN.read)
document = stream.children.first
if document && document.root.is_a?(Psych::Nodes::Mapping)
  # Psych uses YAML 1.1; quote workflow keys so GitHub's `on` stays a string.
  document.root.children.each_slice(2) do |key, _|
    if key.is_a?(Psych::Nodes::Scalar)
      key.style = Psych::Nodes::Scalar::DOUBLE_QUOTED
      key.plain = false
      key.quoted = true
    end
  end
end
puts JSON.generate(Psych.safe_load(stream.to_yaml, aliases: true))
"""],
        input=source, text=True, capture_output=True,
    )
    if result.returncode:
        raise GateError(f"workflow YAML: {result.stderr.strip()}")
    return json.loads(result.stdout)


CHECKOUT = {
    "name": "Checkout",
    "uses": "actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10",
}
SELECT_XCODE = {"name": "Select the committed Xcode", "uses": "./.github/actions/select-xcode"}
WORKFLOW_KEYS = {"name", "on", "permissions", "concurrency", "jobs"}
MACOS_JOB_KEYS = {"name", "runs-on", "steps", "needs", "timeout-minutes", "permissions"}


def violations(workflows, profile):
    if "ci.yml" not in workflows:
        raise GateError("ci.yml must exist")
    for filename, workflow in workflows.items():
        if not isinstance(workflow, dict) or not isinstance(workflow.get("jobs"), dict):
            raise GateError(f"{filename}: workflow must contain a jobs mapping")
    if not isinstance(profile, dict) or not isinstance(profile.get("parts"), list):
        raise GateError("profile must contain a parts array")
    found = []
    extra = workflows["ci.yml"].keys() - WORKFLOW_KEYS
    if extra:
        found.append(f"ci.yml: unsupported workflow keys {', '.join(sorted(extra))}")
    for field, expected in (("version", 2), ("platforms", ["aarch64-darwin"])):
        if profile.get(field) != expected:
            found.append(f"profile {field}: expected {expected!r}, got {profile.get(field)!r}")
    parts = {}
    for part in profile["parts"]:
        if not isinstance(part, dict) or not isinstance(part.get("id"), str):
            found.append("profile part must be a table with a string id")
            continue
        parts.setdefault(part["id"], []).append(part)
    macos_jobs = {}
    check_names = set()
    for filename, workflow in workflows.items():
        for job_id, job in workflow["jobs"].items():
            if not isinstance(job, dict):
                found.append(f"{job_id}: job must be a mapping")
                continue
            check = job.get("name", job_id)
            if isinstance(check, str) and "${{" in check:
                found.append(f"{job_id}: name must not contain expressions")
            elif filename == "ci.yml" and isinstance(check, str):
                check_names.add(check)
            runner = job.get("runs-on")
            labels = runner if isinstance(runner, list) else [runner]
            if any(not isinstance(label, str) or "${{" in label for label in labels):
                found.append(f"{job_id}: runs-on must be a literal label or list of literal labels")
                continue
            if not any(label.startswith(("macos-", "xcode-")) for label in labels):
                continue
            if filename != "ci.yml":
                found.append(f"{filename}: macOS job {job_id} must be in ci.yml")
                continue
            macos_jobs[job_id] = (job, labels)
    expected_ids = set()
    for job_id, (job, labels) in macos_jobs.items():
        strategy = job.get("strategy", {})
        if isinstance(strategy, dict) and "matrix" in strategy:
            found.append(
                f"macOS job {job_id} uses a matrix; split it into one job per instance, "
                "or extend this check when a real need appears"
            )
            continue
        check = job.get("name", job_id)
        if not isinstance(check, str):
            found.append(f"{job_id}: name must be a string")
            continue
        macos_runner = any(label.startswith("macos-") for label in labels)
        xcode_runner = any(label.startswith("xcode-") for label in labels)
        allowed_keys = MACOS_JOB_KEYS | ({"env"} if xcode_runner and not macos_runner else set())
        extra = job.keys() - allowed_keys
        if extra:
            found.append(f"{job_id}: unsupported job keys {', '.join(sorted(extra))}")
        command = f"make ci-{job_id}"
        steps = job.get("steps")
        if not isinstance(steps, list) or any(not isinstance(step, dict) for step in steps):
            found.append(f"{job_id}: steps must be an array of mappings")
            steps = []
        selector = ["--xcode-version-file", ".xcode-version"]
        if xcode_runner:
            env = job.get("env")
            pinned = None
            if isinstance(env, dict) and env.keys() == {"DEVELOPER_DIR"} and isinstance(env["DEVELOPER_DIR"], str):
                pinned = re.fullmatch(r"/Applications/Xcode_([0-9]+(?:\.[0-9]+)+)\.app/Contents/Developer", env["DEVELOPER_DIR"])
            if pinned:
                selector = ["--xcode", pinned[1]]
            else:
                found.append(f"{job_id}: explicit DEVELOPER_DIR must be the only env entry and name a versioned Xcode application")
        checkouts = [i for i, step in enumerate(steps) if step == CHECKOUT]
        if len(checkouts) != 1:
            found.append(f"{job_id}: expected exactly one checkout")
        for index in checkouts:
            selection = steps[index + 1] if index + 1 < len(steps) else {}
            if macos_runner and selection != SELECT_XCODE:
                found.append(f"{job_id}: select the committed Xcode immediately after checkout")
        allowed_setup = [CHECKOUT, SELECT_XCODE] if macos_runner else [CHECKOUT]
        for index, step in enumerate(steps):
            gate_step = step.keys() == {"name", "run"} and isinstance(step["name"], str) and step["run"] == command
            if step not in allowed_setup and not gate_step:
                found.append(f"{job_id}: unsupported step {index + 1}: {step!r}")
        commands = [step["run"] for step in steps if "run" in step]
        if commands != [command]:
            found.append(f"{job_id}: expected exactly one run step {command!r}, got {commands!r}")
        expected = [
            {"id": job_id, "kind": "local", "host": "aarch64-darwin", "level": "eval",
             "proves": ["aarch64-darwin"], "argv": ["xcode-test", *selector, "make", f"ci-{job_id}"]},
            {"id": f"{job_id}-ci", "kind": "ci", "level": "build", "proves": ["aarch64-darwin"],
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
            if part_id not in expected_ids and isinstance(argv, list) and argv[:1] == ["xcode-test"]:
                found.append(f"{part_id}: no corresponding macOS CI instance")
            if part.get("kind") == "ci":
                checks = part.get("checks")
                if not isinstance(checks, list) or not checks or any(
                    not isinstance(check, dict) or check.get("app") != "github-actions"
                    or not isinstance(check.get("name"), str) or check["name"] not in check_names
                    for check in checks
                ):
                    found.append(f"{part_id}: checks must name existing jobs in ci.yml")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    root = parser.parse_args().repo_root
    try:
        workflows = {
            file.name: parse_workflow(file.read_text(), subprocess.run)
            for file in sorted((root / ".github/workflows").iterdir())
            if file.is_file() and file.suffix in {".yml", ".yaml"}
        }
        profile = tomllib.loads((root / "gate-profile.toml").read_text())
        found = violations(workflows, profile)
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

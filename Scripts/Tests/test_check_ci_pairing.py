#!/usr/bin/env python3
"""Behavior of Scripts/check-ci-pairing.py over fixed workflow and profile fixtures."""

import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "check-ci-pairing.py"
FIXTURES = Path(__file__).parent / "Fixtures/ci-pairing"
spec = importlib.util.spec_from_file_location("check_ci_pairing", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PairingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = gate.parse_workflow((FIXTURES / "ci.yml").read_text(), subprocess.run)
        cls.profile = tomllib.loads((FIXTURES / "gate-profile.toml").read_text())

    def setUp(self):
        self.workflow = copy.deepcopy(type(self).workflow)
        self.profile = copy.deepcopy(type(self).profile)
        self.job = self.workflow["jobs"]["test"]

    def errors(self):
        return "\n".join(gate.violations({"ci.yml": self.workflow}, self.profile))

    def test_valid_fixture_passes(self):
        self.assertEqual(self.errors(), "")

    def test_ci_top_level_keys_are_closed(self):
        source = (FIXTURES / "ci.yml").read_text()
        for field, value in (
            ("env", "{DEVELOPER_DIR: /other}"),
            ("defaults", "{run: {working-directory: other}}"),
            ("unexpected", "null"), ("true", "null"),
        ):
            with self.subTest(field=field):
                workflow = gate.parse_workflow(f"{field}: {value}\n{source}", subprocess.run)
                self.assertIn(
                    "ci.yml: unsupported workflow keys",
                    "\n".join(gate.violations({"ci.yml": workflow}, self.profile)),
                )
        self.workflow.update(permissions={"contents": "read"}, concurrency="ci")
        self.assertEqual(self.errors(), "")

    def test_job_names_must_not_contain_expressions(self):
        for filename, runner in (("ci.yml", "macos-26"), ("ci.yml", "ubuntu-latest"),
                                 ("other.yaml", "ubuntu-latest")):
            with self.subTest(filename=filename, runner=runner):
                workflow = copy.deepcopy(self.workflow)
                workflow["jobs"]["test"].update(name="Package ${{ github.ref }}", **{"runs-on": runner})
                workflows = {"ci.yml": self.workflow, filename: workflow}
                self.assertIn("test: name must not contain expressions", "\n".join(gate.violations(workflows, self.profile)))

    def test_psych_rejects_malformed_yaml_and_object_tags(self):
        for source in ("jobs: [", "--- !ruby/object:Object {}"):
            with self.subTest(source=source), self.assertRaises(gate.GateError):
                gate.parse_workflow(source, subprocess.run)

    def test_psych_resolves_yaml_aliases(self):
        workflow = gate.parse_workflow("jobs:\n  linux: &job {runs-on: ubuntu-latest}\n  other: *job\n", subprocess.run)
        self.assertEqual(gate.violations({"ci.yml": workflow}, {"version": 2, "platforms": ["aarch64-darwin"], "parts": []}), [])

    def test_missing_or_malformed_top_level_inputs_fail(self):
        for workflow, profile in ((None, self.profile), ({}, self.profile), (self.workflow, {})):
            with self.subTest(workflow=workflow, profile=profile), self.assertRaises(gate.GateError):
                gate.violations({"ci.yml": workflow}, profile)

    def test_profile_version_and_platforms_are_checked(self):
        self.profile.update(version=1, platforms=["x86_64-linux"])
        errors = self.errors()
        self.assertIn("profile version", errors)
        self.assertIn("profile platforms", errors)

    def test_every_local_and_ci_field_is_checked(self):
        for index in (0, 1):
            for field in self.profile["parts"][index]:
                with self.subTest(index=index, field=field):
                    profile = copy.deepcopy(self.profile)
                    del profile["parts"][index][field]
                    self.assertTrue(gate.violations({"ci.yml": self.workflow}, profile))

    def test_wrong_values_and_extra_fields_fail(self):
        for index, field, value in (
            (0, "kind", "ci"), (0, "host", "x86_64-darwin"), (0, "level", "build"),
            (0, "proves", ["x86_64-darwin"]), (0, "argv", ["make", "ci-test"]),
            (0, "command", "make ci-test"), (1, "kind", "local"), (1, "level", "eval"),
            (1, "proves", []), (1, "checks", [{"app": "github-actions", "name": "test"}]),
            (1, "checks", [{"app": "other", "name": "Package Gate"}]),
        ):
            with self.subTest(index=index, field=field, value=value):
                profile = copy.deepcopy(self.profile)
                profile["parts"][index][field] = value
                self.assertTrue(gate.violations({"ci.yml": self.workflow}, profile))

    def test_duplicate_parts_fail(self):
        self.profile["parts"] += copy.deepcopy(self.profile["parts"])
        self.assertEqual(self.errors().count("expected exactly one profile part, got 2"), 2)

    def test_orphaned_local_and_ci_parts_fail(self):
        self.workflow["jobs"].clear()
        self.assertIn("test: no corresponding macOS CI instance", self.errors())
        self.assertIn("test-ci: checks must name existing jobs in ci.yml", self.errors())

    def test_every_mismatch_is_reported(self):
        del self.job["steps"][1]
        self.job["steps"][-1]["run"] = "make test"
        self.profile["parts"][0]["host"] = "wrong"
        self.profile["parts"][1]["checks"] = []
        errors = self.errors()
        for fragment in ("immediately after checkout", "exactly one run step", "test host", "test-ci checks"):
            self.assertIn(fragment, errors)

    def test_xcode_selection_must_immediately_follow_checkout(self):
        self.job["steps"][1:1] = [{"name": "Intervening action", "uses": "some/action@pin"}]
        self.assertIn("immediately after checkout", self.errors())

    def test_missing_xcode_selection_action_fails(self):
        del self.job["steps"][1]
        self.assertIn("immediately after checkout", self.errors())

    def test_xcode_selection_action_uses_must_match_exactly(self):
        for uses in (None, "./.github/actions/select-xcode/", "./.github/actions/Select-Xcode", "other/select-xcode@pin"):
            with self.subTest(uses=uses):
                self.job["steps"][1]["uses"] = uses
                self.assertIn("immediately after checkout", self.errors())

    def test_setup_steps_must_match_their_exact_content(self):
        for index in (0, 1):
            for field in self.job["steps"][index]:
                with self.subTest(index=index, field=field):
                    workflow = copy.deepcopy(self.workflow)
                    del workflow["jobs"]["test"]["steps"][index][field]
                    self.assertTrue(gate.violations({"ci.yml": workflow}, self.profile))
        self.job["steps"][0]["uses"] = "actions/checkout@other"
        self.assertTrue(self.errors())
        self.job["steps"][0] = copy.deepcopy(type(self).workflow["jobs"]["test"]["steps"][0])
        self.job["steps"].insert(2, {"uses": "some/action@pin"})
        self.assertIn("unsupported step", self.errors())

    def test_macos_explicit_pin_does_not_replace_selection_action(self):
        self.job["env"] = {"DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer"}
        self.profile["parts"][0]["argv"][1:3] = ["--xcode", "27.1"]
        del self.job["steps"][1]
        self.assertIn("immediately after checkout", self.errors())

    def test_extra_run_steps_cannot_hide_behind_selection_name(self):
        self.job["steps"].append({"name": "Select the committed Xcode", "run": "swift test"})
        self.assertTrue(self.errors())

    def test_malformed_step_and_environment_values_report_errors(self):
        for field, value in (("steps", [None]), ("env", False)):
            with self.subTest(field=field):
                workflow = copy.deepcopy(self.workflow)
                workflow["jobs"]["test"][field] = value
                self.assertTrue(gate.violations({"ci.yml": workflow}, self.profile))
        for value in (None, False, {"command": "make ci-test"}):
            with self.subTest(run=value):
                self.job["steps"][-1]["run"] = value
                self.assertTrue(self.errors())

    def test_selection_cannot_be_skipped_or_allowed_to_fail(self):
        for field, value in (("if", False), ("continue-on-error", True)):
            with self.subTest(field=field):
                workflow = copy.deepcopy(self.workflow)
                workflow["jobs"]["test"]["steps"][1][field] = value
                self.assertTrue(gate.violations({"ci.yml": workflow}, self.profile))

    def test_gate_step_cannot_be_skipped_or_allowed_to_fail(self):
        for field, value in (("if", False), ("continue-on-error", True)):
            with self.subTest(field=field):
                workflow = copy.deepcopy(self.workflow)
                workflow["jobs"]["test"]["steps"][-1][field] = value
                self.assertTrue(gate.violations({"ci.yml": workflow}, self.profile))

    def test_checkout_missing_duplicate_or_last_fails(self):
        steps = self.job["steps"]
        for replacement in (steps[1:], [steps[0], *steps], [steps[-1], steps[0]]):
            with self.subTest(steps=replacement):
                self.job["steps"] = replacement
                self.assertTrue(self.errors())

    def test_gate_command_must_be_the_single_literal_make_step(self):
        for command in ("make test", "make ci-test && swift test", "make ci-test\nswift test", "make ci-other", " make ci-test", "make ci-test\n"):
            with self.subTest(command=command):
                self.job["steps"][-1]["run"] = command
                self.assertIn("exactly one run step", self.errors())
        self.job["steps"][-1]["run"] = "make ci-test"
        self.job["steps"].append(copy.deepcopy(self.job["steps"][-1]))
        self.assertIn("exactly one run step", self.errors())

    def test_linux_jobs_are_ignored_but_cannot_have_xcode_parts(self):
        self.workflow["jobs"]["linux"] = {"runs-on": "ubuntu-latest", "steps": [{"run": "swift test"}]}
        self.assertEqual(self.errors(), "")
        part = copy.deepcopy(self.profile["parts"][0])
        part["id"] = "linux"
        self.profile["parts"].append(part)
        self.assertIn("linux: no corresponding macOS CI instance", self.errors())

    def test_new_macos_jobs_are_discovered(self):
        self.workflow["jobs"]["other"] = {"runs-on": "xcode-27.1", "steps": []}
        errors = self.errors()
        for fragment in ("other: expected exactly one checkout", "other: expected exactly one profile part", "other-ci:"):
            self.assertIn(fragment, errors)

    def test_nonliteral_runner_labels_report_errors(self):
        for runner in (
            "${{ matrix.os }}", "macos-${{ matrix.version }}",
            ["self-hosted", "${{ matrix.os }}"],
            {"group": "macos"}, None, False, 26, ["ubuntu-latest", 26],
        ):
            with self.subTest(runner=runner):
                self.workflow["jobs"]["unknown"] = {"runs-on": runner}
                self.assertEqual(self.errors(), "unknown: runs-on must be a literal label or list of literal labels")

    def test_runner_label_lists_and_unnamed_jobs(self):
        self.job["runs-on"] = ["self-hosted", "macos-26"]
        del self.job["name"]
        self.profile["parts"][1]["checks"][0]["name"] = "test"
        self.assertEqual(self.errors(), "")

    def test_macos_matrix_jobs_are_rejected_regardless_of_name_or_expression(self):
        for named in (False, True):
            for expression in (False, True):
                with self.subTest(named=named, expression=expression):
                    workflow = copy.deepcopy(self.workflow)
                    job = workflow["jobs"]["test"]
                    job["strategy"] = {"matrix": {"mode": ["debug", "release"]}}
                    if named:
                        job["name"] = "Package Gate (${{ matrix.mode }})" if expression else "Package Gate"
                    else:
                        del job["name"]
                    if expression:
                        job["steps"][-1]["run"] = "make ci-test-${{ matrix.mode }}"
                    self.assertIn(
                        "macOS job test uses a matrix; split it into one job per instance, "
                        "or extend this check when a real need appears",
                        gate.violations({"ci.yml": workflow}, self.profile),
                    )

    def test_unsupported_matrix_shapes_fail_instead_of_skipping_instances(self):
        for matrix in (None, "${{ fromJSON(needs.plan.outputs.matrix) }}", {}, {"mode": []}, {"include": [{}]}, {"a": [1], "b": [2]}):
            with self.subTest(matrix=matrix):
                self.job["strategy"] = {"matrix": matrix}
                self.assertIn(
                    "macOS job test uses a matrix; split it into one job per instance, "
                    "or extend this check when a real need appears",
                    gate.violations({"ci.yml": self.workflow}, self.profile),
                )

    def test_explicit_second_xcode_uses_its_version(self):
        self.job["runs-on"] = "xcode-27.1"
        del self.job["steps"][1]
        self.job["env"] = {"DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer"}
        self.profile["parts"][0]["argv"][1:3] = ["--xcode", "27.1"]
        self.assertEqual(self.errors(), "")
        self.profile["parts"][0]["argv"][2] = "26.6"
        self.assertIn("test argv", self.errors())
        self.job["env"]["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        self.assertIn("explicit DEVELOPER_DIR", self.errors())

    def test_unsupported_job_keys_are_refused(self):
        for field, value in (
            ("env", {}), ("env", {"DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer"}),
            ("if", True), ("continue-on-error", False), ("defaults", {"run": {"working-directory": "other"}}),
            ("strategy", {}), ("container", "swift"), ("services", {}), ("outputs", {}),
            ("working-directory", "other"), ("unexpected", None),
        ):
            with self.subTest(field=field, value=value):
                workflow = copy.deepcopy(self.workflow)
                workflow["jobs"]["test"][field] = value
                self.assertIn("unsupported job keys", "\n".join(gate.violations({"ci.yml": workflow}, self.profile)))
        self.job.update(needs=["lint"], **{"timeout-minutes": 20, "permissions": {"contents": "read"}})
        self.assertEqual(self.errors(), "")

    def test_steps_refuse_every_extra_key(self):
        for index in range(3):
            for field, value in (
                ("env", {"DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer"}),
                ("working-directory", "other"), ("if", True), ("continue-on-error", False),
                ("shell", "bash"), ("with", {}), ("id", "step"), ("timeout-minutes", 10),
            ):
                with self.subTest(index=index, field=field):
                    workflow = copy.deepcopy(self.workflow)
                    workflow["jobs"]["test"]["steps"][index][field] = value
                    self.assertIn("unsupported step", "\n".join(gate.violations({"ci.yml": workflow}, self.profile)))
        del self.job["steps"][-1]["name"]
        self.assertIn("unsupported step", self.errors())

    def test_xcode_runner_requires_exact_job_pin_and_refuses_selection_action(self):
        self.job["runs-on"] = "xcode-27.1"
        del self.job["steps"][1]
        self.profile["parts"][0]["argv"][1:3] = ["--xcode", "27.1"]
        for env in (
            None, {}, False, {"OTHER": "value"}, {"DEVELOPER_DIR": None},
            {"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"},
            {"DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer", "OTHER": "value"},
        ):
            with self.subTest(env=env):
                self.job["env"] = env
                self.assertIn("explicit DEVELOPER_DIR", self.errors())
        del self.job["env"]
        self.assertIn("explicit DEVELOPER_DIR", self.errors())
        self.job["env"] = {"DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer"}
        self.assertEqual(self.errors(), "")
        self.job["steps"].insert(1, copy.deepcopy(type(self).workflow["jobs"]["test"]["steps"][1]))
        self.assertIn("unsupported step", self.errors())

    def test_ci_checks_must_each_name_existing_jobs_on_any_runner(self):
        self.workflow["jobs"]["linux"] = {"name": "Linux Gate", "runs-on": "ubuntu-latest"}
        part = {"id": "linux-ci", "kind": "ci", "level": "build", "proves": ["x86_64-linux"],
                "checks": [{"app": "github-actions", "name": "Linux Gate"}]}
        self.profile["parts"].append(part)
        self.assertEqual(self.errors(), "")
        for checks in (None, [], "Linux Gate", [None], [{"name": []}],
                       [{"app": "github-actions", "name": "gone"}],
                       [*part["checks"], {"app": "github-actions", "name": "gone"}]):
            with self.subTest(checks=checks):
                part["checks"] = checks
                self.assertIn("linux-ci: checks must name existing jobs in ci.yml", self.errors())
        part["checks"] = [{"app": "github-actions", "name": "Linux Gate"}]
        del self.workflow["jobs"]["linux"]
        self.assertIn("linux-ci: checks must name existing jobs in ci.yml", self.errors())

    def test_cli_reads_both_workflow_extensions_and_refuses_other_macos_jobs(self):
        with tempfile.TemporaryDirectory(prefix="ci-pairing-tests-") as directory:
            root = Path(directory)
            workflows = root / ".github/workflows"
            workflows.mkdir(parents=True)
            source = (FIXTURES / "ci.yml").read_text()
            (workflows / "ci.yml").write_text(source)
            (root / "gate-profile.toml").write_text((FIXTURES / "gate-profile.toml").read_text())
            command = [sys.executable, "-I", "-B", str(SCRIPT), "--repo-root", str(root)]
            for filename in ("other.yml", "other.yaml", "ci.yaml"):
                extra = workflows / filename
                for runner in ("macos-26", "xcode-27.1"):
                    with self.subTest(filename=filename, runner=runner):
                        extra.write_text(source.replace("macos-26", runner))
                        result = subprocess.run(command, capture_output=True, text=True)
                        self.assertEqual(result.returncode, 1, result.stdout)
                        self.assertIn(f"{filename}: macOS job test must be in ci.yml", result.stderr)
                extra.write_text("jobs: {linux: {runs-on: ubuntu-latest}}")
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                extra.write_text("jobs: [")
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("workflow YAML", result.stderr)
                extra.unlink()

    def test_cli_passes_and_reports_parse_failures(self):
        with tempfile.TemporaryDirectory(prefix="ci-pairing-tests-") as directory:
            root = Path(directory)
            workflow = root / ".github/workflows/ci.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text((FIXTURES / "ci.yml").read_text())
            profile = root / "gate-profile.toml"
            profile.write_text((FIXTURES / "gate-profile.toml").read_text())
            command = [sys.executable, "-I", "-B", str(SCRIPT), "--repo-root", str(root)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS:", result.stdout)
            for malformed in ("version = [", "[[parts]]\nid = 'test'\n"):
                profile.write_text(malformed)
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("ERROR:", result.stderr)


class LocalCommandTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ci-pairing-commands-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        repo = SCRIPT.parent.parent
        for relative in ("Makefile",):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((repo / relative).read_text())
            target.chmod((repo / relative).stat().st_mode)
        tests = self.root / "Scripts/Tests"
        tests.mkdir(parents=True)
        for relative in ("Scripts/check-ci-pairing.py", "Scripts/Tests/test_check_ci_pairing.py"):
            (self.root / relative).write_text(
                "import json, sys\nfrom pathlib import Path\n"
                "with Path('pairing-calls.jsonl').open('a') as output:\n"
                "    output.write(json.dumps(bool(sys.flags.dont_write_bytecode)) + '\\n')\n"
            )

    def run_make(self, target):
        result = subprocess.run(
            ["make", "--no-print-directory", target, f"PYTHON={sys.executable}"],
            cwd=self.root, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_pairing_commands_disable_bytecode(self):
        self.run_make("test-ci-pairing")
        self.assertEqual((self.root / "pairing-calls.jsonl").read_text().splitlines(), ["true", "true"])


if __name__ == "__main__":
    unittest.main()

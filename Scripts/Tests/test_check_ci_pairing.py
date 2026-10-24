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
        return "\n".join(gate.violations(self.workflow, self.profile))

    def test_valid_fixture_passes(self):
        self.assertEqual(self.errors(), "")

    def test_psych_rejects_malformed_yaml_and_object_tags(self):
        for source in ("jobs: [", "--- !ruby/object:Object {}"):
            with self.subTest(source=source), self.assertRaises(gate.GateError):
                gate.parse_workflow(source, subprocess.run)

    def test_psych_resolves_yaml_aliases(self):
        workflow = gate.parse_workflow("jobs:\n  linux: &job {runs-on: ubuntu-latest}\n  other: *job\n", subprocess.run)
        self.assertEqual(gate.violations(workflow, {"version": 2, "platforms": ["aarch64-darwin"], "parts": []}), [])

    def test_missing_or_malformed_top_level_inputs_fail(self):
        for workflow, profile in ((None, self.profile), ({}, self.profile), (self.workflow, {})):
            with self.subTest(workflow=workflow, profile=profile), self.assertRaises(gate.GateError):
                gate.violations(workflow, profile)

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
                    self.assertTrue(gate.violations(self.workflow, profile))

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
                self.assertTrue(gate.violations(self.workflow, profile))

    def test_duplicate_parts_fail(self):
        self.profile["parts"] += copy.deepcopy(self.profile["parts"])
        self.assertEqual(self.errors().count("expected exactly one profile part, got 2"), 2)

    def test_orphaned_local_and_ci_parts_fail(self):
        self.workflow["jobs"].clear()
        self.assertEqual(self.errors().count("no corresponding macOS CI instance"), 2)

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

    def test_xcode_selection_action_name_is_not_required(self):
        del self.job["steps"][1]["name"]
        self.assertEqual(self.errors(), "")

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
                self.assertTrue(gate.violations(workflow, self.profile))
        for value in (None, False, {"command": "make ci-test"}):
            with self.subTest(run=value):
                self.job["steps"][-1]["run"] = value
                self.assertTrue(self.errors())

    def test_selection_cannot_be_skipped_or_allowed_to_fail(self):
        for field, value in (("if", False), ("continue-on-error", True)):
            with self.subTest(field=field):
                workflow = copy.deepcopy(self.workflow)
                workflow["jobs"]["test"]["steps"][1][field] = value
                self.assertTrue(gate.violations(workflow, self.profile))

    def test_gate_step_cannot_be_skipped_or_allowed_to_fail(self):
        for field, value in (("if", False), ("continue-on-error", True)):
            with self.subTest(field=field):
                workflow = copy.deepcopy(self.workflow)
                workflow["jobs"]["test"]["steps"][-1][field] = value
                self.assertTrue(gate.violations(workflow, self.profile))

    def test_checkout_missing_duplicate_or_last_fails(self):
        steps = self.job["steps"]
        for replacement in (steps[1:], [steps[0], *steps], [steps[-1], steps[0]]):
            with self.subTest(steps=replacement):
                self.job["steps"] = replacement
                self.assertTrue(self.errors())

    def test_gate_command_must_be_the_single_literal_make_step(self):
        for command in ("make test", "make ci-test && swift test", "make ci-test\nswift test", "make ci-other"):
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
                        gate.violations(workflow, self.profile),
                    )

    def test_unsupported_matrix_shapes_fail_instead_of_skipping_instances(self):
        for matrix in (None, "${{ fromJSON(needs.plan.outputs.matrix) }}", {}, {"mode": []}, {"include": [{}]}, {"a": [1], "b": [2]}):
            with self.subTest(matrix=matrix):
                self.job["strategy"] = {"matrix": matrix}
                self.assertIn(
                    "macOS job test uses a matrix; split it into one job per instance, "
                    "or extend this check when a real need appears",
                    gate.violations(self.workflow, self.profile),
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

    def test_gate_step_toolchain_override_must_match_its_local_part(self):
        self.job["steps"][-1]["env"] = {"DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer"}
        self.assertIn("test argv", self.errors())
        self.profile["parts"][0]["argv"][1:3] = ["--xcode", "27.1"]
        self.assertEqual(self.errors(), "")

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


if __name__ == "__main__":
    unittest.main()

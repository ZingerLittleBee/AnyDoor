"""Exercise the shared lane with a fake compiler at its external boundary."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "check-swift.sh"


class SwiftCheckTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        shutil.copy(RUNNER, self.root / "scripts/check-swift.sh")
        (self.root / ".github/workflows").mkdir(parents=True)
        self.pinned_xcode = self.root / "Pinned Xcode.app"
        self.developer = self.pinned_xcode / "Contents/Developer"
        (self.root / ".github/workflows/ci.yml").write_text(
            f"env:\n  XCODE_APP: {self.pinned_xcode}\n"
        )
        binaries = self.root / "bin"
        binaries.mkdir()
        compiler = self.developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        compiler.parent.mkdir(parents=True)
        compiler.write_text(
            "#!/bin/bash\n"
            'printf "%s\\n" "$*" >> "$PWD/compiler-calls"\n'
            'case "$1" in\n'
            '  --version) echo "Swift test compiler" ;;\n'
            '  build)\n'
            '    if [[ "${FAKE_WARNING:-}" == first ]]; then\n'
            '      echo "$PWD/Tests/Example.swift:1:1: warning: example"\n'
            '    elif [[ "${FAKE_WARNING:-}" == dependency ]]; then\n'
            '      echo "$PWD/.build/checkouts/Dependency/Sources/Example.swift:1:1: warning: dependency"\n'
            '    fi\n'
            '    exit "${FAKE_BUILD_EXIT:-0}" ;;\n'
            '  test) echo "Executed one fake boundary test" ;;\n'
            'esac\n'
        )
        compiler.chmod(0o755)
        # A different Swift on PATH must not replace the selected compiler.
        rogue = binaries / "swift"
        rogue.write_text("#!/bin/bash\necho 'Wrong PATH compiler' >&2\nexit 91\n")
        rogue.chmod(0o755)
        self.other_developer = self.root / "Other Xcode.app/Contents/Developer"
        alternate = self.other_developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        alternate.parent.mkdir(parents=True)
        shutil.copy(compiler, alternate)
        self.environment = os.environ.copy()
        self.environment.update({
            "PATH": str(binaries) + os.pathsep + self.environment["PATH"],
            "DEVELOPER_DIR": str(self.developer),
        })
        for flag in [
            "CLIPBOARD_HISTORY_REMOVE_GUI_FIXTURE",
            "CLIPBOARD_HISTORY_RELEASE_ACCEPTANCE",
            "CLIPBOARD_HISTORY_GUI_FIXTURE",
            "CLIPBOARD_HISTORY_GUI_MIGRATION",
            "ANYDOOR_RUN_INTERACTIVE_KEYCHAIN_ACL",
            "TOOLCHAINS",
            "SWIFT_EXEC",
            "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC",
        ]:
            self.environment.pop(flag, None)

    def run_lane(self, *arguments, **environment):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts/check-swift.sh"), *arguments],
            cwd=self.root,
            env=self.environment | environment,
            capture_output=True,
            text=True,
        )

    def calls(self):
        path = self.root / "compiler-calls"
        return path.read_text().splitlines() if path.exists() else []

    def test_mismatch_requires_explicit_override(self):
        result = self.run_lane(DEVELOPER_DIR=str(self.other_developer))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--allow-toolchain-mismatch", result.stderr)
        self.assertEqual(self.calls(), [])
        result = self.run_lane(
            "--allow-toolchain-mismatch", DEVELOPER_DIR=str(self.other_developer)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("does not establish CI compiler compatibility", result.stderr)

    def test_first_party_warning_stops_before_tests(self):
        result = self.run_lane(FAKE_WARNING="first")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call.startswith("test ") for call in self.calls()))

    def test_dependency_warning_does_not_fail_first_party_gate(self):
        result = self.run_lane(FAKE_WARNING="dependency")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("test --skip-build", self.calls())

    def test_build_failure_stops_before_tests(self):
        result = self.run_lane(FAKE_BUILD_EXIT="7")
        self.assertEqual(result.returncode, 7)
        self.assertFalse(any(call.startswith("test ") for call in self.calls()))

    def test_focused_test_arguments_reach_compiler(self):
        result = self.run_lane("--", "--filter", "ExampleTests/testBehavior")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "test --skip-build --filter ExampleTests/testBehavior", self.calls()
        )

    def test_build_and_test_modes_remain_separate(self):
        result = self.run_lane("--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call.startswith("test ") for call in self.calls()))
        (self.root / "compiler-calls").unlink()
        result = self.run_lane("--skip-build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["--version", "test --skip-build"])

    def test_live_cleanup_opt_in_is_outside_ordinary_lane(self):
        result = self.run_lane(CLIPBOARD_HISTORY_REMOVE_GUI_FIXTURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ["--version"])
        self.assertIn("outside the ordinary check lane", result.stderr)

    def test_gui_migration_and_interactive_keychain_are_not_ordinary_checks(self):
        for flag in ["CLIPBOARD_HISTORY_GUI_MIGRATION", "ANYDOOR_RUN_INTERACTIVE_KEYCHAIN_ACL"]:
            with self.subTest(flag=flag):
                result = self.run_lane(**{flag: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("outside the ordinary check lane", result.stderr)

    def test_compiler_environment_cannot_bypass_selected_xcode(self):
        result = self.run_lane(SWIFT_EXEC="/unrelated/swift")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unset SWIFT_EXEC", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_path_compiler_is_not_used(self):
        result = self.run_lane("--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Wrong PATH compiler", result.stderr)

    def test_clean_build_precedes_compilation(self):
        result = self.run_lane("--clean-build", "--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.calls(), ["--version", "package clean", "build --build-tests"]
        )


if __name__ == "__main__":
    unittest.main()

"""Behavior tests for the release shell scripts.

notarize.sh, codesign.sh, and keychain.sh run against fake `xcrun`, `spctl`,
`codesign`, and `security` executables, the external boundaries that would
otherwise reach Apple or a real keychain. assemble.sh and an ad-hoc
codesign.sh run end to end on a tiny universal app compiled with clang.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import zipfile
from dataclasses import dataclass
from pathlib import Path

RELEASE_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = RELEASE_DIR.parents[1]
sys.path.insert(0, str(RELEASE_DIR))

import release_conf  # noqa: E402

TEAM_ID = release_conf.get("APPLE_TEAM_ID")
MIN_MACOS = release_conf.get("MIN_MACOS")
IS_DARWIN = sys.platform == "darwin"
SAFE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


@dataclass
class Result:
    returncode: int
    stdout: str
    stderr: str


def write_executable(path: Path, body: str) -> None:
    """Write a Python fake whose shebang is the interpreter running the tests."""
    path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(body))
    path.chmod(0o755)


class FakeToolTestCase(unittest.TestCase):
    """A temp directory with a fake-tool directory first on PATH."""

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # The scripts call `python3`; pin it to this interpreter on every OS.
        (self.bin / "python3").symlink_to(sys.executable)
        self.calls = self.root / "calls.jsonl"
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()

    def environment(self, **overrides: str) -> dict[str, str]:
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("ASC_", "NOTARY_", "DEVELOPER_ID_", "GITHUB_", "RUNNER_", "FAKE_"))
        }
        env.update(PATH=f"{self.bin}{os.pathsep}{SAFE_PATH}", TMPDIR=str(self.tmp), FAKE_CALLS=str(self.calls))
        env.update(overrides)
        return env

    def run_script(self, name: str, *arguments: str, env: dict[str, str]) -> Result:
        completed = subprocess.run(
            ["bash", str(RELEASE_DIR / name), *arguments],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
        )
        return Result(completed.returncode, completed.stdout, completed.stderr)

    def recorded(self, tool: str | None = None) -> list[list[str]]:
        if not self.calls.exists():
            return []
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return [call["argv"] for call in calls if tool is None or call["tool"] == tool]


FAKE_XCRUN = """
import json, os, sys, zipfile

argv = sys.argv[1:]
record = {"tool": "xcrun", "argv": argv}
if argv[:2] == ["notarytool", "submit"]:
    submitted = argv[2]
    record["submitted_exists"] = os.path.exists(submitted)
    if submitted.endswith(".zip") and zipfile.is_zipfile(submitted):
        with zipfile.ZipFile(submitted) as archive:
            record["zip_names"] = sorted(archive.namelist())
    if "--key" in argv:
        key = argv[argv.index("--key") + 1]
        record["key_mode"] = oct(os.stat(key).st_mode & 0o777)
        with open(key) as handle:
            record["key_contents"] = handle.read()
with open(os.environ["FAKE_CALLS"], "a") as handle:
    handle.write(json.dumps(record) + "\\n")

if argv[:2] == ["notarytool", "submit"]:
    sys.stdout.write(os.environ.get("FAKE_SUBMIT_OUTPUT", ""))
    sys.exit(int(os.environ.get("FAKE_SUBMIT_EXIT", "0")))
if argv[:2] == ["notarytool", "log"]:
    if os.environ.get("FAKE_LOG_FAIL"):
        sys.exit(1)
    with open(argv[-1], "w") as handle:
        json.dump({"status": "Accepted", "issues": [
            {"severity": "warning", "path": "AnyDoor.app", "message": "fake note"}]}, handle)
    sys.exit(0)
if argv[0] == "stapler":
    sys.exit(int(os.environ.get("FAKE_STAPLER_EXIT", "0")))
sys.exit(97)
"""

RECORDER = """
import json, os, sys
with open(os.environ["FAKE_CALLS"], "a") as handle:
    handle.write(json.dumps({"tool": os.path.basename(sys.argv[0]), "argv": sys.argv[1:]}) + "\\n")
"""


class NotarizeTests(FakeToolTestCase):
    SUBMISSION_ID = "2efe2717-52ef-43a5-96dc-0797e4ca1041"

    def setUp(self) -> None:
        super().setUp()
        write_executable(self.bin / "xcrun", FAKE_XCRUN)
        write_executable(self.bin / "spctl", RECORDER)
        self.dmg = self.root / "dist" / "AnyDoor-9.9.9.dmg"
        self.dmg.parent.mkdir()
        self.dmg.write_bytes(b"fake dmg")
        self.logs = self.root / "logs"

    def submit_output(self, status: str) -> str:
        return json.dumps({"id": self.SUBMISSION_ID, "status": status, "message": "Processing complete"})

    def api_key_env(self, **overrides: str) -> dict[str, str]:
        return self.environment(
            ASC_API_KEY_P8="-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----",
            ASC_API_KEY_ID="ABC123DEF4",
            ASC_API_ISSUER_ID="69a6de7e-0000-47e3-e053-5b8c7c11a4d1",
            **overrides,
        )

    def submit_record(self) -> dict[str, object]:
        records = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return next(record for record in records if record["argv"][:2] == ["notarytool", "submit"])

    def test_accepted_dmg_is_stapled_and_assessed_with_an_ephemeral_api_key(self) -> None:
        result = self.run_script(
            "notarize.sh", "--file", str(self.dmg), "--staple", "--log-dir", str(self.logs),
            env=self.api_key_env(FAKE_SUBMIT_OUTPUT=self.submit_output("Accepted")),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), self.SUBMISSION_ID)
        submit = self.submit_record()
        argv = submit["argv"]
        assert isinstance(argv, list)
        self.assertEqual(argv[2], str(self.dmg))
        for flag in (["--wait"], ["--timeout", "45m"], ["--output-format", "json"],
                     ["--key-id", "ABC123DEF4"], ["--issuer", "69a6de7e-0000-47e3-e053-5b8c7c11a4d1"]):
            self.assertIn(flag[0], argv)
            if len(flag) == 2:
                self.assertEqual(argv[argv.index(flag[0]) + 1], flag[1])
        self.assertEqual(submit["key_mode"], "0o600")
        self.assertIn("BEGIN PRIVATE KEY", str(submit["key_contents"]))
        key_path = Path(argv[argv.index("--key") + 1])
        self.assertFalse(key_path.exists(), "the API key must not outlive the script")
        self.assertTrue((self.logs / f"notary-AnyDoor-9.9.9.dmg-{self.SUBMISSION_ID}.json").is_file())
        self.assertIn("fake note", result.stderr)
        xcrun = self.recorded("xcrun")
        self.assertIn(["stapler", "staple", str(self.dmg)], xcrun)
        self.assertIn(["stapler", "validate", str(self.dmg)], xcrun)
        self.assertEqual(
            self.recorded("spctl"),
            [["-a", "-t", "open", "--context", "context:primary-signature", "-vv", str(self.dmg)]],
        )

    def test_rejected_status_fails_even_when_notarytool_exits_zero(self) -> None:
        result = self.run_script(
            "notarize.sh", "--file", str(self.dmg), "--staple", "--log-dir", str(self.logs),
            env=self.api_key_env(FAKE_SUBMIT_OUTPUT=self.submit_output("Invalid")),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not accepted (status: Invalid", result.stderr)
        self.assertTrue((self.logs / f"notary-AnyDoor-9.9.9.dmg-{self.SUBMISSION_ID}.json").is_file(),
                        "the log is fetched for rejected submissions too")
        self.assertNotIn("stapler", [argv[0] for argv in self.recorded("xcrun")])
        self.assertEqual(self.recorded("spctl"), [])

    def test_wait_timeout_names_the_submission_to_resume(self) -> None:
        result = self.run_script(
            "notarize.sh", "--file", str(self.dmg), "--log-dir", str(self.logs),
            env=self.api_key_env(FAKE_SUBMIT_OUTPUT=self.submit_output("In Progress"), FAKE_SUBMIT_EXIT="1"),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"xcrun notarytool wait {self.SUBMISSION_ID}", result.stderr)
        self.assertEqual(result.stdout.strip(), self.SUBMISSION_ID)

    def test_output_without_json_fails(self) -> None:
        result = self.run_script(
            "notarize.sh", "--file", str(self.dmg),
            env=self.api_key_env(FAKE_SUBMIT_OUTPUT="Error: HTTP status code: 401", FAKE_SUBMIT_EXIT="69"),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not return JSON", result.stderr)

    def test_json_without_submission_id_fails(self) -> None:
        result = self.run_script(
            "notarize.sh", "--file", str(self.dmg),
            env=self.api_key_env(FAKE_SUBMIT_OUTPUT=json.dumps({"status": "Accepted"})),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no submission id", result.stderr)

    def test_missing_log_is_a_warning_when_accepted(self) -> None:
        result = self.run_script(
            "notarize.sh", "--file", str(self.dmg),
            env=self.api_key_env(FAKE_SUBMIT_OUTPUT=self.submit_output("Accepted"), FAKE_LOG_FAIL="1"),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not fetch the notary log", result.stderr)

    def test_failed_staple_fails(self) -> None:
        result = self.run_script(
            "notarize.sh", "--file", str(self.dmg), "--staple",
            env=self.api_key_env(FAKE_SUBMIT_OUTPUT=self.submit_output("Accepted"), FAKE_STAPLER_EXIT="65"),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.recorded("spctl"), [])

    def test_keychain_profile_is_the_local_fallback(self) -> None:
        archive = self.root / "AnyDoor-9.9.9.zip"
        archive.write_bytes(b"PK fake")
        result = self.run_script(
            "notarize.sh", "--file", str(archive), "--log-dir", str(self.logs),
            env=self.environment(NOTARY_PROFILE="AnyDoor-Notary", FAKE_SUBMIT_OUTPUT=self.submit_output("Accepted")),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        submit, log = self.recorded("xcrun")
        self.assertEqual(submit[submit.index("--keychain-profile") + 1], "AnyDoor-Notary")
        self.assertNotIn("--key", submit)
        self.assertEqual(log[:3], ["notarytool", "log", self.SUBMISSION_ID])
        self.assertIn("--keychain-profile", log)

    @unittest.skipUnless(IS_DARWIN, "ditto is macOS-only")
    def test_app_is_zipped_for_upload_then_stapled_in_place(self) -> None:
        app = self.root / "dist" / "AnyDoor.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "MacOS" / "AnyDoor").write_bytes(b"binary")
        result = self.run_script(
            "notarize.sh", "--file", str(app), "--staple",
            env=self.api_key_env(FAKE_SUBMIT_OUTPUT=self.submit_output("Accepted")),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        submit = self.submit_record()
        argv = submit["argv"]
        assert isinstance(argv, list)
        self.assertTrue(str(argv[2]).endswith("/AnyDoor.zip"))
        self.assertTrue(submit["submitted_exists"])
        self.assertIn("AnyDoor.app/Contents/MacOS/AnyDoor", submit["zip_names"])
        self.assertFalse(Path(str(argv[2])).exists(), "the upload zip is temporary")
        self.assertIn(["stapler", "staple", str(app)], self.recorded("xcrun"))
        self.assertEqual(self.recorded("spctl"), [["-a", "-t", "exec", "-vv", str(app)]])
        self.assertTrue((app.parent / f"notary-AnyDoor.app-{self.SUBMISSION_ID}.json").is_file())

    def test_invalid_arguments_fail_before_any_submission(self) -> None:
        archive = self.root / "AnyDoor.zip"
        archive.write_bytes(b"PK")
        text = self.root / "notes.txt"
        text.write_text("notes")
        accepted = {"FAKE_SUBMIT_OUTPUT": self.submit_output("Accepted")}
        cases: list[tuple[str, list[str], dict[str, str], str]] = [
            ("no arguments", [], self.api_key_env(**accepted), "--file is required"),
            ("file without value", ["--file"], self.api_key_env(**accepted), "--file requires a value"),
            ("missing file", ["--file", str(self.root / "absent.dmg")], self.api_key_env(**accepted), "no such file"),
            ("unsupported type", ["--file", str(text)], self.api_key_env(**accepted), "unsupported file"),
            ("staple a zip", ["--file", str(archive), "--staple"], self.api_key_env(**accepted), "cannot be stapled"),
            ("unknown option", ["--file", str(self.dmg), "--wat"], self.api_key_env(**accepted), "unknown argument"),
            ("bad timeout", ["--file", str(self.dmg), "--timeout", "soon"], self.api_key_env(**accepted), "--timeout"),
            ("no credentials", ["--file", str(self.dmg)], self.environment(**accepted), "no notary credentials"),
            ("partial api key", ["--file", str(self.dmg)],
             self.environment(ASC_API_KEY_P8="key", **accepted), "needs ASC_API_KEY_ID"),
        ]
        for name, arguments, env, message in cases:
            with self.subTest(name):
                result = self.run_script("notarize.sh", *arguments, env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.recorded("xcrun"), [])

    def test_help_exits_zero(self) -> None:
        result = self.run_script("notarize.sh", "--help", env=self.environment())
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage: scripts/release/notarize.sh", result.stdout)


FAKE_CODESIGN = """
import json, os, sys

argv = sys.argv[1:]
with open(os.environ["FAKE_CALLS"], "a") as handle:
    handle.write(json.dumps({"tool": "codesign", "argv": argv}) + "\\n")
target = argv[-1]
if "--sign" in argv:
    marker = os.environ.get("FAKE_FAIL_ONCE", "")
    if marker and target.endswith(marker):
        flag = os.path.join(os.environ["TMPDIR"], "failed-once")
        if not os.path.exists(flag):
            open(flag, "w").close()
            sys.stderr.write(target + ": The timestamp service is not available.\\n")
            sys.exit(1)
    sys.exit(0)
if "--verify" in argv:
    sys.exit(0)
if "--entitlements" in argv:
    print(os.environ.get("FAKE_ENTITLEMENTS", "[Key] com.apple.security.automation.apple-events [Value] [Bool] true"))
    sys.exit(0)
flags = os.environ.get("FAKE_FLAGS", "0x10000(runtime)")
sys.stderr.write(f"Executable={target}\\nCodeDirectory v=20500 size=1 flags={flags} hashes=1+7 location=embedded\\n")
teams = json.loads(os.environ.get("FAKE_TEAMS", "{}"))
team = next((value for suffix, value in teams.items() if target.endswith(suffix)), os.environ.get("FAKE_TEAM", ""))
sys.stderr.write(f"TeamIdentifier={team}\\n")
"""

IDENTITY = "0123456789ABCDEF0123456789ABCDEF01234567"


class CodesignTests(FakeToolTestCase):
    def setUp(self) -> None:
        super().setUp()
        write_executable(self.bin / "codesign", FAKE_CODESIGN)
        self.app = self.root / "AnyDoor.app"
        contents = self.app / "Contents"
        sparkle = contents / "Frameworks" / "Sparkle.framework" / "Versions" / "B"
        for directory in (
            contents / "MacOS",
            contents / "Resources" / "AnyDoor_AnyDoor.bundle",
            contents / "Frameworks" / "SQLCipher.framework",
            sparkle / "XPCServices" / "Downloader.xpc",
            sparkle / "XPCServices" / "Installer.xpc",
            sparkle / "Updater.app",
        ):
            directory.mkdir(parents=True)
        for binary in (contents / "MacOS" / "AnyDoor", contents / "MacOS" / "AnyDoorHostsHelper", sparkle / "Autoupdate"):
            binary.write_bytes(b"binary")
        self.keychain = self.root / "signing.keychain-db"
        self.keychain.write_bytes(b"keychain")

    def sign_calls(self) -> list[list[str]]:
        return [argv for argv in self.recorded("codesign") if "--sign" in argv]

    def signed_targets(self) -> list[str]:
        return [os.path.relpath(argv[-1], self.app) for argv in self.sign_calls()]

    def test_developer_id_signs_depth_first_with_runtime_timestamp_and_team(self) -> None:
        result = self.run_script(
            "codesign.sh", "--app", str(self.app), "--identity", IDENTITY, "--keychain", str(self.keychain),
            env=self.environment(FAKE_TEAM=TEAM_ID),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        targets = self.signed_targets()
        sparkle = "Contents/Frameworks/Sparkle.framework/Versions/B"
        self.assertCountEqual(targets[:2], [f"{sparkle}/XPCServices/Downloader.xpc", f"{sparkle}/XPCServices/Installer.xpc"])
        self.assertEqual(targets[2:], [
            f"{sparkle}/Autoupdate",
            f"{sparkle}/Updater.app",
            "Contents/Frameworks/Sparkle.framework",
            "Contents/Frameworks/SQLCipher.framework",
            "Contents/Resources/AnyDoor_AnyDoor.bundle",
            "Contents/MacOS/AnyDoorHostsHelper",
            "Contents/MacOS/AnyDoor",
            ".",
        ])
        entitlements = str(REPO_ROOT / "Resources" / "AnyDoor.entitlements")
        for argv in self.sign_calls():
            self.assertIn("--force", argv)
            self.assertIn("--options=runtime", argv)
            self.assertIn("--timestamp", argv)
            self.assertEqual(argv[argv.index("--sign") + 1], IDENTITY)
            self.assertEqual(argv[argv.index("--keychain") + 1], str(self.keychain))
            expects_entitlements = argv[-1] in (str(self.app), str(self.app / "Contents/MacOS/AnyDoor"))
            self.assertEqual("--entitlements" in argv, expects_entitlements, argv[-1])
            if expects_entitlements:
                self.assertEqual(argv[argv.index("--entitlements") + 1], entitlements)
        self.assertIn(["--verify", "--deep", "--strict", "--verbose=2", str(self.app)], self.recorded("codesign"))
        team_checks = [argv[-1] for argv in self.recorded("codesign") if argv[:2] == ["-d", "--verbose=4"]]
        self.assertCountEqual(set(team_checks), [argv[-1] for argv in self.sign_calls()])

    def test_ad_hoc_identity_skips_timestamp_and_team(self) -> None:
        result = self.run_script(
            "codesign.sh", "--app", str(self.app), "--identity", "-",
            env=self.environment(FAKE_TEAM="not set", FAKE_FLAGS="0x10002(adhoc,runtime)"),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.sign_calls()), 10)
        for argv in self.sign_calls():
            self.assertNotIn("--timestamp", argv)
            self.assertNotIn("--keychain", argv)
            self.assertIn("--options=runtime", argv)
            self.assertEqual(argv[argv.index("--sign") + 1], "-")

    def test_foreign_team_on_nested_code_fails(self) -> None:
        result = self.run_script(
            "codesign.sh", "--app", str(self.app), "--identity", IDENTITY,
            env=self.environment(FAKE_TEAM=TEAM_ID, FAKE_TEAMS=json.dumps({"AnyDoorHostsHelper": "ZZZZZZZZZZ"})),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AnyDoorHostsHelper has TeamIdentifier 'ZZZZZZZZZZ'", result.stderr)

    def test_missing_apple_events_entitlement_fails(self) -> None:
        result = self.run_script(
            "codesign.sh", "--app", str(self.app), "--identity", IDENTITY,
            env=self.environment(FAKE_TEAM=TEAM_ID, FAKE_ENTITLEMENTS="[Dict]"),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing the Apple Events entitlement", result.stderr)

    def test_missing_hardened_runtime_fails(self) -> None:
        result = self.run_script(
            "codesign.sh", "--app", str(self.app), "--identity", IDENTITY,
            env=self.environment(FAKE_TEAM=TEAM_ID, FAKE_FLAGS="0x0(none)"),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hardened runtime", result.stderr)

    def test_transient_failure_retries_that_signature_once(self) -> None:
        result = self.run_script(
            "codesign.sh", "--app", str(self.app), "--identity", IDENTITY,
            env=self.environment(FAKE_TEAM=TEAM_ID, FAKE_FAIL_ONCE="SQLCipher.framework"),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.signed_targets().count("Contents/Frameworks/SQLCipher.framework"), 2)
        self.assertEqual(len(self.sign_calls()), 11)

    def test_ad_hoc_failure_is_not_retried(self) -> None:
        result = self.run_script(
            "codesign.sh", "--app", str(self.app), "--identity", "-",
            env=self.environment(FAKE_FAIL_ONCE="SQLCipher.framework"),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.signed_targets()[-1], "Contents/Frameworks/SQLCipher.framework")
        self.assertEqual(self.signed_targets().count("Contents/Frameworks/SQLCipher.framework"), 1)

    def test_changed_sparkle_layout_fails(self) -> None:
        shutil.rmtree(self.app / "Contents/Frameworks/Sparkle.framework/Versions/B")
        result = self.run_script("codesign.sh", "--app", str(self.app), "--identity", "-", env=self.environment())

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Sparkle's framework layout changed", result.stderr)
        self.assertEqual(self.sign_calls(), [])

    def test_invalid_arguments(self) -> None:
        cases = [
            ([], "--app is required"),
            (["--app", str(self.app)], "--identity is required"),
            (["--app", str(self.root), "--identity", "-"], "not an app bundle"),
            (["--app", str(self.app), "--identity", "-", "--keychain", str(self.root / "absent")], "keychain does not exist"),
            (["--app", str(self.app), "--identity"], "--identity requires a value"),
            (["--app", str(self.app), "--identity", "-", "--deep"], "unknown argument"),
        ]
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = self.run_script("codesign.sh", *arguments, env=self.environment())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.recorded("codesign"), [])


FAKE_SECURITY = """
import json, os, sys

argv = sys.argv[1:]
state_path = os.environ["FAKE_SECURITY_STATE"]
with open(state_path) as handle:
    state = json.load(handle)
record = {"tool": "security", "argv": argv}
command = argv[0]
if command == "create-keychain":
    open(argv[-1], "w").close()
elif command == "import":
    p12 = argv[1]
    with open(p12, "rb") as handle:
        record["p12_bytes"] = handle.read().hex()
    record["p12_mode"] = oct(os.stat(p12).st_mode & 0o777)
    record["p12_path"] = p12
elif command == "list-keychains":
    if "-s" in argv:
        state["search_list"] = argv[argv.index("-s") + 1:]
    else:
        for entry in state["search_list"]:
            print(f'    "{entry}"')
elif command == "find-identity":
    print(f'  1) {state["identity"]} "Developer ID Application: Test (TEAMID)"')
    print("     1 valid identities found")
elif command == "delete-keychain":
    os.remove(argv[-1])
with open(state_path, "w") as handle:
    json.dump(state, handle)
with open(os.environ["FAKE_CALLS"], "a") as handle:
    handle.write(json.dumps(record) + "\\n")
"""


class KeychainGuardTests(FakeToolTestCase):
    def setUp(self) -> None:
        super().setUp()
        write_executable(self.bin / "security", RECORDER)

    def test_refuses_outside_github_hosted_runners(self) -> None:
        runner_temp = str(self.root)
        cases = [
            {},
            {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": runner_temp},
            {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted", "RUNNER_TEMP": runner_temp},
            {"RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_TEMP": runner_temp},
        ]
        for subcommand in ("create", "delete"):
            for overrides in cases:
                with self.subTest(subcommand=subcommand, env=overrides):
                    result = self.run_script("keychain.sh", subcommand, env=self.environment(**overrides))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("only runs on GitHub-hosted runners", result.stderr)
                    self.assertEqual(self.recorded("security"), [])

    def test_invalid_arguments(self) -> None:
        cases = [
            ([], "a subcommand is required"),
            (["create", "delete"], "only one subcommand"),
            (["rotate"], "unknown argument"),
            # No lock/unlock: dmgbuild is trusted code (docs/releasing.md), so
            # locking the keychain around it would only look like isolation.
            (["lock"], "unknown argument"),
            (["unlock"], "unknown argument"),
            (["create", "--keychain"], "--keychain requires a value"),
        ]
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = self.run_script("keychain.sh", *arguments, env=self.environment())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_help_exits_zero(self) -> None:
        result = self.run_script("keychain.sh", "--help", env=self.environment())
        self.assertEqual(result.returncode, 0)
        self.assertIn("create|delete", result.stdout)


@unittest.skipUnless(IS_DARWIN, "keychain.sh runs only on macOS")
class KeychainLifecycleTests(FakeToolTestCase):
    SHA1 = "89ABCDEF0123456789ABCDEF0123456789ABCDEF"
    LOGIN = "/Users/runner/Library/Keychains/login.keychain-db"

    def setUp(self) -> None:
        super().setUp()
        write_executable(self.bin / "security", FAKE_SECURITY)
        # Never let a lookup fall through to the real /usr/bin/security.
        self.assertEqual(shutil.which("security", path=self.environment()["PATH"]), str(self.bin / "security"))
        self.state = self.root / "security-state.json"
        self.state.write_text(json.dumps({"search_list": [self.LOGIN], "identity": self.SHA1}))
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.output = self.root / "github-output"
        self.p12 = b"\x30\x82fake-pkcs12"
        self.keychain = self.runner_temp / "anydoor-signing.keychain-db"

    def ci_environment(self, **overrides: str) -> dict[str, str]:
        values = {
            "GITHUB_ACTIONS": "true",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_OUTPUT": str(self.output),
            "FAKE_SECURITY_STATE": str(self.state),
            "DEVELOPER_ID_P12_BASE64": base64.b64encode(self.p12).decode(),
            "DEVELOPER_ID_P12_PASSWORD": "p12-password",
            # Lowercase on purpose: the fingerprint comparison is case-insensitive.
            "DEVELOPER_ID_SHA1": self.SHA1.lower(),
        }
        values.update(overrides)
        return self.environment(**values)

    def security_records(self) -> list[dict[str, object]]:
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def search_list(self) -> list[str]:
        return json.loads(self.state.read_text())["search_list"]

    def test_create_delete_round_trip(self) -> None:
        created = self.run_script("keychain.sh", "create", env=self.ci_environment())

        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertEqual(self.output.read_text(), f"keychain_path={self.keychain}\n")
        self.assertEqual(self.search_list(), [str(self.keychain), self.LOGIN])
        records = self.security_records()
        password = records[0]["argv"][2]  # type: ignore[index]
        assert isinstance(password, str)
        self.assertGreaterEqual(len(password), 40)
        # The password exists only inside the create step; no file holds it.
        self.assertEqual(sorted(path.name for path in self.runner_temp.iterdir()),
                         ["anydoor-signing.keychain-db", "anydoor-signing.search-list"])
        commands = [record["argv"][0] for record in records]  # type: ignore[index]
        self.assertEqual(commands[:5], ["create-keychain", "set-keychain-settings", "unlock-keychain", "import",
                                        "set-key-partition-list"])
        self.assertEqual(records[0]["argv"], ["create-keychain", "-p", password, str(self.keychain)])
        self.assertEqual(records[1]["argv"], ["set-keychain-settings", "-lut", "21600", str(self.keychain)])
        imported = records[3]
        argv = imported["argv"]
        assert isinstance(argv, list)
        self.assertEqual(bytes.fromhex(str(imported["p12_bytes"])), self.p12)
        self.assertEqual(imported["p12_mode"], "0o600")
        self.assertFalse(Path(str(imported["p12_path"])).exists(), "the decoded p12 is deleted after import")
        self.assertIn("-x", argv)
        self.assertEqual(argv[argv.index("-T") + 1], "/usr/bin/codesign")
        self.assertEqual(argv.count("-T"), 1)
        self.assertNotIn("-A", argv)
        self.assertEqual(argv[argv.index("-P") + 1], "p12-password")
        self.assertEqual(argv[argv.index("-k") + 1], str(self.keychain))
        self.assertEqual(records[4]["argv"], ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                                              "-k", password, str(self.keychain)])

        deleted = self.run_script("keychain.sh", "delete", env=self.ci_environment())
        self.assertEqual(deleted.returncode, 0, deleted.stderr)
        self.assertEqual(self.search_list(), [self.LOGIN])
        self.assertFalse(self.keychain.exists())
        self.assertEqual(sorted(path.name for path in self.runner_temp.iterdir()), [])

    def test_create_fails_when_the_identity_is_not_the_expected_one(self) -> None:
        result = self.run_script(
            "keychain.sh", "create", env=self.ci_environment(DEVELOPER_ID_SHA1="1" * 40),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no valid codesigning identity 1111", result.stderr)
        self.assertFalse(self.output.exists())

    def test_create_requires_every_secret(self) -> None:
        for missing in ("DEVELOPER_ID_P12_BASE64", "DEVELOPER_ID_P12_PASSWORD", "DEVELOPER_ID_SHA1"):
            with self.subTest(missing=missing):
                env = self.ci_environment()
                del env[missing]
                result = self.run_script("keychain.sh", "create", env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{missing} is required", result.stderr)
                self.assertFalse(self.calls.exists())

    def test_delete_without_a_keychain_succeeds(self) -> None:
        result = self.run_script("keychain.sh", "delete", env=self.ci_environment())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.search_list(), [self.LOGIN])


def have_universal_clang() -> bool:
    return IS_DARWIN and shutil.which("xcrun") is not None and subprocess.run(
        ["xcrun", "--find", "clang"], capture_output=True).returncode == 0


@unittest.skipUnless(have_universal_clang(), "needs macOS with Xcode clang")
class AssembleTests(FakeToolTestCase):
    """assemble.sh and an ad-hoc codesign.sh over SwiftPM-shaped products."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.sdk = subprocess.run(
            ["xcrun", "--show-sdk-version", "--sdk", "macosx"], check=True, capture_output=True, text=True,
        ).stdout.strip()

    def setUp(self) -> None:
        super().setUp()
        self.products = self.root / "Products" / "Release"
        self.products.mkdir(parents=True)
        self.sources = self.root / "src"
        self.sources.mkdir()
        self.build_framework(self.products / "SQLCipher.framework", "SQLCipher", "A")
        sparkle = self.build_framework(self.products / "PackageFrameworks" / "Sparkle.framework", "Sparkle", "B")
        self.build_bundle(sparkle / "XPCServices" / "Installer.xpc", "Installer", "XPC!")
        self.build_bundle(sparkle / "Updater.app", "Updater", "APPL")
        self.compile_executable(sparkle / "Autoupdate")
        self.compile_executable(self.products / "AnyDoor", link_sqlcipher=True)
        self.compile_executable(self.products / "AnyDoorHostsHelper")
        resources = self.products / "AnyDoor_AnyDoor.bundle" / "Contents"
        (resources / "Resources").mkdir(parents=True)
        (resources / "Resources" / "Localizable.strings").write_text('"a" = "b";\n')
        self.write_plist(resources / "Info.plist", "AnyDoor-AnyDoor-resources", "BNDL", executable=None)
        self.out = self.root / "out"

    def clang(self, *arguments: str, minos: str = MIN_MACOS, archs: tuple[str, ...] = ("arm64", "x86_64")) -> None:
        arch_flags = [flag for arch in archs for flag in ("-arch", arch)]
        subprocess.run(
            ["xcrun", "clang", *arch_flags, f"-mmacosx-version-min={minos}",
             f"-Wl,-platform_version,macos,{minos},{self.sdk}",
             # SwiftPM links with header padding; install_name_tool needs it.
             "-Wl,-headerpad_max_install_names", *arguments],
            check=True, capture_output=True,
        )

    def compile_executable(self, path: Path, *, link_sqlcipher: bool = False, extra: tuple[str, ...] = (),
                           **options: object) -> None:
        source = self.sources / f"{path.name}.c"
        if link_sqlcipher:
            source.write_text("int sqlcipher_marker(void);\nint main(void) { return sqlcipher_marker(); }\n")
            extra = ("-F", str(self.products), "-framework", "SQLCipher", *extra)
        else:
            source.write_text("int main(void) { return 0; }\n")
        path.parent.mkdir(parents=True, exist_ok=True)
        self.clang(str(source), "-o", str(path), *extra, **options)  # type: ignore[arg-type]

    def write_plist(self, path: Path, identifier: str, package_type: str, executable: str | None) -> None:
        import plistlib

        values: dict[str, str] = {
            "CFBundleIdentifier": f"dev.bybee.test.{identifier}",
            "CFBundlePackageType": package_type,
            "CFBundleName": identifier,
        }
        if executable:
            values["CFBundleExecutable"] = executable
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as handle:
            plistlib.dump(values, handle)

    def build_framework(self, framework: Path, name: str, version: str) -> Path:
        root = framework / "Versions" / version
        source = self.sources / f"{name}.c"
        source.write_text(f"int {name.lower()}_marker(void) {{ return 0; }}\n")
        root.mkdir(parents=True)
        self.clang("-dynamiclib", "-install_name", f"@rpath/{name}.framework/Versions/{version}/{name}",
                   str(source), "-o", str(root / name))
        self.write_plist(root / "Resources" / "Info.plist", name, "FMWK", executable=name)
        (framework / "Versions" / "Current").symlink_to(version)
        (framework / name).symlink_to(f"Versions/Current/{name}")
        (framework / "Resources").symlink_to("Versions/Current/Resources")
        return root

    def build_bundle(self, bundle: Path, name: str, package_type: str) -> None:
        self.write_plist(bundle / "Contents" / "Info.plist", name, package_type, executable=name)
        self.compile_executable(bundle / "Contents" / "MacOS" / name)

    def assemble(self) -> Result:
        return self.run_script("assemble.sh", "--out", str(self.out), "--bin-path", str(self.products),
                               env=self.environment(PATH=SAFE_PATH))

    def test_assembled_app_has_the_release_layout_and_signs_ad_hoc(self) -> None:
        result = self.assemble()

        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.out / "AnyDoor.app"
        self.assertEqual(result.stdout.strip(), str(app))
        contents = app / "Contents"
        for relative in (
            "MacOS/AnyDoor", "MacOS/AnyDoorHostsHelper", "Resources/AppIcon.icns",
            "Library/LaunchDaemons/dev.bybee.AnyDoor.HostsHelper.plist",
            "Resources/AnyDoor_AnyDoor.bundle/Contents/Info.plist",
            "Frameworks/Sparkle.framework/Versions/B/Autoupdate",
            "Frameworks/SQLCipher.framework/Versions/A/SQLCipher",
        ):
            self.assertTrue((contents / relative).exists(), relative)
        self.assertTrue((contents / "Frameworks/SQLCipher.framework/Versions/Current").is_symlink())
        self.assertEqual((contents / "Info.plist").read_bytes(), (REPO_ROOT / "Info.plist").read_bytes())
        load_commands = subprocess.run(["otool", "-l", str(contents / "MacOS/AnyDoor")],
                                       check=True, capture_output=True, text=True).stdout
        self.assertIn("@executable_path/../Frameworks", load_commands)

        signed = self.run_script("codesign.sh", "--app", str(app), "--identity", "-",
                                 env=self.environment(PATH=SAFE_PATH))
        self.assertEqual(signed.returncode, 0, signed.stderr)
        details = subprocess.run(["codesign", "-d", "--verbose=2", str(app)], capture_output=True, text=True).stderr
        self.assertRegex(details, r"flags=0x[0-9a-f]+\(adhoc,runtime\)")

    def test_single_architecture_executable_is_rejected(self) -> None:
        self.compile_executable(self.products / "AnyDoorHostsHelper", archs=("arm64",))
        result = self.assemble()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AnyDoorHostsHelper is not universal", result.stderr)

    def test_system_sqlite_binding_is_rejected(self) -> None:
        self.compile_executable(self.products / "AnyDoor", link_sqlcipher=True, extra=("-lsqlite3",))
        result = self.assemble()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not bind the system SQLite library", result.stderr)

    def test_missing_sqlcipher_binding_is_rejected(self) -> None:
        self.compile_executable(self.products / "AnyDoor")
        result = self.assemble()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not bound to the bundled SQLCipher framework", result.stderr)

    def test_wrong_minimum_macos_is_rejected(self) -> None:
        self.compile_executable(self.products / "AnyDoor", link_sqlcipher=True, minos="15.0")
        result = self.assemble()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LC_BUILD_VERSION minos is 15.0", result.stderr)

    def test_missing_resource_bundle_is_rejected(self) -> None:
        shutil.rmtree(self.products / "AnyDoor_AnyDoor.bundle")
        result = self.assemble()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing resource bundle", result.stderr)

    def test_invalid_arguments(self) -> None:
        for arguments, message in (([], "--out is required"), (["--out"], "--out requires a value"),
                                   (["--out", str(self.out), "--bin-path", str(self.root / "absent")],
                                    "release products directory does not exist"),
                                   (["--bogus"], "unknown argument")):
            with self.subTest(arguments=arguments):
                result = self.run_script("assemble.sh", *arguments, env=self.environment(PATH=SAFE_PATH))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


class ScriptInterfaceTests(unittest.TestCase):
    def test_every_script_documents_its_usage(self) -> None:
        for name in ("build.sh", "assemble.sh", "codesign.sh", "keychain.sh", "notarize.sh"):
            with self.subTest(script=name):
                result = subprocess.run(["bash", str(RELEASE_DIR / name), "--help"], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Usage: scripts/release/{name}", result.stdout)

    def test_build_rejects_arguments(self) -> None:
        result = subprocess.run(["bash", str(RELEASE_DIR / "build.sh"), "--fast"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown argument", result.stderr)


if __name__ == "__main__":
    unittest.main()

"""Behavior checks for the Developer ID provisioning command.

Apple's CMS decoding and code-signature inspection are external boundaries.
Fixtures never access a signing identity, an Apple service, or a real Keychain.
"""

from __future__ import annotations

import contextlib
import io
import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from test_release_shell import (
    FAKE_CMS, IDENTITY, FakeToolTestCase, RELEASE_DIR, profile_fixture, write_executable,
)

import provisioning
import release_conf

TEAM = "9VM4RM39R3"
BUNDLE = "dev.bybee.AnyDoor"
GROUP = "9VM4RM39R3.dev.bybee.AnyDoor"
CONTAINER = "iCloud.dev.bybee.AnyDoor"

FAKE_SIGNATURE = """
import json, os, pathlib, plistlib, sys
if "--verify" in sys.argv:
    with open(os.environ["FAKE_CALLS"], "a") as handle:
        handle.write(json.dumps({"tool": "codesign", "argv": sys.argv[1:]}) + "\\n")
    requirement = sys.argv[sys.argv.index("--test-requirement") + 1]
    if not requirement.startswith("="):
        try:
            pathlib.Path(requirement).read_bytes()
        except OSError:
            print("invalid requirement specification", file=sys.stderr)
            sys.exit(1)
    sys.exit(1 if os.environ.get("FAKE_INVALID_SIGNATURE") else 0)
if "--extract-certificates" in sys.argv:
    prefix = sys.argv[sys.argv.index("--extract-certificates") + 1]
    value = b"wrong certificate" if os.environ.get("FAKE_WRONG_CERTIFICATE") else b"fixture Developer ID certificate"
    pathlib.Path(prefix + "0").write_bytes(value)
    sys.exit(0)
if "--xml" not in sys.argv:
    print("[Dict]\\n[Key] keychain-access-groups [Value] [Array]")
    sys.exit(0)
values = plistlib.loads(pathlib.Path(os.environ["FAKE_ENTITLEMENTS_PATH"]).read_bytes())
if os.environ.get("FAKE_DROP_KEYCHAIN"):
    values.pop("keychain-access-groups", None)
if os.environ.get("FAKE_EXTRA_GROUP"):
    values["keychain-access-groups"].append("9VM4RM39R3.unrelated")
sys.stdout.buffer.write(plistlib.dumps(values))
"""


class ProvisioningTests(FakeToolTestCase):
    def setUp(self) -> None:
        super().setUp()
        write_executable(self.bin / "security", FAKE_CMS)
        write_executable(self.bin / "codesign", FAKE_SIGNATURE)
        self.app = self.root / "AnyDoor.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/AnyDoor").write_bytes(b"fixture executable")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": BUNDLE}))
        self.profile = self.root / "AnyDoor.provisionprofile"
        self.entitlements = self.root / "signing.entitlements"
        self.command = RELEASE_DIR / "provisioning.py"
        self.values = profile_fixture()
        self.write_profile()

    def write_profile(self) -> None:
        self.profile.write_bytes(plistlib.dumps(self.values))

    def provision(
        self, command: str = "prepare", *, umask: int = -1, config: Path | None = None, **environment: str,
    ) -> subprocess.CompletedProcess[str]:
        configuration = ["--config", str(config)] if config is not None else []
        return subprocess.run(
            [sys.executable, str(self.command), command,
             "--app", str(self.app), "--profile", str(self.profile), "--identity", IDENTITY,
             "--entitlements", str(self.entitlements), *configuration],
            env=self.environment(FAKE_ENTITLEMENTS_PATH=str(self.entitlements), **environment),
            capture_output=True, text=True, umask=umask,
        )

    def provision_at(self, now: datetime, command: str = "prepare") -> subprocess.CompletedProcess[str]:
        arguments = [command, "--app", str(self.app), "--profile", str(self.profile),
                     "--identity", IDENTITY, "--entitlements", str(self.entitlements)]
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, self.environment(FAKE_ENTITLEMENTS_PATH=str(self.entitlements)), clear=True), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = provisioning.main(arguments, now=now)
        return subprocess.CompletedProcess(arguments, result, stdout.getvalue(), stderr.getvalue())

    def test_release_configuration_drift_fails_before_preparation_changes_the_app(self) -> None:
        configuration = self.root / "release.conf"
        embedded = self.app / "Contents/embedded.provisionprofile"
        for key, value in [
            ("APPLE_TEAM_ID", "FIXTURE123"),
            ("BUNDLE_ID", "dev.bybee.AnyDoorAlternate"),
            ("CLIPBOARD_SYNC_CONTAINER_ID", "iCloud.dev.bybee.AnyDoorAlternate"),
            ("CLIPBOARD_SYNC_ENVIRONMENT", "Development"),
        ]:
            with self.subTest(key=key):
                values = release_conf.load()
                values[key] = value
                configuration.write_text("".join(f"{name}={setting}\n" for name, setting in values.items()))
                # This profile and artifact authorize the edited release configuration;
                # only disagreement with the actual Swift runtime should reject them.
                self.values = profile_fixture()
                self.values["TeamIdentifier"] = [values["APPLE_TEAM_ID"]]
                group = f'{values["APPLE_TEAM_ID"]}.{values["BUNDLE_ID"]}'
                self.values["Entitlements"].update({
                    "com.apple.application-identifier": group,
                    "com.apple.developer.team-identifier": values["APPLE_TEAM_ID"],
                    "com.apple.developer.icloud-container-identifiers": [values["CLIPBOARD_SYNC_CONTAINER_ID"]],
                    "com.apple.developer.icloud-container-environment": values["CLIPBOARD_SYNC_ENVIRONMENT"],
                    "keychain-access-groups": [group],
                })
                self.write_profile()
                (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": values["BUNDLE_ID"]}))
                embedded.write_bytes(b"previous profile")
                self.entitlements.write_bytes(b"previous entitlements")

                result = self.provision(config=configuration)

                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("ClipboardSyncNativeConfiguration", result.stderr)
                self.assertIn("release.conf", result.stderr)
                self.assertEqual(embedded.read_bytes(), b"previous profile")
                self.assertEqual(self.entitlements.read_bytes(), b"previous entitlements")
                self.assertEqual(self.recorded(), [])

    def test_runtime_declarations_must_be_unique_literals_in_the_configuration_type(self) -> None:
        checkout = self.root / "source checkout"
        release_directory = checkout / "scripts/release"
        release_directory.mkdir(parents=True)
        for name in ("provisioning.py", "release_conf.py", "release.conf"):
            shutil.copyfile(RELEASE_DIR / name, release_directory / name)
        runtime_relative = Path("Sources/ClipboardHistory/ClipboardHistorySyncKeychain.swift")
        runtime = checkout / runtime_relative
        runtime.parent.mkdir(parents=True)
        source = (RELEASE_DIR.parents[1] / runtime_relative).read_text()
        runtime.write_text(source)
        resources = checkout / "Resources"
        resources.mkdir()
        shutil.copyfile(RELEASE_DIR.parents[1] / "Resources/AnyDoor.entitlements", resources / "AnyDoor.entitlements")
        self.command = release_directory / "provisioning.py"
        # The unmodified production declarations pass through the copied real command.
        accepted = self.provision()
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        embedded = self.app / "Contents/embedded.provisionprofile"
        approved_profile, approved_entitlements = embedded.read_bytes(), self.entitlements.read_bytes()
        declaration = next(line for line in source.splitlines() if "static let team =" in line)
        for reason, replacement in [
            ("missing", source.replace(declaration, "")),
            ("duplicate", source.replace(declaration, f"{declaration}\n{declaration}")),
            ("expression", source.replace(declaration, declaration + ' + ""')),
            ("outside type", source.replace(declaration, "") + f"\nenum Unrelated {{\n{declaration}\n}}\n"),
            ("nested type", source.replace(declaration, f"    enum Nested {{\n{declaration}\n    }}")),
            ("comment", source.replace(declaration, "// " + declaration)),
            ("nested block comment", source.replace(declaration,
                '    static var team: String { "OTHERTEAM" }\n    /* outer /* inner */\n' + declaration + '\n    */')),
            ("multiline string", source.replace(declaration,
                '    static var team: String { "OTHERTEAM" }\n    static let decoy = """\n' + declaration + '\n    """')),
            ("raw multiline string", source.replace(declaration,
                '    static var team: String { "OTHERTEAM" }\n    static let decoy = #"""\n' + declaration + '\n    """#')),
            ("inactive conditional declaration", source.replace(declaration,
                '#if NEVER_DEFINED\n' + declaration + '\n#else\n    static var team: String { "OTHERTEAM" }\n#endif')),
            ("duplicate after method", source.replace("    static func validate", declaration + "\n    static func validate")),
            ("duplicate type", source + "\nenum ClipboardSyncNativeConfiguration {}\n"),
        ]:
            with self.subTest(reason=reason):
                runtime.write_text(replacement)

                result = self.provision()

                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("ClipboardSyncNativeConfiguration", result.stderr)
                self.assertEqual(embedded.read_bytes(), approved_profile)
                self.assertEqual(self.entitlements.read_bytes(), approved_entitlements)
                self.assertEqual(self.recorded(), [])

    def test_validation_and_final_verification_reject_runtime_drift_before_external_inspection(self) -> None:
        self.assertEqual(self.provision().returncode, 0)
        configuration = self.root / "release.conf"
        values = release_conf.load()
        values["CLIPBOARD_SYNC_CONTAINER_ID"] += ".changed"
        configuration.write_text("".join(f"{name}={setting}\n" for name, setting in values.items()))
        for command in ("validate", "verify"):
            with self.subTest(command=command):
                result = self.provision(command, config=configuration, FAKE_CMS_FAILURE="1")

                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("release.conf disagrees with ClipboardSyncNativeConfiguration", result.stderr)
                self.assertEqual(self.recorded(), [])

    def test_preparation_requires_thirty_days_of_profile_validity_before_writing(self) -> None:
        now = datetime(2030, 1, 1, tzinfo=timezone.utc)
        embedded = self.app / "Contents/embedded.provisionprofile"
        for expiry, accepted in [
            (datetime(2030, 1, 30, 23, 59, 59), False),
            (datetime(2030, 1, 31), True),
            (datetime(2030, 1, 31, 0, 0, 1), True),
        ]:
            with self.subTest(expiry=expiry):
                self.values["ExpirationDate"] = expiry
                self.write_profile()
                embedded.write_bytes(b"previous profile")
                self.entitlements.write_bytes(b"previous entitlements")

                result = self.provision_at(now)

                self.assertEqual(result.returncode, 0 if accepted else 1, result.stdout + result.stderr)
                if accepted:
                    self.assertEqual(embedded.read_bytes(), self.profile.read_bytes())
                    self.assertIn("keychain-access-groups", plistlib.loads(self.entitlements.read_bytes()))
                else:
                    self.assertIn("at least 30 days", result.stderr)
                    self.assertEqual(embedded.read_bytes(), b"previous profile")
                    self.assertEqual(self.entitlements.read_bytes(), b"previous entitlements")

    def test_validation_and_final_verification_recheck_remaining_profile_validity(self) -> None:
        now = datetime(2030, 1, 1, tzinfo=timezone.utc)
        self.values["ExpirationDate"] = datetime(2030, 1, 31)
        self.write_profile()
        self.assertEqual(self.provision_at(now).returncode, 0)
        embedded = self.app / "Contents/embedded.provisionprofile"
        approved_profile, approved_entitlements = embedded.read_bytes(), self.entitlements.read_bytes()
        for command in ("validate", "verify"):
            with self.subTest(command=command):
                accepted = self.provision_at(now, command)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                signature_checks = self.recorded("codesign")

                rejected = self.provision_at(datetime(2030, 1, 1, 0, 0, 1, tzinfo=timezone.utc), command)

                self.assertEqual(rejected.returncode, 1, rejected.stdout + rejected.stderr)
                self.assertIn("at least 30 days", rejected.stderr)
                self.assertEqual(self.recorded("codesign"), signature_checks)
                self.assertEqual(embedded.read_bytes(), approved_profile)
                self.assertEqual(self.entitlements.read_bytes(), approved_entitlements)

    def test_authorized_profile_embeds_exact_bytes_and_concrete_capabilities(self) -> None:
        result = self.provision()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "Contents/embedded.provisionprofile").read_bytes(), self.profile.read_bytes())
        entitlements = plistlib.loads(self.entitlements.read_bytes())
        self.assertEqual(entitlements, {
            "com.apple.security.automation.apple-events": True,
            "com.apple.application-identifier": GROUP,
            "com.apple.developer.team-identifier": TEAM,
            "com.apple.developer.icloud-container-identifiers": [CONTAINER],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-environment": "Production",
            "keychain-access-groups": [GROUP],
        })
        self.assertNotIn("$", self.entitlements.read_text())
        self.assertNotIn("*", self.entitlements.read_text())
        self.assertNotIn("certificate", result.stdout)

    def test_embedded_profile_is_readable_by_other_users_under_a_private_umask(self) -> None:
        self.profile.chmod(0o600)

        result = self.provision(umask=0o077)

        self.assertEqual(result.returncode, 0, result.stderr)
        embedded = self.app / "Contents/embedded.provisionprofile"
        self.assertEqual(embedded.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.profile.stat().st_mode & 0o777, 0o600)

    def test_apple_wildcard_service_grant_emits_only_concrete_cloudkit(self) -> None:
        self.values["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        self.write_profile()

        result = self.provision()

        self.assertEqual(result.returncode, 0, result.stderr)
        entitlements = plistlib.loads(self.entitlements.read_bytes())
        self.assertEqual(entitlements["com.apple.developer.icloud-services"], ["CloudKit"])

    def test_malformed_service_grants_are_not_treated_as_wildcard_authorization(self) -> None:
        for services in ("CloudKit", "Cloud*", " * ", ["*"], True, {"CloudKit": True}, ["CloudKit", True]):
            with self.subTest(services=services):
                self.values["Entitlements"]["com.apple.developer.icloud-services"] = services
                self.write_profile()

                result = self.provision()

                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("does not authorize CloudKit", result.stderr)
                self.assertFalse(self.entitlements.exists())

    def test_unauthorized_profiles_leave_the_app_and_output_unchanged(self) -> None:
        cases = [
            ("ExpirationDate", datetime(2020, 1, 1), "expired"),
            ("TeamIdentifier", ["OTHERTEAM"], "team"),
            ("ProvisionsAllDevices", False, "Developer ID"),
            ("ProvisionedDevices", ["fixture-device"], "Developer ID"),
            ("Platform", ["iOS"], "macOS"),
            ("DeveloperCertificates", [b"different certificate"], "signing certificate"),
            ("entitlement:com.apple.application-identifier", f"{TEAM}.*", "explicit"),
            ("entitlement:com.apple.developer.team-identifier", "OTHERTEAM", "team"),
            ("entitlement:com.apple.developer.icloud-container-identifiers", ["iCloud.other"], "container"),
            ("entitlement:com.apple.developer.icloud-services", [], "CloudKit"),
            ("entitlement:com.apple.developer.icloud-container-environment", "Development", "Production"),
            ("entitlement:keychain-access-groups", ["OTHERTEAM.*"], "Keychain"),
            ("entitlement:com.apple.security.get-task-allow", True, "debugging"),
        ]
        for field, value, message in cases:
            with self.subTest(field=field):
                self.values = profile_fixture()
                if field.startswith("entitlement:"):
                    self.values["Entitlements"][field.removeprefix("entitlement:")] = value
                else:
                    self.values[field] = value
                self.write_profile()
                embedded = self.app / "Contents/embedded.provisionprofile"
                embedded.write_bytes(b"previous profile")
                self.entitlements.write_bytes(b"previous entitlements")

                result = self.provision()

                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(embedded.read_bytes(), b"previous profile")
                self.assertEqual(self.entitlements.read_bytes(), b"previous entitlements")

    def test_profile_cannot_write_through_an_artifact_symlink(self) -> None:
        victim = self.root / "unrelated-file"
        victim.write_bytes(b"keep this")
        (self.app / "Contents/embedded.provisionprofile").symlink_to(victim)

        result = self.provision()

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("symlink", result.stderr)
        self.assertEqual(victim.read_bytes(), b"keep this")
        self.assertFalse(self.entitlements.exists())

    def test_matching_signed_app_passes_profile_and_capability_verification(self) -> None:
        self.assertEqual(self.provision().returncode, 0)

        result = self.provision("verify")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified", result.stdout)
        checks = self.recorded("codesign")
        self.assertCountEqual([argv[-1] for argv in checks], [str(self.app), str(self.app / "Contents/MacOS/AnyDoor")])
        for argv in checks:
            self.assertIn("--strict", argv)
            requirement = argv[argv.index("--test-requirement") + 1]
            self.assertTrue(requirement.startswith("="), "codesign must receive literal requirement text")
            for clause in (
                f'identifier "{BUNDLE}"', 'anchor apple generic',
                'certificate 1[field.1.2.840.113635.100.6.2.6] exists',
                'certificate leaf[field.1.2.840.113635.100.6.1.13] exists',
                f'certificate leaf[subject.OU] = "{TEAM}"',
            ):
                self.assertIn(clause, requirement)

    def test_signature_must_keep_the_authorized_certificate_and_exact_capabilities(self) -> None:
        self.assertEqual(self.provision().returncode, 0)
        for flag, message in [
            ("FAKE_DROP_KEYCHAIN", "entitlements"),
            ("FAKE_EXTRA_GROUP", "entitlements"),
            ("FAKE_WRONG_CERTIFICATE", "certificate"),
            ("FAKE_INVALID_SIGNATURE", "signature"),
        ]:
            with self.subTest(flag=flag):
                result = self.provision("verify", **{flag: "1"})
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)

    def test_embedded_profile_cannot_be_substituted_after_preparation(self) -> None:
        self.assertEqual(self.provision().returncode, 0)
        (self.app / "Contents/embedded.provisionprofile").write_bytes(b"replacement profile")

        result = self.provision("verify")

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("embedded profile", result.stderr)

    def test_profile_can_be_validated_without_preparing_or_signing_an_app(self) -> None:
        result = subprocess.run(
            [sys.executable, str(RELEASE_DIR / "provisioning.py"), "validate",
             "--profile", str(self.profile), "--identity", IDENTITY],
            env=self.environment(), capture_output=True, text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validated", result.stdout)
        self.assertFalse(self.entitlements.exists())
        self.assertFalse((self.app / "Contents/embedded.provisionprofile").exists())

    def test_malformed_profile_fails_without_a_traceback_or_partial_output(self) -> None:
        self.profile.write_bytes(b'<?xml version="1.0"?><plist><dict>')

        result = self.provision()

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid provisioning profile", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.entitlements.exists())


if __name__ == "__main__":
    import unittest
    unittest.main()

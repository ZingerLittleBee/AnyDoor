#!/usr/bin/env python3
"""Prepare the profile and concrete capabilities for Developer ID Clipboard Sync."""

from __future__ import annotations

import argparse
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from xml.parsers.expat import ExpatError

import release_conf

REPO_ROOT = Path(__file__).resolve().parents[2]


class ProvisioningError(Exception):
    """A profile or signature cannot authorize the intended release."""


@dataclass(frozen=True)
class SigningConfiguration:
    team: str
    bundle: str
    container: str
    environment: str

    @property
    def app_identifier(self) -> str:
        return f"{self.team}.{self.bundle}"

    @classmethod
    def load(cls) -> SigningConfiguration:
        return cls(
            team=release_conf.get("APPLE_TEAM_ID"),
            bundle=release_conf.get("BUNDLE_ID"),
            container=release_conf.get("CLIPBOARD_SYNC_CONTAINER_ID"),
            environment=release_conf.get("CLIPBOARD_SYNC_ENVIRONMENT"),
        )

    def entitlements(self) -> dict[str, object]:
        base = read_plist((REPO_ROOT / "Resources/AnyDoor.entitlements").read_bytes(), "base entitlements")
        return {
            **base,
            "com.apple.application-identifier": self.app_identifier,
            "com.apple.developer.team-identifier": self.team,
            "com.apple.developer.icloud-container-identifiers": [self.container],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-environment": self.environment,
            "keychain-access-groups": [self.app_identifier],
        }


def read_plist(data: bytes, description: str) -> dict[str, object]:
    try:
        value = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise ProvisioningError(f"invalid {description}") from error
    if not isinstance(value, dict):
        raise ProvisioningError(f"invalid {description}: expected a dictionary")
    return value


def decode_profile(path: Path) -> dict[str, object]:
    if not path.is_file():
        raise ProvisioningError("provisioning profile does not exist")
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
    if result.returncode:
        raise ProvisioningError("cannot decode the provisioning profile with security cms")
    return read_plist(result.stdout, "provisioning profile")


def validate_profile(profile: dict[str, object], identity: str, configuration: SigningConfiguration) -> None:
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
        raise ProvisioningError("identity must be the signing certificate's SHA-1 fingerprint")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime) or expiry.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ProvisioningError("provisioning profile is expired or has no expiration date")
    if profile.get("TeamIdentifier") != [configuration.team]:
        raise ProvisioningError("profile team does not match release.conf")
    if profile.get("ProvisionsAllDevices") is not True or "ProvisionedDevices" in profile:
        raise ProvisioningError("profile is not a Developer ID distribution profile")
    if profile.get("Platform") != ["OSX"]:
        raise ProvisioningError("profile must authorize macOS")
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not any(
        isinstance(certificate, bytes) and hashlib.sha1(certificate).hexdigest().upper() == identity.upper()
        for certificate in certificates
    ):
        raise ProvisioningError("profile does not authorize the selected signing certificate")
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise ProvisioningError("profile has no entitlement authorization")
    if entitlements.get("com.apple.application-identifier") != configuration.app_identifier:
        raise ProvisioningError("profile must authorize the explicit AnyDoor application identifier")
    if entitlements.get("com.apple.developer.team-identifier") != configuration.team:
        raise ProvisioningError("profile entitlement team does not match release.conf")
    if any(entitlements.get(key) not in (None, False) for key in ("get-task-allow", "com.apple.security.get-task-allow")):
        raise ProvisioningError("profile must not authorize debugging")
    containers = entitlements.get("com.apple.developer.icloud-container-identifiers")
    if not isinstance(containers, list) or configuration.container not in containers:
        raise ProvisioningError("profile does not authorize the Clipboard Sync container")
    services = entitlements.get("com.apple.developer.icloud-services")
    # Apple-issued profiles can use the exact string "*" as the service grant
    # (TN2415). The app signature still claims only the concrete CloudKit service.
    if services != "*" and not (
        isinstance(services, list) and all(isinstance(service, str) for service in services)
        and "CloudKit" in services
    ):
        raise ProvisioningError("profile does not authorize CloudKit")
    environment = entitlements.get("com.apple.developer.icloud-container-environment")
    if environment != configuration.environment and not (
        isinstance(environment, list) and configuration.environment in environment
    ):
        raise ProvisioningError(f"profile does not authorize the {configuration.environment} CloudKit environment")
    groups = entitlements.get("keychain-access-groups")
    if not isinstance(groups, list) or not any(
        group in (configuration.app_identifier, f"{configuration.team}.*") for group in groups
    ):
        raise ProvisioningError("profile does not authorize the Clipboard Sync Keychain access group")


def validate_app(app_path: Path, configuration: SigningConfiguration) -> None:
    for path in (
        app_path, app_path / "Contents", app_path / "Contents/Info.plist",
        app_path / "Contents/embedded.provisionprofile", app_path / "Contents/MacOS",
        app_path / "Contents/MacOS/AnyDoor",
    ):
        if path.is_symlink():
            raise ProvisioningError("app profile path must not contain an artifact symlink")
    app = read_plist((app_path / "Contents/Info.plist").read_bytes(), "app Info.plist")
    if app.get("CFBundleIdentifier") != configuration.bundle:
        raise ProvisioningError("app bundle identifier does not match release.conf")


def prepare(args: argparse.Namespace) -> None:
    configuration = SigningConfiguration.load()
    profile = decode_profile(args.profile)
    validate_profile(profile, args.identity, configuration)
    validate_app(args.app, configuration)
    args.entitlements.write_bytes(plistlib.dumps(configuration.entitlements()))
    embedded = args.app / "Contents/embedded.provisionprofile"
    shutil.copyfile(args.profile, embedded)
    # The distributed app must remain usable by another macOS login user.
    # Keep the temporary input private, but make this bundle resource readable.
    embedded.chmod(0o644)
    print("Prepared Developer ID Clipboard Sync capabilities")


def verify(args: argparse.Namespace) -> None:
    configuration = SigningConfiguration.load()
    validate_app(args.app, configuration)
    embedded = args.app / "Contents/embedded.provisionprofile"
    if not embedded.is_file() or embedded.read_bytes() != args.profile.read_bytes():
        raise ProvisioningError("embedded profile differs from the approved profile")
    validate_profile(decode_profile(embedded), args.identity, configuration)
    expected = configuration.entitlements()
    requirement = (
        f'identifier "{configuration.bundle}" and anchor apple generic '
        'and certificate 1[field.1.2.840.113635.100.6.2.6] exists '
        'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
        f'and certificate leaf[subject.OU] = "{configuration.team}"'
    )
    for target in (args.app / "Contents/MacOS/AnyDoor", args.app):
        checked = subprocess.run(
            ["codesign", "--verify", "--strict", "--test-requirement", requirement, str(target)],
            capture_output=True,
        )
        if checked.returncode:
            raise ProvisioningError("app signature does not satisfy the Developer ID requirement")
        result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(target)], capture_output=True)
        if result.returncode or read_plist(result.stdout, "signed entitlements") != expected:
            raise ProvisioningError("signed entitlements do not match the approved Clipboard Sync capabilities")
        with tempfile.TemporaryDirectory(prefix="anydoor-signing-certificate-") as directory:
            prefix = str(Path(directory) / "certificate")
            result = subprocess.run(
                ["codesign", "-d", "--extract-certificates", prefix, str(target)], capture_output=True,
            )
            leaf = Path(prefix + "0")
            if result.returncode or not leaf.is_file() or hashlib.sha1(leaf.read_bytes()).hexdigest().upper() != args.identity.upper():
                raise ProvisioningError("signed certificate differs from the profile-authorized identity")
    print("Verified Developer ID Clipboard Sync profile and capabilities")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "prepare", "verify"])
    parser.add_argument("--app", type=Path)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--entitlements", type=Path)
    args = parser.parse_args()
    if args.command != "validate" and (args.app is None or args.entitlements is None):
        parser.error("prepare and verify require --app and --entitlements")
    try:
        if args.command == "validate":
            validate_profile(decode_profile(args.profile), args.identity, SigningConfiguration.load())
            print("Validated Developer ID Clipboard Sync profile authorization")
        elif args.command == "prepare":
            prepare(args)
        else:
            verify(args)
    except (ProvisioningError, OSError) as error:
        print(f"Provisioning failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

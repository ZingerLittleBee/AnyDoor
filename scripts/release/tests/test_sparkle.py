"""Behavior checks for the Sparkle appcast pipeline in scripts/release.

Covers sparkle_keys.py, verify_sparkle_signatures.py, seed-feed.sh,
fetch-sparkle-tools.sh, scripts/validate-appcast.py --repository, and an
end-to-end appcast.sh run with the real Sparkle tools (macOS only; set
SPARKLE_TARBALL to a downloaded Sparkle tarball to avoid the network).
"""

from __future__ import annotations

import base64
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import ClassVar

RELEASE_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = RELEASE_DIR.parents[1]
sys.path.insert(0, str(RELEASE_DIR))

import release_conf
import sparkle_keys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

CONF = release_conf.load()
SPARKLE_KEYS = RELEASE_DIR / "sparkle_keys.py"
VERIFY = RELEASE_DIR / "verify_sparkle_signatures.py"
SEED_FEED = RELEASE_DIR / "seed-feed.sh"
FETCH_TOOLS = RELEASE_DIR / "fetch-sparkle-tools.sh"
APPCAST_SH = RELEASE_DIR / "appcast.sh"
VALIDATE_APPCAST = REPO_ROOT / "scripts/validate-appcast.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Release Test",
    "GIT_AUTHOR_EMAIL": "release-test.invalid",
    "GIT_COMMITTER_NAME": "Release Test",
    "GIT_COMMITTER_EMAIL": "release-test.invalid",
}


def run(args: list[str | Path], *, env: dict[str, str] | None = None,
        stdin: str | None = None, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(arg) for arg in args], capture_output=True, text=True,
        env=env, input=stdin, cwd=cwd, check=False,
    )


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def new_key() -> tuple[str, str]:
    """Return (secret, public) in Sparkle's --ed-key-file / SUPublicEDKey formats."""
    pair = sparkle_keys.generate()
    return pair.secret_base64, pair.public_base64


def ed_private(secret: str) -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(base64.b64decode(secret))


def sign_feed(content: bytes, secret: str) -> bytes:
    """Append a signed-feed block exactly as Sparkle's signAppcast writes it
    (.build/checkouts/Sparkle/common_cli/Signing.swift:85-99)."""
    signature = b64(ed_private(secret).sign(content))
    block = f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n"
    return content + block.encode()


def feed_with_enclosure(name: str, data: bytes, secret: str, *, extra: str = "") -> bytes:
    signature = b64(ed_private(secret).sign(data))
    return (
        '<?xml version="1.0" standalone="yes"?>\n'
        f'<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0"><channel><title>AnyDoor</title>'
        "<item><sparkle:version>9.0.99</sparkle:version>"
        f'<enclosure url="https://github.com/o/r/releases/download/v9.0.0/{name}" '
        f'length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>'
        f"</item>{extra}</channel></rss>\n"
    ).encode()


def write_executable(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(0o755)


class TempDirTestCase(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp = Path(directory.name)


class SparkleKeysTests(TempDirTestCase):
    def test_generate_writes_sparkle_seed_format(self) -> None:
        private_out, public_out = self.tmp / "private.key", self.tmp / "public.key"
        result = run([sys.executable, SPARKLE_KEYS, "generate",
                      "--private-out", private_out, "--public-out", public_out])
        self.assertEqual(result.returncode, 0, result.stderr)

        secret_text = private_out.read_text()
        self.assertEqual(secret_text.count("\n"), 1, "one line, as sign_update reads stdin")
        seed = base64.b64decode(secret_text.strip(), validate=True)
        self.assertEqual(len(seed), 32, "new-format keys are the 32-byte private seed")
        self.assertEqual(private_out.stat().st_mode & 0o777, 0o600)

        derived = b64(Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes_raw())
        self.assertEqual(public_out.read_text().strip(), derived)
        self.assertEqual(result.stdout.strip(), derived)

    def test_generate_refuses_to_overwrite(self) -> None:
        private_out = self.tmp / "private.key"
        private_out.write_text("existing\n")
        result = run([sys.executable, SPARKLE_KEYS, "generate",
                      "--private-out", private_out, "--public-out", self.tmp / "public.key"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(private_out.read_text(), "existing\n")

    def test_public_key_from_seed_on_stdin(self) -> None:
        secret, public = new_key()
        result = run([sys.executable, SPARKLE_KEYS, "public-key"], stdin=secret + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), public)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_public_key_from_legacy_96_byte_secret(self) -> None:
        # Legacy keys are the expanded private key followed by the public key
        # (.build/checkouts/Sparkle/common_cli/Secret.swift:39-41).
        public = os.urandom(32)
        result = run([sys.executable, SPARKLE_KEYS, "public-key"],
                     stdin=b64(os.urandom(64) + public) + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), b64(public))

    def test_public_key_rejects_what_sparkle_rejects(self) -> None:
        cases = {
            "wrong length": b64(os.urandom(64)),
            "not base64": "not*base64",
            "empty": "",
            "two lines": new_key()[0] + "\n" + new_key()[0],
        }
        for name, stdin in cases.items():
            with self.subTest(name):
                result = run([sys.executable, SPARKLE_KEYS, "public-key"], stdin=stdin + "\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("sparkle_keys:", result.stderr)


class VerifySignaturesTests(TempDirTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.secret, self.public = new_key()
        self.archive = self.tmp / "AnyDoor-9.0.0.zip"
        self.archive.write_bytes(os.urandom(4096))
        self.appcast = self.tmp / "appcast.xml"

    def write_feed(self, *, signed: bool = True, extra: str = "") -> bytes:
        content = feed_with_enclosure(self.archive.name, self.archive.read_bytes(), self.secret,
                                      extra=extra)
        data = sign_feed(content, self.secret) if signed else content
        self.appcast.write_bytes(data)
        return data

    def verify(self, *extra: str, public: str | None = None) -> subprocess.CompletedProcess[str]:
        return run([sys.executable, VERIFY, "--appcast", self.appcast,
                    "--public-key", public or self.public, *extra])

    def archive_arg(self) -> str:
        return f"{self.archive.name}={self.archive}"

    def test_valid_feed_and_archive_pass(self) -> None:
        self.write_feed()
        result = self.verify("--archive", self.archive_arg(), "--require-feed-signature")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("feed signature verified", result.stdout)

    def test_missing_feed_signature_fails_only_when_required(self) -> None:
        self.write_feed(signed=False)
        self.assertEqual(self.verify("--archive", self.archive_arg()).returncode, 0)
        result = self.verify("--require-feed-signature")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no Sparkle feed signature block", result.stderr)

    def test_feed_modified_after_signing_fails(self) -> None:
        data = self.write_feed()
        self.appcast.write_bytes(data.replace(b"<title>AnyDoor</title>", b"<title>AnyDoer</title>"))
        result = self.verify("--require-feed-signature")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("feed EdDSA signature does not verify", result.stderr)

    def test_unsigned_feed_with_a_present_block_is_still_checked(self) -> None:
        data = self.write_feed()
        self.appcast.write_bytes(b" " + data)
        self.assertNotEqual(self.verify().returncode, 0)

    def test_feed_length_mismatch_fails(self) -> None:
        data = self.write_feed()
        self.appcast.write_bytes(re.sub(rb"length: \d+", b"length: 1", data))
        result = self.verify("--require-feed-signature")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("feed signature length", result.stderr)

    def test_bytes_after_the_block_fail(self) -> None:
        data = self.write_feed()
        self.appcast.write_bytes(data + b"<!-- extra -->\n")
        result = self.verify("--require-feed-signature")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("after the feed signature block", result.stderr)

    def test_wrong_public_key_fails(self) -> None:
        self.write_feed()
        _, other_public = new_key()
        result = self.verify("--archive", self.archive_arg(), public=other_public)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not verify", result.stderr)

    def test_tampered_archive_fails(self) -> None:
        self.write_feed()
        data = bytearray(self.archive.read_bytes())
        data[100] ^= 0x01
        self.archive.write_bytes(bytes(data))
        result = self.verify("--archive", self.archive_arg())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AnyDoor-9.0.0.zip: EdDSA signature does not verify", result.stderr)

    def test_archive_length_mismatch_fails(self) -> None:
        self.write_feed()
        with self.archive.open("ab") as handle:
            handle.write(b"x")
        result = self.verify("--archive", self.archive_arg())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("enclosure length", result.stderr)

    def test_archive_without_enclosure_fails(self) -> None:
        self.write_feed()
        result = self.verify("--archive", f"AnyDoor-9.9.9.zip={self.archive}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected one enclosure for AnyDoor-9.9.9.zip, found 0", result.stderr)

    def test_duplicate_enclosures_fail(self) -> None:
        duplicate = (
            f'<item><sparkle:version>9.0.98</sparkle:version><enclosure '
            f'url="https://example.invalid/{self.archive.name}" length="1"/></item>'
        )
        self.write_feed(extra=duplicate)
        result = self.verify("--archive", self.archive_arg())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 2", result.stderr)

    def test_bad_arguments_are_rejected(self) -> None:
        self.write_feed()
        self.assertEqual(self.verify("--archive", "no-separator").returncode, 2)
        self.assertNotEqual(self.verify(public=b64(b"short")).returncode, 0)


class ValidateAppcastRepositoryTests(TempDirTestCase):
    def write_feed(self, repository: str) -> Path:
        appcast = self.tmp / "appcast.xml"
        appcast.write_text(
            f'<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0"><channel><item>'
            "<title>9.0.0</title><sparkle:version>9.0.99</sparkle:version>"
            "<sparkle:shortVersionString>9.0.0</sparkle:shortVersionString>"
            f'<enclosure url="https://github.com/{repository}/releases/download/v9.0.0/'
            'AnyDoor-9.0.0.zip" sparkle:edSignature="c2ln"/>'
            "</item></channel></rss>\n"
        )
        return appcast

    def validate(self, appcast: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return run([sys.executable, VALIDATE_APPCAST, "--appcast", appcast,
                    "--release-id", "9.0.0", "--channel", "stable",
                    "--short-version", "9.0.0", "--build-version", "9.0.99",
                    "--display-version", "9.0.0", *extra])

    def test_default_repository_is_unchanged(self) -> None:
        result = self.validate(self.write_feed("ZingerLittleBee/AnyDoor"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_fork_repository(self) -> None:
        appcast = self.write_feed("someone/AnyDoor-fork")
        self.assertNotEqual(self.validate(appcast).returncode, 0)
        result = self.validate(appcast, "--repository", "someone/AnyDoor-fork")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_repository_is_rejected(self) -> None:
        appcast = self.write_feed("ZingerLittleBee/AnyDoor")
        self.assertEqual(self.validate(appcast, "--repository", "../x").returncode, 2)


# seed-feed.sh runs the verifier through `uv run` in a copied project pointed at
# this interpreter's environment; never let uv sync into a system Python.
@unittest.skipUnless(sys.prefix != sys.base_prefix and shutil.which("uv"),
                     "run under `uv run --project scripts/release` (needs its virtual environment)")
class SeedFeedTests(TempDirTestCase):
    """seed-feed.sh in a throwaway repo, with fake gh and curl on PATH."""

    ARCHIVE_URL = "https://github.com/ZingerLittleBee/AnyDoor/releases/download/v4.2.7/AnyDoor-4.2.7.zip"
    ARCHIVE = b"AnyDoor 4.2.7 update archive"

    def feed(self, url: str = ARCHIVE_URL, data: bytes = ARCHIVE) -> bytes:
        signature = b64(ed_private(self.secret).sign(data))
        return (
            f'<?xml version="1.0" standalone="yes"?>\n<rss xmlns:sparkle="{SPARKLE_NS}" '
            'version="2.0"><channel><title>AnyDoor</title><item><title>4.2.7</title>'
            "<sparkle:version>4.2.799</sparkle:version>"
            f'<enclosure url="{url}" length="{len(data)}" type="application/octet-stream" '
            f'sparkle:edSignature="{signature}"/></item></channel></rss>\n'
        ).encode()

    def setUp(self) -> None:
        super().setUp()
        self.secret, self.public = new_key()
        self.unsigned = self.feed()
        self.signed = sign_feed(self.unsigned, self.secret)

        self.repo = self.tmp / "repo"
        self.release = self.repo / "scripts/release"
        self.release.mkdir(parents=True)
        for name in ("lib.sh", "release.conf", "seed-feed.sh", "verify_sparkle_signatures.py",
                     "pyproject.toml", "uv.lock"):
            shutil.copy2(RELEASE_DIR / name, self.release / name)
        # Each test names the legacy tag it needs, independent of release.conf.
        self.set_legacy_tag("")
        # The first migration seeds from git: the old flow's unsigned feed.
        (self.repo / "appcast.xml").write_bytes(self.unsigned)
        (self.repo / "Info.plist").write_bytes(plistlib.dumps({"SUPublicEDKey": self.public}))
        for args in (["init", "-q"], ["add", "appcast.xml"], ["commit", "-q", "-m", "seed"]):
            subprocess.run(["git", *args], cwd=self.repo, env=GIT_ENV, check=True)
        self.script = self.release / "seed-feed.sh"

        self.asset = self.tmp / "asset.xml"
        self.asset.write_bytes(self.signed)
        self.live = self.tmp / "live.xml"
        self.live.write_bytes(self.signed)
        self.downloads = self.tmp / "downloads"
        self.downloads.mkdir()
        (self.downloads / "AnyDoor-4.2.7.zip").write_bytes(self.ARCHIVE)
        self.calls = self.tmp / "calls.log"

        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        write_executable(bin_dir / "gh", """#!/bin/bash
printf 'gh %s\\n' "$*" >> "$FAKE_CALLS"
case "$1 $2" in
  "release view")
    [[ -z "${FAKE_VIEW_EXIT:-}" ]] || { echo "release not found" >&2; exit "$FAKE_VIEW_EXIT"; }
    case "$*" in
      *isDraft*) echo "${FAKE_DRAFT:-false}" ;;
      *isImmutable*) echo "${FAKE_IMMUTABLE:-false}" ;;
    esac ;;
  "release download")
    [[ -n "${FAKE_ASSET:-}" ]] || { echo "no assets match the file pattern" >&2; exit 1; }
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --dir ]]; then cp "$FAKE_ASSET" "$2/appcast.xml"; fi
      shift
    done ;;
  "release verify-asset") exit "${FAKE_VERIFY_EXIT:-0}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 64 ;;
esac
""")
        # The live feed URL serves FAKE_LIVE; Release downloads serve files
        # from FAKE_DOWNLOADS by basename.
        write_executable(bin_dir / "curl", """#!/bin/bash
printf 'curl %s\\n' "$*" >> "$FAKE_CALLS"
url="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
if [[ "$url" == "$FAKE_FEED_URL" ]]; then
  [[ -n "${FAKE_LIVE:-}" ]] || { echo "curl: (6) Could not resolve host" >&2; exit 6; }
  cp "$FAKE_LIVE" "$out"
elif [[ -f "$FAKE_DOWNLOADS/${url##*/}" ]]; then
  cp "$FAKE_DOWNLOADS/${url##*/}" "$out"
else
  echo "curl: (22) The requested URL returned error: 404" >&2; exit 22
fi
""")
        self.env = {
            **GIT_ENV,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_CALLS": str(self.calls),
            "FAKE_ASSET": str(self.asset),
            "FAKE_LIVE": str(self.live),
            "FAKE_FEED_URL": CONF["FEED_URL"],
            "FAKE_DOWNLOADS": str(self.downloads),
            # The copied project resolves to the environment running these
            # tests, which the lockfile already describes: no network needed.
            "UV_PROJECT_ENVIRONMENT": sys.prefix,
            "UV_OFFLINE": "1",
        }
        self.out = self.tmp / "out/appcast.xml"

    def seed(self, *args: str, public_key: str | None = "", **env: str) -> subprocess.CompletedProcess[str]:
        key_args = [] if public_key is None else ["--public-key", public_key or self.public]
        return run([self.script, "--out", self.out, *args, *key_args], env={**self.env, **env})

    def set_legacy_tag(self, tag: str) -> None:
        conf = self.release / "release.conf"
        conf.write_text(re.sub(r"(?m)^LEGACY_UNSIGNED_FEED_TAG=.*$", f"LEGACY_UNSIGNED_FEED_TAG={tag}",
                               conf.read_text()))

    def call_log(self) -> str:
        return self.calls.read_text() if self.calls.exists() else ""

    def test_release_seed_equal_to_live_feed(self) -> None:
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.out.read_bytes(), self.asset.read_bytes())
        log = self.call_log()
        self.assertIn("--repo ZingerLittleBee/AnyDoor", log)
        self.assertIn(f"-H Cache-Control: no-cache {CONF['FEED_URL']}", log)
        self.assertNotIn("verify-asset", log, "mutable Releases have no attestation")

    def test_release_mode_rejects_live_mismatch(self) -> None:
        self.live.write_bytes(self.signed.replace(b"AnyDoor<", b"Changed<"))
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the live feed", result.stderr)
        self.assertFalse(self.out.exists())

    def test_rehearsal_mode_warns_on_live_mismatch(self) -> None:
        self.live.write_bytes(self.signed.replace(b"AnyDoor<", b"Changed<"))
        result = self.seed("--mode", "rehearsal", "--previous-tag", "v4.2.7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning: seed", result.stderr)
        self.assertEqual(self.out.read_bytes(), self.asset.read_bytes())

    def test_immutable_release_asset_is_attested(self) -> None:
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7", FAKE_IMMUTABLE="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("gh release verify-asset v4.2.7", self.call_log())

        failed = self.seed("--mode", "release", "--previous-tag", "v4.2.7",
                           FAKE_IMMUTABLE="true", FAKE_VERIFY_EXIT="1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("attestation", failed.stderr)

    def test_draft_previous_release_is_rejected(self) -> None:
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7", FAKE_DRAFT="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not published", result.stderr)

    def test_release_mode_requires_the_asset(self) -> None:
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7", FAKE_ASSET="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot download appcast.xml", result.stderr)

    def test_rehearsal_falls_back_to_live_feed_without_asset(self) -> None:
        result = self.seed("--mode", "rehearsal", "--previous-tag", "v4.2.7", FAKE_ASSET="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.out.read_bytes(), self.live.read_bytes())
        self.assertIn("live feed as seed", result.stderr)

    def test_unviewable_release_fails_release_mode_only(self) -> None:
        failed = self.seed("--mode", "release", "--previous-tag", "v4.2.7", FAKE_VIEW_EXIT="1")
        self.assertNotEqual(failed.returncode, 0)
        rehearsal = self.seed("--mode", "rehearsal", "--previous-tag", "v4.2.7", FAKE_VIEW_EXIT="1")
        self.assertEqual(rehearsal.returncode, 0, rehearsal.stderr)
        self.assertEqual(self.out.read_bytes(), self.live.read_bytes())

    def test_from_git_seed_still_requires_live_equality(self) -> None:
        self.live.write_bytes(self.unsigned)
        result = self.seed("--mode", "release", "--from-git", "HEAD", FAKE_ASSET="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.out.read_bytes(), self.unsigned)
        self.assertNotIn("gh ", self.call_log())
        self.assertIn(self.ARCHIVE_URL, self.call_log(), "an unsigned seed's enclosures are verified")

        self.live.write_bytes(self.unsigned.replace(b"4.2.799", b"4.2.899"))
        self.assertNotEqual(self.seed("--mode", "release", "--from-git", "HEAD").returncode, 0)

    def test_release_mode_needs_the_live_feed(self) -> None:
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7", FAKE_LIVE="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot fetch the live feed", result.stderr)

    def test_unparsable_seed_is_rejected(self) -> None:
        self.asset.write_text("<rss><channel>")
        self.live.write_text("<rss><channel>")
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a usable appcast", result.stderr)

    def test_signed_seed_must_verify_with_the_pinned_key(self) -> None:
        _, other_public = new_key()
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7", public_key=other_public)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("feed signature does not verify", result.stderr)
        self.assertFalse(self.out.exists())

        rehearsal = self.seed("--mode", "rehearsal", "--previous-tag", "v4.2.7", public_key=other_public)
        self.assertEqual(rehearsal.returncode, 0, rehearsal.stderr)
        self.assertIn("warning: the seed's", rehearsal.stderr)

    def test_tampered_signed_seed_is_rejected_even_when_live_matches(self) -> None:
        # Someone with write access replaced both the asset and the live feed.
        tampered = self.signed.replace(b"<title>4.2.7</title>", b"<title>4.2.7 (see evil.example)</title>")
        self.asset.write_bytes(tampered)
        self.live.write_bytes(tampered)
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("feed signature does not verify", result.stderr)

    def test_unsigned_seed_needs_the_legacy_tag(self) -> None:
        self.asset.write_bytes(self.unsigned)
        self.live.write_bytes(self.unsigned)
        result = self.seed("--mode", "release", "--previous-tag", "v4.2.7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no Sparkle feed signature", result.stderr)
        self.assertNotIn(self.ARCHIVE_URL, self.call_log())

        self.set_legacy_tag("v4.2.6")
        self.assertNotEqual(self.seed("--mode", "release", "--previous-tag", "v4.2.7").returncode, 0)

        self.set_legacy_tag("v4.2.7")
        migrated = self.seed("--mode", "release", "--previous-tag", "v4.2.7")
        self.assertEqual(migrated.returncode, 0, migrated.stderr)
        self.assertEqual(self.out.read_bytes(), self.unsigned)
        self.assertIn(self.ARCHIVE_URL, self.call_log())

    def test_unsigned_legacy_seed_enclosures_must_verify(self) -> None:
        self.set_legacy_tag("v4.2.7")
        self.asset.write_bytes(self.unsigned)
        self.live.write_bytes(self.unsigned)
        cases = {
            "tampered archive": lambda: (self.downloads / "AnyDoor-4.2.7.zip").write_bytes(b"tampered"),
            "missing archive": lambda: (self.downloads / "AnyDoor-4.2.7.zip").unlink(),
        }
        for name, damage in cases.items():
            with self.subTest(name):
                (self.downloads / "AnyDoor-4.2.7.zip").write_bytes(self.ARCHIVE)
                damage()
                result = self.seed("--mode", "release", "--previous-tag", "v4.2.7")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("failed verification", result.stderr)

        with self.subTest("enclosure outside the repository"):
            (self.downloads / "AnyDoor-4.2.7.zip").write_bytes(self.ARCHIVE)
            foreign = self.feed(url="https://example.invalid/AnyDoor-4.2.7.zip")
            self.asset.write_bytes(foreign)
            self.live.write_bytes(foreign)
            result = self.seed("--mode", "release", "--previous-tag", "v4.2.7")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("is not a ZingerLittleBee/AnyDoor Release download", result.stderr)

    def test_rehearsal_reads_the_key_from_info_plist(self) -> None:
        result = self.seed("--mode", "rehearsal", "--previous-tag", "v4.2.7", public_key=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("feed signature verifies", result.stderr)
        self.assertNotIn("warning", result.stderr)

    def test_argument_validation(self) -> None:
        cases = {
            "missing source": ["--mode", "release"],
            "bad mode": ["--mode", "ship", "--previous-tag", "v4.2.7"],
            "two sources": ["--mode", "release", "--previous-tag", "v4.2.7", "--from-git", "HEAD"],
            "bad tag": ["--mode", "release", "--previous-tag", "4.2.7"],
            "option as revision": ["--mode", "release", "--from-git", "--output=x"],
            "bad repository": ["--mode", "release", "--previous-tag", "v4.2.7",
                               "--repository", "a/b/c"],
        }
        for name, args in cases.items():
            with self.subTest(name):
                self.assertNotEqual(self.seed(*args).returncode, 0)
        no_key = self.seed("--mode", "release", "--previous-tag", "v4.2.7", public_key=None)
        self.assertNotEqual(no_key.returncode, 0)
        self.assertIn("release mode needs --public-key", no_key.stderr)
        self.assertEqual(run([self.script, "--help"]).returncode, 0)


class FetchSparkleToolsTests(TempDirTestCase):
    def test_checksum_mismatch_is_fatal(self) -> None:
        bogus = self.tmp / "Sparkle.tar.xz"
        bogus.write_bytes(b"not the release tarball")
        result = run([FETCH_TOOLS, "--dest", self.tmp / "tools", "--tarball", bogus])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stderr)
        self.assertFalse((self.tmp / "tools/sign_update").exists())

    def test_package_resolved_pin_must_match(self) -> None:
        release = self.tmp / "scripts/release"
        release.mkdir(parents=True)
        for name in ("lib.sh", "release.conf", "fetch-sparkle-tools.sh"):
            shutil.copy2(RELEASE_DIR / name, release / name)
        (self.tmp / "Package.resolved").write_text(
            '{"pins": [{"identity": "sparkle", "state": {"version": "2.0.0"}}], "version": 3}'
        )
        result = run([release / "fetch-sparkle-tools.sh", "--dest", self.tmp / "tools"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match Package.resolved", result.stderr)

    def test_arguments(self) -> None:
        self.assertNotEqual(run([FETCH_TOOLS]).returncode, 0)
        self.assertEqual(run([FETCH_TOOLS, "--help"]).returncode, 0)


@unittest.skipUnless(sys.platform == "darwin", "Sparkle's tools are macOS binaries")
@unittest.skipUnless(shutil.which("uv") and shutil.which("ditto"), "needs uv and ditto")
class AppcastRoundTripTests(unittest.TestCase):
    """appcast.sh against the real Sparkle 2.9.2 generate_appcast and sign_update."""

    tools: ClassVar[Path]
    _tools_dir: ClassVar[tempfile.TemporaryDirectory[str]]

    @classmethod
    def setUpClass(cls) -> None:
        cls._tools_dir = tempfile.TemporaryDirectory()
        cls.tools = Path(cls._tools_dir.name) / "tools"
        args: list[str | Path] = [FETCH_TOOLS, "--dest", cls.tools]
        if os.environ.get("SPARKLE_TARBALL"):
            args += ["--tarball", os.environ["SPARKLE_TARBALL"]]
        result = run(args)
        if result.returncode != 0:
            cls._tools_dir.cleanup()
            raise unittest.SkipTest(f"cannot fetch Sparkle tools (offline?): {result.stderr.strip()}")

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tools_dir.cleanup()

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp = Path(directory.name)
        self.secret, self.public = new_key()
        self.notes = self.tmp / "notes.md"
        self.notes.write_text("### Fixed\n\n- Round-trip test.\n")
        # The old local flow's last feed, byte-identical to the live feed it
        # published: the real seed of the first pipeline release.
        self.seed = FIXTURES / "appcast-v4.2.7.xml"
        self.out = self.tmp / "out/appcast.xml"

    def make_zip(self, version: str, short: str, build: str, *, public: str | None = None) -> Path:
        """A minimal but real app bundle: generate_appcast reads its Info.plist."""
        app = self.tmp / "bundle" / version / f"{CONF['APP_NAME']}.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        info = plistlib.loads((REPO_ROOT / "Info.plist").read_bytes())
        info.update(CFBundleShortVersionString=short, CFBundleVersion=build,
                    SUPublicEDKey=public or self.public)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        write_executable(app / "Contents/MacOS" / str(info["CFBundleExecutable"]), "#!/bin/sh\n")
        archive = self.tmp / f"{CONF['APP_NAME']}-{version}.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
        return archive

    def appcast(self, zip_path: Path, tag: str, *extra: str, public: str | None = None,
                secret: str | None = None) -> subprocess.CompletedProcess[str]:
        return run(
            [APPCAST_SH, "--seed", self.seed, "--zip", zip_path, "--notes", self.notes,
             "--tools", self.tools, "--tag", tag, "--public-key", public or self.public,
             "--out", self.out, *extra],
            env={**os.environ, "SPARKLE_ED_PRIVATE_KEY": secret or self.secret},
        )

    def verify(self, *args: str, public: str | None = None) -> subprocess.CompletedProcess[str]:
        return run([sys.executable, VERIFY, "--appcast", self.out,
                    "--public-key", public or self.public, *args])

    def test_stable_round_trip_and_negative_checks(self) -> None:
        archive = self.make_zip("99.0.0", "99.0.0", "99.0.99")
        # Secrets saved from a key file keep its trailing newline.
        result = self.appcast(archive, "v99.0.0", secret=self.secret + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(self.secret, result.stdout + result.stderr)

        feed = self.out.read_text()
        self.assertIn("<sparkle:version>99.0.99</sparkle:version>", feed)
        self.assertIn(
            "https://github.com/ZingerLittleBee/AnyDoor/releases/download/v99.0.0/AnyDoor-99.0.0.zip",
            feed,
        )
        self.assertTrue(feed.endswith("-->\n"))
        archive_arg = f"{archive.name}={archive}"
        ok = self.verify("--archive", archive_arg, "--require-feed-signature")
        self.assertEqual(ok.returncode, 0, ok.stderr)

        # Sparkle's own verifier agrees with ours about the signed feed.
        sparkle_check = run([self.tools / "sign_update", "--ed-key-file", "-", "--verify", self.out],
                            stdin=self.secret + "\n", cwd=self.tmp)
        self.assertEqual(sparkle_check.returncode, 0, sparkle_check.stdout + sparkle_check.stderr)

        with self.subTest("wrong public key"):
            _, other_public = new_key()
            self.assertNotEqual(self.verify("--archive", archive_arg, public=other_public).returncode, 0)

        with self.subTest("missing feed signature"):
            signed = self.out.read_bytes()
            self.out.write_bytes(signed[: signed.rfind(b"<!-- sparkle-signatures:\n")])
            missing = self.verify("--require-feed-signature")
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("no Sparkle feed signature block", missing.stderr)
            self.out.write_bytes(signed)

        with self.subTest("tampered zip byte"):
            data = bytearray(archive.read_bytes())
            data[len(data) // 2] ^= 0x01
            archive.write_bytes(bytes(data))
            tampered = self.verify("--archive", archive_arg)
            self.assertNotEqual(tampered.returncode, 0)
            self.assertIn("does not verify", tampered.stderr)

    def test_signed_feed_seeds_the_next_release(self) -> None:
        first = self.make_zip("99.0.0", "99.0.0", "99.0.99")
        self.assertEqual(self.appcast(first, "v99.0.0").returncode, 0)
        self.seed = self.tmp / "seed-signed.xml"
        shutil.copy2(self.out, self.seed)

        second = self.make_zip("99.0.1", "99.0.1", "99.0.199")
        result = self.appcast(second, "v99.0.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = self.out.read_bytes()
        self.assertEqual(feed.count(b"<!-- sparkle-signatures:"), 1, "the seed's signature block is replaced")
        self.assertIn(b"<sparkle:version>99.0.99</sparkle:version>", feed)
        self.assertIn(b"<sparkle:version>99.0.199</sparkle:version>", feed)
        verified = self.verify("--archive", f"{second.name}={second}", "--require-feed-signature")
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_beta_with_rollout_and_critical_update(self) -> None:
        archive = self.make_zip("99.0.1-beta.1", "99.0.1", "99.0.101")
        result = self.appcast(archive, "v99.0.1-beta.1",
                              "--phased-rollout-interval", "86400",
                              "--critical-update-version", "*",
                              "--repository", "someone/AnyDoor-fork")
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = self.out.read_text()
        item = feed[: feed.index("</item>")]
        self.assertIn("<sparkle:version>99.0.101</sparkle:version>", item)
        self.assertIn("<sparkle:channel>beta</sparkle:channel>", item)
        self.assertIn("<title>99.0.1 Beta 1</title>", item)
        self.assertIn("<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>", item)
        self.assertIn("<sparkle:criticalUpdate", item)
        self.assertIn("github.com/someone/AnyDoor-fork/releases/download/v99.0.1-beta.1/", item)
        self.assertEqual(self.verify("--archive", f"{archive.name}={archive}",
                                     "--require-feed-signature").returncode, 0)

    def test_secret_must_match_public_key(self) -> None:
        archive = self.make_zip("99.0.0", "99.0.0", "99.0.99")
        other_secret, _ = new_key()
        result = self.appcast(archive, "v99.0.0", secret=other_secret)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match --public-key", result.stderr)
        self.assertNotIn(other_secret, result.stdout + result.stderr)
        self.assertFalse(self.out.exists())

    def test_app_trusting_another_key_fails(self) -> None:
        # generate_appcast only warns and leaves the item unsigned
        # (generate_appcast/Appcast.swift:200-210); appcast.sh must fail.
        _, app_public = new_key()
        archive = self.make_zip("99.0.0", "99.0.0", "99.0.99", public=app_public)
        result = self.appcast(archive, "v99.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing its Sparkle EdDSA signature", result.stderr)
        self.assertFalse(self.out.exists())

    def test_input_validation(self) -> None:
        archive = self.make_zip("99.0.0", "99.0.0", "99.0.99")
        renamed = archive.with_name("AnyDoor.zip")
        shutil.copy2(archive, renamed)
        cases: dict[str, tuple[Path, str, tuple[str, ...]]] = {
            "zip not named for the release": (renamed, "v99.0.0", ()),
            "invalid tag": (archive, "99.0.0", ()),
            "bad phased rollout": (archive, "v99.0.0", ("--phased-rollout-interval", "0")),
            "bad critical version": (archive, "v99.0.0", ("--critical-update-version", "1.2")),
        }
        for name, (zip_path, tag, extra) in cases.items():
            with self.subTest(name):
                self.assertNotEqual(self.appcast(zip_path, tag, *extra).returncode, 0)
        missing_key = run([APPCAST_SH, "--seed", self.seed, "--zip", archive, "--notes", self.notes,
                           "--tools", self.tools, "--tag", "v99.0.0", "--public-key", self.public,
                           "--out", self.out],
                          env={k: v for k, v in os.environ.items() if k != "SPARKLE_ED_PRIVATE_KEY"})
        self.assertNotEqual(missing_key.returncode, 0)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY is not set", missing_key.stderr)
        self.assertEqual(run([APPCAST_SH, "--help"]).returncode, 0)


if __name__ == "__main__":
    unittest.main()

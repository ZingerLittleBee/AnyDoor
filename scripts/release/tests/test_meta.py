"""Behavior checks for scripts/release/meta.py, the release tag gate."""

from __future__ import annotations

import json
import os
import plistlib
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

META = RELEASE_DIR / "meta.py"
CONF = release_conf.load()
PUBLIC_KEY = "hbLSRwztl+EyMPefu7uNJHn7FjWQEREtC5Nx0MzM+Xk="

# Isolate git from the maintainer's config (tag.gpgSign, hooks, default branch).
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Release Test",
    "GIT_AUTHOR_EMAIL": "release-test.invalid",
    "GIT_COMMITTER_NAME": "Release Test",
    "GIT_COMMITTER_EMAIL": "release-test.invalid",
}


def run_meta(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(META), *args],
        capture_output=True,
        text=True,
        env=GIT_ENV,
        check=False,
    )


def parse_outputs(text: str) -> dict[str, str]:
    outputs: dict[str, str] = {}
    for line in text.splitlines():
        key, _, value = line.partition("=")
        outputs[key] = value
    return outputs


class TempDirTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="meta-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def assertMetaOK(self, *args: str) -> dict[str, str]:
        result = run_meta(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return parse_outputs(result.stdout)

    def assertMetaFails(self, *args: str, message: str) -> None:
        result = run_meta(*args)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)


class IdentityTests(TempDirTestCase):
    def test_stable_identity(self) -> None:
        self.assertEqual(
            self.assertMetaOK("identity", "--tag", "v4.2.8"),
            {
                "tag": "v4.2.8",
                "version": "4.2.8",
                "channel": "stable",
                "short_version": "4.2.8",
                "build_version": "4.2.899",
                "display_version": "4.2.8",
                "prerelease": "false",
            },
        )

    def test_beta_identity(self) -> None:
        outputs = self.assertMetaOK("identity", "--tag", "v4.3.0-beta.12")
        self.assertEqual(outputs["channel"], "beta")
        self.assertEqual(outputs["short_version"], "4.3.0")
        self.assertEqual(outputs["build_version"], "4.3.12")
        self.assertEqual(outputs["display_version"], "4.3.0 Beta 12")
        self.assertEqual(outputs["prerelease"], "true")

    def test_github_output_is_appended(self) -> None:
        output = self.tmp / "github_output"
        output.write_text("earlier=1\n")
        result = run_meta("identity", "--tag", "v1.0.0", "--github-output", str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        lines = output.read_text().splitlines()
        self.assertEqual(lines[0], "earlier=1")
        self.assertIn("build_version=1.0.99", lines)

    def test_rejects_malformed_tags(self) -> None:
        for tag in (
            "4.2.8",
            "v4.2",
            "v04.2.8",
            "v4.02.8",
            "v4.2.08",
            "v4.2.8-beta.0",
            "v4.2.8-beta.01",
            "v4.2.8-beta.100",
            "v4.2.8-rc.1",
            "v4.2.8-beta",
            "v4.2.8\n",
            "v4.2.8 ",
            "v4.2.8-beta.1;rm",
        ):
            with self.subTest(tag=tag):
                self.assertMetaFails("identity", "--tag", tag, message="vX.Y.Z")

    def test_resolver_bounds_beta_number(self) -> None:
        self.assertMetaFails(
            "identity", "--tag", "v4.2.8-beta.99", message="between 1 and 98"
        )


class GitRepoTestCase(TempDirTestCase):
    """A clone of a bare origin, so origin/* refs exist like in a CI checkout."""

    def setUp(self) -> None:
        super().setUp()
        self.origin = self.tmp / "origin.git"
        self.repo = self.tmp / "work"
        self.git_in(self.tmp, "init", "--bare", "-b", "main", str(self.origin))
        self.git_in(self.tmp, "clone", "-q", str(self.origin), str(self.repo))
        self.git("checkout", "-q", "-b", "main")
        self.commit("initial")
        self.git("push", "-q", "origin", "main")

    def git_in(self, cwd: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            env=GIT_ENV,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def git(self, *args: str) -> str:
        return self.git_in(self.repo, *args)

    def commit(self, message: str) -> str:
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def tag(self, name: str, message: str | None = None, rev: str = "HEAD") -> None:
        if message is None:
            self.git("tag", name, rev)
        else:
            self.git("tag", "-a", name, "-m", message, rev)


class VerifyTagTests(GitRepoTestCase):
    def verify(self, tag: str, *extra: str) -> list[str]:
        return ["verify-tag", "--tag", tag, "--repo-dir", str(self.repo), *extra]

    def test_stable_tag_on_main(self) -> None:
        self.commit("release")
        self.git("push", "-q", "origin", "main")
        self.tag("v1.0.0", "AnyDoor 1.0.0")
        self.git("fetch", "-q", "origin")
        self.assertMetaOK(*self.verify("v1.0.0"))

    def test_lightweight_tag_is_rejected(self) -> None:
        self.git("push", "-q", "origin", "main")
        self.tag("v1.0.0")
        self.assertMetaFails(*self.verify("v1.0.0"), message="lightweight")

    def test_missing_tag_is_rejected(self) -> None:
        self.assertMetaFails(*self.verify("v1.0.0"), message="does not exist")

    def test_tag_must_be_head(self) -> None:
        self.tag("v1.0.0", "AnyDoor 1.0.0")
        self.commit("later")
        self.git("push", "-q", "origin", "main")
        self.assertMetaFails(*self.verify("v1.0.0"), message="checkout is at")

    def test_stable_tag_off_main_is_rejected(self) -> None:
        self.git("checkout", "-q", "-b", "side")
        self.commit("side work")
        self.tag("v1.0.0", "AnyDoor 1.0.0")
        self.assertMetaFails(*self.verify("v1.0.0"), message="not on origin/main")

    def test_stable_tag_needs_origin_main(self) -> None:
        self.tag("v1.0.0", "AnyDoor 1.0.0")
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.assertMetaFails(*self.verify("v1.0.0"), message="origin/main not found")

    def beta_setup(self, *, include_stable: bool) -> None:
        if include_stable:
            self.tag("v1.0.0", "AnyDoor 1.0.0")
        self.git("checkout", "-q", "-b", "release/1.1-beta")
        self.commit("beta work")
        self.git("push", "-q", "origin", "release/1.1-beta")
        self.tag("v1.1.0-beta.1", "AnyDoor 1.1.0 Beta 1")
        if not include_stable:
            self.git("checkout", "-q", "main")
            self.commit("stable after branch point")
            self.tag("v1.0.0", "AnyDoor 1.0.0")
            self.git("checkout", "-q", "v1.1.0-beta.1")

    def test_beta_tag_on_beta_branch_containing_stable(self) -> None:
        self.beta_setup(include_stable=True)
        self.assertMetaOK(
            *self.verify("v1.1.0-beta.1", "--latest-stable-tag", "v1.0.0")
        )

    def test_beta_tag_must_contain_latest_stable(self) -> None:
        self.beta_setup(include_stable=False)
        self.assertMetaFails(
            *self.verify("v1.1.0-beta.1", "--latest-stable-tag", "v1.0.0"),
            message="does not contain latest stable v1.0.0",
        )

    def test_beta_tag_requires_latest_stable_argument(self) -> None:
        self.beta_setup(include_stable=True)
        self.assertMetaFails(
            *self.verify("v1.1.0-beta.1"), message="--latest-stable-tag"
        )

    def test_beta_without_any_stable_release(self) -> None:
        self.beta_setup(include_stable=True)
        result = run_meta(*self.verify("v1.1.0-beta.1", "--latest-stable-tag", ""))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no published stable release", result.stderr)

    def test_beta_tag_must_be_on_its_beta_branch(self) -> None:
        self.git("checkout", "-q", "-b", "release/1.1-beta")
        self.git("push", "-q", "origin", "release/1.1-beta")
        self.commit("unpushed beta work")
        self.tag("v1.1.0-beta.1", "AnyDoor 1.1.0 Beta 1")
        self.assertMetaFails(
            *self.verify("v1.1.0-beta.1", "--latest-stable-tag", ""),
            message="not on origin/release/1.1-beta",
        )

    def test_beta_tag_on_wrong_minor_branch(self) -> None:
        self.git("checkout", "-q", "-b", "release/1.2-beta")
        self.git("push", "-q", "origin", "release/1.2-beta")
        self.tag("v1.1.0-beta.1", "AnyDoor 1.1.0 Beta 1")
        self.assertMetaFails(
            *self.verify("v1.1.0-beta.1", "--latest-stable-tag", ""),
            message="origin/release/1.1-beta not found",
        )

    def test_latest_stable_must_be_a_stable_tag(self) -> None:
        self.beta_setup(include_stable=True)
        self.assertMetaFails(
            *self.verify("v1.1.0-beta.1", "--latest-stable-tag", "v1.0.0-beta.1"),
            message="not a stable tag",
        )


class VerifyPlistTests(TempDirTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.plist = self.tmp / "Info.plist"
        self.package = self.tmp / "Package.swift"
        major = CONF["MIN_MACOS"].split(".")[0]
        self.package.write_text(f"    platforms: [.macOS(.v{major})],\n")
        self.values: dict[str, object] = {
            "CFBundleShortVersionString": "4.2.8",
            "CFBundleVersion": "4.2.899",
            "SUPublicEDKey": PUBLIC_KEY,
            "SUFeedURL": CONF["FEED_URL"],
            "LSMinimumSystemVersion": CONF["MIN_MACOS"],
        }

    def check(self, *extra: str) -> list[str]:
        with self.plist.open("wb") as handle:
            plistlib.dump(self.values, handle)
        return [
            "verify-plist",
            "--tag",
            "v4.2.8",
            "--plist",
            str(self.plist),
            "--package-swift",
            str(self.package),
            *extra,
        ]

    def test_consistent_plist_passes(self) -> None:
        self.assertMetaOK(*self.check("--expected-public-key", PUBLIC_KEY))

    def test_version_mismatch(self) -> None:
        self.values["CFBundleVersion"] = "4.2.801"
        self.assertMetaFails(*self.check(), message="CFBundleVersion is '4.2.801'")
        self.values["CFBundleVersion"] = "4.2.899"
        self.values["CFBundleShortVersionString"] = "4.2.7"
        self.assertMetaFails(*self.check(), message="CFBundleShortVersionString")

    def test_public_key_checks(self) -> None:
        self.assertMetaFails(
            *self.check("--expected-public-key", "AAAA"), message="pinned key"
        )
        self.values["SUPublicEDKey"] = "PLACEHOLDER_REPLACE_WITH_GENERATE_KEYS_OUTPUT"
        self.assertMetaFails(*self.check(), message="placeholder")
        self.values["SUPublicEDKey"] = ""
        self.assertMetaFails(*self.check(), message="SUPublicEDKey is missing")
        del self.values["SUPublicEDKey"]
        self.assertMetaFails(*self.check(), message="SUPublicEDKey is missing")

    def test_feed_url_and_minimum_system(self) -> None:
        self.values["SUFeedURL"] = "https://example.invalid/appcast.xml"
        self.assertMetaFails(*self.check(), message="SUFeedURL")
        self.values["SUFeedURL"] = CONF["FEED_URL"]
        self.values["LSMinimumSystemVersion"] = "13.0"
        self.assertMetaFails(*self.check(), message="LSMinimumSystemVersion")

    def test_package_swift_platform(self) -> None:
        self.package.write_text("    platforms: [.macOS(.v13)],\n")
        self.assertMetaFails(*self.check(), message="does not declare .macOS(.v")

    def test_signed_feed_requires_verify_before_extraction(self) -> None:
        self.values["SURequireSignedFeed"] = True
        self.assertMetaFails(*self.check(), message="SUVerifyUpdateBeforeExtraction")
        self.values["SUVerifyUpdateBeforeExtraction"] = True
        self.assertMetaOK(*self.check())

    def test_unreadable_plist(self) -> None:
        args = self.check()
        self.plist.write_text("not a plist")
        self.assertMetaFails(*args, message="cannot read")

    def test_repository_plist_matches_its_own_identity(self) -> None:
        with (REPO_ROOT / "Info.plist").open("rb") as handle:
            plist = plistlib.load(handle)
        short = plist["CFBundleShortVersionString"]
        slot = int(plist["CFBundleVersion"].split(".")[2]) % 100
        tag = f"v{short}" if slot == 99 else f"v{short}-beta.{slot}"
        self.assertMetaOK(
            "verify-plist",
            "--tag",
            tag,
            "--plist",
            str(REPO_ROOT / "Info.plist"),
            "--package-swift",
            str(REPO_ROOT / "Package.swift"),
        )


class VerifyMonotonicTests(TempDirTestCase):
    PUBLISHED: ClassVar[list[dict[str, object]]] = [
        {
            "tagName": "v4.2.7",
            "isPrerelease": False,
            "publishedAt": "2026-10-03T19:10:46Z",
        },
        {
            "tagName": "v4.2.6",
            "isPrerelease": False,
            "publishedAt": "2026-10-01T18:32:35Z",
        },
        {
            "tagName": "v4.2.0",
            "isPrerelease": False,
            "publishedAt": "2026-09-01T00:00:00Z",
        },
        {
            "tagName": "v4.2.0-beta.3",
            "isPrerelease": True,
            "publishedAt": "2026-08-20T00:00:00Z",
        },
        {
            "tagName": "v4.2.0-beta.2",
            "isPrerelease": True,
            "publishedAt": "2026-08-10T00:00:00Z",
        },
    ]

    def check(
        self, tag: str, published: list[dict[str, object]] | None = None
    ) -> list[str]:
        path = self.tmp / "published.json"
        path.write_text(json.dumps(self.PUBLISHED if published is None else published))
        return ["verify-monotonic", "--tag", tag, "--published", str(path)]

    def test_next_stable(self) -> None:
        self.assertEqual(
            self.assertMetaOK(*self.check("v4.2.8")),
            {"latest_stable_tag": "v4.2.7", "previous_tag": "v4.2.7"},
        )

    def test_next_beta_after_stable(self) -> None:
        outputs = self.assertMetaOK(*self.check("v4.3.0-beta.1"))
        self.assertEqual(outputs["latest_stable_tag"], "v4.2.7")

    def test_beta_of_next_patch_is_newer_than_stable(self) -> None:
        self.assertMetaOK(*self.check("v4.2.8-beta.1"))

    def test_already_published(self) -> None:
        self.assertMetaFails(*self.check("v4.2.7"), message="already published")

    def test_stable_not_newer(self) -> None:
        self.assertMetaFails(
            *self.check("v4.2.5"), message="not newer than published v4.2.7"
        )

    def test_beta_not_newer_than_latest_stable(self) -> None:
        self.assertMetaFails(
            *self.check("v4.2.1-beta.1"), message="not newer than latest stable v4.2.7"
        )
        self.assertMetaFails(
            *self.check("v4.2.0-beta.1"),
            message="not newer than published v4.2.0-beta.3",
        )
        published = [entry for entry in self.PUBLISHED if not entry["isPrerelease"]]
        self.assertMetaFails(
            *self.check("v4.2.7-beta.1", published),
            message="not newer than latest stable v4.2.7",
        )

    def test_beta_not_newer_than_published_beta(self) -> None:
        published = [
            {
                "tagName": "v5.0.0-beta.2",
                "isPrerelease": True,
                "publishedAt": "2026-10-04T00:00:00Z",
            },
            *self.PUBLISHED,
        ]
        self.assertMetaFails(
            *self.check("v5.0.0-beta.1", published),
            message="not newer than published v5.0.0-beta.2",
        )
        outputs = self.assertMetaOK(*self.check("v5.0.0-beta.3", published))
        self.assertEqual(outputs["previous_tag"], "v5.0.0-beta.2")
        self.assertEqual(outputs["latest_stable_tag"], "v4.2.7")

    def test_previous_tag_follows_publication_time(self) -> None:
        published = [
            {
                "tagName": "v4.2.7",
                "isPrerelease": False,
                "publishedAt": "2026-10-03T19:10:46Z",
            },
            {
                "tagName": "v4.3.0-beta.1",
                "isPrerelease": True,
                "publishedAt": "2026-10-04T08:00:00Z",
            },
        ]
        outputs = self.assertMetaOK(*self.check("v4.2.8", published))
        self.assertEqual(
            outputs, {"latest_stable_tag": "v4.2.7", "previous_tag": "v4.3.0-beta.1"}
        )

    def test_first_release(self) -> None:
        self.assertEqual(
            self.assertMetaOK(*self.check("v1.0.0", [])),
            {"latest_stable_tag": "", "previous_tag": ""},
        )

    def test_non_release_tags_are_ignored(self) -> None:
        published = [
            {
                "tagName": "nightly",
                "isPrerelease": True,
                "publishedAt": "2026-10-05T00:00:00Z",
            },
            *self.PUBLISHED,
        ]
        result = run_meta(*self.check("v4.2.8", published))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ignoring published release", result.stderr)
        self.assertIn("previous_tag=v4.2.7", result.stdout)

    def test_malformed_input(self) -> None:
        path = self.tmp / "published.json"
        path.write_text("{}")
        self.assertMetaFails(
            "verify-monotonic",
            "--tag",
            "v1.0.0",
            "--published",
            str(path),
            message="expected a JSON array",
        )
        self.assertMetaFails(
            *self.check("v4.2.8", [{"tagName": "v4.2.7", "isPrerelease": False}]),
            message="no publishedAt",
        )


class NotesTests(TempDirTestCase):
    CHANGELOG = (
        "# Changelog\n"
        "\n"
        "## [Unreleased]\n"
        "\n"
        "### Fixed\n"
        "\n"
        "- A beta fix that wraps\n"
        "  onto a second line.\n"
        "\n"
        "## [4.2.7] - 2026-10-04\n"
        "\n"
        "### Added\n"
        "\n"
        "- Keep Awake can now run for 4, 8, or 12 hours, in the menu-bar\n"
        "  panel's duration menu.\n"
        "\n"
        "## [4.2.6] - 2026-10-02\n"
        "\n"
        "- Older.\n"
    )

    def notes(self, tag: str, changelog: str | None = None) -> list[str]:
        path = self.tmp / "CHANGELOG.md"
        path.write_text(self.CHANGELOG if changelog is None else changelog)
        self.out = self.tmp / "out" / "notes.md"
        return ["notes", "--tag", tag, "--changelog", str(path), "--out", str(self.out)]

    def test_stable_notes_use_the_dated_section(self) -> None:
        self.assertMetaOK(*self.notes("v4.2.7"))
        self.assertEqual(
            self.out.read_text(),
            "### Added\n\n- Keep Awake can now run for 4, 8, or 12 hours, in the "
            "menu-bar panel's duration menu.\n",
        )

    def test_beta_notes_use_unreleased(self) -> None:
        self.assertMetaOK(*self.notes("v4.3.0-beta.1"))
        self.assertEqual(
            self.out.read_text(),
            "### Fixed\n\n- A beta fix that wraps onto a second line.\n",
        )

    def test_last_section_runs_to_end_of_file(self) -> None:
        self.assertMetaOK(*self.notes("v4.2.6"))
        self.assertEqual(self.out.read_text(), "- Older.\n")

    def test_missing_section(self) -> None:
        self.assertMetaFails(
            *self.notes("v4.2.8"), message="no ## [4.2.8] - YYYY-MM-DD"
        )
        self.assertMetaFails(
            *self.notes("v4.3.0-beta.1", "# Changelog\n"), message="no ## [Unreleased]"
        )

    def test_empty_section(self) -> None:
        changelog = "## [Unreleased]\n\n## [4.2.7] - 2026-10-04\n\n- Item.\n"
        self.assertMetaFails(
            *self.notes("v4.3.0-beta.1", changelog), message="is empty"
        )
        self.assertFalse(self.out.exists())

    def test_empty_section_with_placeholder(self) -> None:
        changelog = "## [Unreleased]\n\n## [4.2.7] - 2026-10-04\n\n- Item.\n"
        args = self.notes("v4.3.0-beta.1", changelog)
        result = run_meta(*args, "--empty-placeholder", "- Rehearsal build.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is empty", result.stderr)
        self.assertEqual(self.out.read_text(), "- Rehearsal build.\n")

    def test_placeholder_does_not_hide_a_missing_section(self) -> None:
        args = self.notes("v4.3.0-beta.1", "# Changelog\n")
        result = run_meta(*args, "--empty-placeholder", "- Rehearsal build.")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no ## [Unreleased]", result.stderr)

    def test_placeholder_is_unused_when_notes_exist(self) -> None:
        self.assertMetaOK(
            *self.notes("v4.3.0-beta.1"), "--empty-placeholder", "- Rehearsal build."
        )
        self.assertIn("A beta fix", self.out.read_text())

    def test_duplicate_section(self) -> None:
        changelog = (
            "## [4.2.7] - 2026-10-04\n\n- A.\n\n## [4.2.7] - 2026-10-05\n\n- B.\n"
        )
        self.assertMetaFails(*self.notes("v4.2.7", changelog), message="2 ## [4.2.7]")

    def test_undated_stable_heading_is_not_a_release(self) -> None:
        changelog = "## [4.2.7]\n\n- Item.\n"
        self.assertMetaFails(*self.notes("v4.2.7", changelog), message="no ## [4.2.7]")

    def test_repository_changelog_has_unreleased_shape(self) -> None:
        path = REPO_ROOT / "CHANGELOG.md"
        text = path.read_text()
        self.assertIn("## [Unreleased]", text)
        self.assertMetaOK(
            "notes",
            "--tag",
            "v4.2.7",
            "--changelog",
            str(path),
            "--out",
            str(self.tmp / "notes.md"),
        )
        self.assertTrue((self.tmp / "notes.md").read_text().strip())


class TrailersTests(GitRepoTestCase):
    def trailers(self, message: str, tag: str = "v4.2.8") -> list[str]:
        self.tag(tag, message)
        return ["trailers", "--tag", tag, "--repo-dir", str(self.repo)]

    def test_no_trailers(self) -> None:
        self.assertEqual(
            self.assertMetaOK(*self.trailers("AnyDoor 4.2.8")),
            {"phased_rollout_interval": "", "critical_update_version": ""},
        )

    def test_both_trailers(self) -> None:
        message = (
            "AnyDoor 4.2.8\n\n"
            "Sparkle-Phased-Rollout-Interval: 86400\n"
            "Sparkle-Critical-Update-Version: 4.2.699\n"
        )
        self.assertEqual(
            self.assertMetaOK(*self.trailers(message)),
            {"phased_rollout_interval": "86400", "critical_update_version": "4.2.699"},
        )

    def test_critical_from_any_version_marker(self) -> None:
        message = "AnyDoor 4.2.8\n\nSparkle-Critical-Update-Version: *\n"
        outputs = self.assertMetaOK(*self.trailers(message))
        self.assertEqual(outputs["critical_update_version"], "*")

    def test_unrelated_trailers_are_ignored(self) -> None:
        message = "AnyDoor 4.2.8\n\nReviewed-by: someone\nSparkle-Phased-Rollout-Interval: 60\n"
        self.assertEqual(
            self.assertMetaOK(*self.trailers(message))["phased_rollout_interval"], "60"
        )

    def test_invalid_interval(self) -> None:
        for index, value in enumerate(("0", "012", "1.5", "-5", "ten", "")):
            with self.subTest(value=value):
                message = f"AnyDoor\n\nSparkle-Phased-Rollout-Interval: {value}\n"
                self.assertMetaFails(
                    *self.trailers(message, f"v4.2.{index}"),
                    message="positive number of seconds",
                )

    def test_invalid_critical_version(self) -> None:
        for index, value in enumerate(("4.2", "v4.2.699", "4.02.1", "**", "")):
            with self.subTest(value=value):
                message = f"AnyDoor\n\nSparkle-Critical-Update-Version: {value}\n"
                self.assertMetaFails(
                    *self.trailers(message, f"v4.2.{index}"),
                    message="build version X.Y.Z",
                )

    def test_critical_version_newer_than_release(self) -> None:
        message = "AnyDoor 4.2.8\n\nSparkle-Critical-Update-Version: 4.2.900\n"
        self.assertMetaFails(
            *self.trailers(message), message="is newer than this release"
        )

    def test_unknown_and_duplicate_sparkle_trailers(self) -> None:
        self.assertMetaFails(
            *self.trailers("AnyDoor\n\nSparkle-Phased-Rollout: 60\n", "v4.2.1"),
            message="unknown trailer Sparkle-Phased-Rollout",
        )
        message = (
            "AnyDoor\n\nSparkle-Phased-Rollout-Interval: 60\n"
            "sparkle-phased-rollout-interval: 61\n"
        )
        self.assertMetaFails(
            *self.trailers(message, "v4.2.2"), message="duplicate trailer"
        )

    def test_sparkle_line_outside_trailer_block(self) -> None:
        message = (
            "AnyDoor 4.2.8\n\nSparkle-Phased-Rollout-Interval: 60\n"
            "this line makes the paragraph prose\n"
        )
        self.assertMetaFails(
            *self.trailers(message), message="outside the final trailer"
        )
        self.assertMetaFails(
            *self.trailers("Sparkle-Phased-Rollout-Interval: 60\n", "v4.2.9"),
            message="outside the final trailer",
        )

    def test_lightweight_tag(self) -> None:
        self.tag("v4.2.8")
        self.assertMetaFails(
            "trailers",
            "--tag",
            "v4.2.8",
            "--repo-dir",
            str(self.repo),
            message="not an annotated tag",
        )

    @unittest.skipUnless(shutil.which("ssh-keygen"), "ssh-keygen is required")
    def test_signed_tag_signature_is_not_parsed(self) -> None:
        key = self.tmp / "signing-key"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
            check=True,
            capture_output=True,
        )
        self.git("config", "gpg.format", "ssh")
        self.git("config", "user.signingkey", str(key))
        self.git(
            "tag",
            "-s",
            "v4.2.8",
            "-m",
            "AnyDoor 4.2.8\n\nSparkle-Phased-Rollout-Interval: 3600\n",
        )
        self.assertIn("SSH SIGNATURE", self.git("cat-file", "tag", "v4.2.8"))
        self.assertEqual(
            self.assertMetaOK(
                "trailers", "--tag", "v4.2.8", "--repo-dir", str(self.repo)
            ),
            {"phased_rollout_interval": "3600", "critical_update_version": ""},
        )


class RehearsalIdentityTests(TempDirTestCase):
    def check(
        self, short_version: str, published: list[dict[str, object]]
    ) -> list[str]:
        plist = self.tmp / "Info.plist"
        with plist.open("wb") as handle:
            plistlib.dump({"CFBundleShortVersionString": short_version}, handle)
        path = self.tmp / "published.json"
        path.write_text(json.dumps(published))
        return ["rehearsal-identity", "--plist", str(plist), "--published", str(path)]

    def test_next_patch_beta_after_info_plist(self) -> None:
        outputs = self.assertMetaOK(
            *self.check("4.2.7", VerifyMonotonicTests.PUBLISHED)
        )
        self.assertEqual(outputs["tag"], "v4.2.8-beta.1")
        self.assertEqual(outputs["version"], "4.2.8-beta.1")
        self.assertEqual(outputs["build_version"], "4.2.801")

    def test_skips_past_betas_published_from_a_release_branch(self) -> None:
        # main still says 4.2.7 while release/4.3-beta has shipped Betas.
        published = [
            {
                "tagName": "v4.3.0-beta.2",
                "isPrerelease": True,
                "publishedAt": "2026-10-05T00:00:00Z",
            },
            *VerifyMonotonicTests.PUBLISHED,
        ]
        outputs = self.assertMetaOK(*self.check("4.2.7", published))
        self.assertEqual(outputs["tag"], "v4.3.1-beta.1")
        path = self.tmp / "published.json"
        self.assertMetaOK(
            "verify-monotonic", "--tag", outputs["tag"], "--published", str(path)
        )

    def test_without_published_releases(self) -> None:
        self.assertEqual(
            self.assertMetaOK(*self.check("1.0.0", []))["tag"], "v1.0.1-beta.1"
        )

    def test_rejects_a_malformed_short_version(self) -> None:
        self.assertMetaFails(*self.check("4.2", []), message="not an X.Y.Z version")


class VerifyAppTests(TempDirTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.reference = self.tmp / "Info.plist"
        with self.reference.open("wb") as handle:
            plistlib.dump(
                {"CFBundleVersion": "4.2.899", "SUPublicEDKey": PUBLIC_KEY}, handle
            )
        self.app = self.tmp / "AnyDoor.app"
        (self.app / "Contents").mkdir(parents=True)
        shutil.copyfile(self.reference, self.app / "Contents" / "Info.plist")

    def check(self, public_key: str = PUBLIC_KEY) -> list[str]:
        return [
            "verify-app",
            "--app",
            str(self.app),
            "--plist-ref",
            str(self.reference),
            "--public-key",
            public_key,
        ]

    def test_matching_app(self) -> None:
        self.assertEqual(self.assertMetaOK(*self.check()), {})

    def test_modified_plist(self) -> None:
        with (self.app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {"CFBundleVersion": "4.2.899", "SUPublicEDKey": "AAAA"}, handle
            )
        self.assertMetaFails(*self.check(), message="differs from the tag's Info.plist")

    def test_byte_level_difference(self) -> None:
        # Same values, different serialization: still not the tag's file.
        with (self.app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {"CFBundleVersion": "4.2.899", "SUPublicEDKey": PUBLIC_KEY},
                handle,
                fmt=plistlib.FMT_BINARY,
            )
        self.assertMetaFails(*self.check(), message="differs")

    def test_unpinned_public_key(self) -> None:
        self.assertMetaFails(*self.check("AAAA"), message="expected the pinned key")

    def test_missing_app(self) -> None:
        shutil.rmtree(self.app)
        self.assertMetaFails(*self.check(), message="cannot read Info.plist")

    def test_requires_arguments(self) -> None:
        result = run_meta("verify-app", "--app", str(self.app))
        self.assertEqual(result.returncode, 2)
        result = run_meta(*self.check(""))
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()

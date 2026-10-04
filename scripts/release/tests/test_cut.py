"""Behavior checks for scripts/release/cut.py.

Integration tests run cut.py against a real temporary clone with a bare
"origin"; only gh is faked, by an executable on PATH that serves canned JSON.
Tests that perform the bump need PlistBuddy, so they are macOS-only.
"""

from __future__ import annotations

import contextlib
import datetime
import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

RELEASE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RELEASE_DIR))

import cut  # noqa: E402

CUT = RELEASE_DIR / "cut.py"
HAS_PLISTBUDDY = sys.platform == "darwin" and Path("/usr/libexec/PlistBuddy").exists()

CHANGELOG = """\
# Changelog

All notable changes to AnyDoor are documented here.

## [Unreleased]

### Fixed

- Release notes no longer break lines in the middle
  of a sentence.

## [4.2.7] - 2026-10-04

### Added

- Keep Awake can run for 4, 8, or 12 hours.
"""

CI_YML = """\
name: CI
on:
  push:
    branches: [main]
    paths-ignore: &docs-and-meta
      - '*.md'
      - 'docs/**'
      # comments inside the list are fine
      - '.gitignore'
  pull_request:
    paths-ignore: *docs-and-meta
jobs: {}
"""

FAKE_GH = """\
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
with open(os.environ["FAKE_GH_STATE"]) as handle:
    state = json.load(handle)


def emit(key):
    print(json.dumps(state.get(key, [])))
    sys.exit(0)


if args[:2] == ["auth", "status"]:
    sys.exit(0 if state.get("auth_ok", True) else 1)
if args[:2] == ["release", "list"]:
    emit("releases")
if args[:2] == ["run", "list"]:
    workflow = args[args.index("--workflow") + 1]
    if workflow == "ci.yml":
        emit("ci_head_runs" if "--commit" in args else "ci_branch_runs")
    emit("release_runs")
if args[:2] == ["run", "watch"]:
    sys.exit(state.get("watch_exit", 0))
if args[:2] == ["variable", "get"]:
    value = state.get("variables", {}).get(args[2])
    if value is None:
        sys.stderr.write("variable " + args[2] + " was not found\\n")
        sys.exit(1)
    print(value)
    sys.exit(0)
sys.stderr.write("fake gh: unexpected arguments: " + " ".join(args) + "\\n")
sys.exit(2)
"""


def ci_run(sha: str, status: str = "completed", conclusion: str = "success", run_id: int = 1) -> dict:
    return {
        "databaseId": run_id,
        "status": status,
        "conclusion": conclusion,
        "headSha": sha,
        "url": f"https://example.invalid/runs/{run_id}",
        "createdAt": f"2026-10-04T00:00:{run_id:02d}Z",
    }


def release(tag: str, prerelease: bool = False) -> dict:
    return {"tagName": tag, "isPrerelease": prerelease, "publishedAt": "2026-10-04T00:00:00Z"}


def write_plist(path: Path, short: str, build: str) -> None:
    payload = {
        "CFBundleIdentifier": "dev.bybee.AnyDoor",
        "CFBundleShortVersionString": short,
        "CFBundleVersion": build,
    }
    with path.open("wb") as handle:
        plistlib.dump(payload, handle)


class Fixture:
    """A work clone of a bare origin, released as v4.2.7, with a fake gh."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.origin = root / "origin.git"
        self.work = root / "work"
        self.bin = root / "bin"
        self.state_path = root / "gh-state.json"
        self.gh_log = root / "gh-log.jsonl"
        gitconfig = root / "gitconfig"
        gitconfig.write_text(
            "[user]\n\tname = Release Test\n\temail = release-test@example.invalid\n"
            "[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n"
        )
        self.bin.mkdir()
        fake_gh = self.bin / "gh"
        fake_gh.write_text(f"#!{sys.executable}\n{FAKE_GH}")
        fake_gh.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
            GIT_CONFIG_GLOBAL=str(gitconfig),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
            FAKE_GH_STATE=str(self.state_path),
            FAKE_GH_LOG=str(self.gh_log),
        )

        self.run("git", "init", "--quiet", "--bare", "-b", "main", str(self.origin), cwd=root)
        self.run("git", "clone", "--quiet", str(self.origin), str(self.work), cwd=root)
        write_plist(self.work / "Info.plist", "4.2.7", "4.2.799")
        (self.work / "CHANGELOG.md").write_text(CHANGELOG)
        (self.work / ".github" / "workflows").mkdir(parents=True)
        (self.work / ".github" / "workflows" / "ci.yml").write_text(CI_YML)
        (self.work / "Sources").mkdir()
        (self.work / "Sources" / "App.swift").write_text("let version = 1\n")
        self.commit("chore: release v4.2.7")
        self.git("tag", "-a", "v4.2.7", "-m", "AnyDoor 4.2.7")
        self.git("push", "--quiet", "origin", "main", "refs/tags/v4.2.7")
        self.set_state(
            releases=[release("v4.2.7")],
            ci_head_runs=[ci_run(self.head())],
            variables={"RELEASE_PIPELINE": "actions"},
        )

    def run(self, *args: str, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            list(args), cwd=cwd or self.work, env=self.env, capture_output=True, text=True, check=check
        )

    def git(self, *args: str, cwd: Path | None = None) -> str:
        return self.run("git", *args, cwd=cwd).stdout.strip()

    def commit(self, message: str) -> str:
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", message)
        return self.head()

    def head(self) -> str:
        return self.git("rev-parse", "HEAD")

    def origin_ref(self, ref: str) -> str:
        return self.run("git", "rev-parse", "--verify", "--quiet", ref, cwd=self.origin, check=False).stdout.strip()

    def set_state(self, **values: object) -> None:
        state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        state.update(values)
        self.state_path.write_text(json.dumps(state))

    def gh_calls(self) -> list[list[str]]:
        if not self.gh_log.exists():
            return []
        return [json.loads(line) for line in self.gh_log.read_text().splitlines()]

    def cut(self, *args: str, stdin: str = "") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CUT), "--repo-dir", str(self.work), *args],
            env=self.env,
            input=stdin,
            capture_output=True,
            text=True,
            check=False,
        )

    def snapshot(self) -> tuple[str, str, str, str, str]:
        return (
            self.head(),
            self.git("status", "--porcelain"),
            self.git("tag", "--list"),
            self.origin_ref("refs/heads/main"),
            self.run("git", "tag", "--list", cwd=self.origin).stdout,
        )


class FixtureTestCase(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.repo = Fixture(Path(temp.name).resolve())

    def assertFails(self, result: subprocess.CompletedProcess[str], message: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)


# --- pure logic ---------------------------------------------------------------


class InferVersionTests(unittest.TestCase):
    def test_after_a_stable_the_patch_advances(self) -> None:
        version, reason = cut.infer_version(cut.PlistVersions("4.2.7", "4.2.799"))
        self.assertEqual(version, "4.2.8")
        self.assertIn("patch+1", reason)

    def test_after_a_beta_the_same_short_version_ships_as_stable(self) -> None:
        version, reason = cut.infer_version(cut.PlistVersions("4.3.0", "4.3.2"))
        self.assertEqual(version, "4.3.0")
        self.assertIn("Beta 2", reason)

    def test_non_numeric_versions_require_an_explicit_version(self) -> None:
        with self.assertRaises(cut.CutError):
            cut.infer_version(cut.PlistVersions("4.2", "42"))


class IdentityTests(unittest.TestCase):
    def test_uses_the_shared_encoder_and_derives_branches(self) -> None:
        stable = cut.resolve_identity("4.2.8")
        self.assertEqual((stable.channel, stable.build_version, stable.branch), ("stable", "4.2.899", "main"))
        beta = cut.resolve_identity("4.3.0-beta.2")
        self.assertEqual(
            (beta.channel, beta.build_version, beta.display_version, beta.branch, beta.tag),
            ("beta", "4.3.2", "4.3.0 Beta 2", "release/4.3-beta", "v4.3.0-beta.2"),
        )

    def test_rejects_malformed_versions(self) -> None:
        for version in ("4.2", "04.2.8", "4.2.8-beta.0", "4.2.8-rc.1"):
            with self.subTest(version=version), self.assertRaises(cut.CutError):
                cut.resolve_identity(version)


class ChangelogTests(unittest.TestCase):
    def test_cut_without_stale_sections_keeps_the_body_verbatim(self) -> None:
        result = cut.cut_changelog(CHANGELOG, "4.2.8", "2026-10-05", (4, 2, 7))
        expected = CHANGELOG.replace("## [Unreleased]", "## [Unreleased]\n\n## [4.2.8] - 2026-10-05", 1)
        self.assertEqual(result.text, expected)
        self.assertEqual(result.folded, [])
        self.assertTrue(result.body.startswith("### Fixed"))

    def test_folds_never_published_sections_into_the_new_one(self) -> None:
        text = CHANGELOG.replace(
            "## [4.2.7] - 2026-10-04",
            "## [4.2.8] - 2026-10-05\n\n### Added\n\n- Voided feature.\n\n### Fixed\n\n- Voided fix.\n\n"
            "## [4.2.7] - 2026-10-04",
        )
        result = cut.cut_changelog(text, "4.2.9", "2026-10-06", (4, 2, 7))
        self.assertEqual(result.folded, ["## [4.2.8] - 2026-10-05"])
        self.assertEqual(
            result.text,
            "# Changelog\n\nAll notable changes to AnyDoor are documented here.\n\n"
            "## [Unreleased]\n\n"
            "## [4.2.9] - 2026-10-06\n\n"
            "### Added\n\n- Voided feature.\n\n"
            "### Fixed\n\n- Release notes no longer break lines in the middle\n  of a sentence.\n- Voided fix.\n\n"
            "## [4.2.7] - 2026-10-04\n\n### Added\n\n- Keep Awake can run for 4, 8, or 12 hours.\n",
        )

    def test_rejects_a_version_not_newer_than_the_changelog(self) -> None:
        with self.assertRaisesRegex(cut.CutError, r"already has ## \[4.2.7\]"):
            cut.cut_changelog(CHANGELOG, "4.2.7", "2026-10-05", (4, 2, 7))

    def test_merge_orders_headings_and_keeps_intro_text(self) -> None:
        merged = cut.merge_bodies(
            ["### Fixed\n\n- New fix.", "Intro line.\n\n### Security\n\n- Patch.\n\n### Added\n\n- Old add."]
        )
        self.assertEqual(
            merged, "Intro line.\n\n### Added\n\n- Old add.\n\n### Fixed\n\n- New fix.\n\n### Security\n\n- Patch."
        )


class CiPathFilterTests(unittest.TestCase):
    def test_reads_the_push_paths_ignore_list(self) -> None:
        self.assertEqual(cut.ci_paths_ignore(CI_YML), ["*.md", "docs/**", ".gitignore"])

    def test_github_globs(self) -> None:
        self.assertTrue(cut.github_glob("*.md").match("README.md"))
        self.assertFalse(cut.github_glob("*.md").match("docs/README.md"))
        self.assertTrue(cut.github_glob("docs/**").match("docs/a/b.md"))
        self.assertFalse(cut.github_glob("docs/**").match("docsx/a.md"))
        self.assertTrue(cut.github_glob(".github/workflows/deploy-*.yml").match(".github/workflows/deploy-feed.yml"))


class TrailerTests(unittest.TestCase):
    def test_valid_trailers(self) -> None:
        self.assertEqual(
            cut.build_trailers("86400", "*"),
            ["Sparkle-Phased-Rollout-Interval: 86400", "Sparkle-Critical-Update-Version: *"],
        )
        self.assertEqual(cut.build_trailers(None, "4.2.799"), ["Sparkle-Critical-Update-Version: 4.2.799"])
        self.assertEqual(cut.build_trailers(None, None), [])

    def test_invalid_trailers(self) -> None:
        for phased, critical in (("0", None), ("-5", None), ("1h", None), (None, ""), (None, "4.2"), (None, "v4.2.7")):
            with self.subTest(phased=phased, critical=critical), self.assertRaises(cut.CutError):
                cut.build_trailers(phased, critical)


class MonotonicTests(unittest.TestCase):
    def published(self, *tags: str) -> cut.PublishedReleases:
        return cut.PublishedReleases.from_json([release(tag, "-beta." in tag) for tag in tags])

    def test_latest_stable_is_by_version(self) -> None:
        latest = self.published("v4.2.10", "v4.2.9", "v4.3.0-beta.1").latest_stable()
        self.assertEqual(latest, ("v4.2.10", (4, 2, 10, 99)))

    def test_rejects_republishing_and_regressions(self) -> None:
        releases = self.published("v4.2.7", "v4.3.0-beta.2")
        releases.check_monotonic(cut.resolve_identity("4.2.8"))
        releases.check_monotonic(cut.resolve_identity("4.3.0-beta.3"))
        for version in ("4.2.7", "4.2.6", "4.3.0-beta.2", "4.2.7-beta.1"):
            with self.subTest(version=version), self.assertRaises(cut.CutError):
                releases.check_monotonic(cut.resolve_identity(version))


# --- preflight against a real temporary clone ----------------------------------------


class PreflightTests(FixtureTestCase):
    def test_dry_run_prints_the_inferred_plan_and_changes_nothing(self) -> None:
        before = self.repo.snapshot()
        result = self.repo.cut("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("4.2.8 (stable), inferred: Info.plist build 4.2.799", result.stdout)
        self.assertIn("CFBundleVersion 4.2.799 -> 4.2.899", result.stdout)
        self.assertIn("git push --atomic origin HEAD:refs/heads/main refs/tags/v4.2.8", result.stdout)
        self.assertIn("ci.yml run for HEAD", result.stdout)
        # Notes are unwrapped the same way the published Release body will be.
        self.assertIn("- Release notes no longer break lines in the middle of a sentence.", result.stdout)
        self.assertEqual(self.repo.snapshot(), before)

    def test_dirty_tree_fails_before_fetching(self) -> None:
        (self.repo.work / "scratch.txt").write_text("x")
        self.assertFails(self.repo.cut("--dry-run"), "working tree is dirty")
        self.assertEqual(self.repo.gh_calls(), [])

    def test_beta_must_run_from_its_release_branch(self) -> None:
        self.assertFails(self.repo.cut("--dry-run", "--version", "4.3.0-beta.1"), "must be cut from release/4.3-beta")

    def test_head_must_match_the_remote_branch(self) -> None:
        (self.repo.work / "Sources" / "App.swift").write_text("let version = 2\n")
        self.repo.commit("feat: unpushed")
        self.assertFails(self.repo.cut("--dry-run"), "not in sync with origin/main")

    def test_empty_unreleased_fails(self) -> None:
        text = CHANGELOG.replace(
            "### Fixed\n\n- Release notes no longer break lines in the middle\n  of a sentence.\n\n", ""
        )
        (self.repo.work / "CHANGELOG.md").write_text(text)
        self.repo.commit("docs: empty unreleased")
        self.repo.git("push", "--quiet", "origin", "main")
        self.repo.set_state(ci_head_runs=[ci_run(self.repo.head())])
        self.assertFails(self.repo.cut("--dry-run"), "'## [Unreleased]' is empty")

    def test_existing_tag_fails(self) -> None:
        self.repo.git("tag", "-a", "v4.2.8", "-m", "voided")
        self.repo.git("push", "--quiet", "origin", "refs/tags/v4.2.8")
        self.assertFails(self.repo.cut("--dry-run"), "tag v4.2.8 already exists")

    def test_gh_must_be_authenticated(self) -> None:
        self.repo.set_state(auth_ok=False)
        self.assertFails(self.repo.cut("--dry-run"), "gh is not authenticated")

    def test_pipeline_switch_off_blocks_a_cut_and_warns_a_dry_run(self) -> None:
        for variables, shown in (({}, "unset"), ({"RELEASE_PIPELINE": "local"}, "'local'")):
            with self.subTest(shown=shown):
                self.repo.set_state(variables=variables)
                before = self.repo.snapshot()
                self.assertFails(self.repo.cut("--yes"), f"RELEASE_PIPELINE is {shown}")
                self.assertEqual(self.repo.snapshot(), before)
                dry = self.repo.cut("--dry-run")
                self.assertEqual(dry.returncode, 0, dry.stderr)
                self.assertIn(f"RELEASE_PIPELINE is {shown}", dry.stdout)

    def test_failed_or_running_ci_blocks_the_cut(self) -> None:
        head = self.repo.head()
        self.repo.set_state(ci_head_runs=[ci_run(head, conclusion="failure")])
        self.assertFails(self.repo.cut("--dry-run"), "concluded failure")
        self.repo.set_state(ci_head_runs=[ci_run(head, status="in_progress", conclusion="")])
        self.assertFails(self.repo.cut("--dry-run"), "still in_progress")

    def test_newest_ci_run_for_head_decides(self) -> None:
        head = self.repo.head()
        self.repo.set_state(ci_head_runs=[ci_run(head, conclusion="failure", run_id=1), ci_run(head, run_id=2)])
        self.assertEqual(self.repo.cut("--dry-run").returncode, 0)

    def test_docs_only_commits_are_vouched_for_by_an_ancestor_run(self) -> None:
        vouching = self.repo.head()
        (self.repo.work / "docs").mkdir()
        (self.repo.work / "docs" / "guide.md").write_text("guide\n")
        (self.repo.work / "README.md").write_text("readme\n")
        self.repo.commit("docs: add guide")
        self.repo.git("push", "--quiet", "origin", "main")
        self.repo.set_state(ci_head_runs=[], ci_branch_runs=[ci_run(vouching)])
        result = self.repo.cut("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"run for ancestor {vouching[:12]}", result.stdout)

    def test_ancestor_run_does_not_vouch_for_code_changes(self) -> None:
        vouching = self.repo.head()
        (self.repo.work / "Sources" / "App.swift").write_text("let version = 2\n")
        self.repo.commit("feat: change code")
        self.repo.git("push", "--quiet", "origin", "main")
        self.repo.set_state(ci_head_runs=[], ci_branch_runs=[ci_run(vouching)])
        self.assertFails(self.repo.cut("--dry-run"), "need CI: Sources/App.swift")

    def test_already_published_version_fails(self) -> None:
        self.repo.set_state(releases=[release("v4.2.8"), release("v4.2.7")])
        self.assertFails(self.repo.cut("--dry-run"), "v4.2.8 is already a published Release")

    def test_voided_stable_section_is_folded_into_the_next_cut(self) -> None:
        # v4.2.8 was cut and tagged but never published. The cut itself leaves
        # [Unreleased] empty: its notes now live only in the [4.2.8] section.
        voided = cut.cut_changelog(CHANGELOG, "4.2.8", "2026-10-05", (4, 2, 7))
        self.assertEqual(cut.Changelog.parse(voided.text).unreleased().body, "")
        (self.repo.work / "CHANGELOG.md").write_text(voided.text)
        write_plist(self.repo.work / "Info.plist", "4.2.8", "4.2.899")
        self.repo.commit("chore: release v4.2.8")
        self.repo.git("tag", "-a", "v4.2.8", "-m", "AnyDoor 4.2.8")
        self.repo.git("push", "--quiet", "origin", "main", "refs/tags/v4.2.8")
        self.repo.set_state(ci_head_runs=[ci_run(self.repo.head())])
        result = self.repo.cut("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("4.2.9 (stable), inferred", result.stdout)
        self.assertIn("folds never-published ## [4.2.8] - 2026-10-05 into [4.2.9]", result.stdout)
        self.assertIn("- Release notes no longer break lines in the middle", result.stdout)

    def test_empty_unreleased_fails_a_beta(self) -> None:
        text = CHANGELOG.replace(
            "### Fixed\n\n- Release notes no longer break lines in the middle\n  of a sentence.\n\n", ""
        )
        (self.repo.work / "CHANGELOG.md").write_text(text)
        self.repo.commit("docs: empty unreleased")
        self.repo.git("checkout", "--quiet", "-b", "release/4.3-beta")
        self.repo.git("push", "--quiet", "origin", "release/4.3-beta")
        self.repo.set_state(ci_head_runs=[ci_run(self.repo.head())])
        self.assertFails(self.repo.cut("--dry-run", "--version", "4.3.0-beta.1"), "'## [Unreleased]' is empty")

    def test_declined_confirmation_changes_nothing(self) -> None:
        before = self.repo.snapshot()
        result = self.repo.cut(stdin="n\n")
        self.assertFails(result, "Aborted")
        self.assertEqual(self.repo.snapshot(), before)


# --- the full cut ---------------------------------------------------------------------


@unittest.skipUnless(HAS_PLISTBUDDY, "bump-version.sh needs /usr/libexec/PlistBuddy")
class CutTests(FixtureTestCase):
    def plist(self, path: Path | None = None) -> tuple[str, str]:
        with (path or self.repo.work / "Info.plist").open("rb") as handle:
            data = plistlib.load(handle)
        return data["CFBundleShortVersionString"], data["CFBundleVersion"]

    def test_stable_cut_commits_tags_and_pushes_atomically(self) -> None:
        parent = self.repo.head()
        result = self.repo.cut("--yes", "--no-watch", "--phased-rollout-interval", "3600")
        self.assertEqual(result.returncode, 0, result.stderr)

        head = self.repo.head()
        self.assertEqual(self.repo.git("rev-parse", "HEAD~1"), parent)
        self.assertEqual(self.repo.git("log", "-1", "--format=%s"), "chore: release v4.2.8")
        self.assertEqual(
            sorted(self.repo.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines()),
            ["CHANGELOG.md", "Info.plist"],
        )
        self.assertEqual(self.plist(), ("4.2.8", "4.2.899"))
        today = datetime.date.today().isoformat()
        self.assertEqual(
            (self.repo.work / "CHANGELOG.md").read_text(),
            CHANGELOG.replace("## [Unreleased]", f"## [Unreleased]\n\n## [4.2.8] - {today}", 1),
        )
        self.assertEqual(self.repo.git("status", "--porcelain"), "")

        self.assertEqual(self.repo.origin_ref("refs/heads/main"), head)
        self.assertEqual(self.repo.origin_ref("refs/tags/v4.2.8^{commit}"), head)
        self.assertEqual(self.repo.run("git", "cat-file", "-t", "v4.2.8", cwd=self.repo.origin).stdout.strip(), "tag")
        message = self.repo.run(
            "git", "for-each-ref", "--format=%(contents)", "refs/tags/v4.2.8", cwd=self.repo.origin
        ).stdout
        self.assertEqual(message, "AnyDoor 4.2.8\n\nSparkle-Phased-Rollout-Interval: 3600\n\n")
        self.assertFalse(any(call[:2] == ["run", "watch"] for call in self.repo.gh_calls()))

    @unittest.skipUnless(HAS_PLISTBUDDY, "the bump needs PlistBuddy")
    def test_next_cut_after_a_voided_stable_folds_its_notes(self) -> None:
        first = self.repo.cut("--yes", "--no-watch")
        self.assertEqual(first.returncode, 0, first.stderr)
        # v4.2.8 is never published: the release list still ends at v4.2.7.
        self.repo.set_state(ci_head_runs=[ci_run(self.repo.head())])
        result = self.repo.cut("--yes", "--no-watch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("folds never-published ## [4.2.8]", result.stdout)
        self.assertEqual(self.plist(), ("4.2.9", "4.2.999"))
        today = datetime.date.today().isoformat()
        changelog = cut.Changelog.parse((self.repo.work / "CHANGELOG.md").read_text())
        self.assertEqual([s.heading.strip() for s in changelog.sections],
                         ["## [Unreleased]", f"## [4.2.9] - {today}", "## [4.2.7] - 2026-10-04"])
        self.assertIn("of a sentence.", changelog.sections[1].body)
        self.assertEqual(self.repo.origin_ref("refs/tags/v4.2.9^{commit}"), self.repo.head())

    def test_beta_cut_leaves_the_changelog_alone(self) -> None:
        self.repo.git("checkout", "--quiet", "-b", "release/4.3-beta")
        self.repo.git("push", "--quiet", "origin", "release/4.3-beta")
        self.repo.git("branch", "--quiet", "--set-upstream-to", "origin/release/4.3-beta")
        result = self.repo.cut("--yes", "--no-watch", "--version", "4.3.0-beta.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CHANGELOG   unchanged", result.stdout)
        self.assertEqual(self.repo.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"), "Info.plist")
        self.assertEqual(self.plist(), ("4.3.0", "4.3.1"))
        self.assertEqual((self.repo.work / "CHANGELOG.md").read_text(), CHANGELOG)
        self.assertEqual(self.repo.origin_ref("refs/heads/release/4.3-beta"), self.repo.head())
        self.assertEqual(self.repo.origin_ref("refs/tags/v4.3.0-beta.1^{commit}"), self.repo.head())
        self.assertEqual(self.repo.origin_ref("refs/heads/main"), self.repo.git("rev-parse", "HEAD~1"))

    def test_beta_branch_must_contain_the_latest_stable(self) -> None:
        self.repo.git("checkout", "--quiet", "-b", "release/4.3-beta", "HEAD")
        (self.repo.work / "Sources" / "App.swift").write_text("let version = 3\n")
        self.repo.commit("feat: beta work")
        self.repo.git("push", "--quiet", "origin", "release/4.3-beta")
        self.repo.set_state(ci_head_runs=[ci_run(self.repo.head())])
        # Publish a newer Stable that this branch does not contain.
        self.repo.git("checkout", "--quiet", "main")
        (self.repo.work / "Sources" / "App.swift").write_text("let version = 4\n")
        self.repo.commit("chore: release v4.2.8")
        self.repo.git("tag", "-a", "v4.2.8", "-m", "AnyDoor 4.2.8")
        self.repo.git("push", "--quiet", "origin", "main", "refs/tags/v4.2.8")
        self.repo.git("checkout", "--quiet", "release/4.3-beta")
        self.repo.set_state(releases=[release("v4.2.8"), release("v4.2.7")])
        self.assertFails(
            self.repo.cut("--dry-run", "--version", "4.3.0-beta.1"), "must contain the latest Stable v4.2.8"
        )

    def test_rejected_push_prints_recovery_and_undoes_nothing(self) -> None:
        hook = self.repo.origin / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\necho 'rejected by test hook' >&2\nexit 1\n")
        hook.chmod(0o755)
        origin_main = self.repo.origin_ref("refs/heads/main")
        result = self.repo.cut("--yes", "--no-watch")
        self.assertFails(result, "push failed")
        self.assertIn("git tag -d v4.2.8", result.stderr)
        self.assertIn("git reset --hard HEAD~1", result.stderr)
        self.assertIn("git push --atomic origin HEAD:refs/heads/main refs/tags/v4.2.8", result.stderr)
        # Local state is left for the maintainer; the remote got nothing.
        self.assertEqual(self.repo.git("rev-parse", "v4.2.8^{commit}"), self.repo.head())
        self.assertEqual(self.repo.origin_ref("refs/heads/main"), origin_main)
        self.assertEqual(self.repo.origin_ref("refs/tags/v4.2.8"), "")

    def test_confirmed_cut_then_watches_the_release_run(self) -> None:
        result = self.repo.cut("--no-watch", stdin="y\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        tag_sha = self.repo.git("rev-parse", "v4.2.8^{commit}")
        self.assertEqual(self.repo.origin_ref("refs/tags/v4.2.8^{commit}"), tag_sha)

        # Watching runs in-process so the polling interval can be shortened.
        plan = cut.Plan(
            identity=cut.resolve_identity("4.2.8"),
            inferred_from=None,
            remote="origin",
            head=tag_sha,
            ci=cut.CiVouch(tag_sha, "", ""),
            plist_before=cut.PlistVersions("4.2.7", "4.2.799"),
            changelog=None,
            notes="",
            sign_tag=False,
            trailers=[],
        )
        other_run = {"databaseId": 76, "headSha": "0" * 40, "url": "u", "createdAt": "t"}
        self.repo.set_state(watch_exit=3, release_runs=[other_run])
        with (
            patched_environ(self.repo.env),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
            unittest.mock.patch.object(cut, "WATCH_ATTEMPTS", 1),
        ):
            self.assertEqual(cut.watch(plan, self.repo.work, "Owner/Repo"), 0)
        self.assertIn("no release.yml run for v4.2.8 yet", stderr.getvalue())

        tag_run = {"databaseId": 77, "headSha": tag_sha, "url": "u", "createdAt": "t"}
        self.repo.set_state(release_runs=[other_run, tag_run])
        with (
            patched_environ(self.repo.env),
            contextlib.redirect_stdout(io.StringIO()) as stdout,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(cut.watch(plan, self.repo.work, "Owner/Repo"), 3)
        self.assertIn("release.yml run: u", stdout.getvalue())
        watches = [call for call in self.repo.gh_calls() if call[:2] == ["run", "watch"]]
        self.assertEqual(watches, [["run", "watch", "77", "--exit-status", "--repo", "Owner/Repo"]])


@contextlib.contextmanager
def patched_environ(env: dict[str, str]):
    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update(env)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(saved)


if __name__ == "__main__":
    unittest.main()

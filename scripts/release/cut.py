#!/usr/bin/env python3
"""Cut an AnyDoor release locally: bump, cut CHANGELOG, commit, tag, push.

The tag push triggers .github/workflows/release.yml, which builds, signs,
notarizes, and publishes. This command only prepares and pushes the release
commit and its annotated tag, after read-only preflight checks:

  python3 scripts/release/cut.py                       # next Stable (inferred)
  python3 scripts/release/cut.py --version 4.3.0       # explicit Stable
  python3 scripts/release/cut.py --version 4.3.0-beta.1
  python3 scripts/release/cut.py --dry-run             # print the plan only

Stable releases run from main and turn CHANGELOG's [Unreleased] into the new
version's section. Beta releases run from release/X.Y-beta, leave CHANGELOG
alone, and publish [Unreleased] as their notes.

Nothing is undone automatically on failure; the error says how to recover.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import plistlib
import re
import subprocess
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TOOLS_ROOT = SCRIPT_DIR.parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import release_conf  # noqa: E402

RESOLVE_SCRIPT = TOOLS_ROOT / "scripts" / "resolve-release-version.sh"
BUMP_SCRIPT = TOOLS_ROOT / "scripts" / "bump-version.sh"
UNWRAP_SCRIPT = TOOLS_ROOT / "scripts" / "unwrap-release-notes.py"

CI_WORKFLOW = "ci.yml"
RELEASE_WORKFLOW = "release.yml"
PIPELINE_SWITCH = "RELEASE_PIPELINE"
PIPELINE_SWITCH_ON = "actions"
CI_WORKFLOW_PATH = Path(".github") / "workflows" / CI_WORKFLOW

# release.yml's run appears a few seconds after the tag push.
WATCH_ATTEMPTS = 12
WATCH_INTERVAL_SECONDS = 5.0

TAG_PATTERN = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-beta\.([1-9][0-9]?))?$")
STABLE_SECTION = re.compile(r"^## \[(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\] - \d{4}-\d{2}-\d{2}\s*$")
VERSION_SECTION = re.compile(r"^## \[(\d+)\.(\d+)\.(\d+)\]")
UNRELEASED_HEADING = "## [Unreleased]"
CRITICAL_VERSION = re.compile(r"^(?:\*|(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")
# Keep a Changelog's heading order; anything else follows in first-seen order.
HEADING_ORDER = ("Added", "Changed", "Deprecated", "Removed", "Fixed", "Security")


class CutError(Exception):
    """A failed check or step; the message says what to do next."""


# --- small process helpers -------------------------------------------------


def log(message: str) -> None:
    print(f"\033[1;34m▸\033[0m {message}", file=sys.stderr)


def warn(message: str) -> None:
    print(f"\033[1;33m!\033[0m {message}", file=sys.stderr)


def run(
    args: Sequence[str],
    cwd: Path,
    *,
    check: bool = True,
    input_text: str | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            list(args),
            cwd=cwd,
            input=input_text,
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
    except FileNotFoundError as error:
        raise CutError(f"{args[0]} not found: {error}") from error
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise CutError(f"`{' '.join(args)}` failed (exit {result.returncode}): {detail}")
    return result


class Git:
    def __init__(self, repo: Path) -> None:
        self.repo = repo

    def __call__(self, *args: str, check: bool = True) -> str:
        return run(["git", *args], self.repo, check=check).stdout.strip()

    def ok(self, *args: str) -> bool:
        return run(["git", *args], self.repo, check=False).returncode == 0


class Gh:
    def __init__(self, repo_dir: Path, repository: str) -> None:
        self.repo_dir = repo_dir
        self.repository = repository

    def json(self, *args: str) -> list[dict]:
        output = run(["gh", *args, "--repo", self.repository], self.repo_dir).stdout
        try:
            value = json.loads(output or "[]")
        except json.JSONDecodeError as error:
            raise CutError(f"`gh {' '.join(args)}` returned invalid JSON: {error}") from error
        if not isinstance(value, list):
            raise CutError(f"`gh {' '.join(args)}` did not return a JSON list")
        return value

    def variable(self, name: str) -> str | None:
        """A repository variable's value, or None when it is not set."""
        result = run(["gh", "variable", "get", name, "--repo", self.repository], self.repo_dir, check=False)
        if result.returncode != 0:
            if "not found" in result.stderr:
                return None
            raise CutError(f"`gh variable get {name}` failed: {result.stderr.strip()}")
        return result.stdout.strip()


# --- release identity --------------------------------------------------------


@dataclass(frozen=True)
class Identity:
    release_id: str
    channel: str
    short_version: str
    build_version: str
    display_version: str

    @property
    def tag(self) -> str:
        return f"v{self.release_id}"

    @property
    def branch(self) -> str:
        if self.channel == "stable":
            return "main"
        major, minor, _ = self.short_version.split(".")
        return f"release/{major}.{minor}-beta"

    @property
    def order_key(self) -> tuple[int, int, int, int]:
        key = tag_order_key(self.tag)
        assert key is not None
        return key


def resolve_identity(version: str) -> Identity:
    result = run([str(RESOLVE_SCRIPT), version], TOOLS_ROOT, check=False)
    if result.returncode != 0:
        raise CutError(result.stderr.strip() or f"cannot resolve release version {version}")
    fields = result.stdout.rstrip("\n").split("\t")
    if len(fields) != 5:
        raise CutError(f"unexpected resolver output: {result.stdout!r}")
    return Identity(*fields)


def tag_order_key(tag: str) -> tuple[int, int, int, int] | None:
    """(major, minor, patch, slot) with Stable as slot 99, the build-version order."""
    match = TAG_PATTERN.match(tag)
    if match is None:
        return None
    major, minor, patch, beta = match.groups()
    return int(major), int(minor), int(patch), int(beta) if beta else 99


@dataclass(frozen=True)
class PlistVersions:
    short_version: str
    build_version: str


def read_plist_versions(path: Path) -> PlistVersions:
    try:
        with path.open("rb") as handle:
            data = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CutError(f"cannot read {path}: {error}") from error
    short = data.get("CFBundleShortVersionString")
    build = data.get("CFBundleVersion")
    if not isinstance(short, str) or not isinstance(build, str):
        raise CutError(f"{path} lacks CFBundleShortVersionString/CFBundleVersion strings")
    return PlistVersions(short, build)


def infer_version(versions: PlistVersions) -> tuple[str, str]:
    """Next Stable after Info.plist's current identity, plus a one-line reason."""
    short = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", versions.short_version)
    build = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", versions.build_version)
    if short is None or build is None:
        raise CutError(
            f"Info.plist versions are not X.Y.Z (short {versions.short_version}, "
            f"build {versions.build_version}); pass --version"
        )
    major, minor, patch = (int(part) for part in short.groups())
    slot = int(build.group(3)) % 100
    if slot != 99:
        # The last cut was a Beta of this short version, so ship its Stable.
        return (
            f"{major}.{minor}.{patch}",
            f"Info.plist build {versions.build_version} is Beta {slot} of {versions.short_version}",
        )
    return (
        f"{major}.{minor}.{patch + 1}",
        f"Info.plist build {versions.build_version} is Stable {versions.short_version}; patch+1",
    )


# --- CHANGELOG ----------------------------------------------------------------


# Identity equality: two sections with equal text are still different sections.
@dataclass(eq=False)
class Section:
    heading: str
    lines: list[str]

    @property
    def raw(self) -> str:
        return "".join([self.heading, *self.lines])

    @property
    def body(self) -> str:
        return "".join(self.lines).strip("\n")

    @property
    def stable_version(self) -> tuple[int, int, int] | None:
        match = STABLE_SECTION.match(self.heading)
        if match is None:
            return None
        major, minor, patch = (int(part) for part in match.groups())
        return major, minor, patch


@dataclass
class Changelog:
    preamble: list[str]
    sections: list[Section]

    @classmethod
    def parse(cls, text: str) -> Changelog:
        preamble: list[str] = []
        sections: list[Section] = []
        for line in text.splitlines(keepends=True):
            if line.startswith("## ["):
                sections.append(Section(line, []))
            elif sections:
                sections[-1].lines.append(line)
            else:
                preamble.append(line)
        return cls(preamble, sections)

    def unreleased(self) -> Section:
        matches = [s for s in self.sections if s.heading.rstrip() == UNRELEASED_HEADING]
        if len(matches) != 1:
            raise CutError(f"CHANGELOG.md must have exactly one '{UNRELEASED_HEADING}' section")
        return matches[0]

    def render(self) -> str:
        return "".join(self.preamble) + "".join(section.raw for section in self.sections)


def merge_bodies(bodies: Sequence[str]) -> str:
    """Merge section bodies by `### Heading`, newest body first within each heading."""
    intro: list[str] = []
    groups: dict[str, list[str]] = {}
    for body in bodies:
        current: str | None = None
        chunks: dict[str | None, list[str]] = {}
        for line in body.splitlines():
            if line.startswith("### "):
                current = line[4:].strip()
                chunks.setdefault(current, [])
                continue
            chunks.setdefault(current, []).append(line)
        for heading, lines in chunks.items():
            text = "\n".join(lines).strip("\n")
            if heading is None:
                if text:
                    intro.append(text)
            else:
                groups.setdefault(heading, [])
                if text:
                    groups[heading].append(text)

    def join(chunks: list[str]) -> str:
        merged = ""
        for chunk in chunks:
            if not merged:
                merged = chunk
            elif LIST_ITEM.match(merged.splitlines()[0]) and LIST_ITEM.match(chunk.splitlines()[0]):
                merged += "\n" + chunk  # keep one tight list
            else:
                merged += "\n\n" + chunk
        return merged

    ordered = [h for h in HEADING_ORDER if h in groups]
    ordered += [h for h in groups if h not in HEADING_ORDER]
    parts = list(intro)
    parts += [f"### {heading}\n\n{join(groups[heading])}" for heading in ordered if groups[heading]]
    return "\n\n".join(parts)


@dataclass
class ChangelogCut:
    text: str
    body: str
    folded: list[str]


def cut_changelog(
    text: str,
    version: str,
    date: str,
    latest_published_stable: tuple[int, int, int] | None,
) -> ChangelogCut:
    """Rename [Unreleased] to the new version, folding never-published sections into it."""
    changelog = Changelog.parse(text)
    unreleased = changelog.unreleased()
    stale = [
        s
        for s in changelog.sections
        if latest_published_stable is not None
        and s.stable_version is not None
        and s.stable_version > latest_published_stable
    ]
    new_key = tuple(int(part) for part in version.split("."))
    for section in changelog.sections:
        existing = VERSION_SECTION.match(section.heading)
        if existing and tuple(int(part) for part in existing.groups()) >= new_key:
            raise CutError(f"CHANGELOG.md already has {section.heading.strip()}; {version} must be newer")
    body = merge_bodies([unreleased.body, *(s.body for s in stale)]) if stale else unreleased.body
    if not body.strip():
        raise CutError(f"'{UNRELEASED_HEADING}' is empty; write the release notes first")

    index = changelog.sections.index(unreleased)
    before = [s for s in changelog.sections[:index] if s not in stale]
    after = [s for s in changelog.sections[index + 1 :] if s not in stale]
    if stale:
        lines = ["\n", body + "\n", *(["\n"] if after else [])]
    else:
        # Keep the body byte-for-byte, as the old local driver did.
        lines = list(unreleased.lines)
    rendered = (
        "".join(changelog.preamble)
        + "".join(s.raw for s in before)
        + UNRELEASED_HEADING
        + "\n\n"
        + Section(f"## [{version}] - {date}\n", lines).raw
        + "".join(s.raw for s in after)
    )
    return ChangelogCut(rendered, body, [s.heading.strip() for s in stale])


def unwrap_notes(body: str) -> str:
    result = run([sys.executable, str(UNWRAP_SCRIPT)], TOOLS_ROOT, input_text=body.strip() + "\n")
    return result.stdout


# --- GitHub state ----------------------------------------------------------------


@dataclass(frozen=True)
class PublishedReleases:
    tags: frozenset[str]
    keys: tuple[tuple[str, tuple[int, int, int, int]], ...]

    @classmethod
    def from_json(cls, rows: list[dict]) -> PublishedReleases:
        tags = []
        keys = []
        for row in rows:
            tag = row.get("tagName")
            if not isinstance(tag, str):
                continue
            tags.append(tag)
            key = tag_order_key(tag)
            if key is not None:
                keys.append((tag, key))
        return cls(frozenset(tags), tuple(keys))

    def latest_stable(self) -> tuple[str, tuple[int, int, int, int]] | None:
        stables = [(tag, key) for tag, key in self.keys if key[3] == 99]
        return max(stables, key=lambda item: item[1]) if stables else None

    def check_monotonic(self, identity: Identity) -> None:
        if identity.tag in self.tags:
            raise CutError(f"{identity.tag} is already a published Release")
        new_key = identity.order_key
        same_channel = [(t, k) for t, k in self.keys if (k[3] == 99) == (identity.channel == "stable")]
        newest = max(same_channel, key=lambda item: item[1], default=None)
        if newest is not None and new_key <= newest[1]:
            raise CutError(f"{identity.tag} is not newer than published {newest[0]}")
        stable = self.latest_stable()
        if identity.channel == "beta" and stable is not None and new_key <= stable[1]:
            raise CutError(f"{identity.tag} is not newer than published Stable {stable[0]}")


@dataclass(frozen=True)
class CiVouch:
    sha: str
    url: str
    note: str


def github_glob(pattern: str) -> re.Pattern[str]:
    """GitHub filter pattern: `*` stays within a path segment, `**` crosses them."""
    out = ""
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if pattern.startswith("**", index):
            out += ".*"
            index += 2
            continue
        if char == "*":
            out += "[^/]*"
        elif char == "?":
            out += "[^/]"
        else:
            out += re.escape(char)
        index += 1
    return re.compile(out + r"\Z")


def ci_paths_ignore(workflow_text: str) -> list[str]:
    """The first `paths-ignore:` list in ci.yml, which is the push trigger's."""
    patterns: list[str] = []
    collecting = False
    for line in workflow_text.splitlines():
        stripped = line.strip()
        if not collecting:
            if re.match(r"^paths-ignore:(\s*&\S+)?\s*$", stripped):
                collecting = True
            continue
        if not stripped or stripped.startswith("#"):
            continue
        item = re.match(r"^-\s+(['\"]?)(.+?)\1\s*(#.*)?$", stripped)
        if item is None:
            break
        patterns.append(item.group(2))
    return patterns


def check_ci(git: Git, gh: Gh, head: str, branch: str) -> CiVouch:
    fields = "databaseId,status,conclusion,headSha,url,createdAt"
    runs = gh.json("run", "list", "--workflow", CI_WORKFLOW, "--commit", head, "--limit", "20", "--json", fields)
    runs = [r for r in runs if r.get("headSha") == head]
    if runs:
        return judge_run(newest(runs), head, f"{CI_WORKFLOW} run for HEAD")

    # No run for HEAD: CI skips commits that only touch its paths-ignore list,
    # so the newest run on an ancestor vouches if every later change is ignored.
    runs = gh.json("run", "list", "--workflow", CI_WORKFLOW, "--branch", branch, "--limit", "50", "--json", fields)
    for candidate in sorted(runs, key=lambda r: str(r.get("createdAt", "")), reverse=True):
        sha = candidate.get("headSha")
        if not isinstance(sha, str) or not git.ok("merge-base", "--is-ancestor", sha, head):
            continue
        changed = [p for p in git("diff", "--name-only", "--no-renames", sha, head).splitlines() if p]
        workflow = CI_WORKFLOW_PATH
        try:
            patterns = ci_paths_ignore((git.repo / workflow).read_text())
        except OSError as error:
            raise CutError(f"cannot read {workflow}: {error}") from error
        if not patterns:
            raise CutError(f"no {CI_WORKFLOW} run for HEAD and no paths-ignore list in {workflow}")
        matchers = [github_glob(p) for p in patterns]
        tested = [p for p in changed if not any(m.match(p) for m in matchers)]
        if tested:
            raise CutError(
                f"no {CI_WORKFLOW} run for HEAD {head[:12]}, and changes since {sha[:12]} need CI: "
                + ", ".join(tested[:5])
                + f". Wait for CI or run `gh workflow run {CI_WORKFLOW} --ref {branch}`."
            )
        return judge_run(
            candidate,
            sha,
            f"no {CI_WORKFLOW} run for HEAD (later commits touch only ignored paths); run for ancestor {sha[:12]}",
        )
    raise CutError(
        f"no {CI_WORKFLOW} run on {branch} vouches for HEAD {head[:12]}. "
        f"Run `gh workflow run {CI_WORKFLOW} --ref {branch}` and wait for it."
    )


def newest(runs: list[dict]) -> dict:
    return max(runs, key=lambda r: str(r.get("createdAt", "")))


def judge_run(run_info: dict, sha: str, what: str) -> CiVouch:
    url = str(run_info.get("url", ""))
    if run_info.get("status") != "completed":
        raise CutError(f"{what} is still {run_info.get('status')}: {url}; wait for it to finish")
    if run_info.get("conclusion") != "success":
        raise CutError(f"{what} concluded {run_info.get('conclusion')}: {url}")
    return CiVouch(sha, url, what)


# --- plan -------------------------------------------------------------------------


@dataclass
class Plan:
    identity: Identity
    inferred_from: str | None
    remote: str
    head: str
    ci: CiVouch
    plist_before: PlistVersions
    changelog: ChangelogCut | None
    notes: str
    sign_tag: bool
    trailers: list[str]
    warnings: list[str] = field(default_factory=list)

    @property
    def commit_message(self) -> str:
        return f"chore: release {self.identity.tag}"

    @property
    def tag_message(self) -> str:
        message = f"{release_conf.get('APP_NAME')} {self.identity.display_version}\n"
        if self.trailers:
            message += "\n" + "\n".join(self.trailers) + "\n"
        return message

    @property
    def commit_paths(self) -> list[str]:
        return ["Info.plist", "CHANGELOG.md"] if self.changelog else ["Info.plist"]

    @property
    def push_command(self) -> list[str]:
        return [
            "git",
            "push",
            "--atomic",
            self.remote,
            f"HEAD:refs/heads/{self.identity.branch}",
            f"refs/tags/{self.identity.tag}",
        ]

    def render(self) -> str:
        i = self.identity
        lines = [
            "Release plan",
            f"  version     {i.release_id} ({i.channel})"
            + (f", inferred: {self.inferred_from}" if self.inferred_from else ""),
            f"  display     {i.display_version}",
            f"  tag         {i.tag} ({'signed' if self.sign_tag else 'annotated, unsigned'})",
            f"  branch      {i.branch} at {self.head[:12]}",
            f"  CI          {self.ci.note}: {self.ci.url or self.ci.sha[:12]}",
            "",
            "Changes",
            f"  Info.plist  CFBundleShortVersionString {self.plist_before.short_version} -> {i.short_version}",
            f"              CFBundleVersion {self.plist_before.build_version} -> {i.build_version}",
        ]
        if self.changelog:
            lines.append(f"  CHANGELOG   [Unreleased] -> [{i.release_id}], new empty [Unreleased] above")
            for heading in self.changelog.folded:
                lines.append(f"              folds never-published {heading} into [{i.release_id}]")
        else:
            lines.append("  CHANGELOG   unchanged (Beta notes come from [Unreleased])")
        lines += [
            f"  commit      {self.commit_message} ({', '.join(self.commit_paths)})",
            "  tag message " + self.tag_message.rstrip("\n").replace("\n", "\n              "),
            f"  push        {' '.join(self.push_command)}",
        ]
        for message in self.warnings:
            lines.append(f"  warning     {message}")
        lines += ["", "Release notes", *("  " + line if line else "" for line in self.notes.rstrip("\n").splitlines())]
        return "\n".join(lines) + "\n"


def build_trailers(phased: str | None, critical: str | None) -> list[str]:
    trailers = []
    if phased is not None:
        if not re.fullmatch(r"[1-9][0-9]*", phased):
            raise CutError(f"--phased-rollout-interval must be a positive integer of seconds: {phased!r}")
        trailers.append(f"Sparkle-Phased-Rollout-Interval: {phased}")
    if critical is not None:
        if not CRITICAL_VERSION.fullmatch(critical):
            raise CutError(f"--critical-update-version must be a build version X.Y.Z or '*': {critical!r}")
        trailers.append(f"Sparkle-Critical-Update-Version: {critical}")
    return trailers


def preflight(args: argparse.Namespace, repo: Path) -> Plan:
    git = Git(repo)
    gh = Gh(repo, args.repository)
    trailers = build_trailers(args.phased_rollout_interval, args.critical_update_version)

    plist_path = repo / "Info.plist"
    plist_before = read_plist_versions(plist_path)
    inferred_from = None
    version = args.version
    if version is None:
        version, inferred_from = infer_version(plist_before)
    identity = resolve_identity(version)
    if args.version is None and identity.channel != "stable":
        raise CutError("Beta releases require an explicit --version X.Y.Z-beta.N")

    log("Preflight checks")
    if git("status", "--porcelain"):
        raise CutError("working tree is dirty; commit or stash first")
    git("fetch", args.remote, "--tags", "--quiet")
    current = git("branch", "--show-current")
    if current != identity.branch:
        raise CutError(f"{identity.tag} must be cut from {identity.branch}, not {current or 'a detached HEAD'}")
    remote_ref = f"refs/remotes/{args.remote}/{identity.branch}"
    if not git.ok("rev-parse", "--verify", "--quiet", remote_ref):
        raise CutError(f"{args.remote}/{identity.branch} does not exist; push the branch first")
    head = git("rev-parse", "HEAD")
    if head != git("rev-parse", remote_ref):
        raise CutError(f"local {identity.branch} is not in sync with {args.remote}/{identity.branch}")

    changelog_text = (repo / "CHANGELOG.md").read_text()
    unreleased = Changelog.parse(changelog_text).unreleased()
    # A voided Stable cut leaves [Unreleased] empty and its notes in a
    # never-published section, so for Stable the emptiness check waits until
    # cut_changelog has folded such sections in.
    if identity.channel == "beta" and not unreleased.body.strip():
        raise CutError(f"'{UNRELEASED_HEADING}' is empty; write the release notes first")

    if git.ok("rev-parse", "--verify", "--quiet", f"refs/tags/{identity.tag}"):
        raise CutError(f"tag {identity.tag} already exists locally; tags never move, cut the next version")
    if git("ls-remote", "--tags", args.remote, f"refs/tags/{identity.tag}"):
        raise CutError(f"tag {identity.tag} already exists on {args.remote}; cut the next version")

    if run(["gh", "auth", "status"], repo, check=False).returncode != 0:
        raise CutError("gh is not authenticated; run `gh auth login`")
    warnings: list[str] = []
    # release.yml skips every job unless this switch is on, so a tag pushed
    # while it is off would never be published.
    switch = gh.variable(PIPELINE_SWITCH)
    if switch != PIPELINE_SWITCH_ON:
        message = (
            f"the release pipeline is off: repository variable {PIPELINE_SWITCH} is "
            f"{'unset' if switch is None else repr(switch)}, not '{PIPELINE_SWITCH_ON}', "
            f"so {RELEASE_WORKFLOW} would publish nothing"
        )
        if not args.dry_run:
            raise CutError(message)
        warnings.append(message)
    ci = check_ci(git, gh, head, identity.branch)

    published = PublishedReleases.from_json(
        gh.json("release", "list", "--exclude-drafts", "--limit", "200", "--json", "tagName,isPrerelease,publishedAt")
    )
    published.check_monotonic(identity)
    latest_stable = published.latest_stable()

    if identity.channel == "beta":
        if latest_stable is not None:
            stable_tag = latest_stable[0]
            if not git.ok("rev-parse", "--verify", "--quiet", f"refs/tags/{stable_tag}"):
                raise CutError(f"latest published Stable tag {stable_tag} is not in this clone")
            if not git.ok("merge-base", "--is-ancestor", stable_tag, "HEAD"):
                raise CutError(f"{identity.branch} must contain the latest Stable {stable_tag}; merge main first")
        stale = [
            s.heading.strip()
            for s in Changelog.parse(changelog_text).sections
            if latest_stable is not None and s.stable_version is not None and s.stable_version > latest_stable[1][:3]
        ]
        if stale:
            warnings.append("never-published sections stay out of these Beta notes: " + ", ".join(stale))
        changelog_cut = None
        notes = unwrap_notes(unreleased.body)
    else:
        if latest_stable is None:
            warnings.append("no published Stable Release found; never-published sections are not folded")
        changelog_cut = cut_changelog(
            changelog_text,
            identity.release_id,
            datetime.date.today().isoformat(),
            latest_stable[1][:3] if latest_stable else None,
        )
        notes = unwrap_notes(changelog_cut.body)

    signing_key = git("config", "--get", "user.signingkey", check=False)
    return Plan(
        identity=identity,
        inferred_from=inferred_from,
        remote=args.remote,
        head=head,
        ci=ci,
        plist_before=plist_before,
        changelog=changelog_cut,
        notes=notes,
        sign_tag=bool(signing_key),
        trailers=trailers,
        warnings=warnings,
    )


# --- mutations ----------------------------------------------------------------------


def confirm() -> bool:
    try:
        answer = input("Proceed? [y/N] ")
    except EOFError:
        return False
    return answer.strip().lower() in ("y", "yes")


def apply(plan: Plan, repo: Path) -> None:
    git = Git(repo)
    identity = plan.identity
    restore = "git checkout -- " + " ".join(plan.commit_paths)

    log(f"Bump Info.plist to {identity.short_version} ({identity.build_version})")
    env = dict(os.environ, PLIST=str(repo / "Info.plist"))
    try:
        resolved = run([str(BUMP_SCRIPT), identity.release_id], repo, env=env).stdout.strip()
        if resolved != identity.release_id:
            raise CutError(f"bump-version.sh resolved {resolved}, expected {identity.release_id}")
        after = read_plist_versions(repo / "Info.plist")
        if (after.short_version, after.build_version) != (identity.short_version, identity.build_version):
            raise CutError("Info.plist versions do not match the identity after the bump")
        if plan.changelog:
            log(f"Cut CHANGELOG [{identity.release_id}]")
            (repo / "CHANGELOG.md").write_text(plan.changelog.text)
        log(plan.commit_message)
        git("commit", "--quiet", "-m", plan.commit_message, "--", *plan.commit_paths)
    except CutError as error:
        raise CutError(f"{error}\nNothing was committed. Restore the files with: {restore}") from error

    reset = "git reset --hard HEAD~1"
    committed = set(git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines())
    if committed != set(plan.commit_paths):
        raise CutError(
            f"release commit touches {sorted(committed)}, expected {plan.commit_paths}. Undo it with: {reset}"
        )

    log(f"Tag {identity.tag}")
    tag_args = ["tag", "-s" if plan.sign_tag else "-a", identity.tag, "-F", "-", "--cleanup=verbatim"]
    result = run(["git", *tag_args], repo, check=False, input_text=plan.tag_message)
    if result.returncode != 0:
        raise CutError(f"git tag failed: {result.stderr.strip()}\nUndo the release commit with: {reset}")

    log(" ".join(plan.push_command))
    result = run(plan.push_command, repo, check=False)
    if result.returncode != 0:
        raise CutError(
            f"push failed: {(result.stderr or result.stdout).strip()}\n"
            f"The push is atomic, so {plan.remote} has neither the commit nor the tag.\n"
            f"Retry after fixing the cause:\n  {' '.join(plan.push_command)}\n"
            f"Or undo locally (not run for you):\n  git tag -d {identity.tag}\n  {reset}"
        )


def watch(plan: Plan, repo: Path, repository: str) -> int:
    gh = Gh(repo, repository)
    tag_sha = Git(repo)("rev-parse", f"{plan.identity.tag}^{{commit}}")
    log(f"Waiting for the {RELEASE_WORKFLOW} run for {plan.identity.tag}")
    for attempt in range(WATCH_ATTEMPTS):
        runs = gh.json(
            "run",
            "list",
            "--workflow",
            RELEASE_WORKFLOW,
            "--branch",
            plan.identity.tag,
            "--limit",
            "10",
            "--json",
            "databaseId,headSha,url,status,createdAt",
        )
        runs = [r for r in runs if r.get("headSha") == tag_sha]
        if runs:
            run_info = newest(runs)
            print(f"{RELEASE_WORKFLOW} run: {run_info.get('url', '')}")
            return subprocess.run(
                ["gh", "run", "watch", str(run_info["databaseId"]), "--exit-status", "--repo", repository],
                cwd=repo,
                check=False,
            ).returncode
        if attempt + 1 < WATCH_ATTEMPTS:
            time.sleep(WATCH_INTERVAL_SECONDS)
    warn(
        f"no {RELEASE_WORKFLOW} run for {plan.identity.tag} yet; check "
        f"`gh run list --workflow {RELEASE_WORKFLOW} --repo {repository}`"
    )
    return 0


# --- CLI ------------------------------------------------------------------------------


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="cut.py",
        description=(
            "Cut an AnyDoor release: preflight, bump Info.plist, cut CHANGELOG (Stable), "
            "commit 'chore: release vX.Y.Z', tag vX.Y.Z, and push both atomically, which "
            "starts release.yml."
        ),
    )
    parser.add_argument(
        "--version",
        help="X.Y.Z or X.Y.Z-beta.N; default: the next Stable inferred from Info.plist (Beta needs it)",
    )
    parser.add_argument("--dry-run", action="store_true", help="run the preflight, print the plan, change nothing")
    parser.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    parser.add_argument("--remote", default="origin", help="git remote to fetch from and push to (default: origin)")
    parser.add_argument("--no-watch", action="store_true", help="do not follow the release.yml run after pushing")
    parser.add_argument(
        "--phased-rollout-interval",
        metavar="SECONDS",
        help="add a Sparkle-Phased-Rollout-Interval trailer to the tag message",
    )
    parser.add_argument(
        "--critical-update-version",
        metavar="VERSION",
        help="add a Sparkle-Critical-Update-Version trailer (a build version X.Y.Z, or '*' for all)",
    )
    parser.add_argument(
        "--repository",
        default=release_conf.get("DEFAULT_REPOSITORY"),
        help="GitHub OWNER/REPO for gh queries (default: release.conf DEFAULT_REPOSITORY)",
    )
    parser.add_argument(
        "--repo-dir",
        type=Path,
        default=TOOLS_ROOT,
        help="checkout to release (default: the one containing this script)",
    )
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error(f"--repository must be OWNER/REPO: {args.repository}")
    if args.remote.startswith("-") or not args.remote:
        parser.error(f"invalid --remote: {args.remote}")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    repo = args.repo_dir.resolve()
    try:
        plan = preflight(args, repo)
        print(plan.render())
        if args.dry_run:
            log("Dry run: nothing changed")
            return 0
        if not args.yes and not confirm():
            log("Aborted: nothing changed")
            return 1
        apply(plan, repo)
    except CutError as error:
        print(f"\033[1;31m✗\033[0m {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\ninterrupted; check `git status` and `git log -1` before retrying", file=sys.stderr)
        return 130
    log(f"Pushed {plan.identity.tag}; release.yml takes it from here")
    if args.no_watch:
        return 0
    try:
        return watch(plan, repo, args.repository)
    except CutError as error:
        warn(f"could not follow the release run: {error}")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())

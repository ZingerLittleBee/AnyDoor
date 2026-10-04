#!/usr/bin/env python3
"""Release identity and gate checks for the tag-triggered release pipeline.

Every subcommand either fails with a one-line error (exit 1) or emits
``key=value`` lines: appended to ``--github-output PATH`` when given (the
workflow passes ``$GITHUB_OUTPUT``), printed to stdout otherwise. The tag regex
here is the only source of release identity for later jobs; version encoding is
delegated to scripts/resolve-release-version.sh so there is a single encoder.

Subcommands:
  identity          resolve vX.Y.Z[-beta.N] into channel and bundle versions
  verify-tag        tag is annotated, is HEAD, and sits on the channel's branch
  verify-plist      Info.plist / Package.swift agree with the tag and release.conf
  verify-monotonic  tag is newer than every published release of its channel
  notes             extract and unwrap the CHANGELOG section for the tag
  trailers          parse Sparkle-* trailers from the annotated tag message
  verify-app        assembled app carries the tag's Info.plist and the pinned key
  rehearsal-identity  the synthetic next Beta that release rehearsals package
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import release_conf

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
RESOLVER = SCRIPTS_DIR / "resolve-release-version.sh"
UNWRAPPER = SCRIPTS_DIR / "unwrap-release-notes.py"

TAG_PATTERN = re.compile(
    r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.([1-9][0-9]?))?"
)
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
POSITIVE_INT_PATTERN = re.compile(r"[1-9][0-9]*")
TRAILER_LINE = re.compile(r"([A-Za-z0-9][A-Za-z0-9-]*):[ \t]*(.*)")
SPARKLE_KEY = re.compile(r"[ \t]*sparkle-[A-Za-z0-9-]*[ \t]*:", re.IGNORECASE)

PHASED_ROLLOUT_TRAILER = "Sparkle-Phased-Rollout-Interval"
CRITICAL_UPDATE_TRAILER = "Sparkle-Critical-Update-Version"
# Marks "critical from any version" (generate_appcast's empty-string argument),
# which a trailer cannot express directly.
CRITICAL_FROM_ANY_VERSION = "*"
PLACEHOLDER_PUBLIC_KEY = "PLACEHOLDER_REPLACE_WITH_GENERATE_KEYS_OUTPUT"


class MetaError(Exception):
    """A gate failed; the message is shown to the maintainer as-is."""


class EmptyNotesError(MetaError):
    """The CHANGELOG section exists but has no release notes."""


@dataclass(frozen=True)
class ReleaseIdentity:
    tag: str
    version: str
    channel: str
    short_version: str
    build_version: str
    display_version: str

    @property
    def prerelease(self) -> bool:
        return self.channel == "beta"

    @property
    def build_key(self) -> tuple[int, int, int]:
        return version_key(self.build_version)

    @property
    def beta_branch(self) -> str:
        major, minor, _ = self.short_version.split(".")
        return f"release/{major}.{minor}-beta"

    def outputs(self) -> dict[str, str]:
        return {
            "tag": self.tag,
            "version": self.version,
            "channel": self.channel,
            "short_version": self.short_version,
            "build_version": self.build_version,
            "display_version": self.display_version,
            "prerelease": "true" if self.prerelease else "false",
        }


@dataclass(frozen=True)
class PublishedRelease:
    identity: ReleaseIdentity
    published_at: datetime


@dataclass(frozen=True)
class Trailers:
    phased_rollout_interval: str
    critical_update_version: str

    def outputs(self) -> dict[str, str]:
        return {
            "phased_rollout_interval": self.phased_rollout_interval,
            "critical_update_version": self.critical_update_version,
        }


def version_key(version: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.fullmatch(version)
    if match is None:
        raise MetaError(f"not an X.Y.Z version: {version!r}")
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def resolve_identity(tag: str) -> ReleaseIdentity:
    if TAG_PATTERN.fullmatch(tag) is None:
        raise MetaError(f"release tag must be vX.Y.Z or vX.Y.Z-beta.N: {tag!r}")
    version = tag[1:]
    result = subprocess.run(
        ["bash", str(RESOLVER), version], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise MetaError(result.stderr.strip() or f"cannot resolve {tag}")
    fields = result.stdout.rstrip("\n").split("\t")
    if len(fields) != 5 or fields[0] != version:
        raise MetaError(f"unexpected resolver output for {tag}: {result.stdout!r}")
    _, channel, short_version, build_version, display_version = fields
    if channel not in ("stable", "beta"):
        raise MetaError(f"unexpected channel for {tag}: {channel!r}")
    return ReleaseIdentity(
        tag, version, channel, short_version, build_version, display_version
    )


def emit(outputs: dict[str, str], github_output: Path | None) -> None:
    lines = []
    for key, value in outputs.items():
        if "\n" in value or "\r" in value:
            raise MetaError(f"output {key} must be a single line")
        lines.append(f"{key}={value}\n")
    if github_output is None:
        sys.stdout.write("".join(lines))
    else:
        with github_output.open("a", encoding="utf-8") as handle:
            handle.write("".join(lines))


def warn(message: str) -> None:
    print(f"meta.py: warning: {message}", file=sys.stderr)


def git(repo_dir: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo_dir), *args], capture_output=True, text=True, check=False
    )


def git_output_raw(repo_dir: Path, *args: str) -> str:
    result = git(repo_dir, *args)
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise MetaError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout


def git_output(repo_dir: Path, *args: str) -> str:
    return git_output_raw(repo_dir, *args).strip()


def is_ancestor(repo_dir: Path, ancestor: str, descendant: str) -> bool:
    result = git(repo_dir, "merge-base", "--is-ancestor", ancestor, descendant)
    if result.returncode not in (0, 1):
        raise MetaError(
            f"git merge-base --is-ancestor {ancestor} {descendant} failed: "
            f"{result.stderr.strip()}"
        )
    return result.returncode == 0


def require_ref(repo_dir: Path, ref: str, hint: str) -> str:
    result = git(repo_dir, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    if result.returncode != 0:
        raise MetaError(f"{ref} not found ({hint})")
    return result.stdout.strip()


def verify_tag(
    identity: ReleaseIdentity, repo_dir: Path, latest_stable_tag: str | None
) -> None:
    ref = f"refs/tags/{identity.tag}"
    object_type = git(repo_dir, "cat-file", "-t", ref)
    if object_type.returncode != 0:
        raise MetaError(f"tag {identity.tag} does not exist in {repo_dir}")
    if object_type.stdout.strip() != "tag":
        raise MetaError(
            f"tag {identity.tag} is lightweight; release tags must be annotated"
        )
    tag_commit = git_output(repo_dir, "rev-parse", f"{ref}^{{commit}}")
    head = git_output(repo_dir, "rev-parse", "HEAD")
    if tag_commit != head:
        raise MetaError(
            f"tag {identity.tag} points to {tag_commit}, but the checkout is at {head}"
        )

    if identity.channel == "stable":
        main = require_ref(repo_dir, "refs/remotes/origin/main", "fetch origin/main")
        if not is_ancestor(repo_dir, tag_commit, main):
            raise MetaError(f"stable tag {identity.tag} is not on origin/main")
        return

    branch = identity.beta_branch
    branch_head = require_ref(
        repo_dir, f"refs/remotes/origin/{branch}", f"fetch origin/{branch}"
    )
    if not is_ancestor(repo_dir, tag_commit, branch_head):
        raise MetaError(f"beta tag {identity.tag} is not on origin/{branch}")
    if latest_stable_tag is None:
        raise MetaError(
            "beta tags need --latest-stable-tag (an empty value only when no "
            "stable release is published)"
        )
    if not latest_stable_tag:
        warn("no published stable release; skipping the beta base check")
        return
    stable = resolve_identity(latest_stable_tag)
    if stable.channel != "stable":
        raise MetaError(f"--latest-stable-tag is not a stable tag: {latest_stable_tag}")
    stable_commit = require_ref(repo_dir, f"refs/tags/{stable.tag}", "fetch tags")
    if not is_ancestor(repo_dir, stable_commit, tag_commit):
        raise MetaError(
            f"beta tag {identity.tag} does not contain latest stable {stable.tag}"
        )


def read_plist(path: Path) -> dict[str, object]:
    try:
        with path.open("rb") as handle:
            data = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise MetaError(f"cannot read {path}: {error}") from error
    if not isinstance(data, dict):
        raise MetaError(f"{path} is not a dictionary plist")
    return data


def verify_plist(
    identity: ReleaseIdentity,
    plist_path: Path,
    package_swift: Path,
    expected_public_key: str | None,
    conf: dict[str, str],
) -> None:
    plist = read_plist(plist_path)
    problems: list[str] = []

    def expect(key: str, expected: object) -> None:
        actual = plist.get(key)
        if actual != expected:
            problems.append(f"{key} is {actual!r}, expected {expected!r}")

    expect("CFBundleShortVersionString", identity.short_version)
    expect("CFBundleVersion", identity.build_version)
    expect("SUFeedURL", conf["FEED_URL"])
    expect("LSMinimumSystemVersion", conf["MIN_MACOS"])

    public_key = plist.get("SUPublicEDKey")
    if not isinstance(public_key, str) or not public_key.strip():
        problems.append("SUPublicEDKey is missing or empty")
    elif public_key == PLACEHOLDER_PUBLIC_KEY:
        problems.append("SUPublicEDKey is still the placeholder")
    elif expected_public_key is not None and public_key != expected_public_key:
        problems.append(
            f"SUPublicEDKey is {public_key!r}, expected the pinned key "
            f"{expected_public_key!r}"
        )

    # Sparkle refuses to start an updater that requires a signed feed without
    # verifying archives before extraction.
    if plist.get("SURequireSignedFeed") is True and (
        plist.get("SUVerifyUpdateBeforeExtraction") is not True
    ):
        problems.append(
            "SURequireSignedFeed needs SUVerifyUpdateBeforeExtraction = true"
        )

    major = conf["MIN_MACOS"].split(".")[0]
    platform = f".macOS(.v{major})"
    try:
        manifest = package_swift.read_text(encoding="utf-8")
    except OSError as error:
        raise MetaError(f"cannot read {package_swift}: {error}") from error
    if platform not in manifest:
        problems.append(f"{package_swift.name} does not declare {platform}")

    if problems:
        raise MetaError(f"{plist_path}: " + "; ".join(problems))


def parse_published_at(value: object, tag: str) -> datetime:
    if not isinstance(value, str):
        raise MetaError(f"published release {tag} has no publishedAt")
    # fromisoformat accepts gh's trailing "Z" only from Python 3.11, and
    # rehearse.sh may run under macOS's stock python3.
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(value)
    except ValueError as error:
        raise MetaError(
            f"published release {tag}: bad publishedAt {value!r}"
        ) from error


def load_published(path: Path) -> list[PublishedRelease]:
    try:
        entries = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise MetaError(
            f"cannot read published releases from {path}: {error}"
        ) from error
    if not isinstance(entries, list):
        raise MetaError(f"{path}: expected a JSON array from gh release list")
    releases: list[PublishedRelease] = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("tagName"), str):
            raise MetaError(f"{path}: entry without tagName: {entry!r}")
        tag = entry["tagName"]
        if TAG_PATTERN.fullmatch(tag) is None:
            warn(f"ignoring published release with a non-release tag: {tag}")
            continue
        identity = resolve_identity(tag)
        if bool(entry.get("isPrerelease")) != identity.prerelease:
            warn(
                f"published release {tag} has isPrerelease={entry.get('isPrerelease')}"
            )
        releases.append(
            PublishedRelease(
                identity, parse_published_at(entry.get("publishedAt"), tag)
            )
        )
    return releases


def verify_monotonic(
    identity: ReleaseIdentity, published: list[PublishedRelease]
) -> dict[str, str]:
    for release in published:
        if release.identity.tag == identity.tag:
            raise MetaError(f"{identity.tag} is already published")

    same_channel = [r for r in published if r.identity.channel == identity.channel]
    if same_channel:
        newest = max(same_channel, key=lambda r: r.identity.build_key)
        if identity.build_key <= newest.identity.build_key:
            raise MetaError(
                f"{identity.tag} (build {identity.build_version}) is not newer than "
                f"published {newest.identity.tag} (build {newest.identity.build_version})"
            )

    stables = [r for r in published if r.identity.channel == "stable"]
    latest_stable = (
        max(stables, key=lambda r: r.identity.build_key) if stables else None
    )
    if (
        identity.channel == "beta"
        and latest_stable is not None
        and identity.build_key <= latest_stable.identity.build_key
    ):
        raise MetaError(
            f"beta {identity.tag} (build {identity.build_version}) is not newer than "
            f"latest stable {latest_stable.identity.tag} "
            f"(build {latest_stable.identity.build_version})"
        )

    previous = max(published, key=lambda r: r.published_at) if published else None
    return {
        "latest_stable_tag": latest_stable.identity.tag if latest_stable else "",
        "previous_tag": previous.identity.tag if previous else "",
    }


def changelog_section(changelog: str, identity: ReleaseIdentity) -> str:
    if identity.channel == "stable":
        heading = re.compile(
            r"## \["
            + re.escape(identity.version)
            + r"\] - [0-9]{4}-[0-9]{2}-[0-9]{2}[ \t]*"
        )
        label = f"## [{identity.version}] - YYYY-MM-DD"
    else:
        heading = re.compile(r"## \[Unreleased\][ \t]*")
        label = "## [Unreleased]"

    lines = changelog.splitlines()
    starts = [index for index, line in enumerate(lines) if heading.fullmatch(line)]
    if not starts:
        raise MetaError(f"CHANGELOG has no {label} section")
    if len(starts) > 1:
        raise MetaError(f"CHANGELOG has {len(starts)} {label} sections")
    body: list[str] = []
    for line in lines[starts[0] + 1 :]:
        if line.startswith("## "):
            break
        body.append(line)
    return "\n".join(body).strip()


def extract_notes(identity: ReleaseIdentity, changelog_path: Path) -> str:
    try:
        changelog = changelog_path.read_text(encoding="utf-8")
    except OSError as error:
        raise MetaError(f"cannot read {changelog_path}: {error}") from error
    body = changelog_section(changelog, identity)
    if not body:
        raise EmptyNotesError(f"CHANGELOG section for {identity.tag} is empty")
    result = subprocess.run(
        [sys.executable, str(UNWRAPPER)],
        input=body + "\n",
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise MetaError(f"unwrap-release-notes.py failed: {result.stderr.strip()}")
    notes = result.stdout
    if not notes.strip():
        raise EmptyNotesError(f"release notes for {identity.tag} are empty")
    return notes


def tag_message(identity: ReleaseIdentity, repo_dir: Path) -> str:
    ref = f"refs/tags/{identity.tag}"
    object_type = git(repo_dir, "cat-file", "-t", ref)
    if object_type.returncode != 0 or object_type.stdout.strip() != "tag":
        raise MetaError(f"{identity.tag} is not an annotated tag in {repo_dir}")
    contents = git_output_raw(repo_dir, "for-each-ref", "--format=%(contents)", ref)
    signature = git_output_raw(
        repo_dir, "for-each-ref", "--format=%(contents:signature)", ref
    )
    # for-each-ref terminates each record with a newline of its own.
    contents = contents.removesuffix("\n")
    signature = signature.removesuffix("\n")
    if signature and contents.endswith(signature):
        contents = contents[: -len(signature)]
    return contents


def parse_trailers(message: str, identity: ReleaseIdentity) -> Trailers:
    paragraphs: list[list[str]] = [[]]
    for line in message.splitlines():
        if line.strip():
            paragraphs[-1].append(line)
        elif paragraphs[-1]:
            paragraphs.append([])
    paragraphs = [p for p in paragraphs if p]

    trailer_block: list[tuple[str, str]] = []
    last = (
        [TRAILER_LINE.fullmatch(line) for line in paragraphs[-1]] if paragraphs else []
    )
    if len(paragraphs) > 1 and all(last):
        trailer_block = [(m.group(1), m.group(2).rstrip()) for m in last if m]
        body = paragraphs[:-1]
    else:
        body = paragraphs

    # A Sparkle-* line outside the trailer block was meant as a parameter but
    # would be silently ignored, so refuse it instead.
    for paragraph in body:
        for line in paragraph:
            if SPARKLE_KEY.match(line):
                raise MetaError(
                    f"tag {identity.tag}: Sparkle trailer outside the final trailer "
                    f"paragraph: {line.strip()!r}"
                )

    known = {
        PHASED_ROLLOUT_TRAILER.lower(): PHASED_ROLLOUT_TRAILER,
        CRITICAL_UPDATE_TRAILER.lower(): CRITICAL_UPDATE_TRAILER,
    }
    values: dict[str, str] = {}
    for key, value in trailer_block:
        if not key.lower().startswith("sparkle-"):
            continue
        canonical = known.get(key.lower())
        if canonical is None:
            raise MetaError(f"tag {identity.tag}: unknown trailer {key}")
        if canonical in values:
            raise MetaError(f"tag {identity.tag}: duplicate trailer {canonical}")
        values[canonical] = value

    interval = values.get(PHASED_ROLLOUT_TRAILER, "")
    if PHASED_ROLLOUT_TRAILER in values and not POSITIVE_INT_PATTERN.fullmatch(
        interval
    ):
        raise MetaError(
            f"tag {identity.tag}: {PHASED_ROLLOUT_TRAILER} must be a positive "
            f"number of seconds, got {interval!r}"
        )

    critical = values.get(CRITICAL_UPDATE_TRAILER, "")
    if CRITICAL_UPDATE_TRAILER in values and critical != CRITICAL_FROM_ANY_VERSION:
        if VERSION_PATTERN.fullmatch(critical) is None:
            raise MetaError(
                f"tag {identity.tag}: {CRITICAL_UPDATE_TRAILER} must be a build "
                f"version X.Y.Z or '*', got {critical!r}"
            )
        if version_key(critical) > identity.build_key:
            raise MetaError(
                f"tag {identity.tag}: {CRITICAL_UPDATE_TRAILER} {critical} is newer "
                f"than this release's build {identity.build_version}"
            )
    return Trailers(interval, critical)


def verify_app(app: Path, plist_ref: Path, public_key: str) -> None:
    app_plist = app / "Contents" / "Info.plist"
    try:
        actual = app_plist.read_bytes()
        expected = plist_ref.read_bytes()
    except OSError as error:
        raise MetaError(f"cannot read Info.plist: {error}") from error
    if actual != expected:
        raise MetaError(f"{app_plist} differs from the tag's Info.plist {plist_ref}")
    key = read_plist(app_plist).get("SUPublicEDKey")
    if key != public_key:
        raise MetaError(
            f"{app_plist} SUPublicEDKey is {key!r}, expected the pinned key {public_key!r}"
        )


def rehearsal_identity(
    plist: Path, published: list[PublishedRelease]
) -> ReleaseIdentity:
    """The first Beta after both Info.plist and every published release.

    During a Beta cycle main's Info.plist trails the published Betas, so
    bumping Info.plist alone would produce an identity the monotonic gate
    rejects.
    """
    short_version = read_plist(plist).get("CFBundleShortVersionString")
    if not isinstance(short_version, str):
        raise MetaError(f"{plist} has no CFBundleShortVersionString")
    base = version_key(short_version)
    for release in published:
        base = max(base, version_key(release.identity.short_version))
    major, minor, patch = base
    return resolve_identity(f"v{major}.{minor}.{patch + 1}-beta.1")


def non_empty(value: str) -> str:
    if not value:
        raise argparse.ArgumentTypeError("must not be empty")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    def command(
        name: str, help_text: str, *, tag: bool = True
    ) -> argparse.ArgumentParser:
        sub = commands.add_parser(name, help=help_text, description=help_text)
        if tag:
            sub.add_argument("--tag", required=True, help="vX.Y.Z or vX.Y.Z-beta.N")
        sub.add_argument(
            "--github-output",
            type=Path,
            metavar="PATH",
            help="append key=value outputs here (else print them)",
        )
        return sub

    command("identity", "Resolve a release tag into its identity outputs.")

    sub = command(
        "verify-tag", "Check the tag is annotated, is HEAD, and is on its branch."
    )
    sub.add_argument("--repo-dir", type=Path, default=Path("."))
    sub.add_argument(
        "--latest-stable-tag",
        help="latest published stable tag (beta only; empty if none is published)",
    )

    sub = command("verify-plist", "Check Info.plist and Package.swift against the tag.")
    sub.add_argument("--plist", type=Path, required=True)
    sub.add_argument("--package-swift", type=Path, required=True)
    sub.add_argument("--expected-public-key", type=non_empty, metavar="B64")

    sub = command("verify-monotonic", "Check the tag is newer than published releases.")
    sub.add_argument(
        "--published",
        type=Path,
        required=True,
        help="JSON from gh release list --exclude-drafts --json "
        "tagName,isPrerelease,publishedAt",
    )

    sub = command("notes", "Write the unwrapped CHANGELOG notes for the tag.")
    sub.add_argument("--changelog", type=Path, required=True)
    sub.add_argument("--out", type=Path, required=True)
    sub.add_argument(
        "--empty-placeholder",
        metavar="TEXT",
        help="write TEXT instead of failing when the section is empty (rehearsals)",
    )

    sub = command("trailers", "Parse Sparkle-* trailers from the annotated tag.")
    sub.add_argument("--repo-dir", type=Path, default=Path("."))

    sub = command(
        "verify-app", "Check the assembled app's Info.plist and public key.", tag=False
    )
    sub.add_argument("--app", type=Path, required=True)
    sub.add_argument("--plist-ref", type=Path, required=True)
    sub.add_argument("--public-key", type=non_empty, required=True, metavar="B64")

    sub = command(
        "rehearsal-identity",
        "Resolve the next Beta after Info.plist and every published release.",
        tag=False,
    )
    sub.add_argument("--plist", type=Path, required=True)
    sub.add_argument(
        "--published",
        type=Path,
        required=True,
        help="JSON from gh release list --exclude-drafts --json "
        "tagName,isPrerelease,publishedAt",
    )
    return parser


def run(args: argparse.Namespace) -> dict[str, str]:
    if args.command == "verify-app":
        verify_app(args.app, args.plist_ref, args.public_key)
        return {}
    if args.command == "rehearsal-identity":
        return rehearsal_identity(args.plist, load_published(args.published)).outputs()

    identity = resolve_identity(args.tag)
    if args.command == "identity":
        return identity.outputs()
    if args.command == "verify-tag":
        verify_tag(identity, args.repo_dir, args.latest_stable_tag)
    elif args.command == "verify-plist":
        verify_plist(
            identity,
            args.plist,
            args.package_swift,
            args.expected_public_key,
            release_conf.load(),
        )
    elif args.command == "verify-monotonic":
        return verify_monotonic(identity, load_published(args.published))
    elif args.command == "notes":
        try:
            notes = extract_notes(identity, args.changelog)
        except EmptyNotesError as error:
            if args.empty_placeholder is None:
                raise
            warn(f"{error}; writing the placeholder notes")
            notes = args.empty_placeholder.strip() + "\n"
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(notes, encoding="utf-8")
    elif args.command == "trailers":
        return parse_trailers(tag_message(identity, args.repo_dir), identity).outputs()
    return {}


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        emit(run(args), args.github_output)
    except MetaError as error:
        print(f"meta.py: error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Create, fill, verify, and publish the GitHub Release for a tag, by release id.

GitHub allows several draft releases with the same tag_name, and the
`gh release ... <tag>` commands resolve a tag to whichever release the listing
returns first. Anyone with contents:write could add a second draft for the tag
mid-run and have the publish step act on it. So `create` binds the run to one
release id and every later call addresses that id through the REST API. Remote
assets are compared by the server's sha256 digest, not by name and size, and
publishing requires the bound draft to be the only release for its tag.

Every subcommand is safe to re-run ("Re-run failed jobs"): `create` adopts the
single existing draft for the tag (and rewrites its title, body and flags),
`upload` keeps assets whose digest already matches, and `publish` reconciles a
lost response by reading the release state back. A release that is already
published is left alone as long as its assets match.

Subcommands:
  create   bind (create or adopt) the draft; emits release_id
  upload   make the draft's assets exactly the files in --assets
  verify   remote assets == local files (name, state, sha256 digest)
  publish  verify, require a single release for the tag, publish with
           make_latest=false (phase 2 moves `latest` after the feed deploys)

Calls `gh api`, authenticated by GH_TOKEN; the repository comes from --repo,
GH_REPO, or GITHUB_REPOSITORY.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar
from urllib.parse import quote, urlparse

TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]?)?")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
ATTEMPTS = 4

T = TypeVar("T")


class PublishError(Exception):
    """A check failed; the message is shown as-is."""


class GhError(Exception):
    """`gh api` failed; possibly transient."""


@dataclass(frozen=True)
class RemoteAsset:
    id: int
    name: str
    state: str
    digest: str | None


@dataclass(frozen=True)
class Release:
    id: int
    tag_name: str
    draft: bool
    upload_url: str
    assets: tuple[RemoteAsset, ...]

    @classmethod
    def from_json(cls, data: dict) -> Release:
        return cls(
            id=int(data["id"]),
            tag_name=str(data["tag_name"]),
            draft=bool(data["draft"]),
            upload_url=str(data.get("upload_url", "")),
            assets=tuple(
                RemoteAsset(
                    id=int(asset["id"]),
                    name=str(asset["name"]),
                    state=str(asset["state"]),
                    digest=asset.get("digest"),
                )
                for asset in data.get("assets", [])
            ),
        )


@dataclass(frozen=True)
class LocalAsset:
    name: str
    path: Path
    digest: str


def log(message: str) -> None:
    print(f"▸ {message}", file=sys.stderr, flush=True)


class GitHub:
    def __init__(self, repo: str, retry_delay: float) -> None:
        self.repo = repo
        self.retry_delay = retry_delay

    def api(self, method: str, path: str, *, body: dict | None = None,
            input_file: Path | None = None, headers: Sequence[str] = (),
            paginate: bool = False) -> object:
        args = ["gh", "api", "--method", method, path]
        for header in headers:
            args += ["-H", header]
        if paginate:
            args += ["--paginate", "--slurp"]
        stdin: str | None = None
        if body is not None:
            args += ["--input", "-"]
            stdin = json.dumps(body)
        elif input_file is not None:
            args += ["--input", str(input_file)]
        result = subprocess.run(args, input=stdin, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise GhError(f"gh api {method} {path} failed: {result.stderr.strip() or result.returncode}")
        try:
            return json.loads(result.stdout) if result.stdout.strip() else None
        except json.JSONDecodeError:
            raise GhError(f"gh api {method} {path} returned invalid JSON") from None

    def retry(self, label: str, action: Callable[[], T]) -> T:
        """Retry an idempotent call with exponential backoff."""
        delay = self.retry_delay
        for attempt in range(1, ATTEMPTS + 1):
            try:
                return action()
            except GhError as error:
                if attempt == ATTEMPTS:
                    raise PublishError(f"{label} failed after {ATTEMPTS} attempts: {error}") from None
                log(f"{label} failed ({error}); retry {attempt + 1}/{ATTEMPTS} in {delay:g}s")
                time.sleep(delay)
                delay *= 2
        raise AssertionError("unreachable")

    def release(self, release_id: int) -> Release:
        data = self.retry(f"Read release {release_id}",
                          lambda: self.api("GET", f"repos/{self.repo}/releases/{release_id}"))
        assert isinstance(data, dict)
        return Release.from_json(data)

    def releases_for_tag(self, tag: str) -> list[Release]:
        pages = self.retry("List releases", lambda: self.api(
            "GET", f"repos/{self.repo}/releases?per_page=100", paginate=True))
        assert isinstance(pages, list)
        return [Release.from_json(item) for page in pages for item in page if item.get("tag_name") == tag]

    def tag_commit(self, tag: str) -> str:
        ref = self.retry(f"Read refs/tags/{tag}",
                         lambda: self.api("GET", f"repos/{self.repo}/git/ref/tags/{tag}"))
        assert isinstance(ref, dict)
        target = ref["object"]
        # Peel annotated tags (a tag may point at another tag object).
        for _ in range(5):
            if target["type"] == "commit":
                return str(target["sha"])
            if target["type"] != "tag":
                break
            sha = target["sha"]
            tag_object = self.retry(f"Read tag object {sha}",
                                    lambda sha=sha: self.api("GET", f"repos/{self.repo}/git/tags/{sha}"))
            assert isinstance(tag_object, dict)
            target = tag_object["object"]
        raise PublishError(f"refs/tags/{tag} does not point at a commit")


def sha256_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return f"sha256:{digest.hexdigest()}"


def local_assets(directory: Path) -> list[LocalAsset]:
    if not directory.is_dir():
        raise PublishError(f"assets directory not found: {directory}")
    files = sorted(path for path in directory.iterdir() if not path.name.startswith("."))
    if not files:
        raise PublishError(f"no assets in {directory}")
    for path in files:
        if not path.is_file() or path.is_symlink():
            raise PublishError(f"asset is not a regular file: {path}")
    return [LocalAsset(path.name, path, sha256_digest(path)) for path in files]


def asset_differences(release: Release, assets: Sequence[LocalAsset]) -> list[str]:
    expected = {asset.name: asset.digest for asset in assets}
    remote: dict[str, RemoteAsset] = {}
    problems: list[str] = []
    for asset in release.assets:
        if asset.name in remote:
            problems.append(f"{asset.name}: listed twice")
        remote[asset.name] = asset
    for name, digest in expected.items():
        found = remote.get(name)
        if found is None:
            problems.append(f"{name}: missing")
        elif found.state != "uploaded":
            problems.append(f"{name}: state {found.state}")
        elif found.digest != digest:
            problems.append(f"{name}: remote digest {found.digest}, local {digest}")
    problems += [f"{name}: not a local asset" for name in sorted(set(remote) - set(expected))]
    return problems


def check_bound(release: Release, tag: str) -> None:
    if release.tag_name != tag:
        raise PublishError(f"release {release.id} is for {release.tag_name}, not {tag}")


def upload_base(release: Release, repo: str) -> str:
    base = release.upload_url.split("{", 1)[0]
    parsed = urlparse(base)
    if (parsed.scheme, parsed.netloc) != ("https", "uploads.github.com") \
            or parsed.path != f"/repos/{repo}/releases/{release.id}/assets":
        raise PublishError(f"unexpected upload_url for release {release.id}: {release.upload_url!r}")
    return base


# --- subcommands -------------------------------------------------------------------


def create(gh: GitHub, args: argparse.Namespace) -> dict[str, str]:
    commit = gh.tag_commit(args.tag)
    if commit != args.commit:
        raise PublishError(f"{args.tag} is {commit} on GitHub, but this run built {args.commit}")
    fields = {
        "tag_name": args.tag,
        "name": args.title,
        "body": args.notes.read_text(encoding="utf-8"),
        "prerelease": args.prerelease,
        "make_latest": "false",
    }

    def bind(existing: list[Release]) -> Release | None:
        published = [release for release in existing if not release.draft]
        if published:
            if len(existing) != 1:
                raise PublishError(f"{args.tag} has a published release and {len(existing) - 1} other(s)")
            log(f"{args.tag} is already published as release {published[0].id}")
            return published[0]
        if len(existing) > 1:
            ids = ", ".join(str(release.id) for release in existing)
            raise PublishError(f"{args.tag} has {len(existing)} draft releases ({ids}); delete the extra drafts")
        if existing:
            draft = existing[0]
            log(f"Adopting draft release {draft.id} for {args.tag}")
            gh.retry(f"Update draft {draft.id}", lambda: gh.api(
                "PATCH", f"repos/{gh.repo}/releases/{draft.id}", body={**fields, "draft": True}))
            return draft
        return None

    release = bind(gh.releases_for_tag(args.tag))
    attempt = 0
    while release is None:
        attempt += 1
        try:
            created = gh.api("POST", f"repos/{gh.repo}/releases", body={**fields, "draft": True})
            assert isinstance(created, dict)
            release = Release.from_json(created)
            log(f"Created draft release {release.id} for {args.tag}")
        except GhError as error:
            if attempt == ATTEMPTS:
                raise PublishError(f"Create draft for {args.tag} failed: {error}") from None
            log(f"Create draft failed ({error}); checking whether it exists")
            time.sleep(gh.retry_delay * attempt)
            # A lost response may still have created the draft.
            release = bind(gh.releases_for_tag(args.tag))
    return {"release_id": str(release.id)}


def upload(gh: GitHub, args: argparse.Namespace) -> dict[str, str]:
    assets = local_assets(args.assets)
    release = gh.release(args.release_id)
    check_bound(release, args.tag)
    if not release.draft:
        problems = asset_differences(release, assets)
        if problems:
            raise PublishError(f"release {release.id} is published with different assets: {'; '.join(problems)}")
        log(f"Release {release.id} is already published with these assets")
        return {}
    base = upload_base(release, gh.repo)
    wanted = {asset.name for asset in assets}

    for _ in range(ATTEMPTS):
        release = gh.release(args.release_id)
        if not release.draft:
            raise PublishError(f"release {release.id} was published while uploading")
        remote = {asset.name: asset for asset in release.assets}
        for stray in sorted(set(remote) - wanted):
            log(f"Delete stray asset {stray}")
            gh.retry(f"Delete {stray}", lambda a=remote[stray]: gh.api(
                "DELETE", f"repos/{gh.repo}/releases/assets/{a.id}"))
        failed = False
        for asset in assets:
            existing = remote.get(asset.name)
            if existing and existing.state == "uploaded" and existing.digest == asset.digest:
                continue
            try:
                if existing:
                    # Incomplete or different bytes: replace it.
                    gh.api("DELETE", f"repos/{gh.repo}/releases/assets/{existing.id}")
                log(f"Upload {asset.name}")
                gh.api("POST", f"{base}?name={quote(asset.name)}", input_file=asset.path,
                       headers=["Content-Type: application/octet-stream"])
            except GhError as error:
                log(f"{asset.name}: {error}; reconciling")
                failed = True
        if not failed and not asset_differences(gh.release(args.release_id), assets):
            return {}
        time.sleep(gh.retry_delay)
    problems = asset_differences(gh.release(args.release_id), assets)
    raise PublishError(f"assets of release {args.release_id} still differ: {'; '.join(problems) or 'upload errors'}")


def verify(gh: GitHub, args: argparse.Namespace) -> dict[str, str]:
    assets = local_assets(args.assets)
    release = gh.release(args.release_id)
    check_bound(release, args.tag)
    problems = asset_differences(release, assets)
    if problems:
        raise PublishError(f"remote assets of release {release.id} differ: {'; '.join(problems)}")
    log(f"Release {release.id}: {len(assets)} assets match by sha256 digest")
    return {}


def publish(gh: GitHub, args: argparse.Namespace) -> dict[str, str]:
    verify(gh, args)
    others = [release.id for release in gh.releases_for_tag(args.tag) if release.id != args.release_id]
    if others:
        raise PublishError(f"{args.tag} has other releases besides {args.release_id}: {others}")
    if gh.release(args.release_id).draft:
        try:
            gh.api("PATCH", f"repos/{gh.repo}/releases/{args.release_id}",
                   body={"draft": False, "make_latest": "false"})
        except GhError as error:
            # The server may have published before the response was lost.
            log(f"Publish request failed ({error}); checking the release state")
    release = gh.release(args.release_id)
    if release.draft:
        raise PublishError(f"release {release.id} is still a draft")
    verify(gh, args)
    log(f"Published {args.tag} as release {release.id}")
    return {}


# --- CLI ----------------------------------------------------------------------------


def tag_arg(value: str) -> str:
    if not TAG_PATTERN.fullmatch(value):
        raise argparse.ArgumentTypeError(f"not a release tag: {value!r}")
    return value


def sha_arg(value: str) -> str:
    if not SHA_PATTERN.fullmatch(value):
        raise argparse.ArgumentTypeError(f"not a full commit SHA: {value!r}")
    return value


def positive_int(value: str) -> int:
    if not value.isdigit() or int(value) <= 0:
        raise argparse.ArgumentTypeError(f"not a release id: {value!r}")
    return int(value)


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", default=os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY"),
                        help="OWNER/REPO (default: $GH_REPO, then $GITHUB_REPOSITORY)")
    parser.add_argument("--retry-delay", type=float, default=2.0, help=argparse.SUPPRESS)
    parser.add_argument("--github-output", type=Path, help="append key=value outputs here")
    commands = parser.add_subparsers(dest="command", required=True)

    create_parser = commands.add_parser("create", help="bind the draft release for the tag")
    create_parser.add_argument("--tag", type=tag_arg, required=True)
    create_parser.add_argument("--commit", type=sha_arg, required=True,
                               help="commit the tag must peel to on GitHub")
    create_parser.add_argument("--title", required=True)
    create_parser.add_argument("--notes", type=Path, required=True)
    create_parser.add_argument("--prerelease", action="store_true")

    for name, help_text in (("upload", "upload the assets to the draft"),
                            ("verify", "compare remote assets with local files"),
                            ("publish", "publish the verified draft")):
        sub = commands.add_parser(name, help=help_text)
        sub.add_argument("--release-id", type=positive_int, required=True)
        sub.add_argument("--tag", type=tag_arg, required=True)
        sub.add_argument("--assets", type=Path, required=True)

    args = parser.parse_args(argv)
    if not args.repo or not REPOSITORY_PATTERN.fullmatch(args.repo):
        parser.error(f"--repo must be OWNER/REPO, got {args.repo!r}")
    return args


COMMANDS: dict[str, Callable[[GitHub, argparse.Namespace], dict[str, str]]] = {
    "create": create,
    "upload": upload,
    "verify": verify,
    "publish": publish,
}


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    gh = GitHub(args.repo, args.retry_delay)
    try:
        outputs = COMMANDS[args.command](gh, args)
    except (PublishError, OSError) as error:
        print(f"✗ {error}", file=sys.stderr)
        return 1
    lines = "".join(f"{key}={value}\n" for key, value in outputs.items())
    if args.github_output is not None:
        with args.github_output.open("a", encoding="utf-8") as handle:
            handle.write(lines)
    else:
        sys.stdout.write(lines)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

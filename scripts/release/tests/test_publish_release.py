"""Behavior checks for scripts/release/publish_release.py.

`gh api` is the only boundary faked: an executable on PATH serves a small
file-backed model of the Releases REST API, including duplicate drafts for one
tag and responses lost after the server applied the change.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RELEASE_DIR = Path(__file__).resolve().parents[1]
PUBLISH = RELEASE_DIR / "publish_release.py"
REPO = "owner/AnyDoor"
TAG = "v4.2.8"
COMMIT = "1" * 40
TAG_OBJECT = "2" * 40

FAKE_GH = r'''
import hashlib, json, os, sys
from urllib.parse import parse_qs, urlparse

args = sys.argv[1:]
state_path = os.environ["FAKE_GH_STATE"]
state = json.load(open(state_path))
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")

assert args[:2] == ["api", "--method"], args
method, path = args[2], args[3]
rest = args[4:]
body = None
if "--input" in rest:
    source = rest[rest.index("--input") + 1]
    body = sys.stdin.read() if source == "-" else open(source, "rb").read()
repo = state["repo"]


def save():
    json.dump(state, open(state_path, "w"))


def fail_if_planned(key, applied):
    for plan in state["failures"]:
        if plan["key"] == key and plan["when"] == applied and plan["times"] > 0:
            plan["times"] -= 1
            save()
            sys.stderr.write(f"HTTP 502: planned failure for {key}\n")
            sys.exit(1)


def release_view(release):
    return {**release, "upload_url": f"https://uploads.github.com/repos/{repo}/releases/{release['id']}/assets{{?name,label}}"}


def find(release_id):
    for release in state["releases"]:
        if release["id"] == release_id:
            return release
    sys.stderr.write("HTTP 404\n")
    sys.exit(1)


parsed = urlparse(path)
parts = parsed.path.strip("/").split("/")
if parsed.netloc == "uploads.github.com":
    key = "upload"
    fail_if_planned(key, False)
    release = find(int(parts[4]))
    name = parse_qs(parsed.query)["name"][0]
    if any(asset["name"] == name for asset in release["assets"]):
        sys.stderr.write("HTTP 422: already_exists\n")
        sys.exit(1)
    state["next_id"] += 1
    digest = "sha256:" + hashlib.sha256(body).hexdigest()
    asset = {"id": state["next_id"], "name": name, "state": "uploaded", "size": len(body), "digest": digest}
    release["assets"].append(asset)
    save()
    fail_if_planned(key, True)
    print(json.dumps(asset))
    sys.exit(0)

assert parts[:3] == ["repos", *repo.split("/")], parts
tail = parts[3:]
if method == "GET" and tail[:3] == ["git", "ref", "tags"]:
    print(json.dumps({"object": {"type": "tag", "sha": state["tag_object"]}}))
elif method == "GET" and tail[:2] == ["git", "tags"]:
    print(json.dumps({"object": {"type": "commit", "sha": state["tag_commit"]}}))
elif method == "GET" and tail == ["releases"]:
    views = [release_view(r) for r in sorted(state["releases"], key=lambda r: -r["id"])]
    print(json.dumps([views]))  # --paginate --slurp: a list of pages
elif method == "GET" and tail[0] == "releases":
    print(json.dumps(release_view(find(int(tail[1])))))
elif method == "POST" and tail == ["releases"]:
    fail_if_planned("create", False)
    fields = json.loads(body)
    state["next_id"] += 1
    release = {"id": state["next_id"], "assets": [], **fields}
    state["releases"].append(release)
    save()
    fail_if_planned("create", True)
    print(json.dumps(release_view(release)))
elif method == "PATCH" and tail[0] == "releases":
    fields = json.loads(body)
    key = "publish" if fields.get("draft") is False else "update"
    fail_if_planned(key, False)
    release = find(int(tail[1]))
    release.update(fields)
    save()
    fail_if_planned(key, True)
    print(json.dumps(release_view(release)))
elif method == "DELETE" and tail[:2] == ["releases", "assets"]:
    for release in state["releases"]:
        release["assets"] = [a for a in release["assets"] if a["id"] != int(tail[2])]
    save()
else:
    sys.stderr.write(f"fake gh: unexpected {method} {path}\n")
    sys.exit(2)
'''


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


class PublishReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(f"#!{sys.executable}\n{FAKE_GH}")
        gh.chmod(0o755)
        self.state_path = self.root / "state.json"
        self.log_path = self.root / "gh.log"
        self.write_state({"repo": REPO, "releases": [], "failures": [], "next_id": 100,
                          "tag_object": TAG_OBJECT, "tag_commit": COMMIT})
        self.env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                    "FAKE_GH_STATE": str(self.state_path), "FAKE_GH_LOG": str(self.log_path),
                    "GH_REPO": REPO}
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.files = {"AnyDoor-4.2.8.dmg": b"dmg bytes", "AnyDoor-4.2.8.zip": b"zip bytes",
                      "appcast.xml": b"<rss/>", "SHA256SUMS": b"sums"}
        for name, data in self.files.items():
            (self.assets / name).write_bytes(data)
        self.notes = self.root / "notes.md"
        self.notes.write_text("### Fixed\n\n- Things.\n")
        self.output = self.root / "github-output"

    def write_state(self, state: dict) -> None:
        self.state_path.write_text(json.dumps(state))

    def state(self) -> dict:
        return json.loads(self.state_path.read_text())

    def update_state(self, **values: object) -> None:
        state = self.state()
        state.update(values)
        self.write_state(state)

    def plan_failure(self, key: str, *, applied: bool, times: int = 1) -> None:
        state = self.state()
        state["failures"].append({"key": key, "when": applied, "times": times})
        self.write_state(state)

    def run_publish(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(PUBLISH), "--retry-delay", "0", *args],
                              env=self.env, capture_output=True, text=True, check=False)

    def create(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return self.run_publish("--github-output", str(self.output), "create", "--tag", TAG,
                                "--commit", COMMIT, "--title", "AnyDoor 4.2.8", "--notes", str(self.notes),
                                *extra)

    def by_id(self, command: str, release_id: int) -> subprocess.CompletedProcess[str]:
        return self.run_publish(command, "--release-id", str(release_id), "--tag", TAG,
                                "--assets", str(self.assets))

    def release(self, release_id: int) -> dict:
        return next(r for r in self.state()["releases"] if r["id"] == release_id)

    def bound_id(self) -> int:
        lines = self.output.read_text().splitlines()
        self.assertEqual(len(lines), 1, lines)
        key, _, value = lines[-1].partition("=")
        self.assertEqual(key, "release_id")
        return int(value)

    def foreign_draft(self, assets: list[dict]) -> dict:
        state = self.state()
        state["next_id"] += 1
        draft = {"id": state["next_id"], "tag_name": TAG, "name": "evil", "body": "evil", "draft": True,
                 "prerelease": False, "assets": assets}
        state["releases"].append(draft)
        self.write_state(state)
        return draft

    def test_full_flow_publishes_without_moving_latest(self) -> None:
        created = self.create()
        self.assertEqual(created.returncode, 0, created.stderr)
        release_id = self.bound_id()
        draft = self.release(release_id)
        self.assertEqual((draft["draft"], draft["make_latest"], draft["prerelease"]), (True, "false", False))
        self.assertEqual(draft["body"], self.notes.read_text())

        for command in ("upload", "verify", "publish"):
            result = self.by_id(command, release_id)
            self.assertEqual(result.returncode, 0, f"{command}: {result.stderr}")
        published = self.release(release_id)
        self.assertFalse(published["draft"])
        self.assertEqual(published["make_latest"], "false")
        self.assertEqual({a["name"]: a["digest"] for a in published["assets"]},
                         {name: digest(data) for name, data in self.files.items()})
        # Every mutation addresses the bound id, never the tag name.
        for line in self.log_path.read_text().splitlines():
            call = json.loads(line)
            if call[2] in ("PATCH", "DELETE") or "uploads.github.com" in call[3]:
                self.assertTrue(f"/releases/{release_id}" in call[3] or "/releases/assets/" in call[3], call)

    def test_prerelease_flag(self) -> None:
        self.assertEqual(self.create("--prerelease").returncode, 0)
        self.assertTrue(self.release(self.bound_id())["prerelease"])

    def test_tag_must_peel_to_the_built_commit(self) -> None:
        self.update_state(tag_commit="3" * 40)
        result = self.create()
        self.assertEqual(result.returncode, 1)
        self.assertIn("this run built", result.stderr)
        self.assertEqual(self.state()["releases"], [])

    def test_rerun_adopts_the_single_draft_and_resets_its_fields(self) -> None:
        draft = self.foreign_draft([])
        result = self.create()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.bound_id(), draft["id"])
        adopted = self.release(draft["id"])
        self.assertEqual((adopted["name"], adopted["make_latest"]), ("AnyDoor 4.2.8", "false"))
        self.assertEqual(len(self.state()["releases"]), 1)

    def test_duplicate_drafts_stop_create_and_publish(self) -> None:
        self.foreign_draft([])
        self.foreign_draft([])
        result = self.create()
        self.assertEqual(result.returncode, 1)
        self.assertIn("2 draft releases", result.stderr)

    def test_second_draft_added_mid_run_blocks_publish(self) -> None:
        self.assertEqual(self.create().returncode, 0)
        release_id = self.bound_id()
        self.assertEqual(self.by_id("upload", release_id).returncode, 0)
        # Same names and sizes as the public artifact, different bytes.
        fake_assets = [{"id": 900 + i, "name": name, "state": "uploaded", "size": len(data),
                        "digest": digest(data.upper())} for i, (name, data) in enumerate(self.files.items())]
        attacker = self.foreign_draft(fake_assets)
        result = self.by_id("publish", release_id)
        self.assertEqual(result.returncode, 1)
        self.assertIn("other releases", result.stderr)
        self.assertTrue(self.release(release_id)["draft"])
        self.assertTrue(self.release(attacker["id"])["draft"])

    def test_same_size_different_bytes_fail_verification(self) -> None:
        self.assertEqual(self.create().returncode, 0)
        release_id = self.bound_id()
        self.assertEqual(self.by_id("upload", release_id).returncode, 0)
        state = self.state()
        asset = next(a for a in self.release(release_id)["assets"] if a["name"] == "appcast.xml")
        for release in state["releases"]:
            for remote in release["assets"]:
                if remote["id"] == asset["id"]:
                    remote["digest"] = digest(b"<RSS/>")
        self.write_state(state)
        result = self.by_id("verify", release_id)
        self.assertEqual(result.returncode, 1)
        self.assertIn("appcast.xml: remote digest", result.stderr)
        self.assertEqual(self.by_id("publish", release_id).returncode, 1)
        self.assertTrue(self.release(release_id)["draft"])

        # upload replaces the mismatched asset; then publishing succeeds.
        self.assertEqual(self.by_id("upload", release_id).returncode, 0)
        self.assertEqual(self.by_id("publish", release_id).returncode, 0)

    def test_upload_removes_stray_assets_and_keeps_matching_ones(self) -> None:
        self.assertEqual(self.create().returncode, 0)
        release_id = self.bound_id()
        state = self.state()
        release = next(r for r in state["releases"] if r["id"] == release_id)
        release["assets"] = [
            {"id": 1, "name": "AnyDoor-4.2.8.dmg", "state": "uploaded", "size": 9,
             "digest": digest(self.files["AnyDoor-4.2.8.dmg"])},
            {"id": 2, "name": "AnyDoor-4.2.8.zip", "state": "starter", "size": 0, "digest": None},
            {"id": 3, "name": "leftover.txt", "state": "uploaded", "size": 1, "digest": digest(b"x")},
        ]
        self.write_state(state)
        result = self.by_id("upload", release_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        assets = {a["name"]: a for a in self.release(release_id)["assets"]}
        self.assertEqual(set(assets), set(self.files))
        self.assertEqual(assets["AnyDoor-4.2.8.dmg"]["id"], 1, "a matching upload is kept")
        self.assertNotEqual(assets["AnyDoor-4.2.8.zip"]["id"], 2, "an incomplete upload is replaced")

    def test_lost_responses_are_reconciled(self) -> None:
        self.plan_failure("create", applied=True)
        created = self.create()
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertEqual(len(self.state()["releases"]), 1, "the lost create is adopted, not repeated")
        release_id = self.bound_id()

        self.plan_failure("upload", applied=True, times=2)
        self.plan_failure("upload", applied=False)
        uploaded = self.by_id("upload", release_id)
        self.assertEqual(uploaded.returncode, 0, uploaded.stderr)

        self.plan_failure("publish", applied=True)
        published = self.by_id("publish", release_id)
        self.assertEqual(published.returncode, 0, published.stderr)
        self.assertFalse(self.release(release_id)["draft"])

    def test_rerun_after_publication_is_a_verified_no_op(self) -> None:
        self.assertEqual(self.create().returncode, 0)
        release_id = self.bound_id()
        for command in ("upload", "publish"):
            self.assertEqual(self.by_id(command, release_id).returncode, 0)
        self.output.unlink()
        self.assertEqual(self.create().returncode, 0)
        self.assertEqual(self.bound_id(), release_id)
        for command in ("upload", "publish"):
            result = self.by_id(command, release_id)
            self.assertEqual(result.returncode, 0, result.stderr)

        (self.assets / "appcast.xml").write_bytes(b"<rss>changed</rss>")
        changed = self.by_id("upload", release_id)
        self.assertEqual(changed.returncode, 1)
        self.assertIn("published with different assets", changed.stderr)

    def test_release_id_must_belong_to_the_tag(self) -> None:
        self.assertEqual(self.create().returncode, 0)
        release_id = self.bound_id()
        result = self.run_publish("verify", "--release-id", str(release_id), "--tag", "v4.2.9",
                                  "--assets", str(self.assets))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not v4.2.9", result.stderr)

    def test_argument_validation(self) -> None:
        cases = [
            ["create", "--tag", "4.2.8", "--commit", COMMIT, "--title", "t", "--notes", str(self.notes)],
            ["create", "--tag", TAG, "--commit", "abc", "--title", "t", "--notes", str(self.notes)],
            ["upload", "--release-id", "0", "--tag", TAG, "--assets", str(self.assets)],
            ["--repo", "a/b/c", "verify", "--release-id", "1", "--tag", TAG, "--assets", str(self.assets)],
        ]
        for args in cases:
            with self.subTest(args=args):
                self.assertEqual(self.run_publish(*args).returncode, 2)
        self.assertEqual(self.run_publish("--help").returncode, 0)


if __name__ == "__main__":
    unittest.main()

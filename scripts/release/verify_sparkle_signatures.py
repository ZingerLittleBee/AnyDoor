#!/usr/bin/env python3
"""Independently verify the Sparkle EdDSA signatures in a generated appcast.

generate_appcast only warns (generate_appcast/Appcast.swift:200-210) when the
private key does not match an archive's SUPublicEDKey, so the pipeline cannot
trust its exit code. This checks, with the public key the shipped app trusts:
  * each --archive: the enclosure's sparkle:edSignature is an Ed25519
    signature over the file's bytes and its length attribute is the file size;
  * the signed-feed block that Sparkle 2.9 appends to appcast.xml.

Signed-feed format (Sparkle 2.9.2):
  * writer, common_cli/Signing.swift:85-99: the signature covers every byte
    before the block, and the block is appended verbatim as
    "<!-- sparkle-signatures:\\nedSignature: <base64>\\nlength: <n>\\n-->\\n";
  * reader, Sparkle/SPUExtractSignedFeed.m:11-60: the LAST occurrence of
    "<!-- sparkle-signatures:\\n" starts the block, the first "-->" after it ends
    it, and lines prefixed "edSignature:" / "length:" carry the values;
  * client, Sparkle/SUAppcastDriver.m:95-133: verifies the signature over the
    content before the block. We are stricter: length must equal the content
    size and only a final newline may follow the block.

Run with: uv run --locked --project scripts/release python scripts/release/verify_sparkle_signatures.py
"""

from __future__ import annotations

import argparse
import base64
import binascii
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_BLOCK_PREFIX = b"<!-- sparkle-signatures:\n"
FEED_BLOCK_SUFFIX = b"-->"


class VerificationError(Exception):
    pass


@dataclass(frozen=True)
class FeedSignature:
    content: bytes
    signature: bytes
    length: int


@dataclass(frozen=True)
class ArchiveCheck:
    basename: str
    path: Path


def decode_signature(text: str, what: str) -> bytes:
    try:
        signature = base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError):
        raise VerificationError(f"{what} is not valid base64") from None
    if len(signature) != 64:
        raise VerificationError(f"{what} decodes to {len(signature)} bytes, expected 64")
    return signature


def load_public_key(text: str) -> Ed25519PublicKey:
    try:
        raw = base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError):
        raise VerificationError("--public-key is not valid base64") from None
    if len(raw) != 32:
        raise VerificationError(f"--public-key decodes to {len(raw)} bytes, expected 32")
    return Ed25519PublicKey.from_public_bytes(raw)


def extract_feed_signature(data: bytes) -> FeedSignature | None:
    """Split a signed appcast the way SPUExtractAppcastContent does."""
    start = data.rfind(FEED_BLOCK_PREFIX)
    if start < 0:
        return None
    body_start = start + len(FEED_BLOCK_PREFIX)
    end = data.find(FEED_BLOCK_SUFFIX, body_start)
    if end < 0:
        raise VerificationError("feed signature block is not terminated by '-->'")
    trailer = data[end + len(FEED_BLOCK_SUFFIX):]
    if trailer not in (b"", b"\n"):
        raise VerificationError("unexpected bytes after the feed signature block")

    try:
        block = data[body_start:end].decode("utf-8")
    except UnicodeDecodeError:
        raise VerificationError("feed signature block is not UTF-8") from None
    signature_text: str | None = None
    length_text: str | None = None
    for line in block.splitlines():
        if line.startswith("edSignature:"):
            signature_text = line[len("edSignature:"):].strip()
        elif line.startswith("length:"):
            length_text = line[len("length:"):].strip()
    if signature_text is None:
        raise VerificationError("feed signature block has no edSignature line")
    if length_text is None or not length_text.isdigit():
        raise VerificationError("feed signature block has no numeric length line")
    return FeedSignature(
        content=data[:start],
        signature=decode_signature(signature_text, "feed edSignature"),
        length=int(length_text),
    )


def verify_feed(data: bytes, public_key: Ed25519PublicKey, required: bool) -> bytes:
    """Return the feed content (signature block stripped) after verifying it."""
    feed = extract_feed_signature(data)
    if feed is None:
        if required:
            raise VerificationError("appcast has no Sparkle feed signature block")
        return data
    if feed.length != len(feed.content):
        raise VerificationError(
            f"feed signature length is {feed.length}, signed content is {len(feed.content)} bytes"
        )
    try:
        public_key.verify(feed.signature, feed.content)
    except InvalidSignature:
        raise VerificationError("feed EdDSA signature does not verify with the public key") from None
    return feed.content


def enclosure_basename(url: str) -> str:
    return unquote(urlparse(url).path.rsplit("/", 1)[-1])


def verify_archive(root: ET.Element, check: ArchiveCheck, public_key: Ed25519PublicKey) -> None:
    matches = [
        enclosure
        for enclosure in root.iter("enclosure")
        if enclosure_basename(enclosure.get("url", "")) == check.basename
    ]
    if len(matches) != 1:
        raise VerificationError(
            f"expected one enclosure for {check.basename}, found {len(matches)}"
        )
    enclosure = matches[0]
    signature_text = enclosure.get(f"{{{SPARKLE}}}edSignature")
    if not signature_text:
        raise VerificationError(f"{check.basename}: enclosure has no sparkle:edSignature")
    signature = decode_signature(signature_text, f"{check.basename} sparkle:edSignature")

    data = check.path.read_bytes()
    length_text = enclosure.get("length", "")
    if not length_text.isdigit() or int(length_text) != len(data):
        raise VerificationError(
            f"{check.basename}: enclosure length is {length_text!r}, file is {len(data)} bytes"
        )
    try:
        public_key.verify(signature, data)
    except InvalidSignature:
        raise VerificationError(
            f"{check.basename}: EdDSA signature does not verify with the public key"
        ) from None


def parse_archive(value: str) -> ArchiveCheck:
    basename, separator, path = value.partition("=")
    if not separator or not basename or not path or "/" in basename:
        raise argparse.ArgumentTypeError(f"expected URL_BASENAME=PATH, got {value!r}")
    return ArchiveCheck(basename=basename, path=Path(path))


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--public-key", required=True,
                        help="base64 Ed25519 public key (the app's SUPublicEDKey)")
    parser.add_argument("--archive", type=parse_archive, action="append", default=[],
                        metavar="URL_BASENAME=PATH",
                        help="verify the enclosure whose URL ends in URL_BASENAME against PATH")
    parser.add_argument("--require-feed-signature", action="store_true",
                        help="fail when the appcast carries no signed-feed block")
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> list[str]:
    public_key = load_public_key(args.public_key)
    data = args.appcast.read_bytes()
    content = verify_feed(data, public_key, args.require_feed_signature)
    try:
        root = ET.fromstring(content)
    except ET.ParseError as error:
        raise VerificationError(f"cannot parse appcast: {error}") from None
    for check in args.archive:
        verify_archive(root, check, public_key)
    return [check.basename for check in args.archive]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        verified = run(args)
    except (VerificationError, OSError) as error:
        print(f"sparkle signature check failed: {error}", file=sys.stderr)
        return 1
    feed_note = "feed signature verified" if extract_feed_signature(args.appcast.read_bytes()) else "feed unsigned"
    print(f"sparkle signatures OK: {feed_note}; archives: {', '.join(verified) or 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

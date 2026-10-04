#!/usr/bin/env python3
"""Sparkle EdDSA (ed25519) key helpers for the release pipeline.

Key format, as read by Sparkle 2.9.2 `sign_update --ed-key-file` and
`generate_appcast --ed-key-file`: one line of base64 whose decoded bytes are
either
  * 32 bytes: the private seed ("new format", what `generate_keys` creates and
    `generate_keys -x` exports), or
  * 96 bytes: the legacy orlp/ed25519 expanded private key (64 bytes) followed
    by the public key (32 bytes).
See .build/checkouts/Sparkle/common_cli/Secret.swift:11-47 (decoding) and
sign_update/main.swift:54-86 (one stdin line, base64, then decode).

Run with: uv run --locked --project scripts/release python scripts/release/sparkle_keys.py
"""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

SEED_LENGTH = 32
LEGACY_SECRET_LENGTH = 64 + 32
PUBLIC_KEY_LENGTH = 32


class InvalidKeyError(ValueError):
    """A private-key secret that Sparkle would reject."""


@dataclass(frozen=True)
class SparkleKeyPair:
    secret_base64: str
    public_base64: str


def decode_base64(text: str, what: str) -> bytes:
    try:
        return base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError) as error:
        raise InvalidKeyError(f"{what} is not valid base64: {error}") from None


def public_key_from_secret(secret_base64: str) -> str:
    """Return the base64 public key Sparkle derives from an exported secret."""
    secret = decode_base64(secret_base64, "private key")
    if len(secret) == SEED_LENGTH:
        private = Ed25519PrivateKey.from_private_bytes(secret)
        public = private.public_key().public_bytes_raw()
    elif len(secret) == LEGACY_SECRET_LENGTH:
        # Sparkle trusts the embedded public half of the legacy format
        # (Secret.swift:39-41); a mismatched half yields signatures that
        # verify_sparkle_signatures.py rejects downstream.
        public = secret[64:]
    else:
        raise InvalidKeyError(
            f"private key decodes to {len(secret)} bytes; Sparkle accepts "
            f"{SEED_LENGTH} (seed) or {LEGACY_SECRET_LENGTH} (legacy) bytes"
        )
    return base64.b64encode(public).decode("ascii")


def generate() -> SparkleKeyPair:
    private = Ed25519PrivateKey.generate()
    seed = private.private_bytes_raw()
    return SparkleKeyPair(
        secret_base64=base64.b64encode(seed).decode("ascii"),
        public_base64=base64.b64encode(private.public_key().public_bytes_raw()).decode("ascii"),
    )


def write_new_file(path: Path, text: str, mode: int) -> None:
    # O_EXCL: never clobber an existing key file; mode applies at creation.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(text)


def command_generate(args: argparse.Namespace) -> int:
    if args.private_out == args.public_out:
        raise InvalidKeyError("--private-out and --public-out must differ")
    pair = generate()
    write_new_file(args.private_out, pair.secret_base64 + "\n", 0o600)
    write_new_file(args.public_out, pair.public_base64 + "\n", 0o644)
    print(pair.public_base64)
    return 0


def command_public_key(_: argparse.Namespace) -> int:
    secret = sys.stdin.read()
    if not secret.strip():
        raise InvalidKeyError("no private key on standard input")
    if len(secret.strip().splitlines()) != 1:
        # Sparkle reads exactly one line from stdin (sign_update/main.swift:57).
        raise InvalidKeyError("private key on standard input must be a single line")
    print(public_key_from_secret(secret))
    return 0


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    generate_parser = commands.add_parser(
        "generate",
        help="create a throwaway key pair (rehearsals only) in Sparkle's --ed-key-file format",
    )
    generate_parser.add_argument("--private-out", type=Path, required=True,
                                 help="new file for the base64 private seed (mode 0600)")
    generate_parser.add_argument("--public-out", type=Path, required=True,
                                 help="new file for the base64 public key (SUPublicEDKey)")
    generate_parser.set_defaults(handler=command_generate)

    public_parser = commands.add_parser(
        "public-key",
        help="read a private key on stdin and print its base64 public key",
    )
    public_parser.set_defaults(handler=command_public_key)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return args.handler(args)
    except (InvalidKeyError, OSError) as error:
        print(f"sparkle_keys: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

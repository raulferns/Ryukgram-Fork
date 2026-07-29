#!/usr/bin/env python3
"""Rebuild the verified Mapping-V8 snapshot from the repository baseline + delta."""
from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
from pathlib import Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def entry_id(entry: str) -> int:
    head, sep, _ = entry.partition(":")
    if not sep or not head.isdigit():
        raise ValueError(f"invalid mapping entry: {entry[:80]!r}")
    return int(head)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("base", type=Path)
    parser.add_argument("delta", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    base_bytes = args.base.read_bytes()
    if args.delta.is_dir():
        parts = sorted(args.delta.glob("part*"))
        if not parts:
            raise SystemExit("Mapping-V8 delta directory contains no part files")
        expected = [f"part{i:02d}" for i in range(len(parts))]
        actual = [part.name for part in parts]
        if actual != expected:
            raise SystemExit(f"Mapping-V8 delta parts are not contiguous: {actual}")
        delta_bytes = b"".join(part.read_bytes() for part in parts)
        delta_bytes = gzip.decompress(base64.b64decode(delta_bytes))
    else:
        delta_bytes = args.delta.read_bytes()
        if args.delta.name.endswith(".gz.b64"):
            delta_bytes = gzip.decompress(base64.b64decode(delta_bytes))
    delta = json.loads(delta_bytes)
    if sha256(base_bytes) != delta["base_sha256"]:
        raise SystemExit("id mapping baseline SHA-256 mismatch; refusing a stale delta")

    base = json.loads(base_bytes)
    by_id = {entry_id(entry): entry for entry in base}
    for config_id in delta["remove_ids"]:
        by_id.pop(int(config_id), None)
    for config_id, entry in delta["upsert"].items():
        parsed = entry_id(entry)
        if parsed != int(config_id):
            raise SystemExit(f"delta id mismatch: key={config_id} entry={parsed}")
        by_id[parsed] = entry

    order = [int(value) for value in delta["order"]]
    if len(order) != len(set(order)):
        raise SystemExit("target order contains duplicate IDs")
    missing = [value for value in order if value not in by_id]
    extra = sorted(set(by_id) - set(order))
    if missing or extra:
        raise SystemExit(f"delta coverage mismatch missing={missing[:8]} extra={extra[:8]}")

    result = [by_id[value] for value in order]
    if len(result) != int(delta["target_entry_count"]):
        raise SystemExit("target entry count mismatch")

    output = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if sha256(output) != delta["target_sha256"]:
        raise SystemExit("generated Mapping-V8 SHA-256 mismatch")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(output)
    print(f"generated {args.output} ({len(result)} entries, sha256={sha256(output)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

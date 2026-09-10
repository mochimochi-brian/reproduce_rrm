#!/usr/bin/env python3
"""Validate the ordered parallel vertex contract and hash its exact bytes."""

import argparse
import hashlib
from pathlib import Path
import re
import sys


def natural(value: bytes) -> int:
    if not re.fullmatch(rb"0|[1-9][0-9]*", value):
        raise ValueError("expected a canonical nonnegative integer")
    return int(value)


def validate_map(path: Path, expected_count: int) -> str:
    """Read one row at a time; memory is O(permutation degree)."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        def fields() -> list[bytes]:
            line = stream.readline()
            if not line.endswith(b"\n") or b"\r" in line:
                raise ValueError("missing LF-terminated record")
            digest.update(line)
            return line[:-1].split(b"\t")

        header = fields()
        if len(header) != 5 or header[:2] != [b"RRM_VERTEX_MAP", b"1"]:
            raise ValueError("invalid vertex-map header or version")
        count, neq, degree = map(natural, header[2:])
        if count != expected_count or count < neq or (neq == 0 and count != 0):
            raise ValueError("vertex-map count mismatch")
        previous_eq = 0
        previous_identity = None
        for vertex_id in range(1, count + 1):
            row = fields()
            if len(row) != 4 + degree:
                raise ValueError("invalid vertex-map row width")
            vid, eq, original, inverted = map(natural, row[:4])
            if vid != vertex_id or not 1 <= eq <= neq:
                raise ValueError("invalid vertex ID or EQ number")
            if eq not in (previous_eq, previous_eq + 1):
                raise ValueError("EQ blocks must be contiguous and ordered")
            if not 1 <= original <= eq or inverted != int(original != eq):
                raise ValueError("invalid original EQ or inversion flag")
            identity = (original, inverted)
            if eq == previous_eq and identity != previous_identity:
                raise ValueError("inconsistent identity within an EQ block")
            previous_eq, previous_identity = eq, identity
            images = [natural(value) for value in row[4:]]
            if len(set(images)) != degree or any(not 1 <= p <= degree for p in images):
                raise ValueError("invalid permutation point images")
        if previous_eq != neq:
            raise ValueError("missing EQ block")
        if fields() != [b"END", str(count).encode("ascii")]:
            raise ValueError("invalid completion record")
        if stream.read(1):
            raise ValueError("trailing data after completion record")
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expected_count", type=int)
    parser.add_argument("path", type=Path)
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()
    try:
        digest = validate_map(args.path, args.expected_count)
        if args.expected_sha256 is not None:
            if not re.fullmatch(r"[0-9a-f]{64}", args.expected_sha256):
                raise ValueError("invalid expected SHA-256")
            if digest != args.expected_sha256:
                raise ValueError("vertex-map SHA-256 mismatch")
    except (OSError, ValueError) as error:
        print(f"vertex map {args.path}: {error}", file=sys.stderr)
        return 1
    print(digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())

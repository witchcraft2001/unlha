#!/usr/bin/env python3
"""Build synthetic mixed-method LHA archives from existing test archives.

LHA archives are a sequence of records followed by a zero header-size byte.
For regression tests we can concatenate whole records from existing archives
and write one final terminator. This avoids needing a host LHA encoder.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def record_area(path: Path) -> bytes:
    data = path.read_bytes()
    pos = 0
    records = 0
    while pos < len(data):
        header_size = data[pos]
        if header_size == 0:
            if records == 0:
                raise ValueError(f"{path}: no records before terminator")
            return data[:pos]
        if pos + 2 + header_size > len(data):
            raise ValueError(f"{path}: truncated header at offset {pos}")
        packed = int.from_bytes(data[pos + 7 : pos + 11], "little")
        end = pos + 2 + header_size + packed
        if end > len(data):
            raise ValueError(f"{path}: truncated packed data at offset {pos}")
        records += 1
        pos = end
    raise ValueError(f"{path}: missing archive terminator")


def write_mix(out_path: Path, inputs: list[Path]) -> None:
    body = b"".join(record_area(path) for path in inputs)
    out_path.write_bytes(body + b"\x00")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("out_dir", type=Path)
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[1]
    test = repo / "test"
    args.out_dir.mkdir(parents=True, exist_ok=True)

    mixes = {
        "MIXL1L5.LZH": [test / "GS19.LZH", test / "clock.lzh"],
        "MIXL5L1.LZH": [test / "clock.lzh", test / "GS19.LZH"],
        "MIXWPL5.LZH": [test / "WINPROFI.LZH", test / "clock.lzh"],
        "MIXL5WP.LZH": [test / "clock.lzh", test / "WINPROFI.LZH"],
    }
    for name, inputs in mixes.items():
        out_path = args.out_dir / name
        write_mix(out_path, inputs)
        print(f"  {name} <- " + " + ".join(path.name for path in inputs))


if __name__ == "__main__":
    main()
